#!/usr/bin/env bash
# Build and install the minionscode TUI to ~/.local/bin (or $PREFIX/bin if set).
set -euo pipefail

cd "$(dirname "$0")"

PREFIX="${PREFIX:-$HOME/.local}"
DEST="$PREFIX/bin"

echo "→ cargo build --release"
cargo build --release

mkdir -p "$DEST"
install -m 755 target/release/minionscode "$DEST/minionscode"

echo "✓ installed: $DEST/minionscode"
if ! echo ":$PATH:" | grep -q ":$DEST:"; then
  echo
  echo "  note: $DEST is not on your PATH."
  echo "  add this to your shell rc:"
  echo "    export PATH=\"$DEST:\$PATH\""
fi
