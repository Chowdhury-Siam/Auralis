import 'dart:async';

import 'package:auralis/main.dart' show exitForUpdate;

import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter_test/flutter_test.dart';

class ExitBinding extends AutomatedTestWidgetsFlutterBinding {
  void Function(AppExitType)? onExit;
  @override
  Future<AppExitResponse> exitApplication(
    AppExitType type, [
    int exitCode = 0,
  ]) async {
    onExit?.call(type);
    return type == AppExitType.cancelable
        ? AppExitResponse.cancel
        : AppExitResponse.exit;
  }
}

void main() {
  final binding = ExitBinding();
  tearDown(() => binding.onExit = null);

  test('update awaits cleanup then requests required Windows exit, never cancelable exit', () async {
    final events = <String>[];
    final cleanup = Completer<void>();
    binding.onExit = (type) {
      expect(type, AppExitType.required);
      events.add('native exit');
    };
    final result = exitForUpdate(() async {
      events.add('cleanup started');
      await cleanup.future;
      events.add('cleanup completed');
    });
    await Future<void>.delayed(Duration.zero);
    expect(events, ['cleanup started']);
    cleanup.complete();
    expect(await result, isTrue);
    expect(events, ['cleanup started', 'cleanup completed', 'native exit']);
  });

  test(
    'cleanup failure preserves the process instead of starting native exit',
    () async {
      var exitRequested = false;
      binding.onExit = (_) {
        exitRequested = true;
      };
      await expectLater(
        exitForUpdate(() async => throw StateError('test cleanup failed')),
        throwsStateError,
      );
      expect(exitRequested, isFalse);
    },
  );
}
