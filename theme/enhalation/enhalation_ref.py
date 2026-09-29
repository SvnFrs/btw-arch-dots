#!/usr/bin/env python3
"""
enhalation_ref.py — reference oracle for the Enhalation desktop profile.

Stdlib only (python3 >= 3.9; no Pillow). It is the executable form of the
NORMATIVE parts of docs/enhalation-desktop.md:

  --derived          print the resolved + derived desktop tokens as JSON
  --contrast         print the contrast gate table; exit 1 if a required pair fails
  --bake OUTDIR      write the baked grain PNGs (glass-grain.png, switch-on.png)
  --digest           print raw-RGBA sha256 + mean for each baked image (no files)

scripts/gen-theme.py IMPORTS this module for all colour math, the contrast gate and
the baking; it must not re-implement them. The golden values in
docs/enhalation-desktop.md §2 and §8 are this file's output on 2026-09-29.

Inputs (next to this file, in theme/enhalation/):
  tokens.json         Enhalation tokens, vendored verbatim
  grain-220.pgm       the grain tile: grain.svg rasterized at 220x220, 1x,
                      in Chromium (the renderer Enhalation was designed in).
                      8-bit grey, binary PGM (P5). Do not re-render it.
"""
import argparse, hashlib, json, math, os, struct, sys, zlib

ROOT = os.path.dirname(os.path.abspath(__file__))  # theme/enhalation
FLAVOR = "mocha"

# ───────────────────────────── colour basics ─────────────────────────────
def parse_hex(s):
    s = s.strip().lstrip("#")
    if len(s) not in (6, 8):
        raise ValueError(f"not a hex colour: #{s}")
    r, g, b = (int(s[i:i + 2], 16) / 255 for i in (0, 2, 4))
    a = int(s[6:8], 16) / 255 if len(s) == 8 else 1.0
    return (r, g, b, a)

def q8(v):                      # float 0..1 -> 0..255, round half up, clamped
    return max(0, min(255, int(v * 255 + 0.5)))

def to_hex(c, force_alpha=False):
    r, g, b, a = c
    out = "#" + "".join(f"{q8(x):02x}" for x in (r, g, b))
    if force_alpha or q8(a) != 255:
        out += f"{q8(a):02x}"
    return out

def with_alpha_factor(c, f):
    """color-mix(in oklab, C f, transparent) == C's rgb with alpha * f."""
    r, g, b, a = c
    return (r, g, b, a * f)

def with_alpha(c, a8):
    r, g, b, _ = c
    return (r, g, b, a8 / 255)

def over(fg, bg):
    """Porter-Duff source-over, straight alpha in/out."""
    fr, fg_, fb, fa = fg
    br, bg_, bb, ba = bg
    oa = fa + ba * (1 - fa)
    if oa == 0:
        return (0.0, 0.0, 0.0, 0.0)
    ch = lambda f, b: (f * fa + b * ba * (1 - fa)) / oa
    return (ch(fr, br), ch(fg_, bg_), ch(fb, bb), oa)

def srgb_to_lin(v):
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4

def lin_to_srgb(v):
    v = max(0.0, min(1.0, v))
    return 12.92 * v if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055

def luminance(c):
    r, g, b = (srgb_to_lin(x) for x in c[:3])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b

def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)

# OKLab (Björn Ottosson's published matrices)
def to_oklab(c):
    r, g, b = (srgb_to_lin(x) for x in c[:3])
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l, m, s = (math.copysign(abs(x) ** (1 / 3), x) for x in (l, m, s))
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)

def from_oklab(L, A, B, alpha=1.0):
    l = (L + 0.3963377774 * A + 0.2158037573 * B) ** 3
    m = (L - 0.1055613458 * A - 0.0638541728 * B) ** 3
    s = (L - 0.0894841775 * A - 1.2914855480 * B) ** 3
    r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return (lin_to_srgb(r), lin_to_srgb(g), lin_to_srgb(b), alpha)

