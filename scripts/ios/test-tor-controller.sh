#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
python3 - "$temp" <<'PY'
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import sys
import urllib.request

target = Path(sys.argv[1])
# Exact source commit used by the pinned 409.11.2 CocoaPod, not a mutable branch.
url = 'https://raw.githubusercontent.com/iCepa/Tor.framework/727f628a15dd1bd83e0e171deb0aba7ab18be09e/Tor/Classes/Core/'
files = ['TORController.m', 'TORController.h', 'TORCircuit.m', 'TORCircuit.h',
         'TORNode.m', 'TORNode.h', 'NSCharacterSet+PredefinedSets.m',
         'NSCharacterSet+PredefinedSets.h', 'TORControlCommand.h', 'TORControlReplyCode.h']
def fetch(name):
    (target / name).write_bytes(urllib.request.urlopen(url + name, timeout=30).read())
with ThreadPoolExecutor(max_workers=5) as pool:
    list(pool.map(fetch, files))
PY
sources=("$temp/TORController.m" "$temp/TORCircuit.m" "$temp/TORNode.m" "$temp/NSCharacterSet+PredefinedSets.m" "$root/scripts/ios/tor-recovery-tests/ControllerContract.m")
clang -fobjc-arc -framework Foundation -I "$temp" "${sources[@]}" -o "$temp/upstream-contract"
echo 'Reproduce upstream lifecycle defects (three expected failures):'
"$temp/upstream-contract"
python3 "$root/scripts/ios/patch-tor-controller.py" "$temp"
python3 "$root/scripts/ios/patch-tor-controller.py" "$temp"
clang -fobjc-arc -DXAUXAT_PATCHED=1 -framework Foundation -I "$temp" "${sources[@]}" -o "$temp/patched-contract"
echo 'Patched real framework lifecycle checks:'
"$temp/patched-contract"
