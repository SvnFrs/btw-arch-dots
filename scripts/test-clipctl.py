#!/usr/bin/env python3
"""Tests for home/.config/quickshell/enhalation/bin/clipctl (docs/clipboard-ui.md, K1).

Everything runs against throwaway state in one temp dir: CLIPHIST_DB_PATH, XDG_RUNTIME_DIR (the
thumb cache), XDG_DATA_HOME (pins), and a private headless Wayfire whose socket lives in that
runtime dir, so copy tests never reach the real clipboard, its `wl-paste --watch` store, or the
real history. All clip data is synthetic. At the end the real history is checked unchanged
(size + mtime only; it is never read).

    ./scripts/test-clipctl.py [-v]
"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLIPCTL = os.path.join(REPO, "home/.config/quickshell/enhalation/bin/clipctl")
WAYFIRE = "/usr/local/bin/wayfire"
REAL_DB = os.path.expanduser("~/.cache/cliphist/db")
REAL_RUNTIME = os.environ.get("XDG_RUNTIME_DIR", "")
REAL_DATA = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")

T = tempfile.mkdtemp(prefix="clipctl-test-")
# The private runtime dir holds the compositor's socket, and a socket path must fit in 108 bytes,
# so it gets a short home: its own dir under the real runtime dir (tmpfs, user-only), never the
# real enhalation/ cache.
RUN = tempfile.mkdtemp(prefix="clipctl-test-", dir=REAL_RUNTIME or "/tmp")
ENV = {k: v for k, v in os.environ.items()
       if k not in ("WAYLAND_DISPLAY", "WAYFIRE_SOCKET", "DISPLAY", "CLIPBOARD_STATE")}
ENV.update(CLIPHIST_DB_PATH=os.path.join(T, "db"), XDG_RUNTIME_DIR=RUN,
           XDG_DATA_HOME=os.path.join(T, "data"))
CACHE = os.path.join(RUN, "enhalation", "clip")
PINS = os.path.join(T, "data", "enhalation", "clip-pins")
compositor = None
compositor_log = None
real_before = None


def setUpModule():
    global compositor, compositor_log, real_before
    real_before = _real_state()
    os.chmod(RUN, 0o700)
    if not os.access(WAYFIRE, os.X_OK):
        return
    with open(os.path.join(T, "wf.ini"), "w") as f:
        f.write("[core]\nplugins =\nxwayland = false\n")
    compositor_log = open(os.path.join(T, "wf.log"), "wb")
    compositor = subprocess.Popen([WAYFIRE, "-c", os.path.join(T, "wf.ini")],
                                  stdout=compositor_log, stderr=compositor_log,
                                  env=dict(ENV, WLR_BACKENDS="headless", WLR_LIBINPUT_NO_DEVICES="1"))
    for _ in range(100):
        socks = [n for n in os.listdir(ENV["XDG_RUNTIME_DIR"]) if n.startswith("wayland-")
                 and stat.S_ISSOCK(os.stat(os.path.join(ENV["XDG_RUNTIME_DIR"], n)).st_mode)]
        if socks:
            ENV["WAYLAND_DISPLAY"] = socks[0]
            return
        time.sleep(0.1)


def tearDownModule():
    if compositor:
        compositor.terminate()
        compositor.wait(10)
    if compositor_log:
        compositor_log.close()
    shutil.rmtree(T, ignore_errors=True)
    shutil.rmtree(RUN, ignore_errors=True)
    after = _real_state()
    assert after == real_before, f"real state changed: {real_before} -> {after}"
    print(f"\nreal history, cache and pins untouched: {after}", file=sys.stderr)


def _real_state():
    def st(p):
        try:
            s = os.stat(p)
            return (s.st_size, int(s.st_mtime))
        except FileNotFoundError:
            return None
    return {"db": st(REAL_DB),
            "cache": os.path.exists(os.path.join(REAL_RUNTIME, "enhalation", "clip")) if REAL_RUNTIME else None,
            "pins": os.path.exists(os.path.join(REAL_DATA, "enhalation", "clip-pins"))}


def ctl(*args, timeout=30):
    p = subprocess.run([CLIPCTL, *args], capture_output=True, env=ENV, timeout=timeout)
    return p.returncode, json.loads(p.stdout)


def ok(*args, **kw):
    rc, out = ctl(*args, **kw)
    assert rc == 0 and "error" not in out, f"clipctl {args[0]} failed: {out}"
    return out


def store(data):
    if isinstance(data, str):
        data = data.encode()
    subprocess.run(["cliphist", "store"], input=data, env=ENV, check=True)
    return int(subprocess.run(["cliphist", "list"], capture_output=True, env=ENV,
                              check=True).stdout.split(b"\t", 1)[0])


def image(w, h, fmt="png", color="0x89b4fa"):
    path = os.path.join(T, f"img-{w}x{h}-{color}.{fmt}")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"color=c={color}:s={w}x{h}",
                    "-frames:v", "1", "-update", "1", path], check=True)
    with open(path, "rb") as f:
        return f.read()


def decode(cid):
    return subprocess.run(["cliphist", "decode", str(cid)], capture_output=True, env=ENV, check=True).stdout


def cache_files():
    return sorted(os.listdir(CACHE)) if os.path.isdir(CACHE) else None


def paste(*args):
    return subprocess.run(["wl-paste", *args], capture_output=True, env=ENV, timeout=5).stdout


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")


class Base(unittest.TestCase):
    def setUp(self):                                   # a fresh db, cache and pins per test
        for p in (ENV["CLIPHIST_DB_PATH"],):
            if os.path.exists(p):
                os.remove(p)
        shutil.rmtree(os.path.join(RUN, "enhalation"), ignore_errors=True)
        shutil.rmtree(os.path.join(T, "data"), ignore_errors=True)

    def needs_compositor(self):
        if "WAYLAND_DISPLAY" not in ENV:
            self.skipTest("no private headless compositor")


class ListTests(Base):
    def test_empty(self):
        self.assertEqual(ok("list"), {"items": []})

    def test_kinds_hints_and_order(self):
        ids = {
            "multi": store("synthetic first line\n\tsecond line"),
            "url": store("https://example.invalid/some/path?q=1"),
            "hex3": store("#abc"),
            "hex6": store("#89B4FA"),
            "hex8": store("#89b4fa80"),
            "hex4": store("#abcd"),
            "big": store(image(3440, 1440)),
            "jpeg": store(image(64, 48, "jpg")),
        }
        items = ok("list")["items"]
        self.assertEqual([i["id"] for i in items], sorted(ids.values(), reverse=True), "newest first")
        by = {i["id"]: i for i in items}
        self.assertEqual(by[ids["multi"]]["preview"], "synthetic first line second line",
                         "cliphist collapses each whitespace run to one space")
        self.assertEqual(by[ids["multi"]]["hint"], "text")
        self.assertEqual(by[ids["url"]]["hint"], "url")
        self.assertEqual((by[ids["hex3"]]["hint"], by[ids["hex3"]]["color"]), ("color", "#aabbcc"))
        self.assertEqual(by[ids["hex6"]]["color"], "#89b4fa")
        self.assertEqual(by[ids["hex8"]]["color"], "#8089b4fa", "QML is #aarrggbb")
        self.assertEqual(by[ids["hex4"]]["hint"], "text", "#rgba is not in the spec")
        big = by[ids["big"]]
        self.assertEqual((big["kind"], big["fmt"], big["w"], big["h"]), ("image", "png", 3440, 1440))
        self.assertRegex(big["size"], r"^[0-9]+ (B|KiB|MiB)$")
        self.assertEqual((by[ids["jpeg"]]["fmt"], by[ids["jpeg"]]["w"]), ("jpeg", 64))
        for i in items:                                # K0 corrections: list cannot know these
            self.assertNotIn("lines", i)
            self.assertNotIn("chars", i)

    def test_list_decodes_nothing(self):
        store(image(3440, 1440))
        store("synthetic text")
        self.assertIsNone(cache_files(), "list must not even create the cache dir")
        ok("list")
        self.assertIsNone(cache_files())
        ok("thumb", str(store(image(640, 360))))       # now a cache exists…
        before = cache_files()
        ok("list")
        self.assertEqual(cache_files(), before, "…and list adds nothing to it")

    def test_search_depth_400(self):
        text = "a" * 340 + " NEEDLE_IN " + "b" * 90 + " NEEDLE_OUT " + "c" * 50
        cid = store(text)
        preview = next(i for i in ok("list")["items"] if i["id"] == cid)["preview"]
        self.assertIn("NEEDLE_IN", preview)
        self.assertNotIn("NEEDLE_OUT", preview, "past 400 chars is not searchable")
        self.assertLessEqual(len(preview), 401)        # 400 + "…"
        self.assertTrue(preview.endswith("…"))


class ThumbTests(Base):
    def test_big_png_fits_168x96_and_is_cached(self):
        cid = store(image(3440, 1440))
        t = ok("thumb", str(cid))
        self.assertEqual(t["thumb"], os.path.join(CACHE, f"thumb-{cid}.png"))
        self.assertLessEqual(t["w"], 168)
        self.assertLessEqual(t["h"], 96)
        self.assertEqual((t["w"], t["h"]), png_size(t["thumb"]))
        self.assertEqual(t["w"], 168, "a wide image fills the width")
        mtime = os.stat(t["thumb"]).st_mtime_ns
        time.sleep(0.05)
        self.assertEqual(ok("thumb", str(cid))["thumb"], t["thumb"])
        self.assertEqual(os.stat(t["thumb"]).st_mtime_ns, mtime, "second call reuses the cache")
        self.assertEqual(stat.S_IMODE(os.stat(CACHE).st_mode), 0o700)

    def test_small_and_tall_images(self):
        self.assertEqual(tuple(ok("thumb", str(store(image(64, 48))))[k] for k in "wh"), (64, 48),
                         "never upscaled")
        tall = ok("thumb", str(store(image(300, 1200, color="0xf38ba8"))))
        self.assertEqual(tall["h"], 96)
        self.assertLessEqual(tall["w"], 168)

    def test_text_is_refused(self):
        rc, out = ctl("thumb", str(store("synthetic text")))
        self.assertEqual((rc, list(out)), (1, ["error"]))

    def test_thumb_of_a_gone_id_is_pruned_by_list(self):
        keep, gone = store(image(640, 360)), store(image(320, 180, color="0xa6e3a1"))
        ok("thumb", str(keep))
        ok("thumb", str(gone))
        subprocess.run(["cliphist", "delete"], input=f"{gone}\t\n".encode(), env=ENV, check=True)
        ok("list")
        self.assertEqual(cache_files(), [f"thumb-{keep}.png"])


class PreviewTests(Base):
    def test_one_preview_file_replaced_each_time(self):
        a, b = store(image(800, 600)), store(image(64, 48, "jpg"))
        pa = ok("preview", str(a))
        self.assertEqual(pa["path"], os.path.join(CACHE, "preview.png"))
        with open(pa["path"], "rb") as f:
            self.assertEqual(f.read(), decode(a), "full size, byte for byte")
        pb = ok("preview", str(b))
        self.assertEqual(pb["path"], os.path.join(CACHE, "preview.jpeg"))
        self.assertEqual([n for n in cache_files() if n.startswith("preview.")], ["preview.jpeg", "preview.ref"])
        with open(os.path.join(CACHE, "preview.ref")) as f:
            self.assertEqual(f.read(), str(b), "preview.ref names the clip the preview belongs to")

    def test_text_is_refused(self):
        self.assertEqual(ctl("preview", str(store("synthetic text")))[0], 1)


class TextTests(Base):
    def test_meta_and_truncation(self):
        t = ok("text", str(store("a\nb\nc")))
        self.assertEqual((t["text"], t["lines"], t["chars"], t["truncated"]), ("a\nb\nc", 3, 5, False))
        self.assertEqual(ok("text", str(store("one\ntwo\n")))["lines"], 2, "a trailing newline is no line")
        long = ok("text", str(store("z" * 30000)))
        self.assertEqual((len(long["text"]), long["chars"], long["truncated"]), (20000, 30000, True))
        short = ok("text", str(store("0123456789abcdef")), "10")
        self.assertEqual((short["text"], short["truncated"]), ("0123456789", True))

    def test_bad_input(self):
        cid = str(store("synthetic"))
        self.assertEqual(ctl("text", cid, "0")[0], 1)
        self.assertEqual(ctl("text", str(store(image(64, 48))))[0], 1, "an image is not text")


class CopyTests(Base):
    def test_refuses_empty_and_bad_ids(self):
        self.needs_compositor()
        store("synthetic sentinel")
        subprocess.run(["wl-copy"], input=b"clipboard before", env=ENV, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for bad in ("", " ", "abc", "12a", "-1", "99999"):
            rc, out = ctl("copy", bad)
            self.assertEqual((rc, list(out)), (1, ["error"]), repr(bad))
        self.assertEqual(paste("--no-newline"), b"clipboard before", "nothing reached wl-copy")

    def test_text_and_image(self):
        self.needs_compositor()
        cid = store("synthetic copy target")
        t0 = time.monotonic()
        ok("copy", str(cid), timeout=10)
        self.assertLess(time.monotonic() - t0, 5, "wl-copy's forked child must not hold clipctl")
        self.assertEqual(paste("--no-newline"), b"synthetic copy target")
        img = image(320, 200)
        ok("copy", str(store(img)))
        self.assertEqual(paste("--list-types").split(), [b"image/png"])
        self.assertEqual(paste("--type", "image/png"), img)


class DeleteUndoTests(Base):
    def test_round_trip(self):
        a, b, c = store("synthetic a"), store("synthetic b"), store("synthetic c")
        ok("delete", str(b))
        ids = [i["id"] for i in ok("list")["items"]]
        self.assertEqual(ids, [c, a], "exactly that entry")
        self.assertTrue(os.path.exists(os.path.join(CACHE, "undo.bin")))
        u = ok("undo")
        items = ok("list")["items"]
        self.assertEqual(items[0]["preview"], "synthetic b", "back on top")
        self.assertEqual(u["id"], items[0]["id"])
        self.assertNotEqual(u["id"], b, "under a new id (K0)")
        self.assertEqual(decode(u["id"]), b"synthetic b")
        self.assertFalse(os.path.exists(os.path.join(CACHE, "undo.bin")))
        self.assertEqual(ctl("undo")[0], 1, "nothing left to undo")

    def test_image_round_trip_and_its_thumb(self):
        img = image(640, 360)
        cid = store(img)
        ok("thumb", str(cid))
        ok("delete", str(cid))
        self.assertFalse(os.path.exists(os.path.join(CACHE, f"thumb-{cid}.png")))
        self.assertEqual(decode(ok("undo")["id"]), img)

    def test_bad_ids(self):
        store("synthetic")
        for bad in ("", "x", "99999"):
            self.assertEqual(ctl("delete", bad)[0], 1, repr(bad))
        self.assertEqual(len(ok("list")["items"]), 1)


class DeletedMeansGoneTests(Base):              # K3 safety rule 3
    def test_forget_removes_the_stash(self):
        ok("delete", str(store("synthetic to forget")))
        self.assertTrue(os.path.exists(os.path.join(CACHE, "undo.bin")))
        self.assertTrue(ok("forget")["had"])
        for name in ("undo.bin", "undo.json"):
            self.assertFalse(os.path.exists(os.path.join(CACHE, name)))
        self.assertFalse(ok("forget")["had"])
        self.assertEqual(ctl("undo")[0], 1, "nothing to undo once forgotten")

    def test_delete_clears_its_own_preview_only(self):
        a, b = store(image(800, 600)), store(image(64, 48, "jpg"))
        ok("preview", str(a))
        ok("delete", str(b))                           # not the preview's clip: it stays
        self.assertIn("preview.png", cache_files())
        ok("delete", str(a))                           # the preview's clip: preview.* goes
        self.assertEqual([n for n in cache_files() if n.startswith("preview.")], [])

    def test_wipe_removes_the_stash(self):
        ok("delete", str(store("synthetic stash")))
        ok("wipe")
        self.assertIsNone(cache_files())


class WhereamiTests(Base):                          # K3 safety rule 2
    def test_paths(self):
        self.assertEqual(ok("whereami"), {"db": ENV["CLIPHIST_DB_PATH"], "data_home": ENV["XDG_DATA_HOME"],
                                          "runtime": RUN})


class PinTests(Base):
    def test_pin_list_unpin(self):
        t, i = store("synthetic pinned text"), store(image(640, 360))
        p1, p2 = ok("pin", str(t)), ok("pin", str(i))
        pins = ok("pins")["items"]
        self.assertEqual([p["n"] for p in pins], [p2["n"], p1["n"]], "newest pin first")
        self.assertEqual((pins[0]["kind"], pins[0]["fmt"], pins[0]["w"]), ("image", "png", 640))
        for p in pins:
            self.assertTrue(os.path.isfile(p["path"]))
            self.assertEqual(stat.S_IMODE(os.stat(p["path"]).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(PINS).st_mode), 0o700)
        self.assertTrue(ok("pin", str(t))["existing"], "same bytes: no second pin")
        self.assertEqual(len(ok("pins")["items"]), 2)
        ok("unpin", str(p1["n"]))
        self.assertEqual([p["n"] for p in ok("pins")["items"]], [p2["n"]])
        self.assertEqual(ctl("unpin", str(p1["n"]))[0], 1)

    def test_pin_survives_its_entry_and_reads_by_ref(self):
        self.needs_compositor()
        cid = store("synthetic pin source\nline two")
        n = ok("pin", str(cid))["n"]
        img_n = ok("pin", str(store(image(3440, 1440))))["n"]
        subprocess.run(["cliphist", "wipe"], env=ENV, check=True)
        t = ok("text", f"pin:{n}")
        self.assertEqual((t["text"], t["lines"]), ("synthetic pin source\nline two", 2))
        th = ok("thumb", f"pin:{img_n}")
        self.assertLessEqual(th["w"], 168)
        self.assertLessEqual(th["h"], 96)
        self.assertEqual(ok("preview", f"pin:{img_n}")["path"], ok("pins")["items"][0]["path"])
        ok("copy-pin", str(n))
        self.assertEqual(paste("--no-newline"), b"synthetic pin source\nline two")

    def test_at_most_20(self):
        for k in range(20):
            ok("pin", str(store(f"synthetic pin {k}")))
        rc, out = ctl("pin", str(store("synthetic pin 21")))
        self.assertEqual((rc, list(out)), (1, ["error"]))

    def test_damaged_index_cannot_escape(self):
        os.makedirs(PINS, mode=0o700)
        with open(os.path.join(PINS, "index.json"), "w") as f:
            json.dump({"next": 2, "items": [{"n": 1, "kind": "text", "preview": "x", "file": "../../etc"}]}, f)
        for args in (("pins",), ("text", "pin:1"), ("copy-pin", "1"), ("unpin", "1")):
            self.assertEqual(ctl(*args)[0], 1, args)


class WipeTests(Base):
    def test_wipe_clears_cache_keeps_pins(self):
        a, img = store("synthetic a"), store(image(640, 360))
        ok("thumb", str(img))
        ok("preview", str(img))
        ok("pin", str(a))
        ok("delete", str(a))                           # leaves an undo stash
        self.assertTrue(cache_files())
        out = ok("wipe")
        self.assertEqual(out["pins"], 1)
        self.assertEqual(ok("list")["items"], [])
        self.assertIsNone(cache_files(), "the whole clip/ dir goes")
        self.assertEqual(len(ok("pins")["items"]), 1)


class ErrorShapeTests(Base):
    def test_usage_errors_are_json(self):
        for args in ((), ("bogus",), ("copy",), ("list", "extra"), ("text", "1", "2", "3")):
            rc, out = ctl(*args)
            self.assertEqual((rc, list(out)), (1, ["error"]), args)


if __name__ == "__main__":
    unittest.main()
