#!/usr/bin/env python3
"""Fetch immutable dependency revisions and build the iOS Rust FFI archive."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, **kwargs)


def checkout(name, spec):
    dest = ROOT / '.deps' / name
    if not dest.exists():
        dest.mkdir(parents=True)
        run(['git', 'init', dest])
        run(['git', '-C', dest, 'remote', 'add', 'origin', spec['url']])
    result = subprocess.run(['git', '-C', str(dest), 'rev-parse', 'HEAD'],
                            text=True, capture_output=True)
    rev = result.stdout.strip() if result.returncode == 0 else ''
    if rev != spec['revision']:
        run(['git', '-C', dest, 'fetch', '--depth', '1', 'origin', spec['revision']])
        run(['git', '-C', dest, 'checkout', '--detach', spec['revision']])
    return dest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--native-only', action='store_true')
    args = parser.parse_args()
    specs = json.loads((ROOT / 'dependencies.json').read_text())
    src = checkout('idevice', specs['idevice'])
    patch = ROOT / 'Native/idevice.patch'
    check = subprocess.run(['git', '-C', str(src), 'apply', '--reverse', '--check', str(patch)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if check.returncode:
        run(['git', '-C', src, 'apply', '--check', patch])
        run(['git', '-C', src, 'apply', patch])
    # Reviewable native implementation lives in this repository, not an
    # untracked edit to the pinned dependency checkout.
    ddi = src / 'ffi/src/pocket_ddi'
    if ddi.exists():
        shutil.rmtree(ddi)
    shutil.copytree(ROOT / 'Native/ddi', ddi)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    env = os.environ.copy()
    env['SDKROOT'] = sdk
    env['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
    env['CARGO_TARGET_DIR'] = str(ROOT / '.build/rust')
    env['RUSTFLAGS'] = f'--remap-path-prefix={ROOT}=. --remap-path-prefix={Path.home()}=/builder'
    run(['rustup', 'target', 'add', 'aarch64-apple-ios'])
    run(['cargo', 'build', '--manifest-path', src / 'Cargo.toml', '--locked',
         '--release', '--target', 'aarch64-apple-ios', '-p', 'idevice-ffi',
         '--no-default-features', '--features', 'full,ring,display_stream'], env=env)
    out = ROOT / '.build/native'
    out.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / '.build/rust/aarch64-apple-ios/release/libidevice_ffi.a', out / 'libidevice_ffi.a')
    # Keep the header consumed by Swift in sync with the pinned generated ABI.
    shutil.copy2(src / 'ffi/idevice.h', ROOT / 'Native/idevice.h')
    metadata = json.loads(subprocess.check_output(
        ['cargo', 'metadata', '--format-version', '1', '--locked', '--manifest-path', str(src / 'Cargo.toml')],
        text=True))
    notices = ROOT / 'App/Resources/RustLicenses'
    if notices.exists():
        shutil.rmtree(notices)
    notices.mkdir(parents=True)
    manifest = []
    for package in metadata['packages']:
        if package['name'] in ['tools', 'tests']:
            continue
        base = Path(package['manifest_path']).parent
        names = []
        for pattern in ['LICENSE*', 'COPYING*', 'NOTICE*']:
            for notice in base.glob(pattern):
                if not notice.is_file():
                    continue
                target = notices / (package['name'] + '-' + package['version'])
                target.mkdir(exist_ok=True)
                shutil.copy2(notice, target / notice.name)
                names.append(notice.name)
        manifest.append({'name': package['name'], 'version': package['version'],
                         'license': package.get('license'), 'repository': package.get('repository'), 'notices': names})
    (notices / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    if not args.native_only:
        checkout('WebDriverAgent', specs['WebDriverAgent'])


if __name__ == '__main__':
    main()
