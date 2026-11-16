"""End-to-end tests: the test build of the module (fake Spotify) under the fake host.

Run with: zsh tests/run.sh   (builds the test binary into a temp folder first)
Needs MODULE_TEST_BINARY set to that binary. Stdlib only; never touches the
real Spotify app, OpenLogi, or the user's caches.
"""

import importlib.util
import json
import os
import shutil
import struct
import tempfile
import time
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("fake_host", os.path.join(HERE, "..", "tools", "fake_host.py"))
fake_host = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fake_host)

BINARY = os.environ.get("MODULE_TEST_BINARY", "")


def write_png(path, width, height):
    """A plain RGB gradient PNG, for album art."""
    rows = b"".join(
        b"\x00" + bytes(v for x in range(width) for v in (x * 255 // width, y * 255 // height, 160))
        for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


class ModuleTest(unittest.TestCase):
    def setUp(self):
        if not BINARY:
            self.skipTest("MODULE_TEST_BINARY is not set; run zsh tests/run.sh")
        self.dir = tempfile.mkdtemp(prefix="spotify-module-test-")
        self.cache = os.path.join(self.dir, "cache")
        self.images = os.path.join(self.dir, "images")
        os.makedirs(self.images)
        self.art = os.path.join(self.dir, "art.png")
        write_png(self.art, 300, 300)
        self.host = None

    def tearDown(self):
        if self.host:
            self.host.kill()
            self.assertEqual(self.host.problems, [], "the module sent something that is not protocol v1")
        shutil.rmtree(self.dir, ignore_errors=True)

    def set_state(self, **state):
        path = os.path.join(self.dir, "state.json")
        with open(path + ".tmp", "w") as f:
            json.dump(state, f)
        os.replace(path + ".tmp", path)

    def playing(self, **extra):
        state = dict(running=True, state="playing", id="spotify:track:1", name="Midnight City",
                     artist="M83", artwork=self.art)
        state.update(extra)
        self.set_state(**state)

    def calls(self):
        try:
            with open(os.path.join(self.dir, "calls.log")) as f:
                return f.read().split()
        except FileNotFoundError:
            return []

    def start(self, reconcile=30):
        env = dict(os.environ, FAKE_SPOTIFY_DIR=self.dir, SPOTIFY_MODULE_CACHE_DIR=self.cache,
                   FAKE_SPOTIFY_RECONCILE=str(reconcile))
        self.host = fake_host.FakeHost([BINARY], env=env, out_dir=self.images)
        self.host.hello()
        ready = self.host.wait_for("ready", 10)
        self.assertIsNotNone(ready, "no ready within 10 s")
        return self.host

    def image(self, timeout=3):
        message = self.host.wait_for("image_all", timeout)
        self.assertIsNotNone(message, "no image_all")
        self.assertIn("png", message)
        return message

    def slot(self, size=118, name="gridMiddle"):
        return {"device": "keypad-1", "slot": name, "size": size}

    # Protocol

    def test_ready_is_the_first_line_and_answers_hello(self):
        self.playing()
        host = self.start()
        self.assertEqual(host.received[0]["type"], "ready")
        self.assertEqual(host.received[0]["protocol"], 1)

    def test_nothing_is_sent_before_hello(self):
        self.playing()
        env = dict(os.environ, FAKE_SPOTIFY_DIR=self.dir, SPOTIFY_MODULE_CACHE_DIR=self.cache)
        self.host = fake_host.FakeHost([BINARY], env=env)
        self.host.keys([self.slot()])
        self.assertEqual(self.host.drain(1.0), [])
        self.assertNotIn("read", self.calls())

    def test_no_slots_means_no_reads_and_no_images(self):
        self.playing()
        host = self.start(reconcile=0.3)
        host.keys([])
        got = host.drain(1.2)
        self.assertEqual([m for m in got if m["type"] == "image_all"], [])
        self.assertNotIn("read", self.calls())

    def test_keys_bring_the_current_face_at_the_slot_size(self):
        self.playing()
        host = self.start()
        host.keys([self.slot(size=118)])
        self.assertEqual(fake_host.png_size(self.image()["_bytes"]), (118, 118))

    def test_first_slot_size_is_used(self):
        self.playing()
        host = self.start()
        host.keys([self.slot(size=72), self.slot(size=96, name="gridTopLeft")])
        self.assertEqual(fake_host.png_size(self.image()["_bytes"]), (72, 72))

    def test_missing_size_defaults_to_118(self):
        self.playing()
        host = self.start()
        host.keys([{"device": "keypad-1", "slot": "gridMiddle"}])
        self.assertEqual(fake_host.png_size(self.image()["_bytes"]), (118, 118))

    def test_a_size_change_renders_again(self):
        self.playing()
        host = self.start()
        host.keys([self.slot(size=118)])
        self.image()
        host.keys([self.slot(size=80)])
        self.assertEqual(fake_host.png_size(self.image()["_bytes"]), (80, 80))

    def test_a_new_slot_gets_the_face_at_once(self):
        self.playing()
        host = self.start()
        host.keys([self.slot()])
        first = self.image()
        host.keys([self.slot(), self.slot(name="page2:gridTopLeft")])
        again = self.image(timeout=1)
        self.assertEqual(again["png"], first["png"])

    def test_slots_removed_stop_reads_until_they_return(self):
        self.playing()
        host = self.start(reconcile=0.3)
        host.keys([self.slot()])
        self.image()
        host.keys([])
        host.drain(0.3)
        reads = self.calls().count("read")
        got = host.drain(1.2)
        self.assertEqual([m for m in got if m["type"] == "image_all"], [])
        self.assertEqual(self.calls().count("read"), reads)
        host.keys([self.slot()])
        self.image()

    def test_unknown_type_and_bad_lines_are_ignored(self):
        self.playing()
        host = self.start()
        host.send({"type": "some_future_message", "x": 1})
        host.process.stdin.write(b"this is not json\n[1,2]\n\n")
        host.process.stdin.flush()
        host.keys([self.slot()])
        self.image()

    def test_shutdown_exits_promptly(self):
        self.playing()
        host = self.start()
        host.keys([self.slot()])
        self.image()
        started = time.monotonic()
        self.assertEqual(host.shutdown(timeout=2.0), 0)
        self.assertLess(time.monotonic() - started, 2.0)

    def test_stdin_closed_exits(self):
        self.playing()
        host = self.start()
        host.process.stdin.close()
        self.assertEqual(host.process.wait(timeout=2.0), 0)

    # Faces

    def test_state_change_sends_a_new_face(self):
        self.playing()
        host = self.start()
        host.keys([self.slot()])
        playing = self.image()
        self.playing(state="paused")
        paused = self.image(timeout=2)
        self.assertNotEqual(paused["png"], playing["png"])
        self.playing(id="spotify:track:2", name="Another Song")
        self.assertNotEqual(self.image(timeout=2)["png"], paused["png"])

    def test_not_running_shows_the_app_icon_tile(self):
        self.set_state(running=False)
        host = self.start()
        host.keys([self.slot()])
        icon = self.image()
        self.playing()
        self.assertNotEqual(self.image(timeout=2)["png"], icon["png"])

    def test_idle_shows_the_same_tile_as_not_running(self):
        self.set_state(running=False)
        host = self.start()
        host.keys([self.slot()])
        icon = self.image()
        self.assertEqual(host.shutdown(), 0)
        self.assertEqual(host.problems, [])
        self.set_state(running=True, state="stopped")
        self.start().keys([self.slot()])
        self.assertEqual(self.image()["png"], icon["png"])

    def test_reconcile_resends_the_unchanged_face(self):
        self.playing()
        host = self.start(reconcile=0.5)
        host.keys([self.slot()])
        first = self.image()
        again = self.image(timeout=2)
        self.assertEqual(again["png"], first["png"])

    def test_tiles_are_cached_by_track_state_and_size(self):
        self.playing()
        host = self.start()
        host.keys([self.slot()])
        self.image()
        self.playing(state="paused")
        self.image(timeout=2)
        tiles = [n for n in os.listdir(self.cache) if n.endswith(".png")]
        self.assertEqual(len(tiles), 2)
        self.assertTrue(all(len(n) == 64 + 4 for n in tiles), tiles)

    def test_read_error_is_logged_to_the_host_once(self):
        self.playing(read_error="AppleScript failed: timed out [-1712]")
        host = self.start(reconcile=0.3)
        host.keys([self.slot()])
        got = host.drain(1.5)
        errors = [m for m in got if m["type"] == "log" and "-1712" in m["message"]]
        self.assertEqual(len(errors), 1)
        self.assertEqual(errors[0]["level"], "error")
        self.assertEqual([m for m in got if m["type"] == "image_all"], [])

    # Presses

    def test_press_while_playing_pauses_and_refreshes_at_once(self):
        self.playing()
        host = self.start()
        host.keys([self.slot()])
        playing = self.image()
        sent = time.monotonic()
        host.press(device="keypad-1", slot="gridMiddle")
        paused = self.image(timeout=1)
        self.assertLess(time.monotonic() - sent, 0.5)
        self.assertNotEqual(paused["png"], playing["png"])
        self.assertIn("playpause", self.calls())
        self.assertNotIn("launch", self.calls())

    def test_press_while_paused_plays(self):
        self.playing(state="paused")
        host = self.start()
        host.keys([self.slot()])
        self.image()
        host.press()
        self.image(timeout=1)
        with open(os.path.join(self.dir, "state.json")) as f:
            self.assertEqual(json.load(f)["state"], "playing")

    def test_press_when_not_running_launches_then_plays(self):
        self.set_state(running=False, state="paused", id="spotify:track:1", name="Midnight City",
                       artist="M83", artwork=self.art, plays_needed=3)
        host = self.start()
        host.keys([self.slot()])
        icon = self.image()
        host.press()
        face = self.image(timeout=3)
        self.assertNotEqual(face["png"], icon["png"])
        calls = self.calls()
        self.assertEqual(calls.count("launch"), 1)
        self.assertEqual(calls.count("play"), 3)
        self.assertNotIn("playpause", calls)

    def test_press_gives_up_after_forty_tries(self):
        self.set_state(running=False, plays_needed=1000)
        host = self.start()
        host.keys([self.slot()])
        self.image()
        host.press()
        warning = None
        deadline = time.monotonic() + 14
        while warning is None and time.monotonic() < deadline:
            message = host.wait_for("log", deadline - time.monotonic())
            if message and "40 tries" in message["message"]:
                warning = message
        self.assertIsNotNone(warning)
        self.assertEqual(self.calls().count("play"), 40)

    def test_press_when_not_installed_does_nothing(self):
        self.set_state(running=False, installed=False)
        host = self.start()
        host.keys([self.slot()])
        self.image()
        host.press()
        message = host.wait_for("log", 2)
        self.assertIsNotNone(message)
        self.assertIn("not installed", message["message"])
        self.assertNotIn("launch", self.calls())

    def test_messages_keep_flowing_while_spotify_starts(self):
        self.set_state(running=False, plays_needed=1000)
        host = self.start()
        host.keys([self.slot()])
        self.image()
        host.press()
        time.sleep(0.6)
        host.keys([self.slot(size=64)])
        self.assertEqual(fake_host.png_size(self.image(timeout=1.5)["_bytes"]), (64, 64))
        self.assertEqual(host.shutdown(timeout=2.0), 0)


class SelfTest(unittest.TestCase):
    def test_script_wrapper(self):
        if not BINARY:
            self.skipTest("MODULE_TEST_BINARY is not set; run zsh tests/run.sh")
        import subprocess
        result = subprocess.run([BINARY, "--self-test"], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("FAIL", result.stdout)


if __name__ == "__main__":
    unittest.main()
