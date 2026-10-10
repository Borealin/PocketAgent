#!/usr/bin/env python3
"""Inspect clean IPA artifacts and generate an AltStore Classic source."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN_NAMES = ('embedded.mobileprovision', 'rp_pairing_file.plist', 'agent-import.json',
                   'chat-sessions.json', 'providers.json', 'local-signing.json')
FORBIDDEN_BYTES = (b'/Users/',)
PRIVATE_KEY_BLOCK = re.compile(
    rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----\s+'
    rb'[A-Za-z0-9+/=\r\n]{32,}-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----')


def inspect_ipa(path):
    """Reject local identities/data and report actual bundle metadata/permissions."""
    with tempfile.TemporaryDirectory() as td, zipfile.ZipFile(path) as archive:
        for member in archive.infolist():
            parts = PurePosixPath(member.filename).parts
            if not parts or parts[0] != 'Payload' or '..' in parts or member.filename.startswith('/'):
                raise ValueError('Invalid IPA path: ' + member.filename)
            if any(part in FORBIDDEN_NAMES for part in parts):
                raise ValueError('Private data/profile in IPA: ' + member.filename)
            if not member.is_dir():
                data = archive.read(member)
                # Crypto parsers contain the PEM header as a literal constant.
                # Reject complete key material, rather than that required token.
                if any(pattern in data for pattern in FORBIDDEN_BYTES) or PRIVATE_KEY_BLOCK.search(data):
                    raise ValueError('Local identity or secret marker in IPA: ' + member.filename)
        archive.extractall(td)
        roots = list((Path(td) / 'Payload').glob('*.app'))
        if len(roots) != 1:
            raise ValueError('IPA must contain one root app')
        app = roots[0]
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        executable = app / info['CFBundleExecutable']
        if not executable.is_file() or not executable.stat().st_size:
            raise ValueError('Missing executable')
        if info.get('PocketAgentLegacyKeychainService'):
            raise ValueError('Development migration service in release IPA')
        required = ['CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion', 'MinimumOSVersion']
        if any(not info.get(key) for key in required):
            raise ValueError('Missing bundle metadata')
        entitlements, privacy = set(), {}
        bundles = [app, *app.rglob('*.app'), *app.rglob('*.appex')]
        for bundle in bundles:
            bp = plistlib.loads((bundle / 'Info.plist').read_bytes())
            privacy.update({k: v for k, v in bp.items() if k.endswith('UsageDescription')})
            result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(bundle)],
                                    capture_output=True)
            raw = result.stdout
            if raw:
                start = raw.find(b'<?xml')
                if start < 0:
                    start = raw.find(b'<plist')
                if start >= 0:
                    decoded = plistlib.loads(raw[start:])
                    if any(key in decoded for key in ['application-identifier', 'com.apple.developer.team-identifier',
                                                       'keychain-access-groups']):
                        raise ValueError('Team-specific entitlement in IPA')
                    entitlements.update(decoded)
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return {'bundleIdentifier': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'],
                'buildVersion': info['CFBundleVersion'], 'minOSVersion': info['MinimumOSVersion'],
                'size': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                'appPermissions': {'entitlements': sorted(entitlements), 'privacy': privacy}}


def generate_source(apps, repo, previous=None, date=None):
    source = previous or {'name': 'PocketAgent', 'apps': [], 'news': []}
    source = json.loads(json.dumps(source))
    source.update({'name': 'PocketAgent', 'website': f'https://github.com/{repo}', 'tintColor': '#6554E8'})
    source.setdefault('apps', [])
    source.setdefault('news', [])
    for name, path in apps:
        metadata = dict(inspect_ipa(path))
        bundle = metadata.pop('bundleIdentifier')
        permissions = metadata.pop('appPermissions')
        version = dict(metadata, date=date or datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                       downloadURL=f'https://github.com/{repo}/releases/download/v{metadata["version"]}/{path.name}')
        existing = next((a for a in source['apps'] if a['bundleIdentifier'] == bundle), None)
        if existing is None:
            existing = {'name': name, 'bundleIdentifier': bundle, 'developerName': 'Borealin',
                        'localizedDescription': ('Native multi-session phone assistant with configurable model providers.'
                                                 if name == 'PocketAgent' else 'XCTest automation companion required for phone tools.'),
                        'iconURL': f'https://raw.githubusercontent.com/{repo}/main/Distribution/icon.png',
                        'category': 'developer', 'versions': []}
            source['apps'].append(existing)
        existing['appPermissions'] = permissions
        existing['versions'] = [version] + [v for v in existing['versions']
                                            if (v['version'], v.get('buildVersion')) != (version['version'], version['buildVersion'])]
    validate_source(source)
    return source


def validate_source(source):
    if not isinstance(source.get('name'), str) or not isinstance(source.get('apps'), list):
        raise ValueError('Invalid source')
    ids = [a['bundleIdentifier'] for a in source['apps']]
    if len(set(ids)) != len(ids):
        raise ValueError('Duplicate bundle identifiers')
    for app in source['apps']:
        if not all(app.get(k) for k in ['name', 'developerName', 'localizedDescription', 'iconURL', 'versions']):
            raise ValueError('Incomplete app metadata')
        if not isinstance(app['appPermissions']['entitlements'], list) or not isinstance(app['appPermissions']['privacy'], dict):
            raise ValueError('Invalid permissions')
        for version in app['versions']:
            if not all(version.get(k) for k in ['version', 'buildVersion', 'date', 'downloadURL', 'size', 'sha256', 'minOSVersion']):
                raise ValueError('Incomplete release metadata')
            if not version['downloadURL'].startswith('https://') or len(version['sha256']) != 64:
                raise ValueError('Invalid release URL/hash')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dist', type=Path, default=ROOT / 'dist')
    parser.add_argument('--repo')
    parser.add_argument('--output', type=Path, default=ROOT / 'Distribution/source.json')
    args = parser.parse_args()
    config = json.loads((ROOT / 'Distribution/config.json').read_text())
    paths = sorted(args.dist.glob('PocketAgent-*.ipa'))
    if len(paths) != 2:
        raise ValueError('Expected the app and WDA companion IPAs only')
    source = generate_source([('PocketAgent Automation' if '-WDA-' in p.name else 'PocketAgent', p) for p in paths],
                             args.repo or config['repository'],
                             json.loads(args.output.read_text()) if args.output.exists() else None)
    args.output.write_text(json.dumps(source, ensure_ascii=False, indent=2) + '\n')
    checksums = '\n'.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}' for p in paths) + '\n'
    (args.dist / 'SHA256SUMS').write_text(checksums)
    print(args.output)


if __name__ == '__main__':
    main()
