#!/usr/bin/env python3
"""Package a self-contained Finder/Terminal launcher with its execute bit."""
import hashlib
import pathlib
import plistlib
import subprocess
import zipfile

root = pathlib.Path(__file__).resolve().parent
version = plistlib.loads((root / 'Info.plist').read_bytes())['CFBundleShortVersionString']
source = (root / 'install.sh').read_text()
assert source.startswith('#!/bin/bash\n')
assert f"task_version='{version}'" in source
launcher = '#!/bin/bash\n# Self-contained installer: a double click starts installation.\nset -- --yes "$@"\n' + source.split('\n', 1)[1]
folder = root / 'dist'
folder.mkdir(exist_ok=True)
command = folder / f'Install-Mac-USB-Studio-{version}.command'
command.write_text(launcher)
command.chmod(0o755)
subprocess.run(['/bin/bash', '-n', str(command)], check=True)
archive = folder / (command.name + '.zip')
entry = zipfile.ZipInfo(command.name, date_time=(2026, 10, 2, 0, 0, 0))
entry.create_system = 3
entry.external_attr = 0o100755 << 16
entry.compress_type = zipfile.ZIP_DEFLATED
with zipfile.ZipFile(archive, 'w') as output:
    output.writestr(entry, command.read_bytes())
print(archive)
print(hashlib.sha256(archive.read_bytes()).hexdigest())
