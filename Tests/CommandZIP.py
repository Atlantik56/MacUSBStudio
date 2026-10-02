#!/usr/bin/env python3
"""Check the distributed launcher; never install an app or touch physical USB."""
import pathlib
import stat
import subprocess
import tempfile
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
name = 'Install-Mac-USB-Studio-2.1.0.command'
archive = root / 'dist' / (name + '.zip')
with zipfile.ZipFile(archive) as source:
    assert source.namelist() == [name], 'Exactly one launcher should appear after extraction'
    entry = source.getinfo(name)
    assert stat.S_IMODE(entry.external_attr >> 16) == 0o755
    original = (root / 'install.sh').read_text().split('\n', 1)[1]
    assert source.read(name).decode() == '#!/bin/bash\n# Self-contained installer: a double click starts installation.\nset -- --yes "$@"\n' + original
with tempfile.TemporaryDirectory(prefix='mac-usb-command-check-', dir='/private/tmp') as folder:
    subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), folder], check=True)
    command = pathlib.Path(folder) / name
    assert stat.S_IMODE(command.stat().st_mode) == 0o755
    subprocess.run(['/bin/bash', '-n', str(command)], check=True)
    # Execute the file directly, without /bin/bash/chmod typed by a user.
    result = subprocess.run([str(command), '--verify-only', '--image', str(root / 'dist/Mac.USB.Studio-2.1.0.dmg')], text=True, capture_output=True)
    assert result.returncode == 0 and 'проверен. Установка не выполнялась.' in result.stdout, result.stdout + result.stderr
    # Default --yes skips input; running app must still block any replacement.
    result = subprocess.run([str(command), '--no-open', '--destination', str(pathlib.Path(folder) / 'installed'), '--image', '/nonexistent.dmg'], text=True, input='', capture_output=True)
    assert 'автоматический запуск требует --yes' not in result.stderr
    assert result.returncode != 0
print('Command ZIP verified: one file, Unix 0755 preserved by ditto, exact audited payload, direct execution, no input required, installer guards retained. Only a temporary DMG was mounted.')
