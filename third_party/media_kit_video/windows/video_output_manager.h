// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#ifndef VIDEO_OUTPUT_MANAGER_H_
#define VIDEO_OUTPUT_MANAGER_H_

#include <flutter/plugin_registrar_windows.h>

#include <unordered_map>

#include "thread_pool.h"
#include "video_output.h"

// Creates & disposes |VideoOutput| instances for video embedding.
//
// The methods in this class are thread-safe & run on separate worker thread so
// that they don't block Flutter's UI thread while platform channels are being
// invoked.
class VideoOutputManager {
 public:
  VideoOutputManager(flutter::PluginRegistrarWindows* registrar);

  // Creates a new |VideoOutput| instance. It's texture ID may be used to render
  // the video. The changes in it's texture ID & video dimensions will be
  // notified via the |texture_update_callback|.
  void Create(
      int64_t handle,
      VideoOutputConfiguration configuration,
      std::function<void(int64_t, int64_t, int64_t)> texture_update_callback);

  // Sets the required video output size.
  // This forces |VideoOutput| to resize the internal OpenGL surface / D3D
  // texture.
  void SetSize(int64_t handle,
               std::optional<int64_t> width,
               std::optional<int64_t> height);

  // Replies after the texture and mpv render context have been released.
  void Dispose(int64_t handle, std::function<void()> on_disposed);

  ~VideoOutputManager();

 private:
  // The render worker owns all EGL and mpv render calls. A separate FIFO
  // worker orders channel requests and can wait for the render worker.
  ThreadPool render_worker_{1};
  flutter::PluginRegistrarWindows* registrar_ = nullptr;
  std::unordered_map<int64_t, std::unique_ptr<VideoOutput>> video_outputs_;
  ThreadPool operations_{1};
};

#endif  // VIDEO_OUTPUT_MANAGER_H_
