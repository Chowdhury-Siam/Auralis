#include "music_visualizer.h"

#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <ks.h>
#include <ksmedia.h>
#include <mmreg.h>
#include <wrl/client.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <cmath>
#include <cstring>

using Microsoft::WRL::ComPtr;
using flutter::EncodableMap;
using flutter::EncodableValue;

MusicVisualizer::MusicVisualizer(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "app.auralis/visualizer",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "start") {
      Stop();
      running_ = true;
      status_ = 1;
      thread_ = std::thread(&MusicVisualizer::Capture, this);
      result->Success();
    } else if (call.method_name() == "stop") {
      Stop();
      result->Success();
    } else if (call.method_name() == "read") {
      if (status_ < 0) {
        result->Error("capture", "Windows output audio is unavailable. Check the output device and try again.");
      } else {
        std::lock_guard<std::mutex> lock(mutex_);
        if (samples_.empty()) result->Success();
        else result->Success(EncodableValue(EncodableMap{
          {EncodableValue("samples"), EncodableValue(samples_)},
          {EncodableValue("rate"), EncodableValue(rate_)}
        }));
      }
    } else {
      result->NotImplemented();
    }
  });
}

MusicVisualizer::~MusicVisualizer() {
  channel_->SetMethodCallHandler(nullptr);
  Stop();
}

void MusicVisualizer::Stop() {
  running_ = false;
  if (thread_.joinable()) thread_.join();
  status_ = 0;
  std::lock_guard<std::mutex> lock(mutex_);
  samples_.clear();
}

void MusicVisualizer::Capture() {
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized)) { status_ = -1; return; }
  auto capture = [this]() -> HRESULT {
    ComPtr<IMMDeviceEnumerator> enumerator;
    ComPtr<IMMDevice> device;
    ComPtr<IAudioClient> client;
    ComPtr<IAudioCaptureClient> reader;
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
        CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
    if (FAILED(hr)) return hr;
    hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    if (FAILED(hr)) return hr;
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
        reinterpret_cast<void**>(client.GetAddressOf()));
    if (FAILED(hr)) return hr;
    WAVEFORMATEX* allocated = nullptr;
    hr = client->GetMixFormat(&allocated);
    if (FAILED(hr)) return hr;
    // Keep the format alive throughout capture.
    std::unique_ptr<WAVEFORMATEX, decltype(&CoTaskMemFree)> format(allocated, CoTaskMemFree);
    bool floating = format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
    bool pcm = format->wFormatTag == WAVE_FORMAT_PCM;
    if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
        format->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
      const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format.get());
      floating = IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
      pcm = IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_PCM);
    }
    if ((!floating && !pcm) || (floating && format->wBitsPerSample != 32) ||
        (pcm && format->wBitsPerSample != 16 && format->wBitsPerSample != 24 &&
         format->wBitsPerSample != 32) || !format->nChannels) return E_NOTIMPL;
    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK,
        1000000, 0, format.get(), nullptr);
    if (FAILED(hr)) return hr;
    hr = client->GetService(IID_PPV_ARGS(&reader));
    if (FAILED(hr)) return hr;
    hr = client->Start();
    if (FAILED(hr)) return hr;
    std::vector<uint8_t> ring(1024, 128);
    size_t cursor = 0;
    status_ = 2;
    while (running_) {
      UINT32 frames = 0;
      hr = reader->GetNextPacketSize(&frames);
      if (FAILED(hr)) break;
      bool changed = false;
      while (frames && running_) {
        BYTE* bytes = nullptr;
        DWORD flags = 0;
        hr = reader->GetBuffer(&bytes, &frames, &flags, nullptr, nullptr);
        if (FAILED(hr)) break;
        const unsigned step = format->wBitsPerSample / 8;
        for (UINT32 i = 0; i < frames; ++i) {
          double mono = 0;
          if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT) && bytes) {
            for (unsigned channel = 0; channel < format->nChannels; ++channel) {
              const BYTE* sample = bytes + i * format->nBlockAlign + channel * step;
              if (floating) {
                float value;
                std::memcpy(&value, sample, sizeof(value));
                if (std::isfinite(value)) mono += value;
              } else {
                int32_t value = 0;
                if (step == 2) {
                  int16_t pcm_sample;
                  std::memcpy(&pcm_sample, sample, sizeof(pcm_sample));
                  value = pcm_sample;
                  mono += value / 32768.0;
                } else if (step == 3) {
                  value = sample[0] | (sample[1] << 8) | (sample[2] << 16);
                  if (value & 0x800000) value |= ~0xffffff;
                  mono += value / 8388608.0;
                } else {
                  std::memcpy(&value, sample, 4);
                  mono += value / 2147483648.0;
                }
              }
            }
            mono /= format->nChannels;
          }
          ring[cursor] = static_cast<uint8_t>(std::clamp(mono * 127.0 + 128.0, 0.0, 255.0));
          cursor = (cursor + 1) % ring.size();
        }
        hr = reader->ReleaseBuffer(frames);
        if (FAILED(hr)) break;
        changed = true;
        hr = reader->GetNextPacketSize(&frames);
        if (FAILED(hr)) break;
      }
      if (FAILED(hr)) break;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        rate_ = static_cast<int>(format->nSamplesPerSec);
        samples_.resize(ring.size());
        for (size_t i = 0; i < ring.size(); ++i)
          samples_[i] = changed ? ring[(cursor + i) % ring.size()] : 128;
      }
      Sleep(15);
    }
    client->Stop();
    return hr;
  };
  const HRESULT hr = capture();
  if (FAILED(hr) && running_) status_ = -1;
  CoUninitialize();
}
