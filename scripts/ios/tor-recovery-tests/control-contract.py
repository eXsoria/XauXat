"""Real Tor control/listener contract; CI runs this with Docker --network none."""
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time

with tempfile.TemporaryDirectory(prefix="xauxat-tor-contract-") as directory:
    state = Path(directory)
    control_file = state / "control"
    process = subprocess.Popen([
        "tor", "--ClientOnly", "1", "--DataDirectory", str(state),
        "--SocksPort", "127.0.0.1:auto", "--ControlPort", "127.0.0.1:auto",
        "--ControlPortWriteToFile", str(control_file), "--CookieAuthentication", "1",
        "--DisableNetwork", "1", "--Log", "err stderr",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(200):
            if process.poll() is not None:
                raise RuntimeError("Tor exited before opening its control socket")
            if control_file.exists() and (state / "control_auth_cookie").exists():
                match = re.fullmatch(r"PORT=127\.0\.0\.1:(\d+)\s*", control_file.read_text())
                cookie = (state / "control_auth_cookie").read_bytes()
                if match and len(cookie) == 32:
                    break
            time.sleep(0.05)
        else:
            raise RuntimeError("Tor did not open its control socket")
        with socket.create_connection(("127.0.0.1", int(match[1])), timeout=5) as control:
            with control.makefile("rb") as replies:
                def command(text):
                    control.sendall((text + "\r\n").encode("ascii"))
                    lines = []
                    while True:
                        line = replies.readline(8192).decode("ascii").rstrip("\r\n")
                        if not line.startswith("250"):
                            raise RuntimeError("Tor rejected a control command")
                        lines.append(line)
                        if line[3] == " ":
                            return lines

                def listener():
                    lines = command("GETINFO net/listeners/socks")
                    values = [line.split("=", 1)[1] for line in lines if "net/listeners/socks=" in line]
                    assert len(values) == 1
                    match = re.fullmatch(r'"127\.0\.0\.1:(\d+)"', values[0])
                    assert match, "SOCKS must bind only one loopback address"
                    return int(match[1])

                def handshake(port):
                    with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
                        connection.sendall(bytes([5, 1, 0]))
                        data = b""
                        while len(data) < 2:
                            part = connection.recv(2 - len(data))
                            assert part, "SOCKS closed during handshake"
                            data += part
                        assert data == bytes([5, 0])

                command("AUTHENTICATE " + cookie.hex())
                command("SETCONF DisableNetwork=0")
                handshake(listener())
                # Exact repair commands used by EmbeddedTorManager. Tor has no
                # external network interface in this container and no chat data.
                command("SETCONF DisableNetwork=1")
                command("SETCONF SocksPort=0")
                command('SETCONF SocksPort="127.0.0.1:auto" DisableNetwork=0')
                handshake(listener())
                configuration = command("GETCONF SocksPort DisableNetwork")
                assert "250-SocksPort=127.0.0.1:auto" in configuration or "250 SocksPort=127.0.0.1:auto" in configuration
                assert "250-DisableNetwork=0" in configuration or "250 DisableNetwork=0" in configuration
                print("Real Tor accepted bounded repair commands and reopened a loopback SOCKS listener; no Internet access.")
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
