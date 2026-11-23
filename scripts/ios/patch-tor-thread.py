#!/usr/bin/env python3
"""Hash-bounded argv terminator fix for the 409.17.1 Tor wrapper."""
import hashlib
from pathlib import Path
import sys

ORIGINAL = 'ec18372444fc2a840c26fc5434305919230bfa3930a7fe978eb8f250486e01ae'
PATCHED = '585ca3b08ce4a3d4b557deabae27bab59264b9ad33f3ed0d400bb440a66360dc'


def patch(path):
    source = path.read_text(encoding='utf-8')
    digest = hashlib.sha256(source.encode()).hexdigest()
    if digest == PATCHED:
        return
    if digest != ORIGINAL:
        raise ValueError('TORThread.m differs from the pinned wrapper; review before patching')
    fixed = source.replace('char *argv[argc];', 'char *argv[argc + 1];', 1)
    if hashlib.sha256(fixed.encode()).hexdigest() != PATCHED:
        raise ValueError('Unexpected TORThread argv patch output')
    path.chmod(0o644)
    path.write_bytes(fixed.encode())


if __name__ == '__main__':
    patch(Path(sys.argv[1]))