def mix_oklab(c1, c2, p1):
    """color-mix(in oklab, c1 p1, c2) for two opaque colours."""
    a, b = to_oklab(c1), to_oklab(c2)
    return from_oklab(*(x * p1 + y * (1 - p1) for x, y in zip(a, b)))

# ───────────────────────────── tokens ─────────────────────────────
def load_tokens(path=os.path.join(ROOT, "tokens.json"), flavor=FLAVOR):
    t = json.load(open(path, encoding="utf-8"))
    raw = {}
    for group in ("color", "shadow", "opacity", "duration", "easing", "radius", "spacing", "blur"):
        for tok in t[group]["tokens"]:
            v = tok["value"]
            raw[tok["name"]] = v[flavor] if isinstance(v, dict) else v

    def resolve(v, depth=0):
        if depth > 8:
            raise ValueError("alias loop")
        if isinstance(v, str) and v.startswith("{") and v.endswith("}"):
            return resolve(raw[v[1:-1]], depth + 1)
        return v
    return {k: resolve(v) for k, v in raw.items()}

GLASS_DESKTOP_ALPHA8 = 0xF7          # DP1: no backdrop blur -> raise glass-fill-strong alpha

def derive(tok):
    """NORMATIVE derived desktop tokens (docs/enhalation-desktop.md §2)."""
    C = lambda n: parse_hex(tok[n])
    glass = with_alpha(C("glass-fill-strong"), GLASS_DESKTOP_ALPHA8)
    tint = with_alpha_factor(C("glass-edge"), 0.18)
    d = {
        "glass-desktop":   glass,
        "tint":            tint,
        "tint-end":        with_alpha(C("glass-edge"), 0),          # same rgb, alpha 0 (no dark fringe)
        "tint-over-glass": over(tint, glass),                      # rofi gradient stop 0
        "rim":             with_alpha_factor(C("line"), 0.55),
        "pill":            with_alpha_factor(C("ink"), 0.09),
        "pill-hover":      with_alpha_factor(C("ink"), 0.13),
        "pill-top":        with_alpha_factor(C("glass-edge"), 0.70),
        "cell":            with_alpha_factor(C("ink"), 0.04),
        "cell-top":        with_alpha_factor(C("glass-edge"), 0.50),
        "well":            C("glass-shade"),
        "thumb-hi":        mix_oklab(C("thumb"), (1, 1, 1, 1), 0.70),
        "on-halo-hi":      mix_oklab(C("on-halo"), (1, 1, 1, 1), 0.70),
        "thumb-shadow":    with_alpha_factor(C("on-halo"), 0.35),
        "danger-rim":      with_alpha_factor(C("danger"), 0.40),
    }
    out = {k: to_hex(v) for k, v in d.items()}
    out["tint-end"] = to_hex(d["tint-end"], force_alpha=True)
    out["well-shadow"] = f"inset 0 1px 2px {tok['glass-shade']}"
    out["core-gradient"] = f"linear-gradient(115deg, {tok['halo-1']}, {tok['halo-2']})"
    return out

# ───────────────────────────── contrast gate ─────────────────────────────
TEXTS = ("ink", "ink-muted", "accent", "spark", "danger", "on-halo")
BACKDROPS = {"white": (1.0, 1.0, 1.0, 1.0), "crust": None}   # crust filled in from tokens

# (surface, text) pairs the templates USE. Each must reach its minimum on both backdrops.
REQUIRED = [
    ("glass", "ink", 4.5), ("glass", "ink-muted", 4.5), ("glass", "accent", 4.5),
    ("glass", "spark", 4.5), ("glass", "danger", 4.5),
    ("pill", "ink", 4.5), ("pill", "ink-muted", 4.5), ("pill", "accent", 4.5),
    ("pill", "spark", 4.5), ("pill", "danger", 4.5),
    ("cell", "ink", 4.5), ("cell", "ink-muted", 4.5), ("cell", "accent", 4.5),
    ("cell", "danger", 4.5),
    ("well", "ink", 4.5), ("well", "ink-muted", 4.5), ("well", "accent", 4.5),
    ("danger-soft", "ink", 4.5), ("danger-soft", "ink-muted", 4.5), ("danger-soft", "danger", 4.5),
    ("halo-1", "on-halo", 4.5), ("halo-2", "on-halo", 4.5),
    # non-text marks (WCAG 1.4.11): the field baseline against its well, the thumbs
    ("well", "line-strong", 3.0), ("well", "thumb", 3.0), ("well", "accent", 3.0),
]
# Pairs that FAIL and therefore must never appear in a template (§3.4).
FORBIDDEN = [("pill-in-cell", "ink-muted"), ("pill-in-cell", "danger")]

