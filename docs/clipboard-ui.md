# Clipboard panel — cliphist in Quickshell

**Status:** Proposed · **Date:** 2026-09-29 · **Owner:** Tyler (@SvnFrs)
**Depends on:** `docs/enhalation-desktop.md` (tokens, desktop profile, §3.4 pairing rules) and
`docs/capture-ui.md` (the `enhalation` Quickshell config, `Theme.qml`, `GlassPanel.qml`).
**Visual target:** `docs/clipboard-ui-preview.png` (a browser mock; the clip data is invented).

The NORMATIVE sections are the contract. Tool claims carry VERIFIED (how) or INFERRED (from what).
Every INFERRED claim is checked at K0.

## 0. Why

The rofi picker (`actions.sh clip` / `clip-del`) works, but:

- Images show as `[[ binary data 184 KiB png 3440x1440 ]]`.
- Deleting needs a separate mode and key.
- The hover pill can only jump, because rofi has no animation.

With Quickshell already running for the capture UI, the clipboard becomes a panel in the same
process:

- a list with thumbnails and a large preview;
- pin and delete on hover;
- search and a type filter;
- a hover pill that glides.

What does not change:

- **cliphist** stays the store. Watching the clipboard is still `wl-paste --watch cliphist store`
  in `[autostart]`.
- **Selecting nothing never touches the clipboard.** This is today's Esc guard: "never pipe an
  empty selection into wl-copy".
- **The rofi picker stays as the fallback** whenever the panel does not answer `ping`. That is why
  Enhalation I2 still themes `clipboard.rasi` / `clipboard-delete.rasi`.

## 1. Architecture — NORMATIVE

### Files

```
home/.config/quickshell/enhalation/
  ClipPanel.qml          the panel, loaded by shell.qml, IpcHandler target "clip" (ping, open, close)
  bin/clipctl            python3 stdlib helper, the only thing that runs cliphist / wl-copy for the panel
```

### `clipctl` verbs

Each verb prints one JSON object. Every error is `{"error": "…"}` plus a non-zero exit.

| Verb | Does |
|---|---|
| `list` | `cliphist list` → `[{id, kind: text\|image, preview, lines?, chars?, fmt?, w?, h?, size?, thumb?}]`, newest first. Images are decoded once to `$XDG_RUNTIME_DIR/enhalation/clip/<id>.<fmt>` (dir mode 0700); `thumb` is that path. Cache files whose id is gone are pruned. |
| `text <id> [max=20000]` | full text for the preview, truncated at `max` chars, with `truncated: true` if it was |
| `copy <id>` | `cliphist decode <id> \| wl-copy` (image MIME as today's `clip` does it; VERIFIED at K0: no `-t` needed). **Refuses an empty id.** |
| `delete <id>` | stash the decoded bytes in `…/clip/undo.bin` + `undo.json`, then delete exactly that entry (the `id\tpreview` line from `list`, piped to `cliphist delete`) |
| `undo` | `cliphist store < undo.bin`, then remove the stash. The entry comes back at the top — VERIFIED at K0, **with a new id**, so the panel re-lists after `undo` and never reuses the old id |
| `wipe` | `cliphist wipe`, then clear the thumb cache. Pins survive |
| `pins`, `pin <id>`, `unpin <n>`, `copy-pin <n>` | pins (below) |

### Pins

cliphist has no pins, so they live in `$XDG_DATA_HOME/enhalation/clip-pins/`:

- `index.json` holds the order, kind and preview; `<n>.txt` or `<n>.<fmt>` holds the bytes;
- at most 20;
- `pin` decodes from cliphist, so a pin survives cliphist's `max-items` rotation and `wipe`.

Pins are plaintext on disk, the same as cliphist's own db. That goes in `CLAUDE.md`.

### Entry points

- `actions.sh clip` and `clip-del` → `qs -c enhalation ipc call clip open`. If that fails, both run
  today's rofi paths unchanged.
- Super+V and Super+Shift+V keep their bindings, so the wayfire.ini diff is none.
- Mouse: a "Clipboard" button (U+F0EA) joins the capture buttons in the swaync control centre
  (capture-ui C4).

### Window

- One full-screen transparent overlay surface on the focused output, with exclusive keyboard focus
  while open.
- Clicking outside the panel closes it, like rofi's click-to-exit. There is no scrim.
- It is closed at open time if the capture overlay is up.

### Testing

Tests use a **throwaway db**: cliphist's `-db-path` / `CLIPHIST_DB_PATH` (VERIFIED, cliphist
README), filled with synthetic entries. Do not touch Tyler's history.

