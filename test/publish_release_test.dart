import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('stable release publisher', () {
    late Directory project;
    late String commit;
    var invocation = 0;

    setUpAll(() async {
      project = await Directory.systemTemp.createTemp(
        'auralis release fixture ',
      );
      for (final path in [
        'tool/package.ps1',
        'tool/publish-release.ps1',
        'test/fixtures/fake_github_publish.ps1',
      ]) {
        final file = File('${project.path}/$path');
        await file.parent.create(recursive: true);
        await File(path).copy(file.path);
      }
      await File('${project.path}/pubspec.yaml')
          .writeAsString('name: fixture\nversion: 0.9.0+123\n');
      for (final args in [
        ['init'],
        ['add', 'pubspec.yaml'],
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
        final result = await Process.run(
          'git',
          args,
          workingDirectory: project.path,
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }
      final head = await Process.run('git', [
        'rev-parse',
        'HEAD',
      ], workingDirectory: project.path);
      commit = '${head.stdout}'.trim();
      await Directory('${project.path}/dist').create();
      for (final name in [
        'auralis-0.9.0-windows-x64.zip',
        'auralis-0.9.0-windows-x64-setup.exe',
        'auralis-0.9.0-source.zip',
        'SHA256SUMS.txt',
      ]) {
        await File('${project.path}/dist/$name')
            .writeAsString('Harmless fixture, never executed.');
      }
    });
    tearDownAll(() => project.delete(recursive: true));

    Future<(ProcessResult, List<List<dynamic>>)> run(
      String scenario, {
      Map<String, String> environment = const {},
    }) async {
      final calls = File('${project.path}/calls-${invocation++}.jsonl');
      final result = await Process.run(
        'pwsh',
        [
          '-NoProfile',
          '-File',
          'test/fixtures/fake_github_publish.ps1',
          '-Publisher',
          './tool/publish-release.ps1',
        ],
        workingDirectory: project.path,
        environment: {
          'GITHUB_EVENT_NAME': 'push',
          'GITHUB_REF_TYPE': 'branch',
          'GITHUB_REF_NAME': 'main',
          'GITHUB_REPOSITORY': 'fixture/auralis',
          'GITHUB_SHA': commit,
          'AURALIS_FIXTURE_CALLS': calls.path,
          'AURALIS_FIXTURE_SCENARIO': scenario,
          ...environment,
        },
      );
      final commands = await calls.exists()
          ? (await calls.readAsLines())
                .map((line) => jsonDecode(line) as List<dynamic>)
                .toList()
          : <List<dynamic>>[];
      return (result, commands);
    }

    bool changes(List<dynamic> args) =>
        args.contains('POST') || args.first == 'release';

    test('main creates the tested tag and publishes stable latest after digest verification', () async {
      final (result, calls) = await run('main');
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final tag = calls.singleWhere((args) => args.contains('POST'));
      expect(tag, containsAll(['ref=refs/tags/v0.9.0', 'sha=$commit']));
      final create = calls.singleWhere(
        (args) => args.take(2).join(' ') == 'release create',
      );
      expect(
        create,
        containsAll(['--draft', '--prerelease=false', '--verify-tag']),
      );
      final edit = calls.singleWhere(
        (args) => args.take(2).join(' ') == 'release edit',
      );
      expect(
        edit,
        containsAll(['--draft=false', '--prerelease=false', '--latest=true']),
      );
      final digest = calls.indexWhere(
        (args) => args.any((arg) => '$arg'.endsWith('/releases/101')),
      );
      expect(calls.indexOf(edit), greaterThan(digest));
    });

    test(
      'a draft whose by-tag API returns 404 is verified by ID after upload',
      () async {
        final (result, calls) = await run('draft');
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(
          calls.any(
            (args) => args.any((arg) => '$arg'.contains('/releases/tags/')),
          ),
          isFalse,
        );
        final lookup = calls.singleWhere(
          (args) => args.take(2).join(' ') == 'release view',
        );
        expect(
          lookup,
          containsAll([
            'v0.9.0',
            '--json',
            'databaseId',
            '--jq',
            '.databaseId',
          ]),
        );
        final upload = calls.indexWhere(
          (args) => args.take(2).join(' ') == 'release upload',
        );
        final metadata = [
          for (var i = 0; i < calls.length; i++)
            if (calls[i].contains('repos/fixture/auralis/releases/101')) i,
        ];
        expect(metadata, hasLength(2));
        expect(metadata.first, lessThan(upload));
        expect(metadata.last, greaterThan(upload));
        expect(
          calls.last,
          containsAll(['--draft=false', '--prerelease=false']),
        );
      },
    );

    for (final scenario in [
      'invalid-release-id',
      'draft-became-published',
      'lookup-failure',
      'wrong-draft-tag',
    ]) {
      test('$scenario cannot upload or publish assets', () async {
        final (result, calls) = await run(scenario);
        expect(result.exitCode, isNot(0));
        expect(
          calls.any((args) => args.take(2).join(' ') == 'release upload'),
          isFalse,
        );
        expect(
          calls.any((args) => args.take(2).join(' ') == 'release edit'),
          isFalse,
        );
      });
    }

    test(
      'matching version tag publishes without creating or moving its tag',
      () async {
        final (result, calls) = await run(
          'tag',
          environment: {'GITHUB_REF_TYPE': 'tag', 'GITHUB_REF_NAME': 'v0.9.0'},
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(calls.any((args) => args.contains('POST')), isFalse);
        expect(calls.last, contains('--prerelease=false'));
      },
    );

    test(
      'an existing stable release is immutable on same-version main pushes',
      () async {
        final (result, calls) = await run('published');
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(result.stdout, contains('Bump pubspec.yaml'));
        expect(calls.any(changes), isFalse);
      },
    );

    test('finds an existing stable release on a later API page', () async {
      final (result, calls) = await run('pagination');
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('already stable'));
      expect(calls.any(changes), isFalse);
    });

    for (final scenario in ['wrong-tag-commit', 'prerelease', 'read-failure']) {
      test('$scenario fails before any remote mutation', () async {
        final (result, calls) = await run(scenario);
        expect(result.exitCode, isNot(0));
        expect(calls.any(changes), isFalse);
      });
    }

    test('a digest mismatch leaves the release unpublished', () async {
      final (result, calls) = await run('bad-digest');
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('digest mismatch'));
      expect(
        calls.any((args) => args.take(2).join(' ') == 'release edit'),
        isFalse,
      );
    });

    test(
      'an interrupted draft with the tested tag can finish safely',
      () async {
        final (result, calls) = await run('draft');
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(
          calls.any((args) => args.take(2).join(' ') == 'release create'),
          isFalse,
        );
        expect(calls.last, contains('--draft=false'));
      },
    );

    test(
      'an older stable version does not displace a newer latest release',
      () async {
        final (result, calls) = await run('older-version');
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(calls.last, contains('--latest=false'));
      },
    );

    for (final environment in [
      {'GITHUB_REF_NAME': 'feature'},
      {'GITHUB_EVENT_NAME': 'pull_request'},
      {'GITHUB_REF_TYPE': 'tag', 'GITHUB_REF_NAME': 'v0.9.1'},
      {'GITHUB_SHA': '0' * 40},
    ]) {
      test('rejects unauthorized source or version $environment', () async {
        final (result, calls) = await run('main', environment: environment);
        expect(result.exitCode, isNot(0));
        expect(calls, isEmpty);
      });
    }
  }, skip: !Platform.isWindows);
}
