"""Reproducible Windows-only RCP adjustment, applied before Cabal sdists MQ."""
import hashlib
from pathlib import Path
import platform
import subprocess
import sys

MQ_COMMIT = 'efaad8e73436d60f5052f07dda6b71151ad5039b'
CLIENT_SHA256 = 'd267fa0048210cae9acc2c8ac6dfe4f6e16ec2cdb0b7abc535ee92e8e5424de2'
PATCHED_CLIENT_SHA256 = '9730a72efb3194930091b3a8993800046b96cdf8bfe4dd78cf8c4b19e6e041ce'
PROBE = '        liftIO $ peekBuffered tlsBuffer 100000 (TLS.recvData tlsContext) >>= logDebug . tshow -- should normally be ("", Nothing) here'


def patched_client(original):
    assert hashlib.sha256(original.encode()).hexdigest() == CLIENT_SHA256, 'Unexpected pinned MQ client source'
    assert original.count(PROBE) == 1
    result = original.replace('import Simplex.Messaging.Transport.Buffer (peekBuffered)\n', '')
    result = result.replace('\\tls@TLS {tlsBuffer, tlsContext} -> runExceptT $ do', '\\tls -> runExceptT $ do')
    return result.replace(
        '        -- pump socket to detect connection problems\n' + PROBE,
        '        -- Do not start a TLS application-data read before code verification.\n'
        '        -- On Windows the timed peek can remain blocked waiting for data\n'
        '        -- that the controller only sends after the peer confirms its code.\n'
        '        -- TLS authentication and the signed invitation checks are unchanged.\n'
        '        pure ()',
    )


if __name__ == '__main__':
    assert platform.system() == 'Windows', 'This adjustment belongs only to the Windows Desktop build'
    assert len(sys.argv) == 2
    assert hashlib.sha256(Path(__file__).read_bytes()).hexdigest() == sys.argv[1], 'Patch script digest differs from project input'
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    assert head == MQ_COMMIT, 'Refusing to patch a different MQ revision'
    client = Path('src/Simplex/RemoteControl/Client.hs')
    text = client.read_text(encoding='utf-8')
    original_hash = hashlib.sha256(text.encode()).hexdigest()
    if original_hash != CLIENT_SHA256:
        # A source checkout may be reused by Cabal. Only our exact adjustment is
        # accepted, rather than accepting arbitrary prior modifications.
        assert original_hash == PATCHED_CLIENT_SHA256, 'Unexpected prior MQ source modifications'
        print('Windows MQ RCP adjustment already present; pinned checkout verified.')
    else:
        updated = patched_client(text)
        client.write_bytes(updated.encode())
        print('Windows MQ RCP adjustment applied before sdist; source SHA256:', hashlib.sha256(updated.encode()).hexdigest())
