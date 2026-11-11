part of 'video_playback.dart';

Future<VideoSource?> showVideoStreamDialog(
  BuildContext context,
  VideoPlaybackData data,
) => showAuralisDialog<VideoSource>(
  context: context,
  builder: (dialog) {
    var text = '';
    bool? extraction;
    String? error;
    var height = data.webOptions.height;
    var fps = data.webOptions.fps;
    var codec = data.webOptions.codec;
    var container = data.webOptions.container;
    var audio = data.webOptions.audioKbps;
    var hdr = data.webOptions.hdr;
    return StatefulBuilder(
      builder: (context, update) {
        final website = extraction ?? isVideoWebsite(Uri.tryParse(text.trim()));
        void submit() {
          final uri = Uri.tryParse(text.trim());
          if (uri == null ||
              !const {'http', 'https'}.contains(uri.scheme) ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty ||
              text.length > 8192) {
            update(() => error = 'Enter an HTTP or HTTPS video URL.');
            return;
          }
          final parts = uri.pathSegments.where((part) => part.isNotEmpty);
          final options = website
              ? VideoWebOptions(
                  height: height,
                  fps: fps,
                  codec: codec,
                  container: container,
                  audioKbps: audio,
                  hdr: hdr,
                )
              : null;
          if (options != null) data.webOptions = options;
          Navigator.pop(
            dialog,
            VideoSource.file(
              uri,
              website ? uri.host : (parts.lastOrNull ?? uri.host),
              webOptions: options,
            ),
          );
        }

        Widget choice<T>(
          String name,
          T value,
          List<T> values,
          String Function(T) label,
          ValueChanged<T> set,
        ) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: DropdownButtonFormField<T>(
            initialValue: value,
            isExpanded: true,
            decoration: InputDecoration(labelText: name),
            items: [
              for (final item in values)
                DropdownMenuItem(value: item, child: Text(label(item))),
            ],
            onChanged: (next) {
              if (next != null) update(() => set(next));
            },
          ),
        );

        return AuralisDialog(
          title: const Text('Open video stream'),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                autofocus: true,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.go,
                onChanged: (value) {
                  final wasWebsite = isVideoWebsite(Uri.tryParse(text.trim()));
                  text = value;
                  if (extraction == null &&
                      wasWebsite !=
                          isVideoWebsite(Uri.tryParse(value.trim()))) {
                    update(() {});
                  }
                },
                onSubmitted: (_) => submit(),
                decoration: InputDecoration(
                  hintText: 'https://…',
                  errorText: error,
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Resolve video website'),
                subtitle: const Text('Use yt-dlp for a web page'),
                value: website,
                onChanged: (next) => update(() => extraction = next),
              ),
              if (website)
                ExpansionTile(
                  title: const Text('Stream quality'),
                  tilePadding: EdgeInsets.zero,
                  children: [
                    choice(
                      'Max resolution',
                      height,
                      VideoWebOptions.heights,
                      (value) => value == 0 ? 'Any resolution' : '${value}p',
                      (value) => height = value,
                    ),
                    choice(
                      'Max frame rate',
                      fps,
                      VideoWebOptions.frameRates,
                      (value) => value == 0 ? 'Any frame rate' : '$value fps',
                      (value) => fps = value,
                    ),
                    choice(
                      'Preferred video codec',
                      codec,
                      VideoWebOptions.codecs,
                      (value) => switch (value) {
                        'avc1' => 'H.264',
                        'av01' => 'AV1',
                        'hev1' => 'HEVC',
                        'vp9' => 'VP9',
                        _ => 'Any codec',
                      },
                      (value) => codec = value,
                    ),
                    choice(
                      'Preferred container',
                      container,
                      VideoWebOptions.containers,
                      (value) =>
                          value.isEmpty ? 'Any container' : value.toUpperCase(),
                      (value) => container = value,
                    ),
                    choice(
                      'Preferred audio bitrate',
                      audio,
                      VideoWebOptions.audioRates,
                      (value) => value == 0 ? 'Automatic' : '$value kbps',
                      (value) => audio = value,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Prefer HDR stream'),
                      value: hdr,
                      onChanged: (next) => update(() => hdr = next),
                    ),
                  ],
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel'),
            ),
            FilledButton(onPressed: submit, child: const Text('Open')),
          ],
        );
      },
    );
  },
);
