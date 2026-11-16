"""Exercise two simultaneous display streams through the shipped CLI and app."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

FIXTURE = r'''#!/usr/bin/env python3
import os, signal, socket, struct, sys, time
from pathlib import Path
name = sys.argv[-1]
signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
server = socket.socket()
server.bind(("127.0.0.1", 0))
server.listen()
print(f"VNC server is running at vnc://127.0.0.1:{server.getsockname()[1]}", flush=True)
client, _ = server.accept()
def read(n):
    b = b""
    while len(b) < n:
        chunk = client.recv(n - len(b))
        if not chunk: sys.exit(0)
        b += chunk
    return b
def send(data): client.sendall(data)
send(b"RFB 003.008\n")
assert read(12) == b"RFB 003.008\n"
send(b"\x01\x01")
assert read(1) == b"\x01"
send(bytes(4))
assert read(1) == b"\x01"
width = 32 if name == "red" else 48
height = 24
send(struct.pack(">HH", width, height) + bytes(16) + struct.pack(">I", 4) + b"test")
assert read(20)[0] == 0
assert read(12)[0] == 2
assert read(10)[0] == 3
pixel = bytes((0, 0, 255, 0) if name == "red" else (255, 0, 0, 0))
send(struct.pack(">BBHHHHHi", 0, 0, 1, 0, 0, width, height, 0) + pixel * width * height)
while True:
    kind = read(1)[0]
    if kind == 3: read(9)
    elif kind == 4:
        down, _, _, key = struct.unpack(">BBBI", read(7))
        with Path(os.environ["VMLAB_SOCKET_DIR"], name + ".events").open("a") as f:
            print("key", down, key, file=f)
    elif kind == 5:
        buttons, x, y = struct.unpack(">BHH", read(5))
        with Path(os.environ["VMLAB_SOCKET_DIR"], name + ".events").open("a") as f:
            print("pointer", buttons, x, y, file=f)
    else: raise ValueError(kind)
'''

def main():
    app = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="vmlab-test-", dir="/tmp") as directory:
        root = Path(directory)
        fixture = root / "tart"
        fixture.write_text(FIXTURE.replace("/usr/bin/env python3", sys.executable, 1))
        fixture.chmod(0o700)
        for name, os_name in [("red", "darwin"), ("blue", "linux")]:
            vm = root / "tart-home" / "vms" / name
            vm.mkdir(parents=True)
            (vm / "config.json").write_text(json.dumps({"os": os_name}))
        env = dict(os.environ, VMLAB_SOCKET_DIR=directory, VMLAB_TART=str(fixture),
                   TART_HOME=str(root / "tart-home"), VMLAB_CLUSTER_DIR=str(root / "cluster"))
        host = subprocess.Popen([app / "Contents/MacOS/vmLab"], env=env)
        cli = app / "Contents/Helpers/vmlab"

        def call(*args):
            return subprocess.check_output([cli, *args], env=env, text=True, timeout=12)

        def wait_for(predicate):
            end = time.monotonic() + 12
            while time.monotonic() < end:
                if predicate(): return
                time.sleep(0.1)
            raise AssertionError("Timed out waiting for vmLab")

        try:
            wait_for(lambda: (root / "control.sock").exists())
            assert json.loads(call("list")) == []
            call("start", "red")
            call("start", "blue")
            wait_for(lambda: all(m["state"] == "running" for m in json.loads(call("list"))))
            rows = json.loads(call("list"))
            assert [(r["name"], r["width"]) for r in rows] == [("red", 32), ("blue", 48)]
            assert [(r["name"], r["os"]) for r in rows] == [("red", "darwin"), ("blue", "linux")]
            for name, w in [("red", 32), ("blue", 48)]:
                png = root / (name + ".png")
                call("screenshot", name, "--out", str(png))
                assert png.read_bytes()[16:24] == w.to_bytes(4, "big") + (24).to_bytes(4, "big")
            call("key", "blue", "0xffeb+q")
            call("click", "red", "3", "7")
            call("drag", "red", "3", "7", "15", "19")
            wait_for(lambda: (root / "blue.events").exists() and (root / "red.events").exists()
                     and len((root / "blue.events").read_text().splitlines()) == 4
                     and len((root / "red.events").read_text().splitlines()) == 16)
            assert (root / "blue.events").read_text().splitlines() == ["key 1 65515", "key 1 113", "key 0 113", "key 0 65515"]
            assert (root / "red.events").read_text().splitlines() == (
                ["pointer 1 3 7", "pointer 0 3 7"]
                + [f"pointer 1 {x} {x + 4}" for x in range(3, 16)]
                + ["pointer 0 15 19"]
            )
            call("stop", "red")
            call("stop", "blue")
            wait_for(lambda: all(m["state"] == "stopped" for m in json.loads(call("list"))))
            print("PASS: macOS/Linux metadata, two simultaneous displays, PNGs, independent input, and process stop")
        finally:
            host.terminate()
            host.wait(timeout=10)

if __name__ == "__main__":
    main()
