// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "video_output_manager.h"

VideoOutputManager::VideoOutputManager(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {}

void VideoOutputManager::Create(
    int64_t handle,
    VideoOutputConfiguration configuration,
    std::function<void(int64_t, int64_t, int64_t)> texture_update_callback) {
  operations_.Post([this, handle, configuration, texture_update_callback]() {
    if (video_outputs_.find(handle) == video_outputs_.end()) {
      auto output = std::make_unique<VideoOutput>(
          handle, configuration, registrar_, &render_worker_);
      output->SetTextureUpdateCallback(texture_update_callback);
      video_outputs_.emplace(handle, std::move(output));
    }
  });
}

void VideoOutputManager::SetSize(int64_t handle,
                                 std::optional<int64_t> width,
                                 std::optional<int64_t> height) {
  operations_.Post([this, handle, width, height]() {
    auto output = video_outputs_.find(handle);
    if (output != video_outputs_.end()) {
      output->second->SetSize(width, height);
    }
  });
}

void VideoOutputManager::Dispose(int64_t handle,
                                 std::function<void()> on_disposed) {
  operations_.Post([this, handle, on_disposed = std::move(on_disposed)]() {
    video_outputs_.erase(handle);
    on_disposed();
  });
}

VideoOutputManager::~VideoOutputManager() {
  operations_.Post([this]() { video_outputs_.clear(); }).wait();
}
