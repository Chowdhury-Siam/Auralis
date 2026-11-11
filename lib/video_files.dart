import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import 'video_playback_data.dart';

const videoIntentChannel = MethodChannel('app.auralis/video_intents');
const _videoFileChannel = MethodChannel('app.auralis/video');

List<VideoSource> videosFromAndroid(List<Map<Object?, Object?>>? rows) => [
  for (final row in rows ?? const [])
    if (row['uri'] case final String raw)
      if (Uri.tryParse(raw) case final Uri uri when uri.scheme == 'content')
        if (VideoSource.file(
          uri,
          row['name'] is String ? row['name'] as String : 'Video',
        ) case final VideoSource source when source.canPlay)
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
      XTypeGroup(
        label: 'Video files',
        extensions: [
          'mp4', 'mkv', 'webm', 'mov', 'avi', 'm4v', 'mpg', 'mpeg', 'ts',
          'm2ts', 'wmv', 'flv', 'ogv', '3gp',
        ],
      ),
    ],
  );
  return [
    for (final file in files) VideoSource.file(File(file.path).uri, file.name),
  ];
}
