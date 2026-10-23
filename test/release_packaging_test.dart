import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'release packaging uses pubspec version and rejects mismatched tags',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'auralis package fixture ',
      );
      addTearDown(() => project.delete(recursive: true));
      Future<void> write(String name, String value) async {
        final file = File('${project.path}/$name');
        await file.parent.create(recursive: true);
        await file.writeAsString(value);
      }

      await write('pubspec.yaml', 'name: fixture\nversion: 0.9.0+123\n');
      for (final name in [
        'README.md',
        'LICENSE',
        'THIRD_PARTY_NOTICES.md',
        'docs/test.txt',
      ]) {
        await write(name, 'Packaging fixture only.');
      }
      for (final name in [
        'auralis.exe',
        'flutter_windows.dll',
        'libmpv-2.dll',
        'native/tdjson.dll',
      ]) {
        await write(
          'build/windows/x64/runner/Release/$name',
          'Harmless packaging fixture, never executed.',
        );
      }
      await write(
        'tool/package.ps1',
        await File('tool/package.ps1').readAsString(),
      );
      Future<ProcessResult> run(
        String command,
        List<String> args, {
        Map<String, String>? environment,
      }) async {
        return Process.run(
          command,
          args,
          workingDirectory: project.path,
          environment: environment,
        );
      }

      for (final args in [
        ['init'],
        ['add', 'README.md', 'pubspec.yaml'],
        [
          '-c',
          'user.name=Fixture',
          '-c',
          'user.email=fixture@example.invalid',
          '-c',
          'commit.gpgsign=false',
          'commit',
          '-m',
          'Fixture',
        ],
      ]) {
        final result = await run('git', args);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }
      final valid = await run(
        'pwsh',
        ['-NoProfile', '-File', 'tool/package.ps1', '-ValidateOnly'],
        environment: {'GITHUB_REF_TYPE': 'tag', 'GITHUB_REF_NAME': 'v0.9.0'},
      );
      expect(valid.exitCode, 0);
      expect(valid.stdout, contains('0.9.0'));
      final invalid = await run(
        'pwsh',
        ['-NoProfile', '-File', 'tool/package.ps1', '-ValidateOnly'],
        environment: {'GITHUB_REF_TYPE': 'tag', 'GITHUB_REF_NAME': 'v0.9.1'},
      );
      expect(invalid.exitCode, isNot(0));
      expect(invalid.stderr, contains('does not match'));
      final packaged = await run(
        'pwsh',
        ['-NoProfile', '-File', 'tool/package.ps1'],
        environment: {'GITHUB_REF_TYPE': 'branch', 'GITHUB_REF_NAME': 'main'},
      );
      expect(
        packaged.exitCode,
        0,
        reason: '${packaged.stdout}\n${packaged.stderr}',
      );
      for (final name in [
        'auralis-0.9.0-windows-x64.zip',
        'auralis-0.9.0-source.zip',
        'SHA256SUMS.txt',
      ]) {
        expect(await File('${project.path}/dist/$name').exists(), isTrue);
      }
      final hashes = await File('${project.path}/dist/SHA256SUMS.txt')
          .readAsString();
      expect(hashes, contains('auralis-0.9.0-windows-x64.zip'));
      expect(hashes, contains('auralis-0.9.0-source.zip'));
      expect(hashes, isNot(contains('0.1.0')));
    },
    skip: !Platform.isWindows,
  );
}
