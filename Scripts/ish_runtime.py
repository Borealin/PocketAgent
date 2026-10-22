#!/usr/bin/env python3
"""Fetch, patch and build the embedded iSH Linux runtime and its x86 Alpine rootfs.

Inputs are pinned in dependencies.json (`iSH` archives and `alpineRootfs`).
Outputs are ignored build products under .build/ish:

  sources/ish                    patched iSH tree (with deps)
  <config>-iphoneos/*.a          static libraries linked into the app
  ish-root.tar.gz                Alpine i386 rootfs bundled as an app resource
  PocketAgent-iSH-source.tar.gz  corresponding source for GPL distribution

`fetch` needs only Python. `build` needs Xcode, meson, ninja and lld.
`rootfs` needs Docker able to run linux/386 containers; `verify-rootfs`
checks an existing archive (for example one built by the Linux CI job).
"""
import argparse
import getpass
import gzip
import hashlib
import io
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.build/ish'
DOWNLOADS = OUT / 'downloads'
SOURCES = OUT / 'sources'
PATCHES = ROOT / 'Native/ish/patches'
LIBRARIES = ['liblinux', 'libiSHLinux', 'libiSHLinuxUser', 'libfakefs', 'libish_emu', 'libarchive']
EPOCH = 1767225600  # fixed archive timestamps


