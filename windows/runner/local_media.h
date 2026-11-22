#ifndef RUNNER_LOCAL_MEDIA_H_
#define RUNNER_LOCAL_MEDIA_H_

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>

class LocalMedia {
 public:
  static constexpr UINT kReady = WM_APP + 122;
  LocalMedia(HWND window, flutter::BinaryMessenger* messenger);
  ~LocalMedia();

  void Deliver();

 private:
  using Value = flutter::EncodableValue;
  using Result = flutter::MethodResult<Value>;

  struct Request {
    bool artwork;
    std::string path;
    std::unique_ptr<Result> reply;
  };

  void Work();

  HWND window_;
  flutter::MethodChannel<Value> channel_;
  std::mutex mutex_;
  std::condition_variable ready_;
  bool closed_ = false;
  std::deque<Request> requests_;
  std::deque<std::pair<std::unique_ptr<Result>, Value>> completed_;
  std::vector<std::thread> workers_;
};

#endif  // RUNNER_LOCAL_MEDIA_H_
