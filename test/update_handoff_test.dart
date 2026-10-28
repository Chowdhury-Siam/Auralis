@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:auralis/updater.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'installer waits for the requesting process and uses one-step completion',
    () {
      final script = File('tool/installer.iss').readAsStringSync();
      expect(script, contains("{param:AURALISPID|0}"));
      expect(script, contains('WaitForSingleObject(AppProcess, 90000) = 0'));
      expect(script, contains('CloseHandle(AppProcess)'));
      expect(script, contains('if not Result then'));
      expect(script, contains('Check: IsAuralisUpdate'));
      expect(script, contains('Check: not IsAuralisUpdate'));
      expect(script, contains('Flags: nowait skipifsilent runasoriginaluser'));
      expect(script, contains('DisableFinishedPage=yes'));
      expect(script, isNot(contains('postinstall')));
    },
  );

  group('Windows executable handoff', () {
    late Directory dir;
    late File fixture;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp("auralis O'Brien & handoff ");
      addTearDown(() => dir.delete(recursive: true));
      fixture = File('${dir.path}/installer fixture.exe');
      final compiler = File('${dir.path}/make-fixture.ps1');
      await compiler.writeAsString(r'''
param([string]$OutputPath)
$Source = @'
using System;
using System.IO;
public static class Fixture {
  public static int Main(string[] args) {
    string output = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "arguments.txt");
    File.WriteAllLines(output + ".tmp", args);
    File.Move(output + ".tmp", output);
    return 0;
  }
}
'@
Add-Type -TypeDefinition $Source -OutputAssembly $OutputPath -OutputType WindowsApplication
''');
      // Cold PowerShell/.NET startup belongs to setup, not the 30-second
      // executable handoff check. Bound it separately and stop it on failure.
      final compiled = await Process.start(
        '${Platform.environment['SystemRoot']}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          compiler.path,
          '-OutputPath',
          fixture.path,
        ],
      );
      final stdout = compiled.stdout.transform(utf8.decoder).join();
      final stderr = compiled.stderr.transform(utf8.decoder).join();
      await compiled.stdin.close();
      final exitCode = await compiled.exitCode.timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          compiled.kill();
          throw TestFailure(
            'Windows fixture compilation timed out after 90 seconds.',
          );
        },
      );
      expect(exitCode, 0, reason: '${await stdout}\n${await stderr}');
      expect(
        await fixture.exists(),
        isTrue,
        reason: 'Compiler produced no executable.',
      );
    });

    test(
      'real direct Windows executable launch preserves paths and arguments',
      () async {
        final arguments = [
          '/AURALISUPDATE=1',
          '/AURALISPID=$pid',
          '/DIR=${dir.path}/installed app',
          '/LOG=${dir.path}/installer.log',
        ];
        await startWindowsInstaller(fixture, arguments).timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw TestFailure(
            'Windows installer launch timed out after 10 seconds.',
          ),
        );
        final output = File('${dir.path}/arguments.txt');
        final elapsed = Stopwatch()..start();
        while (!await output.exists() &&
            elapsed.elapsed < const Duration(seconds: 10)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          await output.exists(),
          isTrue,
          reason: 'Launched fixture did not write arguments within 10 seconds.',
        );
        expect(await output.readAsLines(), arguments);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }, skip: !Platform.isWindows);
}
