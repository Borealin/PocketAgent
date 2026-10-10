import importlib.util
import pathlib
import json
import os
import subprocess
import tempfile
import unittest
from unittest.mock import patch

MODULE = pathlib.Path(__file__).resolve().parents[2] / 'Scripts/distribution.py'
spec = importlib.util.spec_from_file_location('distribution', MODULE)
distribution = importlib.util.module_from_spec(spec)
spec.loader.exec_module(distribution)
publish_spec = importlib.util.spec_from_file_location('publish', MODULE.parent / 'publish.py')
publish = importlib.util.module_from_spec(publish_spec)
publish_spec.loader.exec_module(publish)


class SourceTests(unittest.TestCase):
    def metadata(self):
        return {'bundleIdentifier': 'test.app', 'version': '2.0', 'buildVersion': '2',
                'minOSVersion': '26.0', 'size': 512, 'sha256': 'a' * 64,
                'appPermissions': {'entitlements': ['get-task-allow'], 'privacy': {'NSLocalNetworkUsageDescription': 'Local device'}}}

    def test_release_update_preserves_older_versions_and_is_idempotent(self):
        old = {'name': 'PocketAgent', 'news': [], 'apps': [{'name': 'PocketAgent', 'bundleIdentifier': 'test.app',
                'developerName': 'Test', 'localizedDescription': 'Test', 'iconURL': 'https://example.com/icon.png',
                'versions': [dict(self.metadata(), version='1.0', buildVersion='1', date='2026-01-01',
                                 downloadURL='https://example.com/old.ipa')]}]}
        with patch.object(distribution, 'inspect_ipa', return_value=self.metadata()):
            new = distribution.generate_source([('PocketAgent', pathlib.Path('PocketAgent-2.0.ipa'))], 'owner/repo', old, '2026-10-10')
            again = distribution.generate_source([('PocketAgent', pathlib.Path('PocketAgent-2.0.ipa'))], 'owner/repo', new, '2026-10-10')
        self.assertEqual(new, again)
        self.assertEqual([v['version'] for v in new['apps'][0]['versions']], ['2.0', '1.0'])
        self.assertEqual(new['apps'][0]['appPermissions'], self.metadata()['appPermissions'])
        self.assertEqual(new['apps'][0]['versions'][0]['downloadURL'], 'https://github.com/owner/repo/releases/download/v2.0/PocketAgent-2.0.ipa')
        self.assertEqual(len(old['apps'][0]['versions']), 1)

    def test_duplicate_bundle_rejected(self):
        with patch.object(distribution, 'inspect_ipa', return_value=self.metadata()):
            source = distribution.generate_source([('PocketAgent', pathlib.Path('app.ipa'))], 'owner/repo', date='2026-10-10')
        source['apps'].append(source['apps'][0].copy())
        with self.assertRaises(ValueError):
            distribution.validate_source(source)

    def test_crypto_parser_token_is_distinct_from_private_key_material(self):
        header = b'-----' + b'BEGIN PRIVATE KEY' + b'-----'
        footer = b'-----' + b'END PRIVATE KEY' + b'-----'
        self.assertIsNone(distribution.PRIVATE_KEY_BLOCK.search(header))
        self.assertIsNotNone(distribution.PRIVATE_KEY_BLOCK.search(header + b'\n' + b'A' * 64 + b'\n' + footer))

    def test_publish_merges_current_main_after_tag_snapshot(self):
        def entry(number):
            return dict(self.metadata(), version=number, buildVersion='1')
        current = {'name': 'PocketAgent', 'news': [], 'apps': [{'bundleIdentifier': 'test.app',
                    'versions': [entry('0.2.0'), entry('0.1.0')], 'appPermissions': {'privacy': {}}}]}
        release = {'name': 'PocketAgent', 'news': [], 'apps': [{'bundleIdentifier': 'test.app',
                    'versions': [entry('0.3.0'), entry('0.1.0')], 'appPermissions': {'privacy': {'new': 'reason'}}}]}
        merged = publish.merge_published_source(current, release)
        self.assertEqual([v['version'] for v in merged['apps'][0]['versions']], ['0.3.0', '0.2.0', '0.1.0'])
        self.assertEqual(publish.merge_published_source(merged, release), merged)
        self.assertEqual(publish.merge_published_source(merged, current), merged)
        self.assertEqual(len(current['apps'][0]['versions']), 2)

    def test_ci_artifact_replaces_same_version_local_hash(self):
        local = dict(self.metadata(), version='0.2.0', buildVersion='1')
        old = dict(self.metadata(), version='0.1.0', buildVersion='1', sha256='c' * 64)
        current = {'apps': [{'bundleIdentifier': 'test.app', 'versions': [local, old]}]}
        built = dict(local, sha256='b' * 64, size=1024)
        stale_old = dict(old, sha256='d' * 64)
        release = {'apps': [{'bundleIdentifier': 'test.app', 'versions': [built, stale_old]}]}
        merged = publish.merge_published_source(current, release)
        self.assertEqual(merged['apps'][0]['versions'], [built, old])
        self.assertEqual(current['apps'][0]['versions'][0]['sha256'], 'a' * 64)

    def test_publish_bootstraps_feed_without_touching_dirty_build_checkout(self):
        real_run = subprocess.run
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory) / 'build'
            remote = pathlib.Path(directory) / 'remote.git'
            root.mkdir()

            def git(*args, cwd=root):
                return real_run(['git', *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()

            git('init', '--bare', str(remote))
            git('init', '-b', 'main')
            (root / 'Native').mkdir()
            header = root / 'Native/idevice.h'
            header.write_text('original header\n')
            git('add', '.')
            git('-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-m', 'Initial source without feed')
            head = git('rev-parse', 'HEAD')
            git('remote', 'add', 'origin', str(remote))
            git('push', 'origin', 'main')
            git('tag', 'v2.0')
            header.write_text('regenerated header\n')
            (root / 'Distribution').mkdir()
            with patch.object(distribution, 'inspect_ipa', return_value=self.metadata()):
                source = distribution.generate_source([('PocketAgent', pathlib.Path('app.ipa'))], 'owner/repo', date='2026-10-10')
            (root / 'Distribution/source.json').write_text(json.dumps(source))
            (root / 'dist').mkdir()
            (root / 'dist/app.ipa').write_bytes(b'fixture')
            (root / 'dist/SHA256SUMS').write_text('fixture\n')
            gh_calls = []

            def run(args, **kwargs):
                if args[0] == 'gh':
                    gh_calls.append(args)
                    return subprocess.CompletedProcess(args, 1 if args[1:3] == ['release', 'view'] else 0)
                if not kwargs.get('capture_output'):
                    kwargs.setdefault('stdout', subprocess.PIPE)
                    kwargs.setdefault('stderr', subprocess.PIPE)
                return real_run(args, **kwargs)

            with patch.object(publish, 'ROOT', root), patch.dict(os.environ, {'RELEASE_TAG': 'v2.0'}), \
                    patch.object(subprocess, 'run', side_effect=run):
                publish.main()
            self.assertEqual(git('rev-parse', 'HEAD'), head)
            self.assertEqual(header.read_text(), 'regenerated header\n')
            published = json.loads(git('show', 'main:Distribution/source.json', cwd=remote))
            self.assertEqual(published, source)
            self.assertEqual(git('worktree', 'list', '--porcelain').count('worktree '), 1)
            self.assertTrue(any(args[1:3] == ['release', 'create'] for args in gh_calls))


if __name__ == '__main__':
    unittest.main()
