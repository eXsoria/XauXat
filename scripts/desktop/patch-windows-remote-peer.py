"""Reproducible Windows-only RCP adjustments, applied before Cabal sdists MQ."""
import hashlib
from pathlib import Path
import platform
import subprocess
import sys

MQ_COMMIT = 'efaad8e73436d60f5052f07dda6b71151ad5039b'
CLIENT_SHA256 = 'd267fa0048210cae9acc2c8ac6dfe4f6e16ec2cdb0b7abc535ee92e8e5424de2'
PATCHED_CLIENT_SHA256 = '9730a72efb3194930091b3a8993800046b96cdf8bfe4dd78cf8c4b19e6e041ce'
DISCOVERY_SHA256 = 'b1c451dad3f46504e5d8d04befbcf22abf585613b76bfcda697cef60c032a87c'
PATCHED_DISCOVERY_SHA256 = '2eee5c5ecd18e1799952f03a55740cbbda43c839922eff40337f8d53937c2eee'
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


def patched_discovery(original):
    assert hashlib.sha256(original.encode()).hexdigest() == DISCOVERY_SHA256, 'Unexpected pinned MQ discovery source'
    server = '      runTransportServerSocket started (pure socket) "RCP TLS" serverParams (mkTransportServerConfig True Nothing True) server'
    assert original.count(server) == 1
    owner = '  bracketOnError (startTCPServer started Nothing $ maybe "0" show port_) (\\_e -> setPort Nothing) $ \\socket ->'
    assert original.count(owner) == 1
    owned = original.replace(owner,
        '  bracket (startTCPServer started Nothing $ maybe "0" show port_) (\\socket -> N.close socket >> setPort Nothing) $ \\socket ->')
    return owned.replace(server,
        '      -- Keep the owner cancellable while accept runs in its own worker.\n'
        '      -- Close the listening socket before joining that worker: Windows\n'
        '      -- accept can otherwise prevent cancellation from completing.\n'
        '      bracket\n'
        '        (async $ runTransportServerSocket started (pure socket) "RCP TLS" serverParams (mkTransportServerConfig True Nothing True) server)\n'
        '        (\\worker -> N.close socket `finally` uninterruptibleCancel worker)\n'
        '        wait')


if __name__ == '__main__':
    assert platform.system() == 'Windows', 'This adjustment belongs only to the Windows Desktop build'
    assert len(sys.argv) == 2
    assert hashlib.sha256(Path(__file__).read_bytes()).hexdigest() == sys.argv[1], 'Patch script digest differs from project input'
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    assert head == MQ_COMMIT, 'Refusing to patch a different MQ revision'
    for name, expected, patched, apply in (
        ('Client.hs', CLIENT_SHA256, PATCHED_CLIENT_SHA256, patched_client),
        ('Discovery.hs', DISCOVERY_SHA256, PATCHED_DISCOVERY_SHA256, patched_discovery),
    ):
        source = Path('src/Simplex/RemoteControl') / name
        text = source.read_text(encoding='utf-8')
        original_hash = hashlib.sha256(text.encode()).hexdigest()
        if original_hash != expected:
            # Cabal may reuse a checkout. Accept only our exact adjustment.
            assert original_hash == patched, f'Unexpected prior MQ modifications: {name}'
            print('Windows MQ RCP adjustment already present:', name)
        else:
            updated = apply(text)
            assert hashlib.sha256(updated.encode()).hexdigest() == patched
            source.write_bytes(updated.encode())
            print('Windows MQ RCP adjustment applied before sdist:', name, patched)
