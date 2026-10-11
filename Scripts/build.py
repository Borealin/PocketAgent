#!/usr/bin/env python3
"""Archive the native app and companion WDA, then create sideloadable IPAs.

Unsigned releases use ad-hoc code signatures and contain no provisioning
identity. Development signing is an explicit, ignored local configuration.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def run(args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, **kwargs)


def sign(app, config=None):
    entitlements = {'get-task-allow': True}
    identity = '-'
    if config:
        identity = config['identity']
        bundle = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier']
        entitlements.update({'application-identifier': config['team'] + '.' + bundle,
                             'com.apple.developer.team-identifier': config['team'],
                             'keychain-access-groups': [config['team'] + '.' + bundle]})
        shutil.copy2(Path(config['profile']).expanduser(), app / 'embedded.mobileprovision')
    else:
        for profile in app.rglob('*.mobileprovision'):
            profile.unlink()
    ef = ROOT / '.build/entitlements.plist'
    ef.write_bytes(plistlib.dumps(entitlements))
    for nested in sorted([*app.rglob('*.framework'), *app.rglob('*.xctest')],
                         key=lambda p: len(p.parts), reverse=True):
        run(['codesign', '--force', '--sign', identity, '--timestamp=none', nested])
    run(['codesign', '--force', '--sign', identity, '--timestamp=none', '--entitlements', ef, app])
    run(['codesign', '--verify', '--deep', '--strict', app])


def ipa(app, path):
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        for item in sorted(app.rglob('*')):
            if item.is_file():
                z.write(item, Path('Payload') / app.name / item.relative_to(app))


def relocate_runner_test_bundle(runner):
    """Keep XCTest code in a nested code bundle recognized by sideload signers.

    AltStore prepares every direct PlugIns child as a separately provisioned
    app extension, but only discovers .appex extensions when fetching profiles.
    A framework is recursively signed without needing a separate app profile.
    Keep the original XCTest bundle metadata and executable unchanged; the
    launcher explicitly selects this path instead of relying on PlugIns lookup.
    """
    plugins = runner / 'PlugIns'
    tests = plugins / 'WebDriverAgentRunner.xctest'
    destination = runner / 'Frameworks/WebDriverAgentRunner.framework'
    if not tests.is_dir() or tests.is_symlink():
        raise ValueError('Runner is missing PlugIns/WebDriverAgentRunner.xctest')
    remaining = sorted(p.name for p in plugins.iterdir() if p != tests)
    if remaining:
        raise ValueError('Unexpected runner PlugIns entries: ' + ', '.join(remaining))
    if destination.exists() or destination.is_symlink():
        raise ValueError('Runner test destination already exists: ' + str(destination.relative_to(runner)))
    try:
        info = plistlib.loads((tests / 'Info.plist').read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise ValueError('Runner XCTest bundle has no readable Info.plist') from error
    if info.get('CFBundlePackageType') != 'BNDL' or info.get('CFBundleExecutable') != 'WebDriverAgentRunner':
        raise ValueError('Runner XCTest bundle has unexpected executable or package type')
    executable = tests / info['CFBundleExecutable']
    if not executable.is_file() or executable.is_symlink() or executable.stat().st_size == 0:
        raise ValueError('Runner XCTest bundle is missing its executable')
    destination.parent.mkdir(parents=True, exist_ok=True)
    tests.rename(destination)
    plugins.rmdir()
    return destination


def prepare_runner(config, version, number, signing=None):
    """Prepare a copy so packaging never changes Xcode's build products."""
    original = ROOT / '.build/WDA/Build/Products/Release-iphoneos/WebDriverAgentRunner-Runner.app'
    runner = ROOT / '.build/Packaging/WebDriverAgentRunner-Runner.app'
    shutil.rmtree(runner, ignore_errors=True)
    shutil.copytree(original, runner)
    # Do not discard a conflicting test bundle during runtime-library cleanup.
    destination = runner / 'Frameworks/WebDriverAgentRunner.framework'
    if destination.exists() or destination.is_symlink():
        raise ValueError('Runner test destination already exists: ' + str(destination.relative_to(runner)))
    # XCTest runtime libraries are supplied by iOS's mounted developer image.
    shutil.rmtree(runner / 'Frameworks', ignore_errors=True)
    # build-for-testing also places the test module's dSYM beside it in PlugIns.
    # Remove symbols before validating that only the expected code bundle remains.
    for symbols in runner.rglob('*.dSYM'):
        shutil.rmtree(symbols)
    relocate_runner_test_bundle(runner)
    # build-for-testing retains linker debug records even in Release; those
    # records include absolute object paths that compiler prefix maps cannot
    # rewrite. Preserve runtime/exported symbols and remove only debug records.
    for bundle in [runner, *runner.rglob('*.framework'), *runner.rglob('*.xctest')]:
        bundle_info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        run(['xcrun', 'strip', '-S', bundle / bundle_info['CFBundleExecutable']])
    info = plistlib.loads((runner / 'Info.plist').read_bytes())
    info['CFBundleIdentifier'] = signing['runnerBundleID'] if signing else config['runnerBundleIdentifier']
    info['CFBundleDisplayName'] = 'PocketAgent Automation'
    info['CFBundleShortVersionString'] = version
    info['CFBundleVersion'] = number
    info['MinimumOSVersion'] = config['minimumOSVersion']
    for key in list(info):
        if key.endswith('UsageDescription') and not info[key]:
            del info[key]
    (runner / 'Info.plist').write_bytes(plistlib.dumps(info))
    shutil.copy2(ROOT / 'Native/WebDriverAgent-LICENSE.txt', runner / 'WebDriverAgent-LICENSE.txt')
    sign(runner, signing)
    return runner


