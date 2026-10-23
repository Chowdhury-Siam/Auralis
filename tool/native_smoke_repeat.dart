import 'dart:io';

/// A printed playback report is insufficient: every child must exit cleanly.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    throw ArgumentError(
      'Usage: dart run tool/native_smoke_repeat.dart <libmpv.dll> <tdjson.dll>',
    );
  }
  final script = Platform.script.resolve('native_smoke.dart').toFilePath();
  for (var run = 1; run <= 3; run++) {
    stdout.writeln('Native smoke process $run/3');
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      script,
      ...arguments,
    ]);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode != 0) {
      throw ProcessException(
        Platform.resolvedExecutable,
        [script, ...arguments],
        'Native smoke process $run failed after playback or during shutdown',
        result.exitCode,
      );
    }
  }
  stdout.writeln('All three native smoke processes exited successfully.');
}
