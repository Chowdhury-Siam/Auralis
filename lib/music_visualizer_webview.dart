import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as win;

/// A local-only renderer. Audio arrives as bounded waveform messages; this
/// WebView never receives a Telegram URL, account details or microphone access.
class MusicVisualizerWebController {
  MusicVisualizerWebController({this.runScript});
  Future<void> Function(String)? runScript;
  Future<void> execute(String script) async => runScript?.call(script);
}

class MusicVisualizerWebView extends StatefulWidget {
  const MusicVisualizerWebView({
    super.key,
    required this.controller,
    required this.onMessage,
    required this.onError,
  });
  final MusicVisualizerWebController controller;
  final ValueChanged<Map<String, dynamic>> onMessage;
  final ValueChanged<String> onError;

  @override
  State<MusicVisualizerWebView> createState() => _MusicVisualizerWebViewState();
}

class _MusicVisualizerWebViewState extends State<MusicVisualizerWebView> {
  WebViewController? _android;
  win.WebviewController? _windows;
  StreamSubscription<dynamic>? _messages;
  late final Future<void> _initialization;
  bool _closed = false, _initialized = false;

  @override
  void initState() {
    super.initState();
    _initialization = _init();
    unawaited(_initialization);
  }

  void _message(dynamic raw) {
    if (_closed) return;
    try {
      if (raw is String && raw.length <= 200000) {
        final value = jsonDecode(raw);
        if (value is Map<String, dynamic>) widget.onMessage(value);
      }
    } on FormatException {
      widget.onError('The visualizer returned an invalid message.');
    }
  }

  Future<void> _init() async {
    try {
      var html = await rootBundle.loadString('assets/visualizer/index.html');
      for (final entry in const {
        'BUTTERCHURN': 'butterchurn.js',
        'PRESETS': 'presets.js',
        'AUDIOMOTION': 'audiomotion.js',
        'BRIDGE': 'bridge.js',
      }.entries) {
        final script = await rootBundle.loadString(
          'assets/visualizer/${entry.value}',
        );
        html = html.replaceFirst(
          '/*__${entry.key}__*/',
          script.replaceAll('</script', r'<\/script'),
        );
      }
      if (_closed) return;
      if (Platform.isWindows) {
        final controller = _windows = win.WebviewController();
        await controller.initialize();
        if (_closed) return;
        await controller.setBackgroundColor(Colors.transparent);
        await controller.setPopupWindowPolicy(
          win.WebviewPopupWindowPolicy.deny,
        );
        if (_closed) return;
        _messages = controller.webMessage.listen(
          _message,
          onError: (_) {
            if (!_closed) {
              widget.onError('The visualizer message channel stopped.');
            }
          },
        );
        widget.controller.runScript = (script) async {
          if (!_closed) await controller.executeScript(script);
        };
        await controller.loadStringContent(html);
      } else if (Platform.isAndroid) {
        final controller = _android = WebViewController(
          onPermissionRequest: (request) => unawaited(request.deny()),
        );
        await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
        await controller.setBackgroundColor(Colors.transparent);
        await controller.addJavaScriptChannel(
          'AuralisVisuals',
          onMessageReceived: (message) => _message(message.message),
        );
        await controller.setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) =>
                request.url == 'about:blank' ||
                    request.url.startsWith('data:text/html')
                ? NavigationDecision.navigate
                : NavigationDecision.prevent,
            onWebResourceError: (_) {
              if (!_closed) {
                widget.onError(
                  'Android WebView could not load the visualizer.',
                );
              }
            },
          ),
        );
        if (_closed) return;
        widget.controller.runScript = (script) async {
          if (!_closed) await controller.runJavaScript(script);
        };
        await controller.loadHtmlString(html);
      } else {
        throw UnsupportedError('Visualizers support Android and Windows.');
      }
      if (!_closed) setState(() => _initialized = true);
    } catch (_) {
      if (!_closed) {
        widget.onError(
          Platform.isWindows
              ? 'The visualizer needs Microsoft Edge WebView2 and a compatible GPU. Install or repair WebView2, then retry.'
              : 'The visualizer needs an up-to-date Android System WebView and a compatible GPU.',
        );
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    widget.controller.runScript = null;
    unawaited(_release());
    super.dispose();
  }

  Future<void> _release() async {
    // Initialization can still be awaiting a native WebView when the user
    // switches back to Lyrics. Release it exactly once, after setup settles.
    await _initialization;
    await _messages?.cancel();
    final windows = _windows;
    if (windows != null && windows.value.isInitialized) {
      try {
        await windows.executeScript('window.auralisVisuals?.destroy()');
      } catch (_) {
        // The document or engine may already have closed.
      }
      try {
        await windows.dispose();
      } catch (_) {}
    }
    final android = _android;
    if (android != null) {
      try {
        await android.runJavaScript('window.auralisVisuals?.destroy()');
        await android.loadHtmlString('');
      } catch (_) {
        // Android disposes the platform view when its widget is removed.
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) return const Center(child: CircularProgressIndicator());
    if (_windows case final controller?) {
      return win.Webview(
        controller,
        permissionRequested: (_, _, _) => win.WebviewPermissionDecision.deny,
      );
    }
    return WebViewWidget(controller: _android!);
  }
}
