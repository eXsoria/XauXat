"""Compile the proxy-setup and forwarding branches from a patched SimpleXMQ checkout."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("checkout", type=Path, help="SimpleXMQ with the project patches applied")
args = parser.parse_args()
fixtures = Path(__file__).resolve().parent
client = (args.checkout / "src/Simplex/Messaging/Agent/Client.hs").read_text()
selected = client.index("\n  selected@(ProtoServerWithAuth srv _)")
policy_start = client.index("\n", client.index("pure\n", selected))
policy_end = client.index("\n  where\n    connectProxy ", policy_start)
dispatch_start = client.index("  case sess_ of", client.index("\nwithProxySession c nm"))
dispatch_end = client.index("\n  where\n    proxySrv", dispatch_start)
source = (fixtures / "Harness.hs.in").read_text()
for marker, snippet in (("-- ACTUAL_POLICY", client[policy_start:policy_end]),
                        ("-- ACTUAL_DISPATCH", client[dispatch_start:dispatch_end])):
    if source.count(marker) != 1:
        raise ValueError("Expected one " + marker + " in the test harness")
    source = source.replace(marker, snippet)

with tempfile.TemporaryDirectory() as tmp:
    work = Path(tmp)
    (work / "Main.hs").write_text(source)
    shutil.copyfile(fixtures / "TM.hs", work / "TM.hs")
    compiler = os.environ.get("GHC", "ghc")
    flags = ["-B" + os.environ["GHC_LIBDIR"]] if "GHC_LIBDIR" in os.environ else []
    subprocess.run([compiler, *flags, "-v0", "Main.hs", "-o", "test"], cwd=work, check=True)
    subprocess.run([str(work / "test")], cwd=work, check=True)