def surfaces(tok, der, backdrop):
    C = lambda n: parse_hex(tok[n])
    D = lambda n: parse_hex(der[n])
    glass = over(D("tint"), over(D("glass-desktop"), backdrop))   # worst case: tint at its peak
    cell = over(D("cell"), glass)
    return {
        "glass": glass,
        "pill": over(D("pill"), glass),
        "cell": cell,
        "pill-in-cell": over(D("pill"), cell),
        "well": over(D("well"), glass),
        "danger-soft": over(C("danger-soft"), glass),
        "halo-1": C("halo-1"),
        "halo-2": C("halo-2"),
    }

def contrast_table(tok, der):
    rows, ok = [], True
    backdrops = dict(BACKDROPS, crust=parse_hex(tok["ground-deep"]))
    fg = {n: parse_hex(tok[n]) for n in TEXTS + ("line-strong", "thumb")}
    for bname, bd in backdrops.items():
        S = surfaces(tok, der, bd)
        for (s, t, need) in REQUIRED:
            r = contrast(fg[t], S[s])
            good = r >= need
            ok &= good
            rows.append((bname, s, to_hex(S[s]), t, round(r, 2), need, "ok" if good else "FAIL"))
        for (s, t) in FORBIDDEN:
            r = contrast(fg[t], S[s])
            rows.append((bname, s, to_hex(S[s]), t, round(r, 2), 4.5, "forbidden"))
    return rows, ok

# ───────────────────────────── grain baking ─────────────────────────────
def read_pgm(path=os.path.join(ROOT, "grain-220.pgm")):
    data = open(path, "rb").read()
    parts, i = [], 0
    while len(parts) < 4:                               # magic, w, h, maxval
        while data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            while data[i:i + 1] not in (b"\n", b""):
                i += 1
            continue
        j = i
        while not data[j:j + 1].isspace():
            j += 1
        parts.append(data[i:j]); i = j
    i += 1                                              # single whitespace before raster
    if parts[0] != b"P5" or int(parts[3]) != 255:
        raise ValueError("grain tile must be 8-bit binary PGM (P5)")
    w, h = int(parts[1]), int(parts[2])
    px = data[i:i + w * h]
    if len(px) != w * h:
        raise ValueError("truncated PGM")
    return w, h, px

def overlay(b, s):
    """W3C Compositing 1, mix-blend-mode: overlay == hard-light with layers swapped."""
    return 2 * b * s if b <= 0.5 else 1 - 2 * (1 - b) * (1 - s)

def blend_over(backdrop, src_grey, src_alpha):
    """Grain layer (grey, opacity src_alpha, mix-blend-mode: overlay) composited on backdrop.
    W3C Compositing 1 §5.8: Cs' = (1 - ab)*Cs + ab*B(Cb, Cs); then source-over."""
    br, bg, bb, ba = backdrop
    out = []
    for cb in (br, bg, bb):
        cs = (1 - ba) * src_grey + ba * overlay(cb, src_grey)
        out.append(cs)
    return over((out[0], out[1], out[2], src_alpha), backdrop)

def css_linear_gradient(w, h, angle_deg, stops):
    """Evaluate a CSS linear-gradient at pixel centres (sRGB interpolation, opaque stops)."""
    th = math.radians(angle_deg)
    dx, dy = math.sin(th), -math.cos(th)
    length = abs(w * dx) + abs(h * dy)
    def at(x, y):
        t = ((x + 0.5 - w / 2) * dx + (y + 0.5 - h / 2) * dy) / length + 0.5
        t = max(0.0, min(1.0, t))
        for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
            if t <= p1:
                f = 0 if p1 == p0 else (t - p0) / (p1 - p0)
                return tuple(a + (b - a) * f for a, b in zip(c0, c1))
        return stops[-1][1]
    return at

