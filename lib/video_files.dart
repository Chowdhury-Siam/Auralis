import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import 'video_duration.dart';
import 'video_playback_data.dart';

const videoIntentChannel = MethodChannel('app.auralis/video_intents');
const _videoFileChannel = MethodChannel('app.auralis/video');

const videoExtensions = [
  'mp4',
  'mkv',
  'webm',
  'mov',
  'avi',
  'm4v',
  'mpg',
  'mpeg',
  'ts',
  'm2ts',
  'wmv',
  'flv',
  'ogv',
  '3gp',
];

List<VideoSource> videosFromAndroid(List<Map<Object?, Object?>>? rows) => [
  for (final row in rows ?? const [])
    if (row['uri'] case final String raw)
      if (Uri.tryParse(raw) case final Uri uri when uri.scheme == 'content')
        if (VideoSource.file(
              uri,
              row['name'] is String ? row['name'] as String : 'Video',
            )
            case final VideoSource source when source.canPlay)
          source,
];

Future<List<VideoSource>> pickVideoFiles() async {
  if (Platform.isAndroid) {
    return videosFromAndroid(
      await _videoFileChannel.invokeListMethod<Map<Object?, Object?>>(
        'openFiles',
      ),
    );
  }
  final files = await openFiles(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Video files', extensions: videoExtensions),
    ],
  );
  return [
    for (final file in files) VideoSource.file(File(file.path).uri, file.name),
  ];
}

Future<Duration?> readLocalVideoDuration(VideoSource source) async {
  final uri = source.uri;
  if (uri == null) return null;
  if (Platform.isAndroid && uri.scheme == 'content') {
    final millis = await _videoFileChannel.invokeMethod<int>(
      'videoDuration',
      uri.toString(),
    );
    return millis == null || millis <= 0
        ? null
        : Duration(milliseconds: millis);
  }
  if (uri.scheme != 'file') return null;
  final file = await File.fromUri(uri).open();
  try {
    return await readVideoDuration((offset, length) async {
      await file.setPosition(offset);
      return file.read(length);
    }, await file.length());
  } finally {
    await file.close();
  }
}
