import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_popups.dart';
import 'video_playback_data.dart';

const _encoder = MethodChannel('app.auralis/video');
const _storage = MethodChannel('app.auralis/platform');

bool isEditableVideo(VideoSource source) =>
    source.canPlay &&
    source.uri?.scheme == (Platform.isAndroid ? 'content' : 'file');

Future<void> showVideoExport(
  BuildContext context,
  List<VideoSource> sources, {
  Duration? duration,
  Duration? position,
}) async {
  if (!context.mounted) return;
  final local = sources.where(isEditableVideo).toList();
  if (local.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Select a local video file to export.')),
    );
    return;
  }
  await showAuralisDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _VideoExportDialog(local, duration, position),
  );
}

enum _Preset {
  original('Original size', 0, 0),
  high('High · up to 1080p', 1080, 6_000_000),
  balanced('Balanced · up to 720p', 720, 2_500_000),
  small('Small · up to 480p', 480, 1_000_000);

  const _Preset(this.label, this.height, this.bitrate);
  final String label;
  final int height, bitrate;
}

enum _ClipCrop {
  original('Keep framing', 0, 0),
  wide('Center crop 16:9', 16, 9),
  square('Center crop 1:1', 1, 1),
  portrait('Center crop 9:16', 9, 16);

  const _ClipCrop(this.label, this.width, this.height);
  final String label;
  final int width, height;
}

class _VideoExportDialog extends StatefulWidget {
  const _VideoExportDialog(this.sources, this.duration, this.position);
  final List<VideoSource> sources;
  final Duration? duration, position;

  @override
  State<_VideoExportDialog> createState() => _VideoExportDialogState();
}

class _VideoExportDialogState extends State<_VideoExportDialog> {
  late final _start = TextEditingController(text: '0');
  late final _end = TextEditingController(text: _seconds(_duration));
  late _Preset _preset = _canTrim ? _Preset.original : _Preset.balanced;
  _ClipCrop _crop = _ClipCrop.original;
  bool _mute = false, _busy = false, _encoding = false, _cancelled = false;
  int _completed = 0, _skipped = 0, _failed = 0;
  double? _progress;
  String? _status;
  Process? _process;

  Duration get _duration => widget.duration ?? Duration.zero;
  bool get _canTrim => widget.sources.length == 1 && _duration > Duration.zero;

  String _seconds(Duration value) => (value.inMilliseconds / 1000).toStringAsFixed(3);

