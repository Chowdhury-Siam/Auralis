#include "local_media.h"

#include <shobjidl.h>
#include <propvarutil.h>
#include <wrl/client.h>

#include <initguid.h>
#include <propkey.h>

#include <cstring>

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

std::wstring WidePath(const std::string& value) {
  if (value.empty() || value.size() > 32768 ||
      value.find('\0') != std::string::npos) {
    return {};
  }
  const int size = static_cast<int>(value.size());
  const int count =
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), size,
                          nullptr, 0);
  std::wstring path(count, L'\0');
  if (count) {
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), size,
                        path.data(), count);
  }
  return path;
}

std::string Utf8(const wchar_t* value) {
  if (!value || !*value) return {};
  const int count = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0,
                                        nullptr, nullptr);
  if (count <= 1 || count > 16384) return {};
  std::string text(count, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, -1, text.data(), count, nullptr,
                      nullptr);
  text.pop_back();
  return text;
}

EncodableValue ReadMetadata(IShellItem2* item) {
  ComPtr<IPropertyStore> store;
  if (FAILED(item->GetPropertyStore(GPS_DEFAULT, IID_PPV_ARGS(&store)))) {
    return EncodableValue();
  }

  EncodableMap tags;
  auto text = [&](const PROPERTYKEY& property, const char* field) {
    PROPVARIANT value;
    PropVariantInit(&value);
    if (SUCCEEDED(store->GetValue(property, &value))) {
      PWSTR display = nullptr;
      if (SUCCEEDED(PropVariantToStringAlloc(value, &display))) {
        auto string = Utf8(display);
        if (!string.empty()) {
          tags.emplace(EncodableValue(field), EncodableValue(std::move(string)));
        }
      }
      CoTaskMemFree(display);
    }
    PropVariantClear(&value);
  };
  text(PKEY_Title, "title");
  text(PKEY_Music_Artist, "artist");
  text(PKEY_Music_AlbumTitle, "album");
  text(PKEY_Music_AlbumArtist, "albumArtist");
  text(PKEY_Music_Genre, "genre");
  PROPVARIANT duration;
  PropVariantInit(&duration);
  ULONGLONG ticks = 0;
  if (SUCCEEDED(store->GetValue(PKEY_Media_Duration, &duration)) &&
      SUCCEEDED(PropVariantToUInt64(duration, &ticks)) && ticks >= 10000) {
    tags.emplace(EncodableValue("duration"),
                 EncodableValue(static_cast<int64_t>(ticks / 10000)));
  }
  PropVariantClear(&duration);
  return EncodableValue(std::move(tags));
}

EncodableValue ReadArtwork(IShellItem2* item) {
  ComPtr<IShellItemImageFactory> factory;
  HBITMAP bitmap = nullptr;
  if (FAILED(item->QueryInterface(IID_PPV_ARGS(&factory))) ||
      FAILED(factory->GetImage({144, 144}, SIIGBF_THUMBNAILONLY, &bitmap))) {
    return EncodableValue();
  }

  BITMAP dimensions{};
  std::vector<uint8_t> bytes;
  if (GetObjectW(bitmap, sizeof(dimensions), &dimensions) &&
      dimensions.bmWidth > 0 && dimensions.bmWidth <= 144 &&
      dimensions.bmHeight > 0 && dimensions.bmHeight <= 144) {
    BITMAPINFO info{};
    auto& header = info.bmiHeader;
    header.biSize = sizeof(BITMAPINFOHEADER);
    header.biWidth = dimensions.bmWidth;
    header.biHeight = dimensions.bmHeight;
    header.biPlanes = 1;
    header.biBitCount = 24;
    header.biCompression = BI_RGB;
    const auto stride = (dimensions.bmWidth * 3 + 3) & ~3;
    const DWORD pixel_bytes = stride * dimensions.bmHeight;
    const DWORD offset = sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER);
    BITMAPFILEHEADER file{};
    file.bfType = 0x4d42;
    file.bfSize = offset + pixel_bytes;
    file.bfOffBits = offset;
    bytes.resize(file.bfSize);

    HDC dc = CreateCompatibleDC(nullptr);
    if (!dc || GetDIBits(dc, bitmap, 0, dimensions.bmHeight,
                         bytes.data() + offset, &info, DIB_RGB_COLORS) == 0) {
      bytes.clear();
    } else {
      std::memcpy(bytes.data(), &file, sizeof(file));
      std::memcpy(bytes.data() + sizeof(file), &header, sizeof(header));
    }
    if (dc) DeleteDC(dc);
  }
  DeleteObject(bitmap);
  return bytes.empty() ? EncodableValue() : EncodableValue(std::move(bytes));
}
}  // namespace

LocalMedia::LocalMedia(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window),
      channel_(messenger, "app.auralis/local_media_windows",
               &flutter::StandardMethodCodec::GetInstance()) {
  channel_.SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "metadata" && call.method_name() != "artwork") {
      result->NotImplemented();
      return;
    }
    const auto* path = call.arguments()
                           ? std::get_if<std::string>(call.arguments())
                           : nullptr;
    if (!path || path->empty()) {
      result->Success();
      return;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      requests_.push_back(
          {call.method_name() == "artwork", *path, std::move(result)});
    }
    ready_.notify_one();
  });
  for (int i = 0; i < 3; i++) workers_.emplace_back([this] { Work(); });
}

LocalMedia::~LocalMedia() {
  channel_.SetMethodCallHandler(nullptr);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    closed_ = true;
    requests_.clear();
  }
  ready_.notify_all();
  for (auto& worker : workers_) worker.join();
}

void LocalMedia::Work() {
  const HRESULT apartment =
      CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
  for (;;) {
    Request request;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      ready_.wait(lock, [this] { return closed_ || !requests_.empty(); });
      if (closed_) break;
      request = std::move(requests_.front());
      requests_.pop_front();
    }

    EncodableValue value;
    if (SUCCEEDED(apartment)) {
      const auto path = WidePath(request.path);
      ComPtr<IShellItem2> item;
      if (!path.empty() &&
          SUCCEEDED(SHCreateItemFromParsingName(path.c_str(), nullptr,
                                                IID_PPV_ARGS(&item)))) {
        value = request.artwork ? ReadArtwork(item.Get()) : ReadMetadata(item.Get());
      }
    }

    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (closed_) break;
      completed_.emplace_back(std::move(request.reply), std::move(value));
    }
    PostMessageW(window_, kReady, 0, 0);
  }
  if (SUCCEEDED(apartment)) CoUninitialize();
}

void LocalMedia::Deliver() {
  decltype(completed_) completed;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    completed.swap(completed_);
  }
  for (const auto& [reply, value] : completed) reply->Success(value);
}
