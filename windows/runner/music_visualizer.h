#ifndef RUNNER_MUSIC_VISUALIZER_H_
#define RUNNER_MUSIC_VISUALIZER_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <atomic>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

// WASAPI render-endpoint loopback. No microphone or audio playback device is opened.
class MusicVisualizer {
 public:
  explicit MusicVisualizer(flutter::BinaryMessenger* messenger);
  ~MusicVisualizer();
  void Stop();
 private:
  void Capture();
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::atomic<bool> running_{false};
  std::atomic<int> status_{0};
  std::thread thread_;
  std::mutex mutex_;
  std::vector<uint8_t> samples_;
  int rate_ = 48000;
};
#endif
