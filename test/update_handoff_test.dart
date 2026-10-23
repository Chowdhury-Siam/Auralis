import 'dart:io';

import 'package:auralis/updater.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('real hidden Windows helper waits for app exit, verifies checksum and preserves spaced paths', () async {
    final dir = await Directory.systemTemp.createTemp(
      'auralis update handoff ',
    );
    final shell =
        '${Platform.environment['SystemRoot']}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
    final script = File('${dir.path}/install-update.ps1');
    await script.writeAsString(installerScript);
    // A real GUI executable catches handoff/exit-code errors hidden by CMD fixtures.
    // It records arguments only; it never installs or opens anything.
    final fixture = File('${dir.path}/installer fixture.exe');
    final ready = File('${dir.path}/update-helper.ready');
    final compiler = File('${dir.path}/make-fixture.ps1');
    await compiler.writeAsString(r'''
param([string]$OutputPath)
$ErrorActionPreference = 'Stop'
$Source = @'
using System;
using System.IO;
public static class Fixture {
  public static int Main(string[] args) {
    string dir = AppDomain.CurrentDomain.BaseDirectory;
    File.WriteAllLines(Path.Combine(dir, "arguments.txt"), args);
    return File.Exists(Path.Combine(dir, "fail.txt")) ? 7 : 0;
  }
}
'@
Add-Type -TypeDefinition $Source -OutputAssembly $OutputPath -OutputType WindowsApplication
''');
    final compiled = await Process.run(shell, [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      compiler.path,
      '-OutputPath',
      fixture.path,
    ]);
    expect(
      compiled.exitCode,
      0,
      reason: '${compiled.stdout}\n${compiled.stderr}',
    );
    final expected = (await sha256.bind(fixture.openRead()).first).toString();
    final parent = await Process.start(shell, [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-Command',
      'Start-Sleep -Seconds 60',
    ]);
    Process? helper;
    try {
      helper = await Process.start(shell, [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
        '-AppProcessId',
        '${parent.pid}',
        '-Installer',
        fixture.path,
        '-ExpectedHash',
        expected,
        '-ReadyFile',
        ready.path,
        '-InstallDirectory',
        '${dir.path}/installed app',
      ]);
      await waitForUpdateHelper(
        ready,
        File('${dir.path}/update-error.txt'),
        helper.pid,
      );
      expect(await File('${dir.path}/arguments.txt').exists(), isFalse);
      parent.kill();
      await parent.exitCode;
      final code = await helper.exitCode.timeout(const Duration(seconds: 15));
      final log = File('${dir.path}/update-error.txt');
      expect(
        code,
        0,
        reason: await log.exists()
            ? await log.readAsString()
            : await helper.stderr
                  .transform(const SystemEncoding().decoder)
                  .join(),
      );
      final arguments = await File('${dir.path}/arguments.txt').readAsString();
      expect(arguments, contains('/AURALISUPDATE=1'));
      expect(arguments, contains('installed app'));
      await ready.delete();
      final rejected = await Process.run(shell, [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
        '-AppProcessId',
        '${parent.pid}',
        '-Installer',
        fixture.path,
        '-ExpectedHash',
        'wrong',
        '-ReadyFile',
        ready.path,
        '-InstallDirectory',
        '${dir.path}/installed app',
      ]);
      expect(rejected.exitCode, 1);
      expect(
        await File('${dir.path}/update-error.txt').readAsString(),
        contains('checksum mismatch'),
      );
      await ready.delete();
      await File('${dir.path}/fail.txt')
          .writeAsString('GUI installer exit-code fixture');
      final failedInstaller = await Process.run(shell, [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-AppProcessId',
        '${parent.pid}',
        '-Installer',
        fixture.path,
        '-ExpectedHash',
        expected,
        '-ReadyFile',
        ready.path,
        '-InstallDirectory',
        '${dir.path}/installed app',
      ]);
      expect(failedInstaller.exitCode, 1);
      expect(
        await File('${dir.path}/update-error.txt').readAsString(),
        contains('exit code 7'),
      );
    } finally {
      parent.kill();
      helper?.kill();
      await dir.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);
}
