"""Compile the complete production device with the app's pinned WebRTC SDK.

Only chat UI/timing and the codec endpoint are adapters. No audio device, engine,
converter, effect processor or notification body is replaced/extracted.
"""
from pathlib import Path
import shutil, sys

root, out = map(Path, sys.argv[1:])
out.mkdir(parents=True, exist_ok=True)
call = root / 'apps/ios/Shared/Views/Call'
device = (call / 'XauXatRealtimeAudioDevice.swift').read_text()
(out / 'Device.swift').write_text(device.replace('import SimpleXChat\n', ''))
shutil.copyfile(call / 'XauXatLLVCCapture.swift', out / 'LLVC.swift')
audio = (root / 'apps/ios/Shared/Model/AudioRecPlay.swift').read_text()
def declaration(marker):
    start = audio.index(marker)
    brace = audio.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (audio[end] == '{') - (audio[end] == '}')
        end += 1
    return audio[start:end]
(out / 'Presets.swift').write_text('import Foundation\n' + '\n'.join(declaration(marker) for marker in ('enum XauXatVoiceMaskError:', 'enum XauXatVoiceMaskPreset:', 'func xauXatBoostMaskedVoice(')))
shutil.copyfile(root / 'scripts/ios/call-audio-tests/LiveHarness.swift', out / 'main.swift')
for name in ('objc.h', 'objc.m'):
    shutil.copyfile(root / 'apps/ios/SimpleXChat' / name, out / name)
assets = out / 'Ambience.xcassets'
assets.mkdir(exist_ok=True)
(assets / 'Contents.json').write_text('{"info":{"author":"xcode","version":1}}')
for name in ('CallAmbienceRain', 'CallAmbienceTraffic'):
    shutil.copytree(root / f'apps/ios/Shared/Assets.xcassets/{name}.dataset', assets / f'{name}.dataset', dirs_exist_ok=True)
