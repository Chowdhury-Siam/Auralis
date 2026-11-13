import 'dart:io';
import 'dart:typed_data' show BytesBuilder;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'playlist_photo_data.dart';
export 'playlist_photo_data.dart';

class PlaylistPhotoStore {
  PlaylistPhotoStore({this.directory});
  final Directory? directory;
  static final shared = PlaylistPhotoStore();
  static const maxInputBytes = 12 * 1024 * 1024;

  Future<Directory> _root() async =>
      directory ??
      Directory(
        '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}playlist-photos',
      );
  Future<File> file(String token) async {
    if (!PlaylistPhotos.validToken(token)) {
      throw const FormatException('Invalid photo.');
    }
    return File('${(await _root()).path}${Platform.pathSeparator}$token');
  }

  Future<Uint8List?> pick() async {
    if (Platform.isAndroid) {
      const platform = MethodChannel('app.auralis/platform');
      final uri = await platform.invokeMethod<String>('openDocument', {
        'mime': 'image/*',
      });
      if (uri == null) return null;
      final bytes = await platform.invokeMethod<Uint8List>('readDocument', {
        'uri': uri,
        'maxBytes': maxInputBytes,
      });
      if (bytes == null || bytes.length > maxInputBytes) {
        throw const FormatException('Choose an image smaller than 12 MiB.');
      }
      return bytes;
    }
    final selected = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Playlist photo',
          extensions: ['png', 'jpg', 'jpeg', 'webp'],
        ),
      ],
    );
    if (selected == null) return null;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in File(
      selected.path,
    ).openRead(0, maxInputBytes + 1)) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.length > maxInputBytes) {
      throw const FormatException('Choose an image smaller than 12 MiB.');
    }
    return bytes;
  }

  Future<String> store(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxInputBytes) {
      throw const FormatException('Choose a valid image smaller than 12 MiB.');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width <= 0 ||
          descriptor.height <= 0 ||
          descriptor.width > 16384 ||
          descriptor.height > 16384 ||
          descriptor.width * descriptor.height > 64000000) {
        throw const FormatException(
          'The selected image dimensions are too large.',
        );
      }
      final ratio =
          512 /
          (descriptor.width > descriptor.height
              ? descriptor.width
              : descriptor.height);
      codec = await descriptor.instantiateCodec(
        targetWidth: ratio < 1
            ? (descriptor.width * ratio).round().clamp(1, 512)
            : descriptor.width,
        targetHeight: ratio < 1
            ? (descriptor.height * ratio).round().clamp(1, 512)
            : descriptor.height,
      );
      image = (await codec.getNextFrame()).image;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null || png.lengthInBytes > 1536 * 1024) {
        throw const FormatException('Could not prepare the playlist photo.');
      }
      final normalized = png.buffer.asUint8List(
        png.offsetInBytes,
        png.lengthInBytes,
      );
      final token = '${sha256.convert(normalized)}.png';
      final target = await file(token);
      await target.parent.create(recursive: true);
      if (!await target.exists() ||
          await target.length() != normalized.length ||
          sha256.convert(await target.readAsBytes()).toString() !=
              token.substring(0, 64)) {
        final temporary = File(
          '${target.path}.${DateTime.now().microsecondsSinceEpoch}.partial',
        );
        try {
          await temporary.writeAsBytes(normalized, flush: true);
          await temporary.rename(target.path);
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
      }
      return token;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Future<void> discard(String? token, PlaylistPhotos photos) async {
    if (token == null || photos.uses(token)) return;
    try {
      final target = await file(token);
      if (await target.exists() && !photos.uses(token)) await target.delete();
    } catch (_) {
      // A cache cleanup failure must not undo a saved playlist edit.
    }
  }
}

class PlaylistPhoto extends StatefulWidget {
  const PlaylistPhoto({
    super.key,
    required this.token,
    required this.fallback,
    this.store,
  });
  final String? token;
  final Widget fallback;
  final PlaylistPhotoStore? store;
  @override
  State<PlaylistPhoto> createState() => _PlaylistPhotoState();
}

class _PlaylistPhotoState extends State<PlaylistPhoto> {
  late Future<File>? _file = _load();
  Future<File>? _load() => widget.token == null
      ? null
      : (widget.store ?? PlaylistPhotoStore.shared).file(widget.token!);
  @override
  void didUpdateWidget(covariant PlaylistPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.token != widget.token || oldWidget.store != widget.store) {
      _file = _load();
    }
  }

  @override
  Widget build(BuildContext context) => _file == null
      ? widget.fallback
      : FutureBuilder<File>(
          future: _file,
          builder: (_, snapshot) {
            if (!snapshot.hasData) return widget.fallback;
            return Image.file(
              snapshot.data!,
              fit: BoxFit.cover,
              cacheWidth: 512,
              gaplessPlayback: false,
              errorBuilder: (_, _, _) => widget.fallback,
            );
          },
        );
}

Future<void> editPlaylistPhoto({
  required BuildContext context,
  required PlaylistPhotos photos,
  required String mode,
  required String scope,
  required String name,
  required bool reset,
  required bool Function() valid,
  required Future<void> Function() save,
  required VoidCallback refresh,
  PlaylistPhotoStore? store,
}) async {
  final files = store ?? PlaylistPhotoStore.shared;
  final generation = photos.begin(mode, scope, name);
  final previous = photos.photo(mode, scope, name);
  String? token;
  bool current() =>
      context.mounted &&
      valid() &&
      photos.current(mode, scope, name, generation);
  try {
    if (!reset) {
      final bytes = await files.pick();
      if (bytes == null || !current()) return;
      token = await files.store(bytes);
    }
    if (!current()) {
      await files.discard(token, photos);
      return;
    }
    photos.set(mode, scope, name, token);
    try {
      await save();
    } catch (_) {
      if (photos.current(mode, scope, name, generation)) {
        photos.set(mode, scope, name, previous);
      }
      rethrow;
    }
    if (current()) refresh();
    await files.discard(previous, photos);
  } catch (_) {
    await files.discard(token, photos);
    if (context.mounted && valid()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not change the playlist photo. Try another image.',
          ),
        ),
      );
    }
  }
}