def idevice_source_path():
    """The bootstrap-managed idevice checkout for the current pin and patch."""
    spec = importlib.util.spec_from_file_location('pocketagent_bootstrap', Path(__file__).with_name('bootstrap.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.idevice_checkout_path(ROOT)


def run(args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, **kwargs)


def pins():
    return json.loads((ROOT / 'dependencies.json').read_text())


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def download(url, path, expected):
    if path.is_file() and sha256(path) == expected:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix(path.suffix + '.part')
    with urllib.request.urlopen(url, timeout=300) as response, partial.open('wb') as output:
        shutil.copyfileobj(response, output, 1 << 20)
    actual = sha256(partial)
    if actual != expected:
        partial.unlink()
        raise SystemExit(f'SHA-256 mismatch for {url}: {actual}')
    partial.replace(path)


def extract(archive, top, destination):
    staging = SOURCES / '.extract'
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    with zipfile.ZipFile(archive) as z:
        root = staging.resolve()
        for member in z.infolist():
            target = (staging / member.filename).resolve()
            if target != root and root not in target.parents:
                raise SystemExit('Archive entry escapes destination: ' + member.filename)
        z.extractall(staging)
        # GitHub archives record executable bits in the external attributes.
        for member in z.infolist():
            mode = member.external_attr >> 16
            if mode & 0o111:
                (staging / PurePosixPath(member.filename)).chmod(mode & 0o777)
    shutil.rmtree(destination, ignore_errors=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(staging / top), str(destination))
    shutil.rmtree(staging)


def source_signature():
    digest = hashlib.sha256(json.dumps(pins()['iSH'], sort_keys=True).encode())
    for patch in sorted(PATCHES.glob('*.patch')):
        digest.update(patch.name.encode() + patch.read_bytes())
    return digest.hexdigest()


def fetch(force=False):
    """Extract every pinned archive and apply PocketAgent's patches once."""
    marker = SOURCES / '.pocketagent-signature'
    signature = source_signature()
    if not force and marker.is_file() and marker.read_text() == signature:
        return SOURCES / 'ish'
    shutil.rmtree(SOURCES, ignore_errors=True)
    for spec in pins()['iSH']['archives']:
        archive = DOWNLOADS / archive_name(spec)
        download(spec['url'], archive, spec['sha256'])
        extract(archive, spec['top'], SOURCES / spec['destination'])
    for patch in sorted(PATCHES.glob('*.patch')):
        run(['/usr/bin/patch', '-d', SOURCES / 'ish', '-p1', '--forward', '-i', patch])
    marker.write_text(signature)
    return SOURCES / 'ish'


def archive_name(spec):
    return f"{spec['name']}-{PurePosixPath(spec['url']).name}"


def check_hostfs(iterations=20000):
    """Compiles the patched hostfs backend for this Mac with
    Tests/RuntimeTests/hostfs_harness.c and returns its JSON result."""
    hostfs = SOURCES / 'ish/deps/linux/fs/hostfs'
    with tempfile.TemporaryDirectory() as directory:
        binary = Path(directory) / 'hostfs-harness'
        run(['xcrun', 'clang', '-O1', '-Wall', '-Werror=implicit-function-declaration', '-include', 'stdlib.h',
             '-Dpanic(message)=abort()', '-I', hostfs, ROOT / 'Tests/RuntimeTests/hostfs_harness.c',
             hostfs / 'hostfs_user.c', '-o', binary], env=dict(os.environ, SDKROOT=''))
        output = subprocess.check_output([str(binary), str(iterations)], text=True, timeout=600)
    return json.loads(output)


def prefix_maps():
    return [f'-ffile-prefix-map={ROOT}=.', f'-ffile-prefix-map={Path.home()}=/builder']


def toolchain_env():
    env = os.environ.copy()
    env.pop('SDKROOT', None)
    extra = [p for p in ['/opt/homebrew/opt/lld/bin', '/opt/homebrew/opt/llvm/bin', '/opt/homebrew/bin',
                         '/usr/local/opt/lld/bin', '/usr/local/bin'] if Path(p).is_dir()]
    env['PATH'] = ':'.join(extra + [env.get('PATH', '')])
    # No local checkout or home paths in kernel/emulator strings (__FILE__,
    # assertions). In a meson cross build CFLAGS reach only the build machine,
    # so patch 0007 adds these to the cross file's c_args, which the kernel's
    # CC also uses.
    env['POCKETAGENT_MESON_C_ARGS'] = ', '.join("'" + arg.replace("'", "\\'") + "'" for arg in prefix_maps())
    env['KCFLAGS'] = ' '.join(prefix_maps())
    env['CFLAGS'] = ' '.join(prefix_maps())
    env.update(KERNEL_IDENTITY)
    return env


# linux_banner otherwise embeds the builder's user@host and the build time.
KERNEL_IDENTITY = {'KBUILD_BUILD_USER': 'builder', 'KBUILD_BUILD_HOST': 'pocketagent',
                   'KBUILD_BUILD_TIMESTAMP': 'Thu Jan  1 00:00:00 UTC 2026', 'KBUILD_BUILD_VERSION': '1'}


def write_notices(source):
    """License texts bundled in the app (App/Resources/iSHLicenses)."""
    notices = ROOT / 'App/Resources/iSHLicenses'
    shutil.rmtree(notices, ignore_errors=True)
    notices.mkdir(parents=True)
    for name in ['LICENSE.md', 'LICENSE.IOS']:
        shutil.copy2(source / name, notices / name)
    shutil.copy2(source / 'deps/libarchive/COPYING', notices / 'libarchive-COPYING')
    shutil.copy2(source / 'deps/linux/COPYING', notices / 'linux-COPYING')
    (notices / 'SOURCE.txt').write_text(
        'The script runtime combines iSH with the iSH Linux kernel (GPL-2.0-only). iSH is licensed under\n'
        'GPL-3.0 and, per its LICENSE.md, its contributions are additionally licensed under GPL-2.0 to allow\n'
        'linking with Linux; LICENSE.IOS grants an additional permission. The app binary containing this\n'
        'runtime is therefore distributed under the terms of the GNU GPL version 2. PocketAgent\'s own code\n'
        'is MIT-licensed and libarchive is BSD-2-Clause, both GPL-compatible.\n\n'
        'The complete corresponding source, PocketAgent-iSH-source-<version>.tar.gz, is published next to\n'
        'each release IPA: the PocketAgent source tree, the pinned upstream iSH, Linux and libarchive\n'
        'archives, PocketAgent\'s patches (Native/ish/patches), the Swift package and idevice sources, the\n'
        'vendored Rust crates and the build scripts. The bundled Alpine rootfs lists its packages in\n'
        '/etc/pocketagent-packages; their sources are in the Alpine Linux v3.19 repositories.\n')


def library_paths(products):
    """Local checkout/home paths or the builder's user@host left in built
    archives (debug info, __FILE__, the kernel banner)."""
    markers = [str(Path.home()).encode(), (getpass.getuser() + '@').encode()]
    found = {}
    for library in LIBRARIES + ['libiSHHost']:
        data = (products / f'{library}.a').read_bytes()
        count = sum(data.count(marker) for marker in markers)
        if count:
            found[library] = count
    return found


def build(configuration='Release', force=False):
    source = fetch()
    products = OUT / f'{configuration}-iphoneos'
    marker = products / '.pocketagent-build'
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip()
    settings = hashlib.sha256(json.dumps([prefix_maps(), KERNEL_IDENTITY]).encode()).hexdigest()[:16]
    signature = f'{configuration}:{sdk}:{source_signature()}:{settings}'
    write_notices(source)
    if not force and marker.is_file() and marker.read_text() == signature and \
            all((products / f'{lib}.a').is_file() for lib in LIBRARIES + ['libiSHHost']):
        print('iSH static libraries are current:', products)
        return products
    # A changed source or setting is a clean build: an existing meson
    # directory keeps its first cross file and options.
    shutil.rmtree(products, ignore_errors=True)
    products.mkdir(parents=True)
    result = check_hostfs()
    if result['failures'] or result['outsideReads'] or result['outsideChanged']:
        raise SystemExit(f'hostfs confinement check failed: {result}')
    env = toolchain_env()
    prefix = ['OTHER_CFLAGS=$(inherited) ' + ' '.join(prefix_maps())]
    for project, target, config in [('iSH.xcodeproj', 'liblinux', f'{configuration}Linux'),
                                    ('iSH.xcodeproj', 'libiSHLinux', f'{configuration}Linux'),
                                    ('iSH.xcodeproj', 'libiSHLinuxUser', f'{configuration}Linux'),
                                    ('iSH.xcodeproj', 'libfakefs', f'{configuration}Linux'),
                                    ('iSH.xcodeproj', 'libish_emu', f'{configuration}Linux'),
                                    ('deps/libarchive.xcodeproj', 'libarchive', configuration)]:
        built = products / f'.{target}'
        run(['xcodebuild', '-project', source / project, '-target', target, '-configuration', config,
             '-sdk', 'iphoneos', 'ARCHS=arm64', 'IPHONEOS_DEPLOYMENT_TARGET=16.4',
             f'CONFIGURATION_BUILD_DIR={built}', f'OBJROOT={products}/.obj-{target}', f'SYMROOT={built}',
             f'MESON_BUILD_DIR={products}/meson', 'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO',
             *prefix, 'build'], env=env)
        output = built / f'{target}.a'
        if not output.is_file():
            output = products / 'meson' / f'{target}.a'
        shutil.copy2(output, products / f'{target}.a')
    options = (products / 'meson/meson-private/cmd_line.txt').read_text()
    if configuration == 'Release' and 'buildtype = debugoptimized' not in options:
        raise SystemExit('iSH meson build is not optimized:\n' + options)
    # fakefs import (tools/fakefs.c) and fchdir helper are not Xcode targets.
    sdk_path = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    objects = []
    for c in ['tools/fakefs.c', 'util/fchdir.c']:
        obj = products / (Path(c).stem + '.o')
        run(['xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64', '-isysroot', sdk_path,
             '-miphoneos-version-min=16.4', '-O2', *prefix_maps(),
             '-I', source, '-I', source / 'deps/libarchive/libarchive', '-c', source / c, '-o', obj], env=env)
        objects.append(obj)
    run(['xcrun', '--sdk', 'iphoneos', 'libtool', '-static', '-o', products / 'libiSHHost.a', *objects], env=env)
    symbols = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', 'nm', '-gU', products / 'libiSHLinux.a'], text=True)
    symbols += subprocess.check_output(['xcrun', '--sdk', 'iphoneos', 'nm', '-gU', products / 'liblinux.a'], text=True)
    for symbol in ['_pocket_mount_workspace', '_pocket_run_process', '_pocket_user_tasks',
                   '_pocket_set_blocked_hosts', '_pocket_hostfs_set_root']:
        if symbol not in symbols:
            raise SystemExit('Patched iSH symbol missing: ' + symbol)
    leaked = library_paths(products)
    if leaked:
        raise SystemExit(f'Local paths in iSH libraries: {leaked}')
    marker.write_text(signature)
    print(products)
    return products


def package_lock():
    """`name=version` for every package of the locked Alpine closure."""
    lock = pins()['alpineRootfs']['lock']
    pinned = []
    for entry in lock:
        name, version, release = entry.rsplit('-', 2)
        pinned.append(f'{name}={version}-{release}')
    return lock, pinned


# Bumped when the repacked archive's layout changes (2: explicit root entry).
ROOTFS_LAYOUT = 2


def rootfs_signature():
    spec = pins()['alpineRootfs']
    setup = ROOT / 'Native/ish/rootfs/setup.sh'
    return hashlib.sha256(json.dumps([spec, ROOTFS_LAYOUT], sort_keys=True).encode() + setup.read_bytes()).hexdigest()


def deterministic_gzip(path):
    """A gzip stream without the current time or file name in its header."""
    raw = path.open('wb')
    return raw, gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0, compresslevel=9)


def rootfs(force=False):
    """Build an i386 Alpine rootfs from a pinned image digest and a locked package closure."""
    spec = pins()['alpineRootfs']
    output = OUT / 'ish-root.tar.gz'
    stamp = OUT / 'ish-root.signature'
    setup = ROOT / 'Native/ish/rootfs/setup.sh'
    signature = rootfs_signature()
    if not force and output.is_file() and stamp.is_file() and stamp.read_text() == signature:
        print('Rootfs is current:', output)
        return output
    OUT.mkdir(parents=True, exist_ok=True)
    lock, pinned = package_lock()
    container = 'pocketagent-ish-rootfs'
    subprocess.run(['docker', 'rm', '-f', container], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run(['docker', 'create', '--platform', spec['platform'], '--name', container, '--network', 'bridge',
         '-e', 'POCKETAGENT_REPOSITORY=' + spec['repository'], '-e', 'POCKETAGENT_PACKAGES=' + ' '.join(pinned),
         '-e', 'POCKETAGENT_LOCK=' + ' '.join(lock), spec['image'], 'sh', '/setup.sh'])
    run(['docker', 'cp', setup, f'{container}:/setup.sh'])
    run(['docker', 'start', '-a', container])
    raw = OUT / 'rootfs-export.tar'
    run(['docker', 'export', '-o', raw, container])
    run(['docker', 'rm', '-f', container])
    # Repack deterministically. Docker bind-mounts these three files at run
    # time; the exported copies are placeholders, so the guest versions are
    # written here.
    generated = {'etc/resolv.conf': b'nameserver 1.1.1.1\nnameserver 8.8.8.8\n',
                 'etc/hosts': b'127.0.0.1\tlocalhost\n::1\tlocalhost\n',
                 'etc/hostname': b'pocketagent\n'}
    partial = output.with_suffix('.part')
    stream, compressed = deterministic_gzip(partial)
    with tarfile.open(raw) as source, stream, compressed, \
            tarfile.open(fileobj=compressed, mode='w', format=tarfile.GNU_FORMAT) as target:
        # docker export has no entry for the root itself; the iSH importer
        # then records the root as mode 0755 without S_IFDIR, and the kernel
        # cannot read it (fakefs: unexpected S_IFMT 0, EIO, no init, panic).
        root = tarfile.TarInfo('./')
        root.type = tarfile.DIRTYPE; root.mode = 0o755; root.mtime = EPOCH
        target.addfile(root)
        for member in sorted(source.getmembers(), key=lambda m: m.name):
            name = member.name.removeprefix('./')
            if name in ['', '.', '.dockerenv', 'setup.sh'] or name in generated:
                continue
            member.mtime = EPOCH
            member.uname = member.gname = ''
            target.addfile(member, source.extractfile(member) if member.isfile() else None)
        for name, data in generated.items():
            info = tarfile.TarInfo(name)
            info.size = len(data); info.mode = 0o644; info.mtime = EPOCH
            target.addfile(info, io.BytesIO(data))
    raw.unlink()
    partial.replace(output)
    verify_rootfs(output)
    stamp.write_text(signature)
    print(output, output.stat().st_size, sha256(output))
    return output


def verify_rootfs(path=OUT / 'ish-root.tar.gz'):
    """The archive holds exactly the locked packages, the runtime files the
    app relies on and no setuid/setgid file or Docker leftover."""
    lock, _ = package_lock()
    required = ['sbin/init', 'bin/sh', 'bin/bash', 'usr/bin/python3', 'usr/bin/node', 'usr/bin/npm', 'etc/inittab',
                'usr/local/bin/pocketagent-phone',
                'etc/resolv.conf', 'etc/passwd', 'workspace', 'home/pocket', 'dev']
    with tarfile.open(path) as archive:
        entries = archive.getmembers()
        members = {m.name.removeprefix('./'): m for m in entries}
        packages = archive.extractfile(members['etc/pocketagent-packages']).read().decode().split()
        passwd = archive.extractfile(members['etc/passwd']).read().decode()
    problems = []
    if sorted(packages) != sorted(lock):
        problems.append(f'package closure differs from dependencies.json lock: '
                        f'extra {sorted(set(packages) - set(lock))}, missing {sorted(set(lock) - set(packages))}')
    problems += [f'missing {name}' for name in required if name not in members]
    roots = [m for m in entries if m.name.rstrip('/') in ['', '.']]
    if not (len(roots) == 1 and roots[0] is entries[0] and roots[0].isdir() and roots[0].mode & 0o777 == 0o755):
        problems.append('the first entry must be the root directory (mode 0755), exactly once')
    problems += [f'setuid/setgid {name}' for name, m in members.items() if m.isfile() and m.mode & 0o6000]
    problems += [f'unexpected {name}' for name in ['.dockerenv', 'setup.sh'] if name in members]
    launcher = members.get('usr/local/bin/pocketagent-phone')
    if launcher is not None and (not launcher.isfile() or launcher.mode & 0o777 != 0o755):
        problems.append('usr/local/bin/pocketagent-phone must be a regular file with mode 0755')
    if 'pocket:x:501:501:' not in passwd:
        problems.append('uid 501 user missing')
    if problems:
        raise SystemExit('Rootfs verification failed:\n' + '\n'.join(problems))
    print('Rootfs verified:', path, sha256(path))


def git_files(directory):
    """Tracked and unignored files of a checkout (local signing data is ignored)."""
    names = subprocess.check_output(['git', '-C', str(directory), 'ls-files', '--cached', '--others',
                                     '--exclude-standard', '-z'], text=True).split('\0')
    return [n for n in sorted(set(names)) if n and (directory / n).is_file()]


def add_tree(tar, directory, prefix, files):
    for name in files:
        info = tar.gettarinfo(str(directory / name), arcname=f'{prefix}/{name}')
        info.mtime = EPOCH
        info.uid = info.gid = 0
        info.uname = info.gname = ''
        if info.isreg():
            with (directory / name).open('rb') as data:
                tar.addfile(info, data)
        else:
            tar.addfile(info)


def source_archive(strict=False):
    """Complete corresponding source of the GPL-2.0 app binary."""
    fetch()
    output = OUT / 'PocketAgent-iSH-source.tar.gz'
    modules = []
    resolved = json.loads((ROOT / 'Package.resolved').read_text())['pins']
    checkouts = ROOT / '.build/DerivedData/SourcePackages/checkouts'
    for pin in resolved:
        checkout = next((p for p in checkouts.glob('*') if p.name.lower() == pin['identity']), None) \
            if checkouts.is_dir() else None
        modules.append((pin['identity'], checkout, pin['state']['revision']))
    idevice = pins()['idevice']
    idevice_checkout = idevice_source_path()
    modules.append(('idevice', idevice_checkout, idevice['revision']))
    missing = [name for name, checkout, _ in modules if checkout is None or not checkout.is_dir()]
    if missing and strict:
        raise SystemExit('Corresponding source missing for: ' + ', '.join(missing))
    partial = output.with_suffix('.part')
    stream, compressed = deterministic_gzip(partial)
    with stream, compressed, tarfile.open(fileobj=compressed, mode='w', format=tarfile.GNU_FORMAT) as tar:
        add_tree(tar, ROOT, 'pocketagent', git_files(ROOT))
        for spec in pins()['iSH']['archives']:
            info = tar.gettarinfo(str(DOWNLOADS / archive_name(spec)), arcname='upstream/' + archive_name(spec))
            info.mtime = EPOCH; info.uid = info.gid = 0; info.uname = info.gname = ''
            with (DOWNLOADS / archive_name(spec)).open('rb') as data:
                tar.addfile(info, data)
        for name, checkout, revision in modules:
            if name in missing:
                continue
            actual = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
            if actual != revision:
                raise SystemExit(f'{name} checkout is {actual}, pinned {revision}')
            # The pinned upstream tree; PocketAgent's own changes (Native/idevice.patch) are in pocketagent/.
            blob = subprocess.check_output(['git', '-C', str(checkout), 'archive', '--format=tar',
                                            f'--prefix={name}/', revision])
            info = tarfile.TarInfo(f'modules/{name}-{revision}.tar')
            info.size = len(blob); info.mtime = EPOCH; info.mode = 0o644
            tar.addfile(info, io.BytesIO(blob))
        if 'idevice' not in missing:
            with tempfile.TemporaryDirectory() as directory:
                vendor = Path(directory) / 'vendor'
                # The iOS build downloads only that target's crates; the
                # corresponding source is every crate in the lock.
                manifest = idevice_checkout / 'Cargo.toml'
                run(['cargo', 'fetch', '--locked', '--manifest-path', manifest], stdout=subprocess.DEVNULL)
                run(['cargo', 'vendor', '--offline', '--locked', '--manifest-path', manifest, vendor],
                    stdout=subprocess.DEVNULL)
                files = sorted(str(p.relative_to(vendor)) for p in vendor.rglob('*') if p.is_file())
                add_tree(tar, vendor, 'modules/idevice-crates', files)
        readme = ('PocketAgent corresponding source\n\n'
                  'pocketagent/        PocketAgent source tree (MIT); Scripts/build.py and Scripts/ish_runtime.py\n'
                  '                    rebuild the app, the iSH libraries and the rootfs from these inputs.\n'
                  'upstream/           pinned iSH, Linux and libarchive archives (dependencies.json).\n'
                  'modules/            pinned Swift package and idevice sources, idevice-crates/ = cargo vendor\n'
                  '                    output for idevice\'s Cargo.lock.\n'
                  + (f'\nNot included in this local archive: {", ".join(missing)}\n' if missing else ''))
        info = tarfile.TarInfo('README.txt')
        info.size = len(readme.encode()); info.mtime = EPOCH; info.mode = 0o644
        tar.addfile(info, io.BytesIO(readme.encode()))
    partial.replace(output)
    print(output, output.stat().st_size, 'missing modules: ' + (', '.join(missing) or 'none'))
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['fetch', 'build', 'rootfs', 'verify-rootfs', 'source', 'all'])
    parser.add_argument('--configuration', default='Release')
    parser.add_argument('--force', action='store_true')
    parser.add_argument('--strict', action='store_true', help='source: fail if a module source is missing')
    args = parser.parse_args()
    if args.command == 'fetch':
        print(fetch(args.force))
    if args.command in ['build', 'all']:
        build(args.configuration, args.force)
    if args.command in ['rootfs', 'all']:
        rootfs(args.force)
    if args.command == 'verify-rootfs':
        verify_rootfs()
    if args.command in ['source', 'all']:
        source_archive(args.strict)


if __name__ == '__main__':
    main()
