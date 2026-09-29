# Enhalation — vendored source

Enhalation is Tyler's (@SvnFrs) design system, built on Catppuccin Mocha/Latte.
Source: https://claude.ai/artifact/YQeQn8cAmhCQjManUjFxTn (private artifact) · vendored 2026-09-29.

| File | Origin | Edit? |
|---|---|---|
| `tokens.json` | the design system's `tokens.json`, byte-for-byte | never by hand; replace wholesale to update |
| `grain.svg` | the design system's `assets/Textures/grain.svg` (feTurbulence .85, 3 octaves, stitched) | never |
| `grain-220.pgm` | `grain.svg` rasterized at 220×220, device scale 1, Chromium (Playwright), converted to 8-bit grey. The SVG's colour matrix makes R=G=B, so grey is lossless. Mean 180.74, σ 45.06 | regenerate only if `grain.svg` changes |
| `enhalation_ref.py` | colour math, desktop-derived tokens, contrast gate, grain baking (stdlib) | yes — it is the implementation `scripts/gen-theme.py` imports |

The desktop mapping (what the tokens become in rofi and swaync, and where it deviates from the web
components) is `docs/enhalation-desktop.md`.

To refresh after the design system changes: replace `tokens.json`, run
`python3 theme/enhalation/enhalation_ref.py --contrast` (must PASS), then `./scripts/gen-theme.py`.
