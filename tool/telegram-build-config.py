#!/usr/bin/env python3
"""Validate repository secrets and write a temporary Flutter define file."""
import argparse
import json
import os
import re
from pathlib import Path


def configuration(environment):
    # PR builds run all checks without access to the release application identity.
    if environment.get('GITHUB_EVENT_NAME') == 'pull_request':
        return {}
    api_id = environment.get('TELEGRAM_API_ID', '').strip()
    api_hash = environment.get('TELEGRAM_API_HASH', '').strip()
    if not re.fullmatch(r'[0-9]+', api_id) or not 0 < int(api_id) <= 2147483647:
        raise ValueError('Set the TELEGRAM_API_ID repository secret to your Telegram application ID.')
    if not re.fullmatch(r'[a-fA-F0-9]{32}', api_hash):
        raise ValueError('Set the TELEGRAM_API_HASH repository secret to your 32-character Telegram application hash.')
    return {'TELEGRAM_API_ID': str(int(api_id)), 'TELEGRAM_API_HASH': api_hash}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        config = configuration(os.environ)
    except ValueError as error:
        parser.exit(1, str(error) + '\n')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(config), encoding='utf-8')
    if os.name != 'nt':
        args.output.chmod(0o600)
    print('Telegram application identity prepared.' if config else 'PR build uses manual Telegram configuration.')


if __name__ == '__main__':
    main()
