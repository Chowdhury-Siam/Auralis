"""The same Telegram application configuration is used by both release builds."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('telegram-build-config.py')
spec = importlib.util.spec_from_file_location('telegram_build_config', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
HASH = 'abcdef0123456789abcdef0123456789'


class TelegramBuildConfigTests(unittest.TestCase):
    def test_normalizes_valid_identity(self):
        self.assertEqual(module.configuration({'TELEGRAM_API_ID': ' 0012345 ', 'TELEGRAM_API_HASH': HASH}),
                         {'TELEGRAM_API_ID': '12345', 'TELEGRAM_API_HASH': HASH})

    def test_missing_invalid_or_partial_identity_fails(self):
        for api_id, api_hash in [('', ''), ('12345', ''), ('', HASH), ('0', HASH), ('-1', HASH),
                                 ('2147483648', HASH), ('1.2', HASH), ('12345', 'not-a-hash')]:
            with self.subTest(api_id=api_id, has_hash=bool(api_hash)):
                with self.assertRaises(ValueError):
                    module.configuration({'TELEGRAM_API_ID': api_id, 'TELEGRAM_API_HASH': api_hash})

    def test_pull_requests_never_use_release_identity(self):
        self.assertEqual(module.configuration({'GITHUB_EVENT_NAME': 'pull_request',
                                              'TELEGRAM_API_ID': '12345', 'TELEGRAM_API_HASH': HASH}), {})

    def test_cli_writes_private_define_file_without_printing_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'auralis-telegram-build.json'
            result = subprocess.run([sys.executable, str(SCRIPT), '--output', str(path)],
                                    env={**os.environ, 'GITHUB_EVENT_NAME': 'push',
                                         'TELEGRAM_API_ID': '12345', 'TELEGRAM_API_HASH': HASH},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(path.read_text()), {'TELEGRAM_API_ID': '12345', 'TELEGRAM_API_HASH': HASH})
            self.assertNotIn(HASH, result.stdout + result.stderr)
            self.assertNotIn('12345', result.stdout + result.stderr)
            if os.name != 'nt':
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_missing_secret_does_not_create_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'auralis-telegram-build.json'
            result = subprocess.run([sys.executable, str(SCRIPT), '--output', str(path)],
                                    env={**os.environ, 'GITHUB_EVENT_NAME': 'push',
                                         'TELEGRAM_API_ID': '12345', 'TELEGRAM_API_HASH': ''},
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('TELEGRAM_API_HASH', result.stderr)
            self.assertFalse(path.exists())

    def test_both_workflows_pass_the_temporary_define_file_to_flutter(self):
        root = SCRIPT.parent.parent
        for workflow in ['android.yml', 'windows.yml']:
            source = (root / '.github/workflows' / workflow).read_text()
            self.assertIn('secrets.TELEGRAM_API_ID', source)
            self.assertIn('secrets.TELEGRAM_API_HASH', source)
            self.assertIn('tool/telegram-build-config.py --output', source)
            self.assertIn('--dart-define-from-file=', source)


if __name__ == '__main__':
    unittest.main()
