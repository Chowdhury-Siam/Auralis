/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:collection';
import 'dart:ffi';
import 'dart:io';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:media_kit/src/player/native/utils/isolates.dart';
import 'package:synchronized/synchronized.dart';

/// {@template initializer_native_callable}
///
/// InitializerNativeCallable
/// -------------------------
/// Initializes [Pointer<mpv_handle>] & notifies about events through the supplied callback.
///
/// {@endtemplate}
class InitializerNativeCallable {
  /// Singleton instance.
  static InitializerNativeCallable? _instance;

  /// {@macro initializer}
  InitializerNativeCallable._(this.mpv);

  /// {@macro initializer}
  factory InitializerNativeCallable(generated.MPV mpv) {
    _instance ??= InitializerNativeCallable._(mpv);
    return _instance!;
  }

  /// Generated libmpv C API bindings.
  final generated.MPV mpv;

  /// Creates [Pointer<mpv_handle>].
  Future<Pointer<generated.mpv_handle>> create(
    Future<void> Function(Pointer<generated.mpv_event>) callback, {
    Map<String, String> options = const {},
  }) async {
    final mtaCookie = Platform.isWindows ? _retainWindowsMta() : nullptr;
    final ctx = mpv.mpv_create();
    if (ctx == nullptr) {
      _releaseWindowsMta(mtaCookie);
      throw StateError('libmpv could not create a player');
    }
    for (final entry in options.entries) {
      final name = entry.key.toNativeUtf8();
      final value = entry.value.toNativeUtf8();
      mpv.mpv_set_option_string(ctx, name.cast(), value.cast());
      calloc.free(name);
      calloc.free(value);
    }
    final status = mpv.mpv_initialize(ctx);
    if (status < 0) {
      mpv.mpv_destroy(ctx);
      _releaseWindowsMta(mtaCookie);
      throw StateError('libmpv initialization failed: $status');
    }
    final nativeCallable = WakeUpNativeCallable.listener(_callback);
    final nativeFunction = nativeCallable.nativeFunction;
    _locks[ctx.address] = Lock();
    _eventCallbacks[ctx.address] = callback;
    _wakeUpNativeCallables[ctx.address] = nativeCallable;
    if (mtaCookie != nullptr) _windowsMtaCookies[ctx.address] = mtaCookie;
    mpv.mpv_set_wakeup_callback(ctx, nativeFunction.cast(), ctx.cast());
    return ctx;
  }

  /// Disposes [Pointer<mpv_handle>].
  void dispose(Pointer<generated.mpv_handle> ctx) {
    _locks.remove(ctx.address);
    _eventCallbacks.remove(ctx.address);

    // Clear the wakeup callback in libmpv before closing NativeCallable
    // to prevent libmpv from invoking a deleted callback
    mpv.mpv_set_wakeup_callback(ctx, nullptr, nullptr);

    _wakeUpNativeCallables.remove(ctx.address)?.close();
  }

  /// Windows must join the native core before releasing its Dart callback.
  Future<void> disposeAndDestroy(Pointer<generated.mpv_handle> ctx) async {
    mpv.mpv_set_wakeup_callback(ctx, nullptr, nullptr);
    _eventCallbacks.remove(ctx.address);
    final lock = _locks.remove(ctx.address);
    if (lock != null) await lock.synchronized(() {});
    await compute(_terminateDestroy, (NativeLibrary.path, ctx.address));
    _wakeUpNativeCallables.remove(ctx.address)?.close();
    _releaseWindowsMta(_windowsMtaCookies.remove(ctx.address) ?? nullptr);
  }

  void _callback(Pointer<generated.mpv_handle> ctx) {
    _locks[ctx.address]?.synchronized(() async {
      while (true) {
        if (!_eventCallbacks.containsKey(ctx.address)) return;
        final event = mpv.mpv_wait_event(ctx, 0);
        if (event == nullptr) return;
        if (event.ref.event_id == generated.mpv_event_id.MPV_EVENT_NONE) return;
        await _eventCallbacks[ctx.address]?.call(event);
      }
    });
  }

  final _locks = HashMap<int, Lock>();
  final _eventCallbacks = EventCallbackMap();
  final _wakeUpNativeCallables = WakeUpNativeCallableMap();
  final _windowsMtaCookies = HashMap<int, Pointer<Void>>();
}

typedef WakeUpCallback = Void Function(Pointer<generated.mpv_handle>);
typedef WakeUpNativeCallable = NativeCallable<WakeUpCallback>;
typedef WakeUpNativeCallableMap = HashMap<int, WakeUpNativeCallable>;

typedef EventCallback = Future<void> Function(Pointer<generated.mpv_event>);
typedef EventCallbackMap = HashMap<int, EventCallback>;

void _terminateDestroy((String, int) handle) {
  final mpv = generated.MPV(DynamicLibrary.open(handle.$1));
  mpv.mpv_terminate_destroy(Pointer.fromAddress(handle.$2));
}

Pointer<Void> _retainWindowsMta() {
  // Keep WASAPI COM objects alive across Dart/core thread exits until teardown.
  final ole32 = DynamicLibrary.open('ole32.dll');
  final increment = ole32.lookupFunction<Int32 Function(Pointer<Pointer<Void>>),
      int Function(Pointer<Pointer<Void>>)>('CoIncrementMTAUsage');
  final slot = calloc<Pointer<Void>>();
  try {
    final result = increment(slot);
    if (result < 0 || slot.value == nullptr) {
      throw StateError('Cannot retain Windows COM during libmpv shutdown: '
          '0x${result.toUnsigned(32).toRadixString(16)}');
    }
    return slot.value;
  } finally {
    calloc.free(slot);
  }
}

void _releaseWindowsMta(Pointer<Void> cookie) {
  if (cookie == nullptr) return;
  final decrement = DynamicLibrary.open('ole32.dll').lookupFunction<
      Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('CoDecrementMTAUsage');
  final result = decrement(cookie);
  if (result < 0) {
    throw StateError('Cannot release Windows COM after libmpv shutdown: '
        '0x${result.toUnsigned(32).toRadixString(16)}');
  }
}
