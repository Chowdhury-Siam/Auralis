import 'dart:io';

import 'package:auralis/updater.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('installer waits for the requesting process and only update installs reopen automatically', () {
    final script = File('tool/installer.iss').readAsStringSync();
    expect(script, contains("{param:AURALISPID|0}"));
    expect(script, contains('WaitForSingleObject(AppProcess, 90000) = 0'));
    expect(script, contains('CloseHandle(AppProcess)'));
    expect(script, contains('if not Result then'));
    expect(script, contains('Check: IsAuralisUpdate'));
    expect(script, contains('Check: not IsAuralisUpdate'));
  });

  test('real direct Windows executable launch preserves paths and arguments', () async {
    final dir = await Directory.systemTemp.createTemp(
      "auralis O'Brien & handoff ",
    );
    final fixture = File('${dir.path}/installer fixture.exe');
    final compiler = File('${dir.path}/make-fixture.ps1');
    await compiler.writeAsString(r'''
param([string]$OutputPath)
$Source = @'
using System;
using System.IO;
public static class Fixture {
  public static int Main(string[] args) {
    File.WriteAllLines(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "arguments.txt"), args);
    return 0;
  }
}
'@
Add-Type -TypeDefinition $Source -OutputAssembly $OutputPath -OutputType WindowsApplication
''');
    try {
      final compiled = await Process.run(
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
      expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
      final arguments = [
        '/AURALISUPDATE=1',
        '/AURALISPID=$pid',
        '/DIR=${dir.path}/installed app',
        '/LOG=${dir.path}/installer.log',
      ];
      await startWindowsInstaller(fixture, arguments);
      final output = File('${dir.path}/arguments.txt');
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!await output.exists() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(await output.readAsLines(), arguments);
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);
}
