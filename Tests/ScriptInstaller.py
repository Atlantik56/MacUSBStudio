#!/usr/bin/env python3
"""Exercise the standalone shell installer using only private test folders/DMG."""
import hashlib
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
image = root / 'dist/Mac.USB.Studio-2.1.0.dmg'
payload = (root / 'install.sh').read_text()
checks = []

def digest(path):
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in path.rglob('*') if p.is_file()}

with tempfile.TemporaryDirectory(prefix='mac-usb-script-check-', dir='/private/tmp') as folder:
    folder = pathlib.Path(folder)
    runner = folder / 'embedded.sh'
    runner.write_text(payload)
    def run(destination, *args, error=None):
        result = subprocess.run(['/bin/bash', str(runner), '--yes', '--no-open', '--image', str(image),
                                 '--destination', str(destination), *args], text=True, capture_output=True)
        if error is None:
            assert result.returncode == 0, result.stdout + result.stderr
        else:
            assert result.returncode != 0 and error in result.stderr, result.stdout + result.stderr
        return result
    destination = folder / 'Программы с пробелами'
    run(destination)
    app = destination / 'Mac USB Studio.app'
    assert digest(app) == digest(root / 'build/Mac USB Studio.app')
    checks.append('fresh install: all app bytes equal the golden build; path with spaces and Cyrillic')
    run(destination)
    backups = list(destination.glob('Mac USB Studio.previous-*.app'))
    assert len(backups) == 1 and digest(backups[0]) == digest(app)
    assert not list(destination.glob('.mac-usb-studio-install*'))
    checks.append('existing matching app preserved as an exact backup; staging and lock removed')

    foreign = folder / 'foreign'
    foreign.mkdir()
    (foreign / app.name).write_text('preserve this file')
    run(foreign, error='другой файл')
    assert (foreign / app.name).read_text() == 'preserve this file'
    checks.append('foreign file not overwritten')

    linked = folder / 'linked'
    linked.mkdir()
    (linked / app.name).symlink_to(app)
    run(linked, error='символической ссылкой')
    directory_link = folder / 'directory-link'
    directory_link.symlink_to(destination)
    run(directory_link, error='символической ссылкой')
    checks.append('app symlink and destination symlink both rejected')

    lock = destination / '.mac-usb-studio-install.lock'
    lock.mkdir()
    run(destination, error='Другая установка')
    assert lock.is_dir()
    lock.rmdir()
    checks.append('existing installation lock preserved and respected')

    info_path = app / 'Contents/Info.plist'
    original_info = info_path.read_bytes()
    info = plistlib.loads(original_info)
    info['CFBundleShortVersionString'] = '9.0.0'
    info_path.write_bytes(plistlib.dumps(info))
    run(destination, error='более новая версия')
    assert plistlib.loads(info_path.read_bytes())['CFBundleShortVersionString'] == '9.0.0'
    info_path.write_bytes(original_info)
    checks.append('newer installed version not downgraded')

    wrong_image = folder / 'wrong.dmg'
    wrong_image.write_bytes(b'wrong bytes')
    run(destination, '--image', str(wrong_image), error='SHA-256')
    checks.append('wrong checksum blocked before opening or changing the app')

    quarantined = folder / 'browser.dmg'
    shutil.copyfile(image, quarantined)
    quarantine_value = '0081;00000000;TestBrowser;installer-test'
    subprocess.run(['/usr/bin/xattr', '-w', 'com.apple.quarantine', quarantine_value, str(quarantined)], check=True)
    run(destination, '--image', str(quarantined), error='карантином')
    assert subprocess.check_output(['/usr/bin/xattr', '-p', 'com.apple.quarantine', str(quarantined)], text=True).strip() == quarantine_value
    checks.append('quarantined input rejected; quarantine attribute remains identical')

    sleeper = folder / 'MacUSBRecorder'
    shutil.copyfile('/bin/sleep', sleeper)
    sleeper.chmod(0o755)
    process = subprocess.Popen([str(sleeper), '60'])
    try:
        subprocess.run(['/usr/bin/pgrep', '-x', 'MacUSBRecorder'], check=True, stdout=subprocess.DEVNULL)
        run(destination, error='процесс записи работает')
        checks.append('active recorder blocks replacement before any download or install')
    finally:
        process.terminate()
        process.wait()
    run(folder / 'unused', '--verify-only')
    assert not (folder / 'unused').exists()
    checks.append('verify-only mode changes no installation folder')
    assert digest(app) == digest(root / 'build/Mac USB Studio.app')
    assert not list(destination.glob('.mac-usb-studio-install*'))
    mounts = subprocess.check_output(['/usr/bin/hdiutil', 'info'], text=True)
    assert str(folder) not in mounts, 'Test image still mounted'
    checks.append('original app bytes intact after failures; no remaining mounts/staging/locks')
    result = subprocess.run(['/bin/bash', str(runner)], text=True, input='', capture_output=True)
    assert result.returncode != 0 and 'автоматический запуск требует --yes' in result.stderr
    checks.append('noninteractive install requires explicit confirmation flag')

print(f'{len(checks)} script installer checks passed:')
for check in checks:
    print('- ' + check)
