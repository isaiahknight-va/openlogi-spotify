#!/usr/bin/env python3
"""A stand-in for OpenLogi's module host, for trying the module without OpenLogi.

It starts the module, speaks protocol v1 to it (hello, keys, pressed, shutdown),
prints every line the module sends (image data shortened), checks that each one
is a valid protocol message, and saves received images to a folder.

    python3 -I tools/fake_host.py                      # ./spotify-module, one 118 px slot
    python3 -I tools/fake_host.py --size 72 --slots 2 --wait 5
    python3 -I tools/fake_host.py --press              # presses the key: plays or pauses Spotify

Stdlib only. Also imported by tests/test_module.py.
"""

import argparse
import base64
import json
import os
import queue
import struct
import subprocess
import sys
import tempfile
import threading
import time

MODULE_TYPES = {"ready", "image", "image_all", "clear", "log"}
LOG_LEVELS = {"debug", "info", "warn", "error"}
MAX_IMAGE_BYTES = 4 * 1024 * 1024
MAX_LINE_BYTES = 8 * 1024 * 1024


def png_size(data):
    """(width, height) of PNG bytes, or None when they are not a PNG."""
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", data[16:24])


def check_message(message):
    """Problems with one module message under protocol v1 (empty when valid)."""
    problems = []
    kind = message.get("type")
    if kind not in MODULE_TYPES:
        problems.append(f"unknown type {kind!r}")
    elif kind == "ready" and message.get("protocol") != 1:
        problems.append("ready without protocol 1")
    elif kind in ("image", "image_all"):
        encoded = message.get("png", message.get("jpeg"))
        if not isinstance(encoded, str):
            problems.append(f"{kind} without png or jpeg")
        else:
            data = base64.b64decode(encoded, validate=True)
            if len(data) > MAX_IMAGE_BYTES:
                problems.append(f"{kind} of {len(data)} bytes is over the 4 MiB cap")
            if "png" in message and png_size(data) is None:
                problems.append(f"{kind} png does not start like a PNG")
        if kind == "image" and not all(isinstance(message.get(k), str) for k in ("device", "slot")):
            problems.append("image without device and slot")
    elif kind == "clear" and not all(isinstance(message.get(k), str) for k in ("device", "slot")):
        problems.append("clear without device and slot")
    elif kind == "log" and (message.get("level") not in LOG_LEVELS or not isinstance(message.get("message"), str)):
        problems.append("log without a valid level and message")
    return problems


