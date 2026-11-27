#!/usr/bin/env python3
"""Create an allowlisted public source bundle; never copy the workspace wholesale."""
from pathlib import Path
import hashlib
import json
import shutil
import zipfile
import re

root = Path(__file__).resolve().parent.parent
version = re.search(r'CFBundleShortVersionString</key><string>([^<]+)', (root / 'build.sh').read_text())[1]
allowed = ['README.md', 'LICENSE', 'CONTRIBUTING.md', 'SECURITY.md', '.gitignore', 'build.sh', 'test.sh', 'package.sh',
           'tools/Icon.swift', 'tools/prepare_source.py']
for folder, suffixes in [('Sources', {'.swift', '.c', '.h'}), ('Tests', {'.swift', '.c'})]:
    allowed.extend(str(p.relative_to(root)) for p in sorted((root / folder).iterdir()) if p.is_file() and p.suffix in suffixes)
base = root / '.build' / 'public-source'
output = base / 'MacPulse'
output.mkdir(parents=True, exist_ok=True)
# Refuse stale unallowlisted files rather than silently publishing them.
existing = {str(p.relative_to(output)) for p in output.rglob('*') if p.is_file()}
if existing - set(allowed):
    raise SystemExit('Unexpected staging files; review before release: ' + repr(existing - set(allowed)))
manifest = []
for name in allowed:
    source = root / name
    if source.is_symlink():
        raise SystemExit('Symlink rejected: ' + name)
    target = output / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    content = target.read_bytes()
    manifest.append({'path': name, 'bytes': len(content), 'sha256': hashlib.sha256(content).hexdigest()})
(root / 'dist').mkdir(exist_ok=True)
archive = root / 'dist' / f'MacPulse-{version}-Source.zip'
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    for name in allowed:
        z.write(output / name, 'MacPulse/' + name)
(base / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
# Payload for an initial GitHub tree, deliberately outside the public source directory.
(base / 'tree-elements.json').write_text(json.dumps([
    {'path': name, 'mode': '100755' if (output/name).stat().st_mode & 0o111 else '100644',
     'type': 'blob', 'content': (output/name).read_text()} for name in allowed
], ensure_ascii=False))
print(json.dumps({'files': len(allowed), 'source_zip': str(archive), 'source_folder': str(output)}, ensure_ascii=False))