  int? _milliseconds(String text) {
    final value = double.tryParse(text.trim());
    return value != null && value.isFinite && value >= 0 &&
        value <= _duration.inMilliseconds / 1000
        ? (value * 1000).round() : null;
  }

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    _process?.kill();
    if (Platform.isAndroid && _encoding) {
      unawaited(_encoder.invokeMethod<void>('cancelExport').catchError((Object _) {}));
    }
    super.dispose();
  }

  Future<void> _cancel() async {
    setState(() => _cancelled = true);
    _process?.kill();
    if (Platform.isAndroid) {
      await _encoder.invokeMethod<void>('cancelExport').catchError((Object _) {});
    }
  }

  Future<void> _encodeAndroid(
    VideoSource source, File output, int start, int? end,
  ) async {
    final timer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      try {
        final progress = await _encoder.invokeMethod<int>('exportProgress');
        if (mounted && _encoding) {
          setState(() => _progress = progress == null ? null : progress / 100);
        }
      } catch (_) {
        // The export result carries the encoder error.
      }
    });
    try {
      await _encoder.invokeMethod<void>('exportVideo', {
        'source': source.uri.toString(),
        'path': output.path,
        'height': _preset.height,
        'bitrate': _preset.bitrate,
        'mute': _mute,
        'crop': _crop.name,
        'start': start,
        'end': end,
      });
    } finally {
      timer.cancel();
    }
  }

  Future<void> _encodeDesktop(
    VideoSource source, File output, int start, int? end,
  ) async {
    final ratio = '${_crop.width}/${_crop.height}';
    final filters = [
      if (_crop != _ClipCrop.original)
        "crop='trunc(min(iw,ih*$ratio)/2)*2':'trunc(min(ih,iw/($ratio))/2)*2'",
      if (_preset.height > 0)
        "scale=-2:'trunc(min(ih,${_preset.height})/2)*2'"
      else
        'scale=trunc(iw/2)*2:trunc(ih/2)*2',
    ];
    final Process process;
    try {
      process = await Process.start('ffmpeg', [
        '-hide_banner', '-loglevel', 'error', '-nostdin',
        '-progress', 'pipe:1', '-nostats',
        if (start > 0) ...['-ss', (start / 1000).toString()],
        '-i', source.uri!.toFilePath(),
        if (end != null) ...['-t', ((end - start) / 1000).toString()],
        '-map', '0:V:0',
        if (_mute) '-an' else ...['-map', '0:a:0?', '-c:a', 'aac', '-b:a', '128k'],
        '-vf', filters.join(','),
        '-c:v', 'libx264', '-preset', 'fast', '-pix_fmt', 'yuv420p',
        if (_preset.bitrate > 0) ...['-b:v', _preset.bitrate.toString()]
        else ...['-crf', '18'],
        '-movflags', '+faststart', '-n', output.path,
      ]);
    } on ProcessException {
      throw const FormatException('FFmpeg with libx264 must be available on PATH.');
    }
    _process = process;
    if (_cancelled || !mounted) process.kill();
    String? lastError;
    final errors = process.stderr.transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter()).forEach((line) => lastError = line);
    final progress = process.stdout.transform(utf8.decoder)
        .transform(const LineSplitter()).forEach((line) {
      if (!line.startsWith('out_time_us=') || !mounted || !_canTrim) return;
      final elapsed = int.tryParse(line.substring('out_time_us='.length));
      final length = (end ?? _duration.inMilliseconds) - start;
      if (elapsed != null && length > 0) {
        setState(() => _progress = (elapsed / (length * 1000)).clamp(0.0, 1.0).toDouble());
      }
    });
    final code = await process.exitCode;
    await Future.wait([errors, progress]);
    _process = null;
    if (code != 0 && !_cancelled) {
      throw FormatException(lastError ?? 'FFmpeg export failed.');
    }
  }

  Future<bool> _publish(File output, String stem, String? destination) async {
    if (Platform.isAndroid) {
      final uri = await _storage.invokeMethod<String>('createDocument', {
        'name': '$stem.mp4', 'mime': 'video/mp4',
      });
      if (uri == null) return false;
      await _storage.invokeMethod<void>('writeVideoDocument', {
        'uri': uri, 'path': output.path,
      });
      return true;
    }
    for (var i = 0; i < 10000; i++) {
      final suffix = i == 0 ? '' : ' ($i)';
      final target = File(p.join(destination!, '$stem$suffix.mp4'));
      try {
        await target.create(exclusive: true);
      } on PathExistsException {
        continue;
      }
      try {
        await output.openRead().pipe(target.openWrite());
      } catch (_) {
        if (await target.exists()) await target.delete();
        rethrow;
      }
      return true;
    }
    throw const FormatException('Too many exports with this file name.');
  }

  Future<void> _run() async {
    final start = _canTrim ? _milliseconds(_start.text) : 0;
    final end = _canTrim ? _milliseconds(_end.text) : null;
    if (start == null || _canTrim && (end == null || end <= start)) {
      setState(() => _status = 'Enter a start and end within the video duration.');
      return;
    }
    final trim = start > 0 || end != null && end < _duration.inMilliseconds;
    setState(() {
      _busy = true;
      _cancelled = false;
      _completed = _skipped = _failed = 0;
      _status = null;
    });
    String? lastError;
    try {
      final destination = Platform.isAndroid ? null : await getDirectoryPath();
      if (!mounted || !Platform.isAndroid && destination == null) return;
      final cache = await getTemporaryDirectory();
      for (var index = 0; index < widget.sources.length && mounted && !_cancelled; index++) {
        final source = widget.sources[index];
        final folder = await cache.createTemp('video-export-');
        final output = File(p.join(folder.path, 'output.mp4'));
        try {
          if (!mounted || _cancelled) break;
          setState(() {
            _encoding = true;
            _progress = null;
            _status = 'Encoding ${index + 1} of ${widget.sources.length} · ${source.title}';
          });
          if (Platform.isAndroid) {
            await _encodeAndroid(source, output, start, trim ? end : null);
          } else {
            await _encodeDesktop(source, output, start, trim ? end : null);
          }
          if (!mounted || _cancelled) break;
          setState(() {
            _encoding = false;
            _status = 'Saving ${source.title}';
          });
          final title = p.basenameWithoutExtension(source.title)
              .replaceAll(RegExp(r'[^\p{L}\p{N}._-]+', unicode: true), '_')
              .characters.take(72).toString();
          final stem = '${title.isEmpty ? 'video' : title}-${trim ? 'clip' : 'export'}';
          if (await _publish(output, stem, destination)) {
            _completed++;
          } else {
            _skipped++;
          }
        } catch (error) {
          if (!_cancelled) {
            _failed++;
            lastError = error is PlatformException ? error.message : error.toString();
          }
        } finally {
          if (await output.exists()) await output.delete();
          await folder.delete();
        }
      }
    } catch (error) {
      _failed++;
      lastError = error.toString();
    } finally {
      if (mounted) {
        setState(() {
          _busy = _encoding = false;
          _progress = null;
          if (_completed + _skipped + _failed > 0 || _cancelled) {
            _status = '${_cancelled ? 'Cancelled · ' : ''}'
                '$_completed saved · $_skipped skipped · $_failed failed'
                '${lastError == null ? '' : '\n$lastError'}';
          }
        });
      }
    }
  }

  Widget _timeInput(String label, TextEditingController controller) => TextField(
    controller: controller,
    enabled: !_busy,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(
      labelText: label,
      suffixIcon: widget.position == null ? null : IconButton(
        tooltip: 'Use current playhead',
        onPressed: _busy ? null : () => controller.text = _seconds(
          Duration(milliseconds: math.min(_duration.inMilliseconds, widget.position!.inMilliseconds)),
        ),
        icon: const Icon(Icons.my_location),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AuralisDialog(
      title: Text(_canTrim ? 'Trim or compress video' : 'Compress videos'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.sources.length == 1 ? widget.sources.first.title : '${widget.sources.length} videos'),
          if (_canTrim) ...[
            _timeInput('Start (seconds)', _start),
            _timeInput('End (seconds)', _end),
            Text('Duration ${_seconds(_duration)} seconds'),
            DropdownButton<_ClipCrop>(
              value: _crop,
              isExpanded: true,
              items: [
                for (final crop in _ClipCrop.values)
                  DropdownMenuItem(value: crop, child: Text(crop.label)),
              ],
              onChanged: _busy ? null : (value) => setState(() => _crop = value!),
            ),
          ],
          DropdownButton<_Preset>(
            value: _preset,
            isExpanded: true,
            items: [
              for (final preset in _Preset.values)
                DropdownMenuItem(value: preset, child: Text(preset.label)),
            ],
            onChanged: _busy ? null : (value) => setState(() => _preset = value!),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Remove audio'),
            value: _mute,
            onChanged: _busy ? null : (value) => setState(() => _mute = value),
          ),
          if (_busy) LinearProgressIndicator(value: _progress),
          if (_status != null) Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_status!),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: !_busy ? () => Navigator.pop(context)
              : _encoding && !_cancelled ? _cancel : null,
          child: Text(_busy ? 'Cancel export' : 'Close'),
        ),
        FilledButton(onPressed: _busy ? null : _run, child: const Text('Export MP4')),
      ],
    ),
  );
}
