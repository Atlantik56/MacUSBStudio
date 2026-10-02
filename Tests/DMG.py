#!/usr/bin/env python3
"""Verify the actual release image without installing the app or changing physical USB."""
import hashlib
import pathlib
import subprocess
import sys
import tempfile

image, source = map(lambda p: pathlib.Path(p).resolve(), sys.argv[1:])
subprocess.run(['/usr/bin/hdiutil', 'verify', str(image)], check=True)
with tempfile.TemporaryDirectory(prefix='mac-usb-dmg-check-', dir='/private/tmp') as folder:
    volume = pathlib.Path(folder) / 'volume'
    subprocess.run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(volume), str(image)], check=True)
    try:
        entries = {p.name for p in volume.iterdir() if not p.name.startswith('.')}
        assert entries == {'Mac USB Studio.app', 'Applications'}, entries
        shortcut = volume / 'Applications'
        assert shortcut.is_symlink() and str(shortcut.readlink()) == '/Applications'
        app = volume / 'Mac USB Studio.app'
        for p in (app, app / 'Contents/Helpers/MacUSBRecorder'):
            subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--all-architectures', str(p)], check=True)
        def files(root):
            return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in root.rglob('*') if p.is_file()}
        assert files(app) == files(source), 'DMG changed application bytes'
        for executable in ('Contents/MacOS/MacUSBStudio', 'Contents/Helpers/MacUSBRecorder'):
            result = subprocess.check_output(['/usr/bin/lipo', '-archs', str(app / executable)], text=True)
            assert set(result.split()) == {'arm64', 'x86_64'}
    finally:
        subprocess.run(['/usr/bin/hdiutil', 'detach', str(volume)], check=True)
print('DMG checks passed: image checksum; exact app bytes; signatures; both architectures; Applications shortcut. Only the test image was mounted and detached.')
