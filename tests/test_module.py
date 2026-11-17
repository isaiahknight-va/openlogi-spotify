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
import subprocess
import tempfile
import time
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("fake_host", os.path.join(HERE, "..", "tools", "fake_host.py"))
fake_host = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fake_host)

BINARY = os.environ.get("MODULE_TEST_BINARY", "")


def write_png(path, width, height, blue=160, srgb=False):
    """A plain RGB gradient PNG, for album art: red follows x, green follows y.
    `srgb` tags it sRGB, so its colors reach the tiles unconverted."""
    rows = b"".join(
        b"\x00" + bytes(v for x in range(width) for v in (x * 255 // width, y * 255 // height, blue))
        for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                + (chunk(b"sRGB", b"\x00") if srgb else b"")
                + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def read_png(data):
    """(width, height, pixel) for an 8-bit, non-interlaced PNG; pixel(x, y)
    gives (r, g, b, a), counting from the top left."""
    width, height, depth, kind, _, _, interlace = struct.unpack(">IIBBBBB", data[16:29])
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[kind]
    assert depth == 8 and interlace == 0, (depth, interlace)
    raw, at = b"", 8
    while at < len(data):
        length, = struct.unpack(">I", data[at:at + 4])
        if data[at + 4:at + 8] == b"IDAT":
            raw += data[at + 8:at + 8 + length]
        at += 12 + length
    raw = zlib.decompress(raw)
    stride = width * channels
    rows, previous = [], bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        method, row = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        for i in range(stride):
            left = row[i - channels] if i >= channels else 0
            up = previous[i]
            corner = previous[i - channels] if i >= channels else 0
            if method == 1:
                row[i] = (row[i] + left) & 255
            elif method == 2:
                row[i] = (row[i] + up) & 255
            elif method == 3:
                row[i] = (row[i] + (left + up) // 2) & 255
            elif method == 4:
                p = left + up - corner
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - corner)
                row[i] = (row[i] + (left if pa <= pb and pa <= pc else up if pb <= pc else corner)) & 255
        rows.append(bytes(row))
        previous = row

    def pixel(x, y):
        v = rows[y][x * channels:(x + 1) * channels]
        if channels == 1:
            return (v[0], v[0], v[0], 255)
        if channels == 2:
            return (v[0], v[0], v[0], v[1])
        if channels == 3:
            return (v[0], v[1], v[2], 255)
        return tuple(v)

    return width, height, pixel


GRID = ["gridTopLeft", "gridTopMiddle", "gridTopRight", "gridMiddleLeft", "gridMiddle",
        "gridMiddleRight", "gridBottomLeft", "gridBottomMiddle", "gridBottomRight"]
PAGE2_ROLES = dict(zip(["page2:" + name for name in GRID],
                       ["title", "title", "title", "shuffle", "time", "repeat", "previous", "art", "next"]))


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

    def start(self, reconcile=30, settings=None):
        env = dict(os.environ, FAKE_SPOTIFY_DIR=self.dir, SPOTIFY_MODULE_CACHE_DIR=self.cache,
                   FAKE_SPOTIFY_RECONCILE=str(reconcile))
        self.host = fake_host.FakeHost([BINARY], env=env, out_dir=self.images)
        self.host.hello(settings)
        ready = self.host.wait_for("ready", 10)
        self.assertIsNotNone(ready, "no ready within 10 s")
        return self.host

    def image(self, timeout=3):
        message = self.host.wait_for("image_all", timeout)
        self.assertIsNotNone(message, "no image_all")
        self.assertIn("png", message)
        return message

    def slot(self, size=118, name="gridMiddle", device="keypad-1"):
        return {"device": device, "slot": name, "size": size}

    def page(self, prefix="", device="keypad-1", size=118):
        return [self.slot(size=size, name=prefix + name, device=device) for name in GRID]

    def keyed_images(self, count, timeout=3):
        """The next `count` image messages (per key), in arrival order."""
        got = []
        deadline = time.monotonic() + timeout
        while len(got) < count:
            message = self.host.wait_for("image", deadline - time.monotonic())
            self.assertIsNotNone(message, f"only {len(got)} of {count} key images")
            got.append(message)
        return got

    def mosaic(self, messages, prefix="", device="keypad-1"):
        """The nine images of one mosaic page, by grid position name."""
        tiles = {m["slot"][len(prefix):]: m for m in messages
                 if m["device"] == device and m["slot"].startswith(prefix) and m["slot"][len(prefix):] in GRID}
        self.assertEqual(sorted(tiles), sorted(GRID))
        return tiles

    def assert_cut(self, tiles, size, gap_percent):
        """Each key shows its own square of the art scaled over the canvas of
        three keys and two gaps: red and green of the gradient art give back
        the canvas position each pixel came from."""
        gap = int(size * gap_percent / 100 + 0.5)
        side = 3 * size + 2 * gap
        self.assertEqual(len({t["png"] for t in tiles.values()}), 9, "the nine keys are not distinct")
        for index, name in enumerate(GRID):
            row, col = divmod(index, 3)
            width, height, pixel = read_png(tiles[name]["_bytes"])
            self.assertEqual((width, height), (size, size))
            for px, py in ((6, 6), (size // 2, size // 3), (size - 7, size - 7)):
                r, g, _, _ = pixel(px, py)
                x = col * (size + gap) + px + 0.5
                y = row * (size + gap) + py + 0.5
                self.assertAlmostEqual(r * side / 255, x, delta=4, msg=f"{name} x at ({px},{py})")
                self.assertAlmostEqual(g * side / 255, y, delta=4, msg=f"{name} y at ({px},{py})")

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

    # Mosaic

    def position_art(self, name="position.png", blue=160):
        path = os.path.join(self.dir, name)
        write_png(path, 512, 512, blue=blue, srgb=True)
        return path

    def test_nine_keys_of_a_page_show_the_art_cut_across_them(self):
        self.playing(artwork=self.position_art())
        host = self.start()
        host.keys(self.page())
        tiles = self.mosaic(self.keyed_images(9))
        self.assert_cut(tiles, 118, 25)
        # Gap 30 at 118: the top-left key starts at the canvas's corner and the
        # bottom-right one at 2 * (118 + 30).
        _, _, top_left = read_png(tiles["gridTopLeft"]["_bytes"])
        _, _, bottom_right = read_png(tiles["gridBottomRight"]["_bytes"])
        self.assertLessEqual(top_left(0, 0)[0], 2)
        self.assertAlmostEqual(bottom_right(0, 0)[0] * 414 / 255, 296, delta=4)
        self.assertEqual([m for m in host.drain(0.5) if m["type"] == "image_all"], [])

    def test_gap_setting_changes_the_cut(self):
        self.playing(artwork=self.position_art())
        host = self.start(settings={"mosaic_gap_percent": 0})
        host.keys(self.page(size=96))
        self.assert_cut(self.mosaic(self.keyed_images(9)), 96, 0)

    def test_eight_keys_keep_the_full_tile(self):
        self.playing(artwork=self.position_art())
        host = self.start()
        host.keys(self.page()[:8])
        tile = self.image()
        self.assertEqual(fake_host.png_size(tile["_bytes"]), (118, 118))
        self.assertEqual([m for m in host.drain(0.6) if m["type"] == "image"], [])

    def test_a_page2_mosaic_beside_single_keys(self):
        self.playing(artwork=self.position_art())
        host = self.start()
        host.keys([self.slot()])
        full = self.image()
        singles = [self.slot(), *self.page(device="keypad-2")[:8]]
        host.keys(self.page("page2:") + singles)
        got = self.keyed_images(18)
        self.assert_cut(self.mosaic(got, prefix="page2:"), 118, 25)
        alone = [m for m in got if not m["slot"].startswith("page2:")]
        self.assertEqual(sorted((m["device"], m["slot"]) for m in alone),
                         sorted((s["device"], s["slot"]) for s in singles))
        self.assertTrue(all(m["png"] == full["png"] for m in alone))
        self.assertEqual([m for m in host.drain(0.5) if m["type"] == "image_all"], [])

    def test_paused_mosaic_is_gray_with_play_on_the_center_key_only(self):
        self.playing(state="paused", artwork=self.position_art())
        host = self.start()
        host.keys(self.page())
        tiles = self.mosaic(self.keyed_images(9))
        for name in GRID:
            _, _, pixel = read_png(tiles[name]["_bytes"])
            for px, py in ((6, 6), (110, 20), (20, 110)):
                r, g, b, _ = pixel(px, py)
                self.assertLessEqual(max(r, g, b) - min(r, g, b), 2, f"{name} is not gray at ({px},{py})")
                self.assertLess(r, 160, f"{name} is not dimmed at ({px},{py})")
            center = pixel(59, 59)
            if name == "gridMiddle":
                self.assertTrue(all(v >= 235 for v in center[:3]), f"no white play triangle: {center}")
                self.assertLess(max(pixel(59, 70)[:3]), 90, "the dark circle is missing under the triangle")
            else:
                self.assertLess(max(center[:3]), 160, f"{name} has a play triangle")

    def test_not_running_shows_the_icon_on_the_center_key_and_black_elsewhere(self):
        self.set_state(running=False)
        host = self.start()
        host.keys([self.slot()])
        icon = self.image()
        host.keys(self.page())
        tiles = self.mosaic(self.keyed_images(9))
        self.assertEqual(tiles["gridMiddle"]["png"], icon["png"])
        for name in GRID:
            if name == "gridMiddle":
                continue
            width, height, pixel = read_png(tiles[name]["_bytes"])
            self.assertTrue(all(pixel(x, y) == (0, 0, 0, 255) for y in range(height) for x in range(width)),
                            f"{name} is not plain black")

    def test_a_press_on_any_mosaic_key_plays_or_pauses_and_repaints_at_once(self):
        self.playing(artwork=self.position_art())
        host = self.start(settings={"mosaic_stagger_ms": 200})
        host.keys(self.page())
        self.keyed_images(9)
        host.press(device="keypad-1", slot="gridTopLeft")
        got = self.keyed_images(9, timeout=1.5)
        self.assertLess(got[-1]["_at"] - got[0]["_at"], 0.12, "a play/pause toggle was staggered")
        self.assertIn("playpause", self.calls())

    def test_a_track_change_reveals_the_keys_in_reading_order(self):
        self.playing(artwork=self.position_art())
        host = self.start(settings={"mosaic_stagger_ms": 150})
        host.keys(self.page())
        first = self.keyed_images(9)
        self.assertLess(first[-1]["_at"] - first[0]["_at"], 0.12, "the first paint was staggered")
        self.playing(id="spotify:track:2", name="Another Song", artwork=self.position_art("b.png", blue=40))
        got = self.keyed_images(9, timeout=5)
        self.assertEqual([m["slot"] for m in got], GRID)
        times = [m["_at"] for m in got]
        self.assertTrue(all(b - a >= 0.03 for a, b in zip(times, times[1:])), times)
        self.assertGreater(times[-1] - times[0], 0.9, times)
        self.assertLess(times[-1] - times[0], 4.0, times)

    def test_a_second_track_change_cancels_the_rest_of_the_reveal(self):
        self.playing(artwork=self.position_art())
        host = self.start(settings={"mosaic_stagger_ms": 300})
        host.keys(self.page())
        self.keyed_images(9)
        self.playing(id="spotify:track:2", name="B", artwork=self.position_art("b.png", blue=40))
        got = self.keyed_images(1, timeout=3)
        time.sleep(0.65)
        self.playing(id="spotify:track:3", name="C", artwork=self.position_art("c.png", blue=240))
        got += [m for m in host.drain(4.5) if m["type"] == "image"]

        def blue(message):
            return read_png(message["_bytes"])[2](59, 59)[2]

        arts = ["B" if abs(blue(m) - 40) <= 3 else "C" if abs(blue(m) - 240) <= 3 else "?" for m in got]
        self.assertNotIn("?", arts)
        b_count = arts.count("B")
        self.assertEqual(arts, ["B"] * b_count + ["C"] * 9, arts)
        self.assertTrue(1 <= b_count < 9, arts)
        self.assertEqual([m["slot"] for m in got], GRID[:b_count] + GRID)

    def test_stagger_zero_sends_all_nine_at_once(self):
        self.playing(artwork=self.position_art())
        host = self.start(settings={"mosaic_stagger_ms": 0})
        host.keys(self.page())
        self.keyed_images(9)
        self.playing(id="spotify:track:2", name="Another Song", artwork=self.position_art("b.png", blue=40))
        got = self.keyed_images(9, timeout=3)
        self.assertEqual([m["slot"] for m in got], GRID)
        self.assertLess(got[-1]["_at"] - got[0]["_at"], 0.12)

    def test_mosaic_tiles_are_cached_per_key(self):
        self.playing(artwork=self.position_art())
        host = self.start()
        host.keys(self.page())
        first = self.keyed_images(9)
        self.assertEqual(len([n for n in os.listdir(self.cache) if n.endswith(".png")]), 9)
        self.assertEqual(host.shutdown(), 0)
        self.assertEqual(host.problems, [])
        os.remove(self.position_art())   # only the cache can draw it now
        self.start().keys(self.page())
        again = self.keyed_images(9)
        self.assertEqual([m["png"] for m in again], [m["png"] for m in first])

    def test_bad_settings_fall_back_with_one_warning(self):
        self.playing()
        host = self.start(settings={"mosaic_gap_percent": "wide", "mosaic_stagger_ms": 5000})
        got = host.drain(0.8)
        warnings = [m for m in got if m["type"] == "log" and m["level"] == "warn"]
        self.assertEqual(len(warnings), 1, warnings)
        self.assertIn("mosaic_gap_percent wide is not a number; using 25", warnings[0]["message"])
        self.assertIn("mosaic_stagger_ms 5000 is outside 0 to 1000; using 1000", warnings[0]["message"])

    def test_good_settings_log_no_warning(self):
        self.playing()
        host = self.start(settings={"mosaic_gap_percent": 12.5, "mosaic_stagger_ms": 0})
        got = host.drain(0.8)
        self.assertEqual([m for m in got if m["type"] == "log" and m["level"] == "warn"], [])

    # Per-key roles

    def control_page(self, **settings):
        return dict(settings, keys=PAGE2_ROLES)

    def by_slot(self, messages):
        return {m["slot"]: m for m in messages}

    def preview(self, *args):
        out = os.path.join(self.dir, "preview.png")
        env = dict(os.environ, FAKE_SPOTIFY_DIR=self.dir)
        result = subprocess.run([BINARY, "--preview", out, *args], capture_output=True, text=True, timeout=30, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(out, "rb") as f:
            return f.read()

    def role_images(self, slot, seconds):
        return [m for m in self.host.drain(seconds) if m["type"] == "image" and m["slot"] == slot]

    def test_roles_draw_each_key_while_page1_stays_a_mosaic(self):
        self.playing(artwork=self.position_art())
        host = self.start(settings=self.control_page())
        host.keys([self.slot()])
        full = self.image()
        host.keys(self.page() + self.page("page2:"))
        got = self.keyed_images(18)
        self.assert_cut(self.mosaic(got), 118, 25)
        page2 = {m["slot"]: m for m in got if m["slot"].startswith("page2:")}
        self.assertEqual(sorted(page2), sorted(PAGE2_ROLES))
        self.assertEqual(len({m["png"] for m in page2.values()}), 9, "control faces are not distinct")
        self.assertEqual(page2["page2:gridBottomMiddle"]["png"], full["png"])
        mosaic_tiles = {m["png"] for m in got if not m["slot"].startswith("page2:")}
        self.assertFalse(mosaic_tiles & {m["png"] for m in page2.values()})
        self.assertEqual([m for m in host.drain(0.5) if m["type"] == "image_all"], [])

    def test_title_banner_runs_across_three_keys(self):
        self.playing(name="Golden Hour Drive", artist="The Night Lanterns", artwork=self.position_art())
        keys = {"page2:" + name: "title" for name in GRID[:3]}
        host = self.start(settings={"keys": keys})
        host.keys(self.page("page2:"))
        tiles = {m["slot"][6:]: m for m in self.keyed_images(9)}
        size, gap = 118, 30
        side = 3 * size + 2 * gap
        # The blurred, darkened cover: red still follows the canvas x, at 60%.
        for col, px in ((0, 90), (1, 6), (1, 60), (2, 6)):
            _, _, pixel = read_png(tiles[GRID[col]]["_bytes"])
            x = col * (size + gap) + px + 0.5
            self.assertAlmostEqual(pixel(px, 4)[0] * side / (0.6 * 255), x, delta=8, msg=f"key {col} at {px}")
        # The title runs from the first key into the second.
        for name in GRID[:2]:
            width, height, pixel = read_png(tiles[name]["_bytes"])
            white = sum(1 for y in range(20, 70) for x in range(width) if min(pixel(x, y)[:3]) >= 235)
            self.assertGreater(white, 20, f"no title on {name}")

    def test_banner_text_is_never_lost_under_the_gaps(self):
        self.playing(name="Golden Hour Drive", artist="The Night Lanterns", artwork=self.position_art())
        keys = {"page2:" + name: "title" for name in GRID[:3]}

        def banner(gap_percent):
            host = self.start(settings={"keys": keys, "mosaic_gap_percent": gap_percent})
            host.keys(self.page("page2:"))
            tiles = {m["slot"][6:]: m for m in self.keyed_images(9)}
            self.assertEqual(host.shutdown(), 0)
            self.assertEqual(host.problems, [])
            decoded = [read_png(tiles[name]["_bytes"]) for name in GRID[:3]]
            # The three keys side by side, with no gaps.
            return [[decoded[x // 118][2](x % 118, y)[:3] for x in range(3 * 118)] for y in range(118)]

        def ink(rows):
            return sum(1 for row in rows for pixel in row if min(pixel) >= 200)

        with_gaps = banner(25)
        _, _, pixel = read_png(self.preview("--role", "title", "--title", "Golden Hour Drive",
                                            "--artist", "The Night Lanterns", "--artwork", self.position_art()))
        whole = [[pixel(x, y)[:3] for x in range(3 * 118)] for y in range(118)]
        self.assertEqual(with_gaps, whole, "the keys are not one uncut banner")
        self.assertGreater(ink(with_gaps), 500)
        self.assertAlmostEqual(ink(with_gaps), ink(banner(0)), delta=ink(with_gaps) * 0.03)

    def scroll_title(self):
        # 387 px at the smallest size, 57 more than the banner holds.
        return "Golden Hour Drive Through The Long Night"

    def test_a_long_title_scrolls_and_rests_at_both_ends(self):
        self.playing(name=self.scroll_title(), artwork=self.position_art())
        keys = {"page2:" + name: "title" for name in GRID[:3]}
        host = self.start(settings={"keys": keys, "banner_fps": 8})
        host.keys(self.page("page2:"))
        frames = self.role_images("page2:gridTopLeft", 9)
        self.assertGreater(len(frames), 4, [round(f["_at"], 2) for f in frames])
        times = [f["_at"] for f in frames]
        self.assertGreater(times[1] - times[0], 1.7, "no rest at the start")
        moving = [b - a for a, b in zip(times[1:], times[2:])]
        rest = next(i for i, d in enumerate(moving) if d > 1.0)
        self.assertGreater(rest, 2, "it hardly moved")
        self.assertTrue(all(d < 0.5 for d in moving[:rest]), moving)
        self.assertGreater(moving[rest], 1.7, "no rest at the end")
        run = [f["png"] for f in frames[:rest + 2]]
        self.assertTrue(all(a != b for a, b in zip(run, run[1:])), "consecutive frames repeat")
        self.assertEqual(frames[rest + 2]["png"], frames[0]["png"], "it did not jump back to the start")

    def test_banner_fps_0_does_not_scroll(self):
        self.playing(name=self.scroll_title(), artwork=self.position_art())
        keys = {"page2:" + name: "title" for name in GRID[:3]}
        host = self.start(settings={"keys": keys, "banner_fps": 0})
        host.keys(self.page("page2:"))
        self.assertEqual(len(self.role_images("page2:gridTopLeft", 3.5)), 1)

    def test_shuffle_and_repeat_presses_toggle_and_redraw_only_that_key(self):
        self.playing(state="paused", artwork=self.position_art(), position=40, duration=200000)
        host = self.start(settings=self.control_page())
        host.keys(self.page("page2:"))
        first = self.by_slot(self.keyed_images(9))
        for slot, field in (("page2:gridMiddleLeft", "shuffling"), ("page2:gridMiddleRight", "repeating")):
            host.press(device="keypad-1", slot=slot)
            got = [m for m in host.drain(1.2) if m["type"] == "image"]
            self.assertEqual([m["slot"] for m in got], [slot])
            self.assertNotEqual(got[0]["png"], first[slot]["png"])
            with open(os.path.join(self.dir, "state.json")) as f:
                self.assertTrue(json.load(f)[field])
        self.assertNotIn("playpause", self.calls())

    def test_time_key_shows_the_time_advances_and_seeks_back(self):
        self.playing(state="paused", artwork=self.position_art(), position=102, duration=236000)
        host = self.start(settings=self.control_page())
        host.keys(self.page("page2:"))
        time_key = self.by_slot(self.keyed_images(9))["page2:gridMiddle"]
        common = ["--role", "time", "--duration", "236", "--artwork", self.position_art()]
        self.assertEqual(time_key["_bytes"], self.preview(*common, "--position", "102", "--paused"))

        playing = {self.preview(*common, "--position", str(p)): p for p in range(102, 108)}
        self.playing(artwork=self.position_art(), position=102, duration=236000)
        ticks = self.role_images("page2:gridMiddle", 3.3)
        seconds = [playing.get(t["_bytes"]) for t in ticks]
        self.assertNotIn(None, seconds, "a tick drew something other than the time")
        self.assertGreaterEqual(len(seconds), 3, seconds)
        self.assertEqual(seconds, sorted(set(seconds)), "the ring did not advance")

        host.press(device="keypad-1", slot="page2:gridMiddle")
        redrawn = self.role_images("page2:gridMiddle", 0.6)
        with open(os.path.join(self.dir, "state.json")) as f:
            position = json.load(f)["position"]
        self.assertTrue(85 < position < seconds[-1] - 13, position)
        self.assertTrue(redrawn, "the time key was not redrawn at once")
        self.assertIn("seek-back", self.calls())

        self.playing(state="paused", artwork=self.position_art(), position=5, duration=236000)
        self.role_images("page2:gridMiddle", 0.6)
        host.press(device="keypad-1", slot="page2:gridMiddle")
        redrawn = self.role_images("page2:gridMiddle", 0.8)
        with open(os.path.join(self.dir, "state.json")) as f:
            self.assertEqual(json.load(f)["position"], 0)
        self.assertEqual(redrawn[-1]["_bytes"], self.preview(*common, "--position", "0", "--paused"))

    def test_previous_and_next_presses_reach_spotify(self):
        self.playing(state="paused", artwork=self.position_art())
        host = self.start(settings=self.control_page())
        host.keys(self.page("page2:"))
        self.keyed_images(9)
        host.press(device="keypad-1", slot="page2:gridBottomLeft")
        host.press(device="keypad-1", slot="page2:gridBottomRight")
        host.drain(0.5)
        calls = self.calls()
        self.assertEqual(calls.count("previous-track"), 1)
        self.assertEqual(calls.count("next-track"), 1)
        self.assertNotIn("playpause", calls)

    def test_control_presses_do_nothing_when_spotify_is_not_running(self):
        self.set_state(running=False)
        host = self.start(settings=self.control_page())
        host.keys(self.page("page2:"))
        self.keyed_images(9)
        for slot, role in PAGE2_ROLES.items():
            if role not in ("title", "art"):
                host.press(device="keypad-1", slot=slot)
        host.drain(0.8)
        self.assertEqual([c for c in self.calls() if c != "read"], [])

    def test_an_unknown_role_warns_once_and_draws_art(self):
        self.playing(artwork=self.position_art())
        host = self.start(settings={"keys": {"gridMiddle": "volume", "gridTopLeft": 7, "gridBottomLeft": "next"}})
        warnings = [m for m in host.drain(0.6) if m["type"] == "log" and m["level"] == "warn"]
        self.assertEqual(len(warnings), 1, warnings)
        self.assertIn("keys gridMiddle = volume is not a role; using art", warnings[0]["message"])
        self.assertIn("keys gridTopLeft = 7 is not a role; using art", warnings[0]["message"])
        host.keys([self.slot(), self.slot(name="gridTopLeft"), self.slot(name="gridBottomLeft")])
        got = self.by_slot(self.keyed_images(3))
        self.assertEqual(got["gridMiddle"]["png"], got["gridTopLeft"]["png"])
        self.assertNotEqual(got["gridBottomLeft"]["png"], got["gridMiddle"]["png"])

    def test_the_tick_sends_only_the_time_key(self):
        self.playing(artwork=self.position_art(), position=30, duration=200000)
        host = self.start(settings=self.control_page())
        host.keys(self.page("page2:"))
        self.keyed_images(9)
        got = [m for m in host.drain(3.2) if m["type"] in ("image", "image_all")]
        self.assertGreaterEqual(len(got), 2)
        self.assertEqual({m["slot"] for m in got}, {"page2:gridMiddle"})


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
