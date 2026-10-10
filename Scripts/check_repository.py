#!/usr/bin/env python3
"""Check non-ignored source for local credentials and accidental user data."""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BLOCKED_SUFFIXES = {'.ipa', '.mobileprovision', '.p12', '.p8', '.key', '.pem', '.log', '.jsonl'}
BLOCKED_NAMES = {'rp_pairing_file.plist', 'agent-import.json', 'chat-sessions.json', 'providers.json', 'local-signing.json'}


def main():
    names = sorted(set(filter(None, subprocess.check_output(
        ['git', '-C', str(ROOT), 'ls-files', '--cached', '--others', '--exclude-standard', '-z'],
        text=True).split('\0'))))
    issues = []
    for name in filter(None, names):
        path = ROOT / name
        if path.suffix in BLOCKED_SUFFIXES or path.name in BLOCKED_NAMES or any(x in path.parts for x in ['.deps', '.build', 'dist', 'work']):
            issues.append(name + ': private/generated file')
            continue
        if not path.is_file():
            continue
        data = path.read_bytes()
        # Policy patterns in these scanners are intentional, never credentials.
        if name in ['Scripts/check_repository.py', 'Scripts/distribution.py']:
            continue
        patterns = [rb'/Users/[^\s]+', rb'https?://[^\s]*\.(?:local|internal)(?:/|$)',
                    rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY',
                    rb'(?i)(?:sk-[a-z0-9]{24,}|gh[pousr]_[a-z0-9]{30,})',
                    rb'00008[0-9a-fA-F]{3}-[0-9a-fA-F]{16}']
        if any(re.search(pattern, data) for pattern in patterns):
            issues.append(name + ': sensitive marker')
    if issues:
        raise SystemExit('\n'.join(issues))
    print('Repository privacy scan passed (' + str(len(names)) + ' files).')


if __name__ == '__main__':
    main()
