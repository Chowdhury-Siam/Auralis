import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  final workflow = loadYaml(
    File('.github/workflows/windows.yml').readAsStringSync(),
  ) as YamlMap;
  final job = workflow['jobs']['build'];
  final steps = job['steps'] as YamlList;
  dynamic step(String name) => steps.singleWhere((s) => s['name'] == name);
  dynamic id(String name) => steps.singleWhere((s) => s['id'] == name);

  test(
    'build cache compatibility excludes UI changes but never skips checks',
    () {
      final cache = id('windows-cache');
      final key = cache['with']['key'] as String;
      final prefix = cache['with']['restore-keys'] as String;
      expect(
        key,
        '$prefix\${{ hashFiles(\'lib/**\', \'assets/**\', \'pubspec.yaml\') }}',
      );
      for (final input in [
        'steps.tdlib-image.outputs.version',
        'steps.flutter.outputs.CACHE-KEY',
        'pubspec.lock',
        'windows/runner/**',
        'windows/CMakeLists.txt',
        'windows/flutter/CMakeLists.txt',
        'third_party/**',
      ]) {
        expect(prefix, contains(input));
      }
      expect(prefix, isNot(contains('windows.yml')));
      expect(prefix, isNot(contains('lib/**')));
      expect(prefix, isNot(contains('ephemeral')));
      final save = step('Save Windows and Dart build intermediates');
      expect(save['with']['path'], cache['with']['path']);
      expect(
        save['with']['key'],
        r'${{ steps.windows-cache.outputs.cache-primary-key }}',
      );
      final paths = cache['with']['path'] as String;
      expect(paths, contains('!build/windows/x64/runner/Release/'));
      expect(paths, contains('.dart_tool/flutter_build/'));
      expect(paths, contains('.dart_tool/hooks_runner/'));
      expect(paths, isNot(contains('windows/flutter/ephemeral')));
      expect(paths, isNot(contains('credentials')));
      expect(paths, isNot(contains('dist/')));
      for (final name in [
        'Resolve locked dependencies',
        'Static analysis',
        'Compile standalone native smoke check',
        'Automated tests',
        'Windows release build',
        'Native encryption, TDLib, playback, proxy and seek smoke test',
        'Package ZIP, installer, source and checksums',
      ]) {
        expect(
          step(name)['if'],
          isNull,
          reason: '$name must run on cache hits',
        );
      }
      expect(
        steps.indexOf(cache),
        lessThan(steps.indexOf(step('Automated tests'))),
      );
      expect(
        steps.indexOf(save),
        greaterThan(steps.indexOf(step('Windows release build'))),
      );
      expect(
        steps.indexOf(save),
        lessThan(
          steps.indexOf(
            step(
              'Native encryption, TDLib, playback, proxy and seek smoke test',
            ),
          ),
        ),
      );
      expect(id('flutter')['with']['cache'], isTrue);
      expect(id('flutter')['with']['pub-cache'], isTrue);
    },
  );

  test(
    'vcpkg fallback is image scoped and saved even if TDLib compilation fails',
    () {
      final cache = id('vcpkg-cache');
      final native = step('Build TDLib from pinned source');
      final save = step('Save vcpkg downloads and compiled dependencies');
      expect(cache['if'], native['if']);
      expect(
        cache['with']['key'],
        r"vcpkg-windows-2022-x64-v1-${{ steps.tdlib-image.outputs.version }}-${{ hashFiles('tool/build-tdlib.ps1') }}",
      );
      expect(
        cache['with']['restore-keys'],
        r'vcpkg-windows-2022-x64-v1-${{ steps.tdlib-image.outputs.version }}-',
      );
      expect(
        save['with']['key'],
        r'${{ steps.vcpkg-cache.outputs.cache-primary-key }}',
      );
      expect(save['with']['path'], cache['with']['path']);
      expect(save['if'], contains('!cancelled()'));
      expect(
        save['if'],
        contains("steps.vcpkg-cache.outputs.cache-primary-key != ''"),
      );
      expect(
        save['if'],
        contains("steps.vcpkg-cache.outputs.cache-hit != 'true'"),
      );
      expect(steps.indexOf(cache), lessThan(steps.indexOf(native)));
      expect(steps.indexOf(native), lessThan(steps.indexOf(save)));
      expect(
        id('tdlib-cache')['with']['key'],
        startsWith('tdlib-windows-2022-x64-release-v2-'),
      );
      expect(id('tdlib-cache')['with']['restore-keys'], isNull);
    },
  );

  test(
    'vcpkg cache setup creates existing absolute paths for the native builder',
    () async {
      final root = await Directory.systemTemp.createTemp('auralis-ci-cache-');
      addTearDown(() => root.delete(recursive: true));
      final variables = <String, String>{};
      for (final name in ['VCPKG_DEFAULT_BINARY_CACHE', 'VCPKG_DOWNLOADS']) {
        final value = job['env'][name] as String;
        expect(value, startsWith(r'${{ github.workspace }}/.ci-cache/'));
        variables[name] = value.replaceAll(
          r'${{ github.workspace }}',
          root.path,
        );
      }
      final script = File('${root.path}/prepare.ps1');
      await script.writeAsString(
        step('Prepare vcpkg cache directories')['run'] as String,
      );
      final result = await Process.run('pwsh', [
        '-NoProfile',
        '-File',
        script.path,
      ], environment: variables);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      for (final value in variables.values) {
        expect(Directory(value).isAbsolute, isTrue);
        expect(await Directory(value).exists(), isTrue);
      }
    },
    skip: !Platform.isWindows,
  );
}
