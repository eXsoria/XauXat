#!/usr/bin/env python3
"""Verify the engine/wrapper pins, deployment lock and installed Tor payload."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re

ENGINE_RELEASE = '409.17.1'
ENGINE_VERSION = '0.4.9.17'
WRAPPER_COMMIT = '9c5df82840cd83a62b592293c2e53249ffa1e083'
ARCHIVE_SHA256 = '39579058d205389ce6aaeda6b152b730bed18032ec987487218f9466e9cd6c49'
PATCHED_SOURCES = {
    'TorCore/TORController.m': 'c9b668e6383efc0d2ce8a5d42c8d683258db2d698ba7ffded75373281f3b4764',
    'TorCore/include/TORController.h': '1819c092cd6ea727ab9a853ab07b05bb0dfbf5990380dcd2987161680be54a61',
    'CTor/TORThread.m': '585ca3b08ce4a3d4b557deabae27bab59264b9ad33f3ed0d400bb440a66360dc',
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(root):
    ios = root / 'apps/ios'
    spec_path = ios / 'podspecs/Tor.podspec.json'
    text = spec_path.read_text(encoding='utf-8')
    spec = json.loads(text)
    # Match CocoaPods' to_pretty_json, including its final newline and key order.
    canonical = json.dumps(spec, indent=2, ensure_ascii=False) + '\n'
    require(text == canonical, 'Keep the podspec in canonical CocoaPods JSON format')
    require(spec['name'] == 'Tor' and spec['version'] == ENGINE_RELEASE, 'Unexpected Tor engine release')
    require(spec['source'] == {
        'git': 'https://github.com/iCepa/Tor.framework.git', 'commit': WRAPPER_COMMIT,
    }, 'The reviewed Objective-C wrapper must remain pinned to its exact commit')
    download = f'https://github.com/iCepa/Tor.framework/releases/download/{ENGINE_RELEASE}/tor-nolzma.xcframework.zip'
    prepare = spec['prepare_command']
    require(download in prepare and ARCHIVE_SHA256 in prepare, 'Unexpected engine archive or SHA-256')
    require(prepare.startswith('set -eu\n') and 'shasum -a 256 -c -' in prepare,
            'Engine installation must stop on checksum/download failure')
    require(prepare.index('shasum -a 256 -c -') < prepare.index('unzip -q'),
            'Verify the engine archive before extracting it')
    require(spec['default_subspecs'] == 'CTor-NoLZMA', 'Use the reviewed NoLZMA engine')
    subspecs = {s['name']: s for s in spec['subspecs']}
    require(subspecs['CTor-NoLZMA']['vendored_frameworks'] == 'tor-nolzma.xcframework',
            'Unexpected vendored Tor framework')

    podfile = (ios / 'Podfile').read_text(encoding='utf-8')
    declaration = "pod 'Tor/CTor-NoLZMA', :podspec => 'podspecs/Tor.podspec.json'"
    for target in ['SimpleX (iOS)', 'SimpleX NSE']:
        match = re.search(r"target '" + re.escape(target) + r"' do\n(.*?)\nend", podfile, re.S)
        require(match is not None and declaration in match[1], f'{target} must use the pinned engine')
    lock = (ios / 'Podfile.lock').read_text(encoding='utf-8')
    for line in [
        f'  - Tor/Core ({ENGINE_RELEASE})',
        f'  - Tor/CTor-NoLZMA ({ENGINE_RELEASE}):',
        '  - Tor/CTor-NoLZMA (from `podspecs/Tor.podspec.json`)',
        'EXTERNAL SOURCES:\n  Tor:\n    :podspec: podspecs/Tor.podspec.json',
        '  Tor: ' + hashlib.sha1(canonical.encode()).hexdigest(),
        'PODFILE CHECKSUM: ' + hashlib.sha1(podfile.encode()).hexdigest(),
    ]:
        require(line in lock, f'Tor deployment lock is stale: {line}')
    return spec


def validate_installed(root):
    tor = root / 'apps/ios/Pods/Tor'
    for relative, expected in PATCHED_SOURCES.items():
        source = (tor / 'Sources' / relative).read_text(encoding='utf-8')
        require(hashlib.sha256(source.encode()).hexdigest() == expected,
                f'Installed Tor wrapper lacks its exact reviewed patch: {relative}')
    framework = tor / 'tor-nolzma.xcframework'
    with (framework / 'Info.plist').open('rb') as stream:
        libraries = plistlib.load(stream)['AvailableLibraries']
    for variant in [None, 'simulator']:
        candidates = [lib for lib in libraries if lib['SupportedPlatform'] == 'ios'
                      and lib.get('SupportedPlatformVariant') == variant
                      and 'arm64' in lib['SupportedArchitectures']]
        require(bool(candidates), f'No ARM64 iOS {variant or "device"} engine slice')
        for lib in candidates:
            binary = framework / lib['LibraryIdentifier'] / lib['LibraryPath'] / 'tor-nolzma'
            payload = binary.read_bytes()
            require(ENGINE_VERSION.encode() in payload, f'Wrong Tor version in {binary}')
            require(b'OpenSSL 3.6.5' in payload, f'Wrong OpenSSL version in {binary}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--installed', action='store_true', help='Also check the installed, patched CocoaPod')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    validate(root)
    if args.installed:
        validate_installed(root)
    print(f'Tor {ENGINE_VERSION}: reviewed wrapper, SHA-256 and deployment lock verified'
          + ('; installed ARM64 device/simulator payloads verified.' if args.installed else '.'))