SWITCH_W, SWITCH_H = 56, 32           # Enhalation switch geometry (bundle.css .enh-switch)
GLASS_TILE = 220                      # .enh-glass__grain background-size: 220px (1:1)
SWITCH_GRAIN_SIZE = 160               # .enh-switch__fill::after background-size: 160px

def bake(tok, der):
    tw, th, tile = read_pgm()
    grey = lambda tx, ty: tile[(ty % th) * tw + (tx % tw)] / 255
    images = {}

    # 1) glass-grain.png — repeatable 220x220 tile: glass-desktop + grain-strength-soft
    base = parse_hex(der["glass-desktop"])
    s = float(tok["grain-strength-soft"])
    buf = bytearray()
    for y in range(GLASS_TILE):
        for x in range(GLASS_TILE):
            buf += bytes(q8(v) for v in blend_over(base, grey(x, y), s))
    images["glass-grain.png"] = (GLASS_TILE, GLASS_TILE, bytes(buf))

    # 2) switch-on.png — 56x32: core fill (115deg halo-1 -> halo-2) + grain-strength, tile at 160px
    grad = css_linear_gradient(SWITCH_W, SWITCH_H, 115,
                               [(0.0, parse_hex(tok["halo-1"])), (1.0, parse_hex(tok["halo-2"]))])
    s = float(tok["grain-strength"])
    k = tw / SWITCH_GRAIN_SIZE                          # nearest-neighbour sample of the scaled tile
    buf = bytearray()
    for y in range(SWITCH_H):
        for x in range(SWITCH_W):
            n = grey(int(x * k), int(y * k))
            buf += bytes(q8(v) for v in blend_over(grad(x, y), n, s))
    images["switch-on.png"] = (SWITCH_W, SWITCH_H, bytes(buf))
    return images

def png_bytes(w, h, rgba):
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + rgba[y * w * 4:(y + 1) * w * 4] for y in range(h))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))

def digest(images):
    out = {}
    for name, (w, h, rgba) in images.items():
        n = w * h
        mean = [round(sum(rgba[i::4]) / n, 2) for i in range(4)]
        out[name] = {"size": [w, h], "raw_rgba_sha256": hashlib.sha256(rgba).hexdigest(), "mean_rgba": mean}
    return out

# ───────────────────────────── main ─────────────────────────────
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--derived", action="store_true")
    ap.add_argument("--contrast", action="store_true")
    ap.add_argument("--bake", metavar="OUTDIR")
    ap.add_argument("--digest", action="store_true")
    a = ap.parse_args()
    tok = load_tokens()
    der = derive(tok)
    rc = 0
    if a.derived:
        print(json.dumps(der, indent=2))
    if a.contrast:
        rows, ok = contrast_table(tok, der)
        print(f"{'backdrop':8} {'surface':13} {'composite':9}  {'text':11} {'ratio':>6} {'min':>4}  result")
        for r in rows:
            print(f"{r[0]:8} {r[1]:13} {r[2]:9}  {r[3]:11} {r[4]:6.2f} {r[5]:4}  {r[6]}")
        print("contrast gate:", "PASS" if ok else "FAIL")
        rc |= 0 if ok else 1
    if a.bake or a.digest:
        imgs = bake(tok, der)
        if a.bake:
            os.makedirs(a.bake, exist_ok=True)
            for name, (w, h, rgba) in imgs.items():
                open(os.path.join(a.bake, name), "wb").write(png_bytes(w, h, rgba))
        print(json.dumps(digest(imgs), indent=2))
    if not (a.derived or a.contrast or a.bake or a.digest):
        ap.print_help()
    return rc

if __name__ == "__main__":
    sys.exit(main())
