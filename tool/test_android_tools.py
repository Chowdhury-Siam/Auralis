import base64
import importlib.util
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
import zipfile


def module(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), Path(__file__).with_name(name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


signing = module('android-signing')
verify = module('verify-android')


def elf(machine=183, alignment=16384):
    data = bytearray(512)
    data[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<H', data, 18, machine)
    struct.pack_into('<Q', data, 32, 64)
    struct.pack_into('<HH', data, 54, 56, 1)
    struct.pack_into('<IIQQQQQQ', data, 64, 1, 5, 0, 0, 0, 512, 512, alignment)
    symbols = b'td_create_client_id td_send td_receive td_execute'
    data[256:256 + len(symbols)] = symbols
    return data


class AndroidToolsTest(unittest.TestCase):
    def test_source_is_complete_and_contains_no_signing_files(self):
        verify.verify_source(Path(__file__).resolve().parents[1])

    def test_source_rejects_gradle_below_flutter_minimum(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temp:
            fixture = Path(temp)
            shutil.copytree(root / 'android', fixture / 'android',
                            ignore=shutil.ignore_patterns('.gradle', 'build', 'local.properties', 'jniLibs'))
            wrapper = fixture / 'android/gradle/wrapper/gradle-wrapper.properties'
            wrapper.write_text(wrapper.read_text().replace('gradle-8.14.3-bin.zip', 'gradle-8.13-bin.zip'))
            with self.assertRaisesRegex(AssertionError, 'requires Gradle 8.14'):
                verify.verify_source(fixture)

    def test_native_validation_rejects_wrong_architecture_and_alignment(self):
        verify.verify_elf(elf(), 'arm64-v8a')
        verify.verify_elf(elf(62), 'x86_64')
        for invalid in (b'not ELF', elf(62), elf(alignment=4096)):
            with self.assertRaises(ValueError):
                verify.verify_elf(invalid, 'arm64-v8a')

    def test_apk_must_include_all_required_native_libraries(self):
        with tempfile.TemporaryDirectory() as temp:
            apk = Path(temp) / 'test.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                for name in ('AndroidManifest.xml', 'classes.dex'):
                    archive.writestr(name, b'fixture')
                for name in ('tdjson', 'mpv', 'mediakitandroidhelper', 'flutter'):
                    archive.writestr('lib/arm64-v8a/lib' + name + '.so', elf())
            verify.verify_apk(apk, 'arm64-v8a')
            with self.assertRaises(ValueError):
                verify.verify_apk(apk, 'x86_64')

    def test_github_workflow_builds_single_abi_split_apk(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/android.yml').read_text()
        self.assertIn('flutter build apk --release --no-pub --split-per-abi --target-platform "$target"', workflow)
        self.assertIn('source_apk="build/app/outputs/flutter-apk/app-$ABI-release.apk"', workflow)
        self.assertIn('cp "$source_apk" "dist/android/auralis-$version-android-$ABI-$flavor.apk"', workflow)
        self.assertIn('manifest debuggable', workflow)
        self.assertNotIn('mode=debug', workflow)
        self.assertNotIn('cp "build/app/outputs/flutter-apk/app-$mode.apk"', workflow)

    def test_apk_rejects_any_extra_architecture_even_when_target_libraries_exist(self):
        with tempfile.TemporaryDirectory() as temp:
            apk = Path(temp) / 'mixed.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                for name in ('AndroidManifest.xml', 'classes.dex'):
                    archive.writestr(name, b'fixture')
                for lib in ('tdjson', 'mpv', 'mediakitandroidhelper', 'flutter'):
                    archive.writestr(f'lib/arm64-v8a/lib{lib}.so', elf())
                archive.writestr('lib/x86_64/libmpv.so', elf(machine=62))
            with self.assertRaisesRegex(ValueError, 'Unexpected ABI'):
                verify.verify_apk(apk, 'arm64-v8a')

    def test_signing_defaults_to_development_and_rejects_partial_secrets(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            self.assertFalse(signing.configure(path, {}))
            with self.assertRaises(ValueError):
                signing.configure(path, {'KEYSTORE': 'incomplete'})
            self.assertEqual(list(path.iterdir()), [])

    def test_real_release_keystore_preparation_and_invalid_password_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            original = path / 'original.jks'
            env = dict(os.environ, TEST_STORE_PASSWORD='test-password')
            subprocess.run(['keytool', '-genkeypair', '-keystore', str(original), '-alias', 'test',
                            '-keyalg', 'RSA', '-keysize', '2048', '-validity', '1', '-dname', 'CN=Test',
                            '-storepass:env', 'TEST_STORE_PASSWORD', '-keypass:env', 'TEST_STORE_PASSWORD'],
                           env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            secrets = dict(KEYSTORE=base64.b64encode(original.read_bytes()).decode(),
                           STORE_PASSWORD='test-password', KEY_ALIAS='test', KEY_PASSWORD='test-password')
            self.assertTrue(signing.configure(path, secrets))
            self.assertEqual((path / 'auralis-release.jks').read_bytes(), original.read_bytes())
            self.assertIn('keyAlias=test\n', (path / 'key.properties').read_text())
            (path / 'auralis-release.jks').unlink()
            (path / 'key.properties').unlink()
            with self.assertRaises(ValueError):
                signing.configure(path, dict(secrets, STORE_PASSWORD='wrong-password'))
            self.assertFalse((path / 'auralis-release.jks').exists())
            self.assertFalse((path / 'key.properties').exists())


if __name__ == '__main__':
    unittest.main()
