# Clipboard panel — cliphist in Quickshell

**Status:** Built, K0–K4 (2026-09-30) · **Date:** 2026-09-29 · **Owner:** Tyler (@SvnFrs)
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
| `list` | *(K0 corrections)* `cliphist -preview-width 400 list` → `{items: [{id, kind: text\|image, preview, hint?, color?, fmt?, w?, h?, size?}]}`, newest first. Image metadata is parsed from the preview line only; **`list` decodes nothing** and creates no files. Thumbs whose id is gone are pruned. |
| `thumb <id>` | *(K0 corrections)* decode, downscale with ffmpeg to fit 168×96 (2× the 84×48 row thumb, never upscaled), cache as `clip/thumb-<id>.png` in `$XDG_RUNTIME_DIR/enhalation/` (dir mode 0700) |
| `preview <id>` | *(K0 corrections)* decode an image full-size into **one** file, `clip/preview.<fmt>`, replaced each time |
| `text <id> [max=20000]` | full text for the preview, truncated at `max` chars, with `truncated: true` if it was, plus `lines` and `chars` of the whole clip |
| `copy <id>` | `cliphist decode <id> \| wl-copy` (image MIME as today's `clip` does it; VERIFIED at K0: no `-t` needed). **Refuses an empty id.** |
| `delete <id>` | stash the decoded bytes in `…/clip/undo.bin` + `undo.json`, then delete exactly that entry (the `id\tpreview` line from `list`, piped to `cliphist delete`) |
| `undo` | `cliphist store < undo.bin`, then remove the stash. The entry comes back at the top — VERIFIED at K0, **with a new id**, so the panel re-lists after `undo` and never reuses the old id |
| `wipe` | `cliphist wipe`, then clear the whole `clip/` dir (thumbs, preview, undo stash). Pins survive |
| `pins`, `pin <id>`, `unpin <n>`, `copy-pin <n>` | pins (below) |

**(K0 corrections, 2026-09-30)** — from the K0 numbers, by Tyler:

1. **Thumbnails, not full-size decodes.** The real db is 243 MB, and `$XDG_RUNTIME_DIR` is RAM-backed
   tmpfs, so decoding every image full-size there is out.
   - `clipctl thumb <id>` decodes one image and downscales it with ffmpeg to fit 168×96 (2× the
     84×48 row thumb), cached as `clip/thumb-<id>.png`.
   - The panel requests thumbs lazily, only for delegates that are created or visible, and
     asynchronously.
   - `list` returns image metadata parsed from the preview line only; it decodes nothing.
   - The preview pane decodes full-size on hover into ONE file (`clip/preview.<fmt>`, replaced each
     time), debounced about 120 ms.
   - Thumbs whose id is gone are pruned, and `wipe` clears the whole dir.
2. **`list` cannot know lines or chars**: previews flatten newlines and cut at the preview width.
   - Row glyphs come from the preview only: URL, hex colour swatch, else plain text.
   - "N lines · M chars" and the multi-line glyph appear in the preview meta only, from
     `clipctl text <id>` on hover.
   - `lines`/`chars` are dropped from `list`'s JSON.
3. **Search depth**: `list` runs `cliphist -preview-width 400 list`, so search matches 400 chars.
   Rows still ellipsize. **Anything past 400 chars is not searchable.**

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
- *(Tyler, 2026-09-30)* **A second press hides the panel.** `clip_panel` calls the IPC function
  `toggle` (the rule 4 routing is otherwise unchanged); `open` stays idempotent for the swaync
  button.
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

Kind glyphs are a heuristic; when in doubt use plain text. *(K0 corrections)* Rows decide from the
400-char preview only (`hint` in `list`); the multi-line glyph is for the preview meta, from
`clipctl text`:

| Clip | Glyph |
|---|---|
| URL | U+F0C1 |
| `#rgb` / `#rrggbb` / `#rrggbbaa` | a 14 px swatch of that colour instead of a glyph |
| multi-line (preview meta only) | U+F121 |
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
- Meta line: glyph + "Text"/"Image" (Demi Bold 13, `ink`) + `4 lines · 162 chars` (from
  `clipctl text` on hover) or `png · 3440×1440 · 184 KiB` (from `list`) (caption, `ink-muted`).
- Image: *(K0 corrections)* `clipctl preview <id>` on hover, debounced ~120 ms.
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
  **K1 record (2026-09-30).** `home/.config/quickshell/enhalation/bin/clipctl` (python3 stdlib, plus the
  `cliphist`, `wl-copy` and `ffmpeg` binaries) and `scripts/test-clipctl.py`: **23 tests, all pass**, none
  skipped. The suite runs in one throwaway state: `CLIPHIST_DB_PATH`, a private `XDG_RUNTIME_DIR` (the
  cache) and `XDG_DATA_HOME` (pins), plus a private headless Wayfire whose socket lives in that runtime
  dir, so the copy tests never reach the real clipboard or its watcher. At the end it asserts that the
  real db's size and mtime, and the absence of the real cache and pins dirs, are unchanged.
  - Covered: list (kinds, hints, QML colours, newest first, no `lines`/`chars`), **`list` decodes
    nothing** (no cache dir, and no new files once one exists), 400-char search depth, **a 3440×1440
    PNG's thumb fits 168×96** (168×70) and is cached, small images are never upscaled, tall images, pruning of
    gone ids, one `preview.<fmt>` file, text truncation and line/char counts, `copy` refusing `""`,
    `" "`, `abc`, `12a`, `-1` and a missing id (the clipboard stays unchanged), copy of text and image
    (`image/png`, identical bytes, and it returns promptly), delete and undo (exactly one entry; it
    comes back on top under a new id), pins (order, 0600/0700 modes, no duplicates, at most 20, they
    survive `wipe` and the loss of their entry, `pin:<n>` refs), a damaged pins index that cannot
    escape the pins dir, `wipe` clearing the whole `clip/` dir, and JSON-only errors.
  - Choices, for review:
    - `list` prints `{"items": [...]}` (the "one JSON object" rule) rather than a bare array.
    - Rows get a `hint` of `url`, `color` or `text`. `color` is converted to QML's `#aarrggbb`,
      because CSS `#rrggbbaa` would read wrong in QML.
    - `text`, `thumb` and `preview` also take `pin:<n>`, and a pin's preview is its own file.
    - A db that was never created (cliphist: "please store something first") lists as empty.
    - `wl-copy` runs with stdout and stderr on `/dev/null`: its forked child would otherwise hold
      clipctl's pipes until the next copy.
    - `delete` pipes `<id>\t<preview>` (cliphist 0.7.0 needs only the id; K1 probe).
  - Found: a preview collapses each whitespace run to one space, and a 400-wide preview is
    400 chars + `…`. Non-image binary is previewed as text (only a decodable image gets
    `[[ binary data … ]]`).
  - Measured on a synthetic 750-entry db (50 images at 3440×1440, 41 MB): `list` about 36 ms (255 KiB
    of JSON), a cold `thumb` 172 ms, a cached one 34 ms, `preview` 36 ms, `text` 35 ms.
  - Peak memory (`/usr/bin/time`): `list` 19 MB, `preview` 18 MB. A cold `thumb` is ffmpeg decoding
    the full frame: 116 MB by default, **77 MB with `-filter_threads 1`** (same pixels, same time),
    which `thumb` now uses. `-threads 1` alone changes nothing. **For K2:** the panel runs at most
    **two** thumb jobs at a time (about 155 MB of transient peak), queueing the rest, so a screen of
    image rows never starts eight decodes at once.
- **K2:** `ClipPanel.qml`, read-only: list, filter, search, preview, the gliding pill, empty and
  error states. Screenshots next to the preview.
  **K2 record (2026-09-30).** `ClipPanel.qml` (one overlay window per screen, active on the focused
  output; IPC target `clip`: `ping`, `open`, `close`, plus test hooks `search`, `pick`, `select`, `scroll`
  and `state`, which reports keys, kinds and counts, never clip text). `shell.qml` loads it. Segmented
  gained optional per-option counts and glyph-less options. Theme gained `lineStrong`, the chip size
  and the clipboard glyphs. The chip is `core-chip.png`, 136×46, from the same `bake_core` as the
  shutter (raw-RGBA sha256 `032d9be8d5498506ab11c9f31df1dca4bd7cf0500b07997b31daa38b68ff00b6`).
  - **Privacy.** Every on-screen check and screenshot ran on the **synthetic** history (the bench
    generator's 750 entries, curated text/URL/#hex/multi-line/long clips on top, 2 pins in a private
    `XDG_DATA_HOME` with the fonts linked in). Quickshell was then restarted normally, and `rec ping`
    answered. The real db's size and mtime and the real clipboard's type and content hashes were unchanged, so nothing was
    copied. The synthetic thumbs in `$XDG_RUNTIME_DIR/enhalation/clip` were removed afterwards
    (their ids could collide with real ones). The screenshots were deleted after the check.
  - **Latency**, from the start of `qs ipc call clip open` to the panel mapped: **104 ms** on the first
    open after a start, **51–55 ms** after that (including the ~20 ms `qs` CLI; `list`, `pins` and the
    focused-output probe run in parallel, and the window maps as soon as the output is known).
  - `clipctl list` runs on **every** open (`listRuns` 3 after 3 opens).
  - **Thumbs:** never more than **2** in flight. They are queued only for delegates that exist (the
    `cacheBuffer` is two image rows): the first screen of Images started 10 jobs for 53 images.
    Scrolling to the end and filtering away at once dropped 6 queued jobs (14 over two full rounds).
  - **Preview:** debounced 120 ms. A late result for a row no longer selected is dropped (counted at
    0.12–0.14 s gaps), and in every case the preview shown matched the selection.
  - **Closing:** `clip close` and **focus loss** (the capture overlay opening over the panel) close it,
    and the panel refuses to open while the capture overlay is up. Esc and click-outside need real
    input, so they are in Tyler's mouse test. No K2 code path writes the clipboard.
  - **Ligatures off, VERIFIED on screen:** the row `a >= b -> c != d === e <= f |> g` and the preview
    render literally, where Cartograph otherwise draws `≥ → ≠ ≡` (K0). The preview's 13.5 px is
    `pointSize: 10.125`, because `pixelSize` is an int and Qt uses 96 dpi at scale 1.0.
  - **Clip text is PlainText everywhere:** `<b>not bold</b> &amp;` renders literally.
  - States: "Nothing copied yet" (no history, no pins); pins still show over an empty history;
    "No clips match"; a search past 400 chars finds nothing; and a broken db shows "cliphist didn't
    answer — see the log" + "Open log". Its line goes to the actions log, with no contents.
  - A clean log (0 warnings) after two rounds of open, filter, scroll, search and close, once the
    cascade delay was clamped (`index` is -1 while a row is removed).
  - Choices, for review:
    - The filter counts count the search hits.
    - Section labels only when both Pinned and Recent are present.
    - The footer reads "Read-only for now · ↑/↓ move · Esc closes" until K3 brings the actions; Clear
      all is drawn but inert, the row buttons come with K3, and a click only selects.
    - The focused output comes from one python-wayfire call per open.
- **K3:** actions (copy, delete+undo, pin, armed Clear all, keys). `actions.sh clip`/`clip-del`
  routing with the rofi fallback; test that fallback with the panel stopped.
  **K3 record (2026-09-30).** Tyler's K3 safety rules, as built and tested:
  - **Actions:**
    - A click or Enter copies (`copy` / `copy-pin`), then the panel closes.
    - Delete (the row button, or the Delete key when nothing is ahead of the caret) removes the row
      (180 ms fade, the list closes the gap). The footer shows `Deleted “…”` + a glass Undo for 6 s.
    - Pin and unpin (the row button, Ctrl+P).
    - Clear all arms for 3 s as "Clear N clips?" on `danger-soft` + `danger-rim`; a second click
      wipes. Pins survive.
    - Hover or keyboard selection shows the two 30 px glass buttons. Pinned rows get only the pin
      button: a pin is removed by unpinning it.
    - Errors show a 6 s footer notice and write a line to the actions log. Neither ever quotes clip text.
    - The footer is now the spec's.
  - **Rule 1, no copy leaks.** The on-screen run put a `wl-copy` stub first on the panel's `PATH`. It
    was called 3 times with exactly the expected sizes (text 32 B, image 464,942 B, pin 48 B, no MIME
    args), and the panel closed after each. Open + close and focus loss added no calls. The real
    copy path is K1's headless-Wayfire tests (copy unchanged).
  - **Rule 2, the destructive guard.** `clipctl whereami` → `{db, data_home, runtime}`. The db is
    what `cliphist version` reports (it prints to stderr). The panel loads it at start into
    `state().where`. Before every delete, undo, pin, unpin and wipe, the test checked all three
    against the synthetic paths. The first run aborted at the guard: the harness could not reach
    the panel, because `qs` matches instances by display and the synthetic one ran with an
    absolute `WAYLAND_DISPLAY`. That was fixed in the harness. No destructive step ever ran against
    anything else.
  - **Rule 3, deleted means gone** (synthetic, VERIFIED):
    - `delete` removed the thumb and the preview it owned (`preview.ref` names the owner); another
      clip's preview stays.
    - The stash (`undo.bin`/`undo.json`) goes when the 6 s window ends (`clipctl forget`), when the
      panel closes inside the window, and on wipe (the whole `clip/` dir).
    - These are plain unlinks. The K1 suite now has **27 tests**, all passing.
  - **Rule 4, routing.** `actions.sh clip` and `clip-del` → `clip_panel`: `qs_call clip ping`, then
    `qs_call clip open`. VERIFIED three ways:
    - the panel answers → it opens, and rofi is not called;
    - ping answers but `open` fails (stubbed) → notify, no rofi;
    - the panel stopped → rofi runs for both verbs (a fake rofi on the synthetic db).
  - **Rule 5.** Undo re-lists: the clip returned on top as id 751 (it was 748). Clear all disarmed
    after 3 s; two clicks wiped 748 clips, and both pins survived.
  - **Isolation.** The synthetic panel also had a **private runtime dir**. Tyler's real
    `$XDG_RUNTIME_DIR/enhalation/clip` exists now (from the K2 mouse test): synthetic thumbs would
    collide with real ids, and the wipe test would have removed it. Afterwards the real db, the
    real cache listing (names + mtimes) and the real clipboard hashes were unchanged, and only the
    normal Quickshell was left running.
  - Choices, for review:
    - Pinned rows have no delete button, and Delete on one unpins.
    - Delete acts only when nothing is ahead of the caret, so it still edits a search mid-text.
    - After an undo, the selection returns to the top.
    - Clear all dims when the history is empty.
- **K4:** motion tuning, the swaync button (with capture-ui C4), and `CLAUDE.md`: the pins
  location, the thumb cache, and the `actions.sh` routing.

  **K4 record (2026-09-30).**
  - **Motion**, checked against §2 and its tokens:
    - open 280 ms ease-out-expo, scale .97 → 1 + fade;
    - the first 8 rows cascade in, 24 ms apart;
    - close 150 ms ease-exit;
    - the pill glides in 420 ms ease-spring.
  - **Delete fixed:** before, the removed row faded while the rows below slid over it. Now it
    **collapses**: height + opacity, 180 ms ease-out-expo. `ListView.delayRemove` holds its slot
    until then, so the rows below follow its height up, and the row clips its content only while
    collapsing. VERIFIED by grabs mid-delete: the row at half height and faded, the next row
    following, nothing overlapping.
  - **The swaync Clipboard button** (U+F0EA) joins Screenshot and Record, three to a row. Its command
    is `setsid -f bash ~/.config/swaync/actions.sh clip open`: it closes the control centre, then
    calls the idempotent IPC `open` (the button never toggles; the keys use `toggle`). The rofi
    fallback is unchanged. VERIFIED by running the command as swaync does (`/bin/sh -c "<command>"`)
    against a synthetic panel: the control centre closed, the panel opened, and a second run left it
    open. The three glass pills fit one row.
  - **`CLAUDE.md`:** the routing, the pins location (plaintext on disk, like cliphist's db), the
    cache's contents and lifetimes, and the testing rules (synthetic Quickshell, `wl-copy` stub,
    the `whereami` guard).

## 5. Later

- Auto-paste into the focused window after a copy (`wtype -M ctrl v`). Opt-in only; it types into
  whatever has focus.
- Treat password-manager clips as sensitive: skip them in `list` if cliphist can tell.
