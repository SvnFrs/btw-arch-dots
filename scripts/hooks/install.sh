#!/usr/bin/env bash
# Point git at the hooks kept in this repo, so they are versioned like everything else.
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
chmod +x "$REPO/scripts/hooks/pre-commit"
git -C "$REPO" config core.hooksPath scripts/hooks
echo "core.hooksPath -> scripts/hooks"
echo "pre-commit will now check drift, keybinding docs, and shell syntax."
