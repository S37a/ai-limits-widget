#!/usr/bin/env bash
set -euo pipefail

# ai-limits-widget install script
# Builds the binary and installs a short `ailimits` command.

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_NAME="ai-limits-widget"

# Pick a writable dir that's already in PATH
INSTALL_DIR=""
for d in /opt/homebrew/bin ~/.local/bin /usr/local/bin; do
  if [ -d "$d" ] && [ -w "$d" ]; then INSTALL_DIR="$d"; break; fi
done
if [ -z "$INSTALL_DIR" ]; then
  echo "No writable dir in PATH found. Create ~/.local/bin and add it to PATH." >&2
  exit 1
fi

echo "Building $BIN_NAME..."
swiftc "$DIR/main.swift" -o "$DIR/$BIN_NAME" -framework Foundation

echo "Installing symlink → $INSTALL_DIR/ailimits"
ln -sf "$DIR/$BIN_NAME" "$INSTALL_DIR/ailimits"

echo "Done. Run \`ailimits\` in any terminal."