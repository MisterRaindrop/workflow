#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WK="$SCRIPT_DIR/wk"
PASS=0; FAIL=0

pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s (got: %s)\n" "$1" "$2"; }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then pass "$desc"
    else fail "$desc — expected '$expected'" "$actual"; fi
}

assert_match() {
    local desc="$1" pattern="$2" actual="$3"
    if echo "$actual" | grep -qE "$pattern"; then pass "$desc"
    else fail "$desc — expected match '$pattern'" "$actual"; fi
}

assert_exit() {
    local desc="$1" expected_code="$2"; shift 2
    local actual_code=0
    "$@" >/dev/null 2>&1 || actual_code=$?
    if [[ "$actual_code" -eq "$expected_code" ]]; then pass "$desc"
    else fail "$desc — expected exit $expected_code" "exit $actual_code"; fi
}

# --- Source helper functions from wk ---
# We extract just the functions we need without triggering the main dispatch
extract_helpers() {
    local tmpfile
    tmpfile="$(mktemp)"
    # Extract everything up to "# --- Main dispatch ---" (all functions)
    sed -n '1,/^# --- Main dispatch ---/p' "$WK" > "$tmpfile"
    # Remove set -euo pipefail and the require_repo call from yaml_get
    sed -i.bak 's/^set -euo pipefail//' "$tmpfile"
    # Stub out require_repo and die for testing
    cat >> "$tmpfile" <<'STUBS'
REPO_ROOT="/tmp/test-repo"
die() { echo "ERROR: $*" >&2; return 1; }
warn() { echo "WARN: $*" >&2; }
info() { echo "INFO: $*" >&2; }
STUBS
    echo "$tmpfile"
}

HELPER_FILE="$(extract_helpers)"
# shellcheck disable=SC1090
source "$HELPER_FILE"

# =============================================
echo "=== Unit Tests: Helper Functions ==="
# =============================================

echo ""
echo "--- sanitize_branch ---"
assert_eq "slash to dash" "feature-foo" "$(sanitize_branch "feature/foo")"
assert_eq "uppercase to lower" "my-branch" "$(sanitize_branch "MY-BRANCH")"
assert_eq "nested slashes" "a-b-c-d" "$(sanitize_branch "a/b/c/d")"
assert_eq "no change needed" "main" "$(sanitize_branch "main")"

echo ""
echo "--- ssh_port_for ---"
port1="$(ssh_port_for "feature/test")"
port2="$(ssh_port_for "feature/test")"
port3="$(ssh_port_for "other-branch")"
assert_eq "deterministic" "$port1" "$port2"
if (( port1 >= 10000 && port1 <= 18999 )); then pass "port in range 10000-18999 ($port1)"
else fail "port in range 10000-18999" "$port1"; fi
if [[ "$port1" != "$port3" ]]; then pass "different branches get different ports"
else fail "different branches get different ports" "$port1 == $port3"; fi

echo ""
echo "--- container_name_for ---"
assert_eq "basic" "lightning-feature-foo" "$(container_name_for "feature/foo")"
assert_eq "simple" "lightning-main" "$(container_name_for "main")"

echo ""
echo "--- parse_duration ---"
assert_eq "seconds" "30" "$(parse_duration "30s")"
assert_eq "minutes" "600" "$(parse_duration "10m")"
assert_eq "hours" "14400" "$(parse_duration "4h")"
assert_eq "days" "172800" "$(parse_duration "2d")"
assert_eq "bare number" "42" "$(parse_duration "42")"

echo ""
echo "--- sed_i ---"
tmpfile="$(mktemp)"
echo "hello world" > "$tmpfile"
sed_i "s/world/earth/" "$tmpfile"
assert_eq "in-place replace" "hello earth" "$(cat "$tmpfile")"
rm -f "$tmpfile"

echo ""
echo "--- stat_mtime ---"
tmpfile="$(mktemp)"
mtime="$(stat_mtime "$tmpfile")"
now="$(date +%s)"
if [[ "$mtime" =~ ^[0-9]+$ ]] && (( mtime > 0 && mtime <= now + 10 )); then
    pass "returns epoch seconds ($mtime)"
else
    fail "returns epoch seconds" "$mtime"
fi
rm -f "$tmpfile"

echo ""
echo "--- compose_file_for ---"
assert_eq "path construction" "/tmp/wt/.wk/docker-compose.yml" "$(compose_file_for "/tmp/wt")"

echo ""
echo "--- resolve_branch ---"
assert_eq "plain name passthrough" "my-branch" "$(resolve_branch "my-branch")"
assert_eq "slash branch passthrough" "feature/test" "$(resolve_branch "feature/test")"

# =============================================
echo ""
echo "=== CLI Smoke Tests ==="
# =============================================

echo ""
echo "--- wk help ---"
help_output="$("$WK" help 2>&1)"
assert_match "exits 0" "Usage" "$help_output"

help2_output="$("$WK" --help 2>&1)"
assert_match "--help works" "Usage" "$help2_output"

help3_output="$("$WK" -h 2>&1)"
assert_match "-h works" "Usage" "$help3_output"

echo ""
echo "--- wk outside repo ---"
assert_exit "ls outside repo fails" 1 bash -c "cd /tmp && '$WK' ls"
assert_exit "ssh outside repo fails" 1 bash -c "cd /tmp && '$WK' ssh test"
assert_exit "unknown cmd fails" 1 bash -c "cd /tmp && '$WK' nonexistent"

# =============================================
echo ""
echo "=== Results ==="
# =============================================

total=$((PASS + FAIL))
echo "$PASS/$total passed"
if (( FAIL > 0 )); then
    echo "$FAIL FAILED"
    rm -f "$HELPER_FILE" "${HELPER_FILE}.bak"
    exit 1
fi
rm -f "$HELPER_FILE" "${HELPER_FILE}.bak"
echo "All tests passed."
