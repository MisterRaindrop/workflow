#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WK_BIN="$SCRIPT_DIR/wk"
TARGET_DIR="${1:-$HOME/.local/bin}"

# Ensure target dir exists and is in PATH
mkdir -p "$TARGET_DIR"
if [[ ":$PATH:" != *":$TARGET_DIR:"* ]]; then
    echo "warn: $TARGET_DIR is not in PATH"
    echo "  add to your shell rc: export PATH=\"$TARGET_DIR:\$PATH\""
fi

# Symlink
ln -sf "$WK_BIN" "$TARGET_DIR/wk"
echo "=> installed: $TARGET_DIR/wk -> $WK_BIN"

# Shell integration (optional auto-cd after wk new)
cat <<'SHELL_FUNC'

# Optional: add this to your .bashrc or .zshrc for auto-cd on `wk new`:
wk() {
    if [[ "${1:-}" == "new" ]]; then
        local output
        output="$(WK_SHELL_INTEGRATION=1 command wk "$@")"
        echo "$output" | grep -v '^__wk_cd:' || true
        local cd_path
        cd_path="$(echo "$output" | grep '^__wk_cd:' | cut -d: -f2-)"
        [[ -n "$cd_path" ]] && cd "$cd_path"
    else
        command wk "$@"
    fi
}
SHELL_FUNC