def swift_licenses():
    """Bundle notices from the exact resolved Swift dependency revisions."""
    pins = json.loads((ROOT / 'Package.resolved').read_text())['pins']
    checkouts = ROOT / '.build/DerivedData/SourcePackages/checkouts'
    packages = {p.name.lower(): p for p in checkouts.iterdir() if p.is_dir()}
    output = ROOT / 'App/Resources/SwiftLicenses'
    shutil.rmtree(output, ignore_errors=True)
    output.mkdir(parents=True)
    manifest = []
    for pin in pins:
        source = packages[pin['identity']]
        revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
        if revision != pin['state']['revision']:
            raise ValueError('Xcode dependency differs from Core test lock: ' + pin['identity'])
        target = output / pin['identity']
        target.mkdir()
        names = []
        for pattern in ['LICENSE*', 'COPYING*', 'NOTICE*']:
            for notice in source.glob(pattern):
                if notice.is_file():
                    shutil.copy2(notice, target / notice.name)
                    names.append(notice.name)
        if not names:
            raise ValueError('Dependency has no bundled notice: ' + pin['identity'])
        manifest.append({'name': pin['identity'], 'revision': revision,
                         'repository': pin['location'], 'notices': names})
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--skip-bootstrap', action='store_true')
    parser.add_argument('--app-only', action='store_true')
    parser.add_argument('--development', type=Path, help='ignored local-signing.json')
    parser.add_argument('--version')
    parser.add_argument('--build-version')
    args = parser.parse_args()
    config = json.loads((ROOT / 'Distribution/config.json').read_text())
    signing = json.loads(args.development.read_text()) if args.development else None
    version = args.version or config['version']
    number = args.build_version or config['buildVersion']
    if not args.skip_bootstrap:
        run(['python3', ROOT / 'Scripts/bootstrap.py'] + (['--native-only'] if args.app_only else []))
    # Embedded Linux runtime: static libraries and the rootfs (CI supplies it
    # from a Linux job; it is verified against the locked closure either way).
    run(['python3', ROOT / 'Scripts/ish_runtime.py', 'build'])
    rootfs = 'verify-rootfs' if (ROOT / '.build/ish/ish-root.tar.gz').is_file() else 'rootfs'
    run(['python3', ROOT / 'Scripts/ish_runtime.py', rootfs])
    (ROOT / 'App/Resources/SwiftLicenses').mkdir(parents=True, exist_ok=True)
    run(['xcodegen', 'generate', '--spec', ROOT / 'project.yml'])
    archive = ROOT / '.build/PocketAgent.xcarchive'
    settings = [f'MARKETING_VERSION={version}', f'CURRENT_PROJECT_VERSION={number}', 'CODE_SIGNING_ALLOWED=NO']
    if signing:
        settings += [f'PRODUCT_BUNDLE_IDENTIFIER={signing["bundleID"]}',
                     f'POCKETAGENT_RUNNER_BUNDLE_ID={signing["runnerBundleID"]}',
                     f'POCKETAGENT_LEGACY_KEYCHAIN_SERVICE={signing.get("legacyKeychainService", "")}']
    env = os.environ.copy()
    env.pop('SDKROOT', None)
    run(['xcodebuild', '-resolvePackageDependencies', '-project', ROOT / 'PocketAgent.xcodeproj',
         '-scheme', 'PocketAgent', '-derivedDataPath', ROOT / '.build/DerivedData',
         '-onlyUsePackageVersionsFromResolvedFile'], env=env)
    swift_licenses()
    # Complete corresponding source of the GPL-2.0 app binary (needs the
    # resolved Swift packages and the idevice checkout).
    run(['python3', ROOT / 'Scripts/ish_runtime.py', 'source', '--strict'])
    run(['xcodebuild', '-project', ROOT / 'PocketAgent.xcodeproj', '-scheme', 'PocketAgent',
         '-configuration', 'Release', '-destination', 'generic/platform=iOS',
         '-derivedDataPath', ROOT / '.build/DerivedData', '-archivePath', archive,
         '-onlyUsePackageVersionsFromResolvedFile', 'archive', *settings], env=env)
    app = archive / 'Products/Applications/PocketAgent.app'
    sign(app, signing)
    out = ROOT / ('build/development' if signing else 'dist')
    out.mkdir(parents=True, exist_ok=True)
    ipa(app, out / f'PocketAgent-{version}.ipa')
    shutil.copy2(ROOT / '.build/ish/PocketAgent-iSH-source.tar.gz', out / f'PocketAgent-iSH-source-{version}.tar.gz')
    if not args.app_only:
        wda = ROOT / '.deps/WebDriverAgent'
        run(['xcodebuild', '-project', wda / 'WebDriverAgent.xcodeproj', '-scheme', 'WebDriverAgentRunner',
             '-configuration', 'Release', '-destination', 'generic/platform=iOS',
             '-derivedDataPath', ROOT / '.build/WDA', 'build-for-testing',
             'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO',
             f'OTHER_CFLAGS=$(inherited) -ffile-prefix-map={ROOT}=. -ffile-prefix-map={Path.home()}=/builder'], env=env)
        runner = prepare_runner(config, version, number, signing)
        ipa(runner, out / f'PocketAgent-WDA-{version}.ipa')
    print(out)


if __name__ == '__main__':
    main()
