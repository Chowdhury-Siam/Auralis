import 'package:auralis/telegram/stream_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

// Keep the widget binding separate from real loopback HTTP proxy tests.
void main() {
  testWidgets('idle proxy cleanup can leave the fake widget clock', (
    tester,
  ) async {
    final proxy = TelegramStreamProxy((_) async => {});
    await tester.pump();
    await tester.runAsync(
      () => proxy.stop().timeout(const Duration(seconds: 2)),
    );
    // Previously completed cleanup must not retain the real async zone either.
    await proxy.stop();
    await tester.runAsync(
      () => proxy.close().timeout(const Duration(seconds: 2)),
    );
  });
}
