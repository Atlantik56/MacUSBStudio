#!/usr/bin/env python3
"""macOS integration checks in private temporary folders; never touches USB or ~/Applications."""
import hashlib
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'install.sh'
ARCHIVE = pathlib.Path(sys.argv.pop(1)).resolve()
QUARANTINE = 'com.apple.quarantine'
QUARANTINE_VALUE = '0083;00000000;MacUSBStudio-Test;'


class InstallChecks(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix='mac-usb-studio-install-checks.', dir='/private/tmp'))
        self.destination = self.root / 'Applications'
        self.target = self.destination / 'Mac USB Studio.app'
        self.archive = self.root / 'release.zip'
        shutil.copy2(ARCHIVE, self.archive)
        self.other = self.root / 'Unrelated.app'
        self.other.mkdir()
        (self.other / 'keep.txt').write_text('do not change')
        subprocess.run(['/usr/bin/xattr', '-w', QUARANTINE, QUARANTINE_VALUE, str(self.other)], check=True)

    def tearDown(self):
        self.assertEqual((self.other / 'keep.txt').read_text(), 'do not change')
        self.assertEqual(self.quarantine(self.other), QUARANTINE_VALUE)
        shutil.rmtree(self.root)

    def quarantine(self, path):
        result = subprocess.run(['/usr/bin/xattr', '-p', QUARANTINE, str(path)], capture_output=True, text=True)
        return result.stdout.strip() if result.returncode == 0 else None

    def install(self):
        return subprocess.run(['/bin/bash', str(SCRIPT), '--archive', str(self.archive),
                               '--destination', str(self.destination), '--no-open'],
                              capture_output=True, text=True, timeout=45)

    def fake_app(self, version='2.1.0', build='30', identifier='local.mac-usb-studio'):
        (self.target / 'Contents').mkdir(parents=True)
        info = {'CFBundleIdentifier': identifier, 'CFBundleShortVersionString': version,
                'CFBundleVersion': build}
        (self.target / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        (self.target / 'keep.txt').write_text('old application')

    def assert_no_install_files(self):
        self.assertFalse(list(self.destination.glob('.mac-usb-studio-install*')))
        self.assertFalse(list(self.destination.glob('Mac USB Studio.previous-*')))

    def test_valid_install_and_scoped_quarantine(self):
        subprocess.run(['/usr/bin/xattr', '-w', QUARANTINE, QUARANTINE_VALUE, str(self.archive)], check=True)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.quarantine(self.archive), QUARANTINE_VALUE)
        self.assertIsNone(self.quarantine(self.target))
        with zipfile.ZipFile(ARCHIVE) as archive:
            expected = {name.removeprefix('Mac USB Studio.app/'): hashlib.sha256(archive.read(name)).hexdigest()
                        for name in archive.namelist() if name.startswith('Mac USB Studio.app/') and not name.endswith('/')}
        actual = {str(path.relative_to(self.target)): hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in self.target.rglob('*') if path.is_file()}
        self.assertEqual(expected, actual)
        for path in self.target.rglob('*'):
            self.assertIsNone(self.quarantine(path), str(path))
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--all-architectures', str(self.target)], check=True)
        self.assert_no_install_files()

    def test_bad_checksum_preserves_existing_app(self):
        self.fake_app()
        original = (self.target / 'Contents/Info.plist').read_bytes()
        with self.archive.open('ab') as file:
            file.write(b'tampered download')
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SHA-256', result.stderr)
        self.assertEqual((self.target / 'Contents/Info.plist').read_bytes(), original)
        self.assertEqual((self.target / 'keep.txt').read_text(), 'old application')
        self.assert_no_install_files()

    def test_reinstall_preserves_previous_copy_and_its_quarantine(self):
        self.fake_app(version='2.0.4', build='29')
        subprocess.run(['/usr/bin/xattr', '-w', QUARANTINE, QUARANTINE_VALUE, str(self.target)], check=True)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        backups = list(self.destination.glob('Mac USB Studio.previous-*.app'))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / 'keep.txt').read_text(), 'old application')
        self.assertEqual(self.quarantine(backups[0]), QUARANTINE_VALUE)
        self.assertFalse((self.target / 'keep.txt').exists())
        self.assertIsNone(self.quarantine(self.target))
        self.assertFalse(list(self.destination.glob('.mac-usb-studio-install*')))

    def test_newer_version_is_preserved(self):
        self.fake_app(version='3.0.0', build='1')
        original = (self.target / 'Contents/Info.plist').read_bytes()
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('более новая версия', result.stderr)
        self.assertEqual((self.target / 'Contents/Info.plist').read_bytes(), original)
        self.assert_no_install_files()

    def test_newer_build_is_preserved(self):
        self.fake_app(build='31')
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('более новая версия', result.stderr)
        self.assertEqual((self.target / 'keep.txt').read_text(), 'old application')
        self.assert_no_install_files()

    def test_foreign_application_is_preserved(self):
        self.fake_app(identifier='example.other-app')
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('другой файл или приложение', result.stderr)
        self.assertEqual((self.target / 'keep.txt').read_text(), 'old application')
        self.assert_no_install_files()

    def test_symlink_is_not_followed(self):
        self.destination.mkdir()
        self.target.symlink_to(self.other, target_is_directory=True)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('символической ссылкой', result.stderr)
        self.assertTrue(self.target.is_symlink())
        self.assert_no_install_files()

    def test_existing_lock_is_preserved(self):
        self.destination.mkdir()
        lock = self.destination / '.mac-usb-studio-install.lock'
        lock.mkdir()
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Другая установка', result.stderr)
        self.assertTrue(lock.is_dir())
        self.assertFalse(self.target.exists())

    def test_active_recorder_blocks_installation(self):
        executable = self.root / 'MacUSBRecorder'
        subprocess.run(['/usr/bin/xcrun', 'clang', '-x', 'c', '-', '-o', str(executable)],
                       input='#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n',
                       text=True, check=True, capture_output=True)
        process = subprocess.Popen([str(executable)])
        try:
            for _ in range(50):
                found = subprocess.run(['/usr/bin/pgrep', '-x', 'MacUSBRecorder'], capture_output=True, text=True)
                if str(process.pid) in found.stdout.splitlines():
                    break
                time.sleep(0.02)
            else:
                self.fail('Temporary recorder process was not visible to pgrep')
            result = self.install()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('процесс записи работает', result.stderr)
            self.assertFalse(self.destination.exists())
        finally:
            process.terminate()
            process.wait(timeout=5)


unittest.main(verbosity=2)
