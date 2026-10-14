#!/usr/bin/env python3
"""Fetch immutable dependency revisions and build the iOS Rust FFI archive."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
# Patched idevice checkouts are keyed by pinned revision and patch digest. A
# key directory appears, by rename, only after its patch applied completely;
# a changed patch gets a new directory. Existing checkouts, including the
# legacy .deps/idevice, are never reset, rewritten or deleted.
MANAGED = 'idevice-pocketagent'
STATE = 'pocketagent-bootstrap.json'
# Bootstrap-owned copy of Native/ddi and the header written by the FFI build.
GENERATED = ['ffi/src/pocket_ddi', 'ffi/idevice.h']


def run(args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, **kwargs)


def git(repo, *args, git_dir='.git', env=None, check=True):
    """Run Git in exactly this repository, never a discovered parent checkout."""
    result = subprocess.run(['git', '-C', str(repo), '--git-dir=' + git_dir, *map(str, args)],
                            text=True, stdout=subprocess.PIPE, env=env)
    if check and result.returncode:
        raise subprocess.CalledProcessError(result.returncode, ['git', *map(str, args)])
    return result.stdout.strip() if result.returncode == 0 else None


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


def patch_digest(patch):
    return hashlib.sha256(Path(patch).read_bytes()).hexdigest()


def idevice_checkout_path(root=ROOT, spec=None):
    """Managed idevice source for the pinned revision and Native/idevice.patch."""
    spec = spec or json.loads((root / 'dependencies.json').read_text())['idevice']
    digest = patch_digest(root / 'Native/idevice.patch')
    return root / '.deps' / MANAGED / f"{spec['revision']}-{digest[:16]}"


@contextlib.contextmanager
def locked(directory):
    directory.mkdir(parents=True, exist_ok=True)
    with open(directory / '.lock', 'w') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def worktree_tree(repo):
    """Tree of the worktree's non-ignored contents; the checkout's index is untouched."""
    with tempfile.TemporaryDirectory() as directory:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(directory) / 'index'))
        git(repo, 'add', '--all', '--', '.', *[':(exclude)' + p for p in GENERATED], env=env)
        return git(repo, 'write-tree', env=env)


def has_commit(cache, revision):
    return git(cache, 'cat-file', '-e', revision + '^{commit}', git_dir='.', check=False) is not None


def cache_revision(cache, spec, legacy):
    """Keep the pinned commit in a bootstrap-owned bare object cache."""
    revision = spec['revision']
    if not cache.exists():
        staging = cache.with_name(f'.staging-{uuid.uuid4().hex}')
        run(['git', 'init', '--quiet', '--bare', staging])
        staging.rename(cache)
    if not has_commit(cache, revision):
        sources = []
        # Read objects from a legacy checkout at the same pin without changing it.
        if (legacy / '.git').is_dir() and git(legacy, 'rev-parse', 'HEAD', check=False) == revision:
            sources.append((legacy.resolve().as_uri(), 'HEAD'))
        sources.append((spec['url'], revision))
        for url, want in sources:
            git(cache, 'fetch', '--quiet', '--depth', '1', '--no-tags', url, want, git_dir='.', check=False)
            if has_commit(cache, revision):
                break
        else:
            raise SystemExit(f'Could not fetch idevice {revision} from {spec["url"]}')
    git(cache, 'update-ref', 'refs/pocketagent/' + revision, revision, git_dir='.')


def create_checkout(cache, spec, patch, digest, target):
    """Build the patched checkout in staging and publish it by one rename."""
    revision = spec['revision']
    staging = target.with_name(f'.staging-{uuid.uuid4().hex}')
    try:
        run(['git', 'init', '--quiet', staging])
        git(staging, 'remote', 'add', 'origin', spec['url'])
        git(staging, 'fetch', '--quiet', '--depth', '1', '--no-tags', cache.resolve().as_uri(),
            'refs/pocketagent/' + revision)
        git(staging, '-c', 'advice.detachedHead=false', 'checkout', '--quiet', '--detach', revision)
        try:
            git(staging, 'apply', '--check', patch.resolve())
            git(staging, 'apply', patch.resolve())
        except subprocess.CalledProcessError:
            raise SystemExit(f'Native/idevice.patch does not apply to idevice {revision}; '
                             'no checkout was created or changed.') from None
        tree = worktree_tree(staging)
        # Keep the recorded tree reachable so Git maintenance cannot prune it.
        git(staging, 'update-ref', 'refs/pocketagent/applied', tree)
        state = {'revision': revision, 'patch_sha256': digest, 'tree': tree}
        (staging / '.git' / STATE).write_text(json.dumps(state, indent=2) + '\n')
        staging.rename(target)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def verify_checkout(target, revision, digest, root):
    """Refuse, without changing anything, a checkout that is not exactly as created."""
    name = target.relative_to(root)
    try:
        state = json.loads((target / '.git' / STATE).read_text())
    except (OSError, ValueError):
        raise SystemExit(f'{name} is not a complete bootstrap checkout and was left untouched; '
                         'move it away to recreate it.') from None
    head = git(target, 'rev-parse', 'HEAD', check=False)
    if state.get('revision') != revision or state.get('patch_sha256') != digest or head != revision:
        raise SystemExit(f'{name} does not match its pinned revision and patch and was left untouched; '
                         'move it away to recreate it.')
    tree = worktree_tree(target)
    if tree != state.get('tree'):
        changed = git(target, 'diff-tree', '-r', '--name-only', state.get('tree', ''), tree, check=False)
        listed = '\n  '.join((changed or '').splitlines()[:20]) or '(changed paths unavailable)'
        raise SystemExit(f'{name} has local edits and was left untouched:\n  {listed}\n'
                         'Move idevice changes into Native/idevice.patch or Native/ddi, '
                         'then move this checkout away to recreate it.')


def prepare_idevice(root, spec):
    """Return the verified checkout for the pin plus the current patch and Native/ddi."""
    patch = root / 'Native/idevice.patch'
    digest = patch_digest(patch)
    parent = root / '.deps' / MANAGED
    target = parent / f"{spec['revision']}-{digest[:16]}"
    legacy = root / '.deps/idevice'
    with locked(parent):
        # Only this function creates staging names, and only under this lock;
        # leftovers are incomplete work from an interrupted run.
        for stale in parent.glob('.staging-*'):
            if stale.is_dir() and not stale.is_symlink():
                shutil.rmtree(stale)
            else:
                stale.unlink()
        if not target.exists():
            cache = parent / 'objects.git'
            cache_revision(cache, spec, legacy)
            create_checkout(cache, spec, patch, digest, target)
        verify_checkout(target, spec['revision'], digest, root)
        # Reviewable native implementation lives in this repository, not an
        # untracked edit to the pinned dependency checkout.
        ddi = target / 'ffi/src/pocket_ddi'
        if ddi.exists():
            shutil.rmtree(ddi)
        shutil.copytree(root / 'Native/ddi', ddi)
    if legacy.exists():
        print(f'Legacy .deps/idevice is no longer used and was left untouched; the build uses '
              f'{target.relative_to(root)}. Remove it yourself after keeping any local edits.')
    return target


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--native-only', action='store_true')
    args = parser.parse_args()
    specs = json.loads((ROOT / 'dependencies.json').read_text())
    src = prepare_idevice(ROOT, specs['idevice'])
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
