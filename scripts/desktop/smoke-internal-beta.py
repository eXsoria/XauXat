#!/usr/bin/env python3
"""Validate the actual jpackage image with isolated test homes and no operator data."""
import json
import hashlib
import os
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
release = root / 'apps/multiplatform/release/main'
system = platform.system()
image = release / 'app' / ('xauxat' if system == 'Linux' else 'XauXat' + ('.app' if system == 'Darwin' else ''))
exe = image / ('Contents/MacOS/XauXat' if system == 'Darwin' else 'XauXat.exe' if system == 'Windows' else 'bin/xauxat')
assert exe.is_file(), f'Missing packaged executable: {exe}'
results = {}
for stage in ('native', 'ui'):
    with tempfile.TemporaryDirectory(prefix='xauxat-package-smoke-') as tmp:
        home = Path(tmp)
        marker = home / 'result.txt'
        (home / 'tmp').mkdir()
        env = dict(os.environ, HOME=tmp, APPDATA=tmp, LOCALAPPDATA=tmp,
                   XDG_CONFIG_HOME=tmp, XDG_DATA_HOME=tmp, XDG_CACHE_HOME=tmp,
                   JAVA_TOOL_OPTIONS=f'-Duser.home="{tmp}" -Djava.io.tmpdir="{home / "tmp"}"',
                   SKIKO_RENDER_API='SOFTWARE')
        env[f'XAUXAT_DESKTOP_{stage.upper()}_SMOKE_RESULT'] = str(marker)
        args = [str(exe)] + (['--xauxat-native-smoke-test'] if stage == 'native' else [])
        if system == 'Linux':
            args = ['xvfb-run', '-a', *args]
        log = home / 'startup.log'
        with log.open('w', encoding='utf-8') as output:
            process = subprocess.Popen(args, env=env, stdout=output, stderr=subprocess.STDOUT)
            try:
                code = process.wait(timeout=150)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise RuntimeError(f'{stage} smoke timed out: {log.read_text(encoding="utf-8", errors="replace")}')
        if code != 0 or not marker.exists() or marker.read_text() != f'{stage}-ok':
            raise RuntimeError(f'{stage} packaged smoke failed ({code}): {log.read_text(encoding="utf-8", errors="replace")}')
        results[stage] = 'passed'
        print(f'Packaged {stage} smoke passed', flush=True)
result = release / 'PACKAGED-SMOKE.json'
result.write_text(json.dumps({'system': system, 'architecture': platform.machine(),
                             'image': image.name, 'checks': results,
                             'native_loopback_pair_verify_query_disconnect_reconnect': results['native'],
                             'physical_iphone_pairing': 'pending', 'vps_operator_pairing': 'pending'}, indent=2) + '\n', encoding='utf-8')
packages = [p for suffix in ('msi', 'dmg', 'deb') for p in (release / suffix).glob(f'*.{suffix}')]
assert packages, 'No installer produced'
lines = []
for package in packages:
    with package.open('rb') as f:
        lines.append(f'{hashlib.file_digest(f, "sha256").hexdigest()}  {package.name}')
(release / 'SHA256SUMS.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8')