**Never print real clipboard contents** in logs, reports or screenshots. Report counts, kinds and
lengths only.

## 2. Design — NORMATIVE

### Panel

- 1040 × 620, centred.
- Glass surface (GlassPanel: fill, sheen, grain, rim, `glass-float`), radius 26, padding 16,
  gap 12.

### Header

| Part | Spec |
|---|---|
| Chip | **The warm core**, the view's one moment, same as the rofi pickers: U+F0EA + "clipboard", Bold Italic, `on-halo`, radius 10, height 46 |
| Search | `well`, radius 10, 2 px `line-strong` baseline, U+F002 in `ink-muted`, accent caret, placeholder "ssh, https://, #hex…". Focused on open; typing anywhere goes here |
| Filter | glass-native segmented (well track, `pill` + `pill-top` thumb gliding 420 ms spring): All · Text · Images (U+F03E), each with a count in `ink-muted` 12 px |
| Clear all | ghost button, U+F1F8 in `danger`, word `ink-muted`. Two clicks: the first arms it for 3 s as "Clear 86 clips?" on `danger-soft` + `danger-rim`. Pins survive |

### List

- The left column is 430 wide.
- Section labels "Pinned" / "Recent": caption, `ink-muted`.
- Rows: min height 42, radius 10, padding 0 10 0 12, glyph column 18 px `ink-muted`, one line,
  ellipsized.
- Clip text is shown **literally**, with ligatures off. Cartograph has programming ligatures
  (`>=` → `≥` in the mock before they were disabled). In QML use `font.features: {"liga": 0,
  "calt": 0}` (VERIFIED at K0 on Qt 6.11.2; the `renderType`/`preferShaping: false` fallback is not needed).
  The same goes for the preview.

Kind glyphs are a heuristic; when in doubt use plain text:

| Clip | Glyph |
|---|---|
| URL | U+F0C1 |
| `#rgb` / `#rrggbb` / `#rrggbbaa` | a 14 px swatch of that colour instead of a glyph |
| multi-line | U+F121 |
| other | U+F036 |

The mock's terminal glyph is optional.

**Image rows** (min height 66):

- an 84 × 48 thumbnail, radius 7, `inset 0 0 0 1px ink×.10`;
- meta `fmt · W×H · size`, caption `ink-muted`.

**Hover or keyboard selection:**

- **one** `pill` + `pill-top` that glides between rows: 420 ms `ease-spring` via the ListView
  highlight. It replaces, never stacks (§3.4 of the brief).
- The row text goes Demi Bold.
- Two 30 px glass buttons appear at the right end: pin U+F08D (`ink`) and delete U+F1F8 (`danger`
  glyph).
- Pinned rows always show U+F08D in `accent`.

### Preview

- The right column fills the rest.
- Meta line: glyph + "Text"/"Image" (Demi Bold 13, `ink`) + `4 lines · 162 chars` or
  `png · 3440×1440 · 184 KiB` (caption, `ink-muted`).
- Box: `well` + `well-shadow`, radius 14, padding 16.
- Text: 13.5 px mono `ink`, wrapped, scrollable, ligatures off, capped by `clipctl text`, with a
  "truncated" caption when it was.
- Image: fit inside with radius 8, `asynchronous: true`, `sourceSize` bounded to the box.

### Footer

- Caption `ink-muted`: "Click copies · hover for pin and delete · Del deletes · Esc closes" on the
  left, the count on the right.
- After a delete, for 6 s: `Deleted "<preview>"` + a glass "Undo" (U+F0E2).

### Interaction

| Input | Result |
|---|---|
| Click a row | `clipctl copy` (or `copy-pin`), then close (150 ms) |
| Click pin / delete | act on that row only; the panel stays open |
| Keys | type = search, ↑/↓ move, Enter copy, Delete delete, Ctrl+P pin/unpin, Esc close |
| Scroll | the list scrolls; the pill stays on the hovered row |

### Motion

