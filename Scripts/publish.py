#!/usr/bin/env python3
"""Publish CI-built assets only after the version tag matches the IPA feed."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def version_key(version):
    match = re.fullmatch(r'(\d+)(?:\.(\d+))?(?:\.(\d+))?', version['version'])
    if not match:
        raise ValueError('IPA version must use one to three numeric components')
    return (*[int(part or '0') for part in match.groups()], int(version['buildVersion']))


def merge_published_source(current, release):
    """Merge against current main, preserving all inspected prior releases."""
    merged = json.loads(json.dumps(current))
    for key, value in release.items():
        if key not in ['apps', 'news']:
            merged.setdefault(key, json.loads(json.dumps(value)))
    for incoming in release['apps']:
        existing = next((app for app in merged['apps'] if app['bundleIdentifier'] == incoming['bundleIdentifier']), None)
        if existing is None:
            merged['apps'].append(json.loads(json.dumps(incoming)))
            continue
        entries = {(v['version'], v['buildVersion']): v for v in existing['versions']}
        for index, version in enumerate(incoming['versions']):
            key = (version['version'], version['buildVersion'])
            if index == 0:
                # The newly inspected CI artifact is authoritative for its own
                # release. A locally generated feed may have the same version
                # but a different compiler/SDK and therefore a different hash.
                entries[key] = version
            else:
                entries.setdefault(key, version)
        versions = sorted(entries.values(), key=version_key, reverse=True)
        if version_key(incoming['versions'][0]) >= version_key(existing['versions'][0]):
            existing.update({k: v for k, v in incoming.items() if k != 'versions'})
        existing['versions'] = versions
    return merged


def main():
    source = json.loads((ROOT / 'Distribution/source.json').read_text())
    versions = {app['versions'][0]['version'] for app in source['apps']}
    tag = os.environ['RELEASE_TAG']
    if versions != {tag.removeprefix('v')} or not tag.startswith('v'):
        raise SystemExit('Release tag must match both IPA versions.')
    subprocess.run(['git', 'fetch', 'origin', 'main'], check=True, cwd=ROOT)
    latest = subprocess.run(['git', 'show', 'origin/main:Distribution/source.json'],
                            capture_output=True, cwd=ROOT)
    previous = json.loads(latest.stdout) if latest.returncode == 0 else {'name': 'PocketAgent', 'apps': [], 'news': []}
    source = merge_published_source(previous, source)
    (ROOT / 'Distribution/source.json').write_text(json.dumps(source, ensure_ascii=False, indent=2) + '\n')
    # The GPL runtime's corresponding source is published with every IPA.
    assets = [*sorted((ROOT / 'dist').glob('*.ipa')), *sorted((ROOT / 'dist').glob('*-iSH-source-*.tar.gz')),
              ROOT / 'dist/SHA256SUMS', ROOT / 'Distribution/source.json']
    exists = subprocess.run(['gh', 'release', 'view', tag], cwd=ROOT,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if exists.returncode == 0:
        subprocess.run(['gh', 'release', 'upload', tag, '--clobber', *map(str, assets)], check=True, cwd=ROOT)
    else:
        subprocess.run(['gh', 'release', 'create', tag, '--verify-tag', '--title', 'PocketAgent ' + tag,
                        '--generate-notes', *map(str, assets)], check=True, cwd=ROOT)
    # The release asset is a stable private/public source URL. Keep the main
    # source file current too, so later public distribution has one fixed URL.
    # Build tools regenerate tracked project/header files. A separate checkout
    # preserves those products and cannot be blocked by their working-tree diffs.
    with tempfile.TemporaryDirectory(prefix='pocketagent-feed-') as directory:
        checkout = Path(directory) / 'checkout'
        subprocess.run(['git', 'worktree', 'add', '--detach', str(checkout), 'origin/main'], check=True, cwd=ROOT)
        try:
            file = checkout / 'Distribution/source.json'
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(json.dumps(source, ensure_ascii=False, indent=2) + '\n')
            subprocess.run(['git', 'add', 'Distribution/source.json'], check=True, cwd=checkout)
            changed = subprocess.run(['git', 'diff', '--cached', '--quiet'], cwd=checkout)
            if changed.returncode:
                subprocess.run(['git', '-c', 'user.name=github-actions[bot]',
                                '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com',
                                'commit', '-m', 'Update AltStore source for ' + tag], check=True, cwd=checkout)
                subprocess.run(['git', 'push', 'origin', 'HEAD:main'], check=True, cwd=checkout)
        finally:
            subprocess.run(['git', 'worktree', 'remove', '--force', str(checkout)], check=True, cwd=ROOT)


if __name__ == '__main__':
    main()
