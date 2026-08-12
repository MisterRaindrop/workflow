#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WK_BIN="$SCRIPT_DIR/wk"

# wk runs on the LXD host, normally as root.
if [[ -n "${1:-}" ]]; then
    TARGET_DIR="$1"
elif [[ "$(id -u)" -eq 0 ]]; then
    TARGET_DIR=/usr/local/bin
else
    TARGET_DIR="$HOME/.local/bin"
fi

mkdir -p "$TARGET_DIR"
ln -sf "$WK_BIN" "$TARGET_DIR/wk"
echo "=> installed: $TARGET_DIR/wk -> $WK_BIN"

if [[ ":$PATH:" != *":$TARGET_DIR:"* ]]; then
    echo "warn: $TARGET_DIR is not in PATH"
    echo "  add to your shell rc: export PATH=\"$TARGET_DIR:\$PATH\""
fi

# Seed the config on first install; never overwrite an existing one.
CONFIG_DIR=/etc/wk
CONFIG_FILE="$CONFIG_DIR/config.env"
if [[ -w "$(dirname "$CONFIG_DIR")" || -w "$CONFIG_DIR" ]] 2>/dev/null; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$CONFIG_DIR"
        cp "$SCRIPT_DIR/config.env.example" "$CONFIG_FILE"
        echo "=> wrote default config: $CONFIG_FILE"
    else
        echo "=> config already present, left alone: $CONFIG_FILE"
    fi
else
    echo "note: cannot write $CONFIG_DIR — copy config.env.example there yourself"
fi

echo ""
echo "Next:"
echo "  wk doctor        # check LXD, proxy egress, memory"
echo "  wk new           # build your first container"
