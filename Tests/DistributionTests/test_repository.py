import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('privacy', ROOT / 'Scripts/check_repository.py')
privacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(privacy)


class RepositoryPrivacyTests(unittest.TestCase):
    def test_checkout_under_runner_work_directory_and_private_child(self):
        with tempfile.TemporaryDirectory() as directory:
            checkout = Path(directory) / 'work' / 'checkout'
            checkout.mkdir(parents=True)
            subprocess.run(['git', 'init', '--quiet', str(checkout)], check=True)
            (checkout / 'App.swift').write_text('import Foundation\n')
            subprocess.run(['git', 'add', 'App.swift'], cwd=checkout, check=True)
            with patch.object(privacy, 'ROOT', checkout), contextlib.redirect_stdout(io.StringIO()):
                privacy.main()
                private = checkout / 'work' / 'private.swift'
                private.parent.mkdir()
                private.write_text('private data\n')
                with self.assertRaisesRegex(SystemExit, 'work/private.swift: private/generated file'):
                    privacy.main()
