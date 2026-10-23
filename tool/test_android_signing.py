"""Exercise one-time key generation and reuse without accessing a real account."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from test_android_tools import module

setup = module('setup-android-signing')
signing = module('android-signing')


class AutomaticSigningTest(unittest.TestCase):
    def setUp(self):
        self.environment = dict(GITHUB_EVENT_NAME='workflow_dispatch', GITHUB_REF='refs/heads/main',
                                GITHUB_REPOSITORY='fixture/auralis', GH_TOKEN='not-a-real-token')

    def test_generated_identity_is_retained_and_signs_with_the_same_certificate_on_two_runners(self):
        stored = {}

        def github(environment, *arguments, value=None):
            self.assertEqual(environment['GH_TOKEN'], 'not-a-real-token')
            if arguments[:2] == ('secret', 'list'):
                return json.dumps([{'name': name} for name in stored])
            self.assertEqual(arguments[:3], ('secret', 'set', setup.IDENTITY))
            self.assertNotIn('--body', arguments)  # Secret goes through stdin.
            stored[setup.IDENTITY] = value
            return ''

        output = io.StringIO()
        with patch.object(setup, 'github', github), contextlib.redirect_stdout(output):
            self.assertTrue(setup.setup(self.environment))
            original = dict(stored)
            self.assertFalse(setup.setup(self.environment))
            self.assertEqual(stored, original)
        bundle = json.loads(stored[setup.IDENTITY])
        for value in bundle.values():
            self.assertNotIn(value, output.getvalue())
        certificates = []
        for _ in range(2):
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.assertTrue(signing.configure(root, dict(SIGNING_IDENTITY=stored[setup.IDENTITY])))
                key = root / 'auralis-release.jks'
                certificate = subprocess.check_output([
                    'keytool', '-exportcert', '-keystore', str(key), '-alias', bundle['KEY_ALIAS'],
                    '-storepass:env', 'TEST_PASSWORD',
                ], env=dict(os.environ, TEST_PASSWORD=bundle['STORE_PASSWORD']), stderr=subprocess.DEVNULL)
                certificates.append(certificate)
                # Sign a certificate request with the private key, then verify
                # that signature independently. This is not an APK/device test.
                request = subprocess.check_output([
                    'keytool', '-certreq', '-keystore', str(key), '-alias', bundle['KEY_ALIAS'],
                    '-storepass:env', 'TEST_PASSWORD', '-keypass:env', 'TEST_PASSWORD',
                ], env=dict(os.environ, TEST_PASSWORD=bundle['STORE_PASSWORD']), stderr=subprocess.DEVNULL)
                subprocess.run(['openssl', 'req', '-verify', '-noout'], input=request,
                               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertEqual(certificates[0], certificates[1])

    def test_setup_never_rotates_existing_or_partially_configured_keys(self):
        for names in [setup.LEGACY, {setup.IDENTITY}, {'ANDROID_KEYSTORE_BASE64'}]:
            with self.subTest(names=names), patch.object(setup, 'github', return_value=json.dumps([
                {'name': name} for name in names
            ])) as github, patch.object(setup.subprocess, 'run') as native:
                if names == {'ANDROID_KEYSTORE_BASE64'}:
                    with self.assertRaisesRegex(ValueError, 'incomplete'):
                        setup.setup(self.environment)
                else:
                    self.assertFalse(setup.setup(self.environment))
                self.assertEqual(github.call_count, 1)
                native.assert_not_called()

    def test_setup_rejects_missing_permission_untrusted_ref_and_api_errors_without_exposing_token(self):
        for overrides in [dict(GH_TOKEN=''), dict(GITHUB_EVENT_NAME='pull_request'),
                          dict(GITHUB_REF='refs/heads/feature'), dict(GITHUB_REPOSITORY='bad/repo/extra')]:
            with self.subTest(overrides=overrides), patch.object(setup, 'github') as github:
                with self.assertRaises(ValueError):
                    setup.setup(dict(self.environment, **overrides))
                github.assert_not_called()
        with patch.object(setup.subprocess, 'run', return_value=subprocess.CompletedProcess(
            [], 1, stdout='private response', stderr='not-a-real-token',
        )):
            with self.assertRaisesRegex(ValueError, 'Secrets read/write') as error:
                setup.setup(self.environment)
            self.assertNotIn('not-a-real-token', str(error.exception))

    def test_identity_validation_and_existing_custom_key_precedence(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for invalid in ['not json', 'null', '{}', '[]', '{"KEYSTORE":123}']:
                with self.subTest(invalid=invalid), self.assertRaisesRegex(ValueError, 'Invalid ANDROID_SIGNING_IDENTITY'):
                    signing.configure(directory, dict(SIGNING_IDENTITY=invalid))
            with self.assertRaisesRegex(ValueError, 'all four'):
                signing.configure(directory, dict(SIGNING_IDENTITY='not json', KEYSTORE='partial'))
            self.assertEqual(list(directory.iterdir()), [])

    def test_setup_workflow_keeps_credentials_out_of_artifacts_and_queues_a_fresh_build(self):
        root = Path(__file__).resolve().parents[1]
        workflow = (root / '.github/workflows/android-signing.yml').read_text()
        build = (root / '.github/workflows/android.yml').read_text()
        self.assertIn("if: github.ref == 'refs/heads/main'", workflow)
        self.assertIn('group: android-signing-setup-${{ github.repository }}', workflow)
        self.assertIn('cancel-in-progress: false', workflow)
        self.assertIn('gh workflow run android.yml', workflow)
        self.assertNotIn('upload-artifact', workflow)
        self.assertNotIn('actions/cache', workflow)
        self.assertIn("github.event_name != 'pull_request' && secrets.ANDROID_SIGNING_IDENTITY", build)
        self.assertNotIn('ANDROID_SIGNING_SETUP_TOKEN', build)


if __name__ == '__main__':
    unittest.main()