- Open: 280 ms `ease-out-expo`, scale .97 → 1 plus fade. The first 8 rows cascade in, 24 ms apart.
- Close: 150 ms `ease-exit`.
- Delete: the row collapses (height + opacity) over 180 ms `ease-out-expo`, and the list closes
  the gap.

### Empty and error states

- No clips: `well` box, "Nothing copied yet", `ink-muted`.
- `clipctl` error: the same box with "cliphist didn't answer — see the log" and a glass "Open log".

## 3. Contrast

Every pair above is already in the gate:

- text: `ink` / `ink-muted` on glass, pill and well;
- the `danger` glyph on pill (icon, 3:1), the `accent` pin on glass and pill;
- `on-halo` on the warm core.

The armed Clear all uses `danger-soft` text pairs as in capture-ui §4.1. Nothing new is added
to the gate.

## 4. Increments

Each increment ends with its checks, screenshots (synthetic data only), a mouse test plan and a
rollback line.

- **K0 (read-only):**
  - `cliphist version`, and the `list` line format for text and images. Show the format, not the
    contents: take it from a throwaway db holding one synthetic text and one image.
  - Dedupe-on-store behaviour for `undo`.
  - How `wl-copy` sets the image MIME, via `wl-paste --list-types` after a copy from the throwaway db.
  - `font.features` in QML on Qt 6.11.
  **K0 record (2026-09-29).** Synthetic data only, in a throwaway `CLIPHIST_DB_PATH`. The real
  `~/.cache/cliphist/db` had the same size and mtime before and after (stat only, never read).
  - `cliphist` 0.7.0 (`cliphist version` also prints the db path in use, so the throwaway is confirmed).
    `max-dedupe-search 100`, `max-items 750`, `preview-width 100`.
  - `list` lines are `<id>` TAB `<preview>`, newest first. Text: newlines and tabs in the preview
    become single spaces (`1\tsynthetic alpha second line after a tab`). Image:
    `2\t[[ binary data 299 B png 64x48 ]]`, so `fmt`, `W×H` and `size` parse from that line.
    `cliphist decode <id>` takes the id as an argument and returns the stored bytes exactly (the PNG
    compared equal).
  - **Dedupe:** storing bytes that are already there removes the old entry and stores them again on
    top under a **new id** (ids `3 2 1` → `4 3 2`, count unchanged). `delete` then storing again
    (the `undo` path) also returns on top under a new id (`4 2` → `5 4 2`). Inferred from this and
    the `wl-paste --watch` store: a `copy` from the panel moves that clip to the top under a new id
    in the real history, as today's rofi `clip` does.
  - **MIME**, checked in a *private headless Wayfire* (own socket `wayland-2`, no plugins, no Xwayland;
    stopped by its PID after its cmdline was checked), so nothing reached the real clipboard or its
    watcher: `cliphist decode <image> | wl-copy` with no `-t` offers exactly `image/png`, and the pasted
    bytes equal the file; text offers `text/plain`, `text/plain;charset=utf-8`, `TEXT`, `STRING`,
    `UTF8_STRING`.
  - **Ligatures:** `font.features: {"liga": 0, "calt": 0}` works (Qt 6.11.2, `qml` runtime offscreen,
    software backend). By default Cartograph draws `≥ → ≠ ≡`; with the features set it draws the literal
    `>= -> != ===` (10.8% of pixels differ).
- **K1:** `clipctl` + unit-style tests against the throwaway db. Cover list, the thumb cache and
  its pruning, text truncation, copy refusing an empty id, delete+undo round-trip, pins, and wipe
  keeping pins.
- **K2:** `ClipPanel.qml`, read-only: list, filter, search, preview, the gliding pill, empty and
  error states. Screenshots next to the preview.
- **K3:** actions (copy, delete+undo, pin, armed Clear all, keys). `actions.sh clip`/`clip-del`
  routing with the rofi fallback; test that fallback with the panel stopped.
- **K4:** motion tuning, the swaync button (with capture-ui C4), and `CLAUDE.md`: the pins
  location, the thumb cache, and the `actions.sh` routing.

## 5. Later

- Auto-paste into the focused window after a copy (`wtype -M ctrl v`). Opt-in only; it types into
  whatever has focus.
- Treat password-manager clips as sensitive: skip them in `list` if cliphist can tell.
