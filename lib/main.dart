import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';

import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'android_audio.dart';
import 'android_updater.dart';
import 'data_files.dart';
import 'player.dart';
import 'storage.dart';
import 'android_storage.dart';
import 'telegram/stream_proxy.dart';
import 'telegram/telegram_service.dart';
import 'updater.dart';
import 'sync/controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  RandomAccessFile? lock;
  try {
    final root = await getApplicationSupportDirectory();
    await root.create(recursive: true);
    lock = await File(p.join(root.path, 'session.lock'))
        .open(mode: FileMode.append);
    await lock.lock(FileLock.exclusive);
    final settings = AppSettings(File(p.join(root.path, 'settings.json')));
    String? warning;
    try {
      await settings.load();
    } catch (_) {
      warning = 'Settings could not be read. Defaults are active; select your Telegram channels again.';
    }
    final vault = Platform.isAndroid
        ? AndroidSecretVault(File(p.join(root.path, 'credentials.aesgcm')))
        : SecretVault(File(p.join(root.path, 'credentials.dpapi')));
    final telegram = TelegramService(
      Directory(p.join(root.path, 'telegram')),
      vault,
    );
    final session = Platform.isAndroid ? await AudioSession.instance : null;
    await session?.configure(const AudioSessionConfiguration.music());
    final audio = MpvBackend(session: session);
    await audio.volume(settings.volume);
    final player = PlayerController(
      audio,
      TelegramStreamProxy(telegram.request, releaseAudio: telegram.releaseAudio),
      settings,
    );
    final artworkDirectory = Platform.isAndroid
        ? Directory(
            p.join((await getTemporaryDirectory()).path, 'auralis-media-artwork'),
          )
        : null;
    final handler = Platform.isAndroid
        ? await AudioService.init(
            builder: () => AndroidAudioHandler(
              player,
              loadArtwork: (track) => telegram.ready && track.fileId != null
                  ? telegram.cover(track)
                  : null,
              artworkDirectory: artworkDirectory,
              artworkChanges: telegram,
            ),
            config: const AudioServiceConfig(
              androidNotificationChannelId: 'com.auralis.siam.playback',
              androidNotificationChannelName: 'Music playback',
              androidNotificationIcon: 'drawable/ic_stat_auralis',
              androidStopForegroundOnPause: false,
              artDownscaleWidth: 512,
              artDownscaleHeight: 512,
            ),
          )
        : null;
    if (session != null) handler?.handleInterruptions(session);
    final package = await PackageInfo.fromPlatform();
    final syncVault = Platform.isAndroid
        ? AndroidSecretVault(File(p.join(root.path, 'sync-credentials.aesgcm')))
        : SecretVault(File(p.join(root.path, 'sync-credentials.dpapi')));
    final sync = SyncController(settings, syncVault,
      telegram: telegram,
      onApplied: player.refreshSettings,
      paused: () => player.restoringData,
      deploymentVault: Platform.isAndroid
          ? AndroidSecretVault(File(p.join(root.path, 'sync-deployment.aesgcm')))
          : SecretVault(File(p.join(root.path, 'sync-deployment.dpapi'))),
    );
    telegram.isStreaming = player.proxy.isStreaming;
    telegram.hasActiveStream = () => player.proxy.hasActiveSource;
    AppUpdater? updater;
    Future<void>? shutdownFuture;
    Future<void> shutdown() => shutdownFuture ??= () async {
      try {
        await player.flushListeningStats();
        await sync.close();
        await handler?.close();
        await player.shutdown();
      } finally {
        try {
          await telegram.shutdown();
        } finally {
          await lock?.close();
        }
      }
      updater?.dispose();
    }();
    if (Platform.isAndroid) {
      try {
        const bridge = AndroidUpdateBridge();
        final info = await bridge.info();
        updater = AppUpdater(
          currentVersion: package.version,
          directory: info.directory,
          settings: settings,
          target: UpdateTarget.android,
          androidAbi: info.abi,
          installAndroid: bridge.install,
        );
      } catch (_) {
        warning = [
          ?warning,
          'Android updates could not initialize. Restart Auralis to retry.',
        ].join(' ');
      }
    } else if (Platform.isWindows) {
      updater = AppUpdater(
        currentVersion: package.version,
        directory: Directory(p.join(root.path, 'updates')),
        settings: settings,
        requestExit: () => exitForUpdate(shutdown),
      );
    }
    AppLifecycleListener(
      onResume: () { updater?.checkOnResume(); sync.resume(); },
      onPause: () => unawaited(() async {
        await player.flushListeningStats();
        await sync.flush();
      }()),
      onExitRequested: () async {
        await shutdown();
        return AppExitResponse.exit;
      },
    );
    runApp(
      AuralisApp(
        player: player,
        telegram: telegram,
        startupWarning: warning,
        updater: updater,
        dataFiles: Platform.isAndroid
            ? const AndroidDataFiles()
            : const DataFiles(),
        sync: sync,
        installedVersion: package.version,
      ),
    );
    updater?.start();
    unawaited(sync.start());
    if (telegram.hasApplicationCredentials || await vault.file.exists()) {
      unawaited(telegram.start());
    }
  } catch (_) {
    await lock?.close();
    runApp(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: SelectableText(
                Platform.isAndroid
                    ? 'Auralis could not start.\n\nRestart the app and check available device storage. Reinstall the complete APK if a native library is missing.\n\nSee README.md for setup instructions.'
                    : 'Auralis could not start.\n\nClose any other Auralis window. '
                          'If this persists, extract the complete Windows bundle, including libmpv-2.dll and the data folder. '
                          'Check that your application data folder is writable.\n\nSee README.md for setup instructions.',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<bool> exitForUpdate(Future<void> Function() shutdown) async {
  await shutdown();
  // Windows acknowledges cancelable exits before the shutdown decision completes.
  await ServicesBinding.instance.exitApplication(AppExitType.required);
  return true;
}
