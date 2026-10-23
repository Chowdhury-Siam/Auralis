import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import 'data_backup.dart';
import 'storage.dart';

class DataFiles {
  const DataFiles();

  Future<String?> savePath(String name, String extension) async =>
      (await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: [
          XTypeGroup(label: extension.toUpperCase(), extensions: [extension]),
        ],
      ))?.path;

  Future<String?> openBackup() async => (await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Auralis backup', extensions: ['json']),
    ],
  ))?.path;

  Future<String?> openLyrics() async => (await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'LRC lyrics', extensions: ['lrc']),
    ],
  ))?.path;

  Future<Uint8List> readBytes(
    String path, {
    int maxBytes = DataBackup.maxBytes,
  }) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in File(path).openRead(0, maxBytes + 1)) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.length > maxBytes) {
      throw const FormatException('Selected file exceeds the size limit.');
    }
    return bytes;
  }

  Future<String> read(String path) async => utf8.decode(await readBytes(path));

  Future<void> write(String path, String text) =>
      atomicWrite(File(path), utf8.encode(text));
}

/// Android document URIs are not filesystem paths; use the Storage Access Framework.
class AndroidDataFiles extends DataFiles {
  const AndroidDataFiles();
  static const _channel = MethodChannel('app.auralis/platform');
  @override
  Future<String?> savePath(String name, String extension) =>
      _channel.invokeMethod<String>('createDocument', {
        'name': name,
        'mime': extension == 'csv' ? 'text/csv' : 'application/json',
      });
  @override
  Future<String?> openBackup() => _channel.invokeMethod<String>('openDocument');
  @override
  Future<String?> openLyrics() => _channel.invokeMethod<String>('openDocument');

  @override
  Future<Uint8List> readBytes(
    String path, {
    int maxBytes = DataBackup.maxBytes,
  }) async {
    if (Uri.tryParse(path)?.scheme != 'content') {
      return super.readBytes(path, maxBytes: maxBytes);
    }
    final bytes = await _channel.invokeMethod<Uint8List>('readDocument', {
      'uri': path,
      'maxBytes': maxBytes,
    });
    if (bytes == null || bytes.length > maxBytes) {
      throw const FormatException(
        'Could not read the selected file within its size limit.',
      );
    }
    return bytes;
  }

  @override
  Future<void> write(String path, String text) async {
    if (Uri.tryParse(path)?.scheme != 'content') return super.write(path, text);
    final bytes = utf8.encode(text);
    if (bytes.length > DataBackup.maxBytes) {
      throw const FormatException('Export exceeds 64 MiB.');
    }
    await _channel.invokeMethod<void>('writeDocument', {
      'uri': path,
      'bytes': bytes,
    });
  }
}