class FakeHost:
    """One running module. Messages arrive on `self.messages` (a queue)."""

    def __init__(self, command, env=None, out_dir=None, echo=False):
        self.out_dir = out_dir
        self.echo = echo
        self.messages = queue.Queue()
        self.received = []
        self.problems = []
        self.stderr_lines = []
        self.images = 0
        self.started = time.monotonic()
        self.process = subprocess.Popen(
            command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, bufsize=0)
        self.readers = [threading.Thread(target=self._read_stdout, daemon=True),
                        threading.Thread(target=self._read_stderr, daemon=True)]
        for reader in self.readers:
            reader.start()

    def _read_stdout(self):
        for raw in self.process.stdout:
            if len(raw) > MAX_LINE_BYTES:
                self.problems.append(f"line of {len(raw)} bytes is over 8 MiB")
                continue
            try:
                message = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                self.problems.append(f"not JSON on stdout: {raw[:80]!r}")
                continue
            if not isinstance(message, dict):
                self.problems.append(f"not a JSON object on stdout: {raw[:80]!r}")
                continue
            self.problems.extend(check_message(message))
            message["_at"] = time.monotonic() - self.started
            if message.get("type") in ("image", "image_all"):
                self._save(message)
            self.received.append(message)
            if self.echo:
                print("<-", describe(message), flush=True)
            self.messages.put(message)
        self.messages.put(None)

    def _read_stderr(self):
        for raw in self.process.stderr:
            line = raw.decode("utf-8", "replace").rstrip("\n")
            self.stderr_lines.append(line)
            if self.echo:
                print("  stderr:", line, flush=True)

    def _save(self, message):
        self.images += 1
        encoded = message.get("png") or message.get("jpeg")
        data = base64.b64decode(encoded)
        message["_bytes"] = data
        if self.out_dir:
            ext = "png" if "png" in message else "jpg"
            path = os.path.join(self.out_dir, f"image-{self.images:03d}.{ext}")
            with open(path, "wb") as f:
                f.write(data)
            message["_path"] = path

    def send(self, message):
        if self.echo:
            print("->", json.dumps(message), flush=True)
        self.process.stdin.write((json.dumps(message) + "\n").encode())
        self.process.stdin.flush()

    def hello(self, settings=None):
        self.send({"type": "hello", "protocol": 1, "host": "openlogi", "host_version": "fake-host",
                   "module_id": "com.typ.openlogi.spotify", "settings": settings or {}})

    def keys(self, slots):
        self.send({"type": "keys", "keys": slots})

    def press(self, device="fake-keypad", slot="gridMiddle"):
        self.send({"type": "pressed", "device": device, "slot": slot})

    def wait_for(self, kind, timeout):
        """The next message of `kind` within `timeout` seconds, else None."""
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            try:
                message = self.messages.get(timeout=left)
            except queue.Empty:
                return None
            if message is None:
                return None
            if message.get("type") == kind:
                return message

    def drain(self, seconds):
        """Every message that arrives in the next `seconds`."""
        got = []
        deadline = time.monotonic() + seconds
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return got
            try:
                message = self.messages.get(timeout=left)
            except queue.Empty:
                return got
            if message is None:
                return got
            got.append(message)

    def shutdown(self, timeout=2.0):
        """Sends shutdown; the exit code, or None when it outlived `timeout`."""
        self.send({"type": "shutdown"})
        try:
            code = self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.kill()
            return None
        self._close()
        return code

    def kill(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        self._close()

    def _close(self):
        for reader in self.readers:
            reader.join(timeout=2)
        for pipe in (self.process.stdin, self.process.stdout, self.process.stderr):
            try:
                pipe.close()
            except (BrokenPipeError, OSError):
                pass


def describe(message):
    shown = {k: v for k, v in message.items() if not k.startswith("_")}
    for key in ("png", "jpeg"):
        if key in shown:
            data = message.get("_bytes", b"")
            size = png_size(data) if key == "png" else None
            dims = f" {size[0]}x{size[1]}" if size else ""
            shown[key] = f"<{len(data)} bytes{dims}>"
    if "_path" in message:
        shown["saved"] = message["_path"]
    return json.dumps(shown)


def slots_for(count, size):
    names = ["gridMiddle", "gridTopLeft", "page2:gridTopLeft", "gridBottomRight"]
    return [{"device": "fake-keypad", "slot": names[i % len(names)], "size": size} for i in range(count)]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--binary", default=os.path.join(here, "..", "spotify-module"))
    parser.add_argument("--size", type=int, default=118)
    parser.add_argument("--slots", type=int, default=1)
    parser.add_argument("--wait", type=float, default=3.0, help="seconds to listen after each step")
    parser.add_argument("--press", action="store_true",
                        help="send one pressed message (the real module then plays or pauses Spotify)")
    parser.add_argument("--out", help="folder for received images (default: a new temp folder)")
    args = parser.parse_args()

    out_dir = args.out or tempfile.mkdtemp(prefix="spotify-module-images-")
    os.makedirs(out_dir, exist_ok=True)
    host = FakeHost([os.path.abspath(args.binary)], out_dir=out_dir, echo=True)
    host.hello()
    if host.wait_for("ready", 10) is None:
        print("FAIL: no ready within 10 s")
        host.kill()
        return 1
    host.keys(slots_for(args.slots, args.size))
    host.drain(args.wait)
    if args.press:
        host.press()
        host.drain(args.wait)
    code = host.shutdown()
    print(f"exit code: {code if code is not None else 'none, killed after 2 s'}")
    print(f"images saved in {out_dir}: {host.images}")
    for problem in host.problems:
        print("PROBLEM:", problem)
    return 0 if code == 0 and not host.problems else 1


if __name__ == "__main__":
    sys.exit(main())
