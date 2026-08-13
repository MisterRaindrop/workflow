#!/usr/bin/env bash
# Unit tests for wk's pure helpers.
#
# LXD + nested Docker cannot be exercised in CI, so this covers the logic that
# does not touch lxc/docker. Integration is verified on a real host with:
#   wk doctor && wk new && wk bind && wk smoke
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WK="$SCRIPT_DIR/wk"
PASS=0; FAIL=0

pass() { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31m✗\033[0m %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"; }

assert_eq() {
    local desc=$1 expected=$2 actual=$3
    [[ "$actual" == "$expected" ]] && pass "$desc" || fail "$desc" "$expected" "$actual"
}

assert_match() {
    local desc=$1 pattern=$2 actual=$3
    if grep -qE -- "$pattern" <<<"$actual"; then pass "$desc"
    else fail "$desc" "a match for /$pattern/" "$(tr '\n' '|' <<<"$actual" | cut -c1-160)"; fi
}

assert_ok() {
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc" "exit 0" "exit $?"; fi
}

assert_fails() {
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then fail "$desc" "non-zero exit" "exit 0"; else pass "$desc"; fi
}

# Load helpers without running a command.
WK_SOURCE_ONLY=1
export WK_SOURCE_ONLY
WK_CONFIG=/nonexistent/wk-test-config.env
export WK_CONFIG
# shellcheck disable=SC1091
source "$WK"
set +e   # source brought in `set -Eeuo pipefail`; assertions need to survive failures

echo "=== fmt_duration ==="
assert_eq "zero"          "0s"  "$(fmt_duration 0)"
assert_eq "seconds"       "45s" "$(fmt_duration 45)"
assert_eq "rounds to min" "1m"  "$(fmt_duration 90)"
assert_eq "one hour"      "1h"  "$(fmt_duration 3600)"
assert_eq "hours"         "5h"  "$(fmt_duration 19000)"
assert_eq "one day"       "1d"  "$(fmt_duration 86400)"
assert_eq "days"          "3d"  "$(fmt_duration 259200)"
assert_eq "negative"      "0s"  "$(fmt_duration -5)"

echo "=== parse_duration ==="
assert_eq "bare number" "30"     "$(parse_duration 30)"
assert_eq "seconds"     "30"     "$(parse_duration 30s)"
assert_eq "minutes"     "300"    "$(parse_duration 5m)"
assert_eq "hours"       "14400"  "$(parse_duration 4h)"
assert_eq "days"        "604800" "$(parse_duration 7d)"
assert_eq "garbage"     "0"      "$(parse_duration abc)"
assert_eq "empty"       "0"      "$(parse_duration '')"

echo "=== fmt_bytes ==="
assert_eq "zero is dash"  "-"     "$(fmt_bytes 0)"
assert_eq "kilobytes"     "1K"    "$(fmt_bytes 1024)"
assert_eq "megabytes"     "1M"    "$(fmt_bytes 1048576)"
assert_eq "real anon"     "1.4G"  "$(fmt_bytes 1506287616)"
assert_eq "real peak"     "15.8G" "$(fmt_bytes 16987611136)"
assert_eq "non-numeric"   "-"     "$(fmt_bytes abc)"

echo "=== valid_slot_name ==="
assert_ok    "plain name"          valid_slot_name lxslot1
assert_ok    "short name"          valid_slot_name wk1
assert_ok    "with dashes"         valid_slot_name my-slot-2
assert_fails "leading digit"       valid_slot_name 1slot
assert_fails "underscore"          valid_slot_name has_underscore
assert_fails "space"               valid_slot_name "has space"
assert_fails "empty"               valid_slot_name ""
assert_fails "dot"                 valid_slot_name "a.b"
assert_fails "too long"            valid_slot_name "$(printf 'a%.0s' {1..64})"

echo "=== next_slot_name ==="
assert_eq "first free"        "lxslot1" "$(next_slot_name "" "lxslot1 lxslot2 lxslot3")"
assert_eq "skips taken"       "lxslot2" "$(next_slot_name "lxslot1" "lxslot1 lxslot2 lxslot3")"
assert_eq "skips two"         "lxslot3" "$(next_slot_name "lxslot1 lxslot2" "lxslot1 lxslot2 lxslot3")"
assert_eq "falls back"        "wk1"     "$(next_slot_name "lxslot1 lxslot2 lxslot3" "lxslot1 lxslot2 lxslot3")"
assert_eq "fallback advances" "wk2"     "$(next_slot_name "lxslot1 lxslot2 lxslot3 wk1" "lxslot1 lxslot2 lxslot3")"
assert_eq "ignores unrelated" "lxslot1" "$(next_slot_name "other-container" "lxslot1 lxslot2")"

echo "=== mem_from_stat (anon + swap, never memory.current) ==="
# Real numbers read from lxslot1: anon 1.40G, file 11.2G, swap 70M.
# The point of this helper is that `file` must never be counted.
REAL_STAT='anon 1506287616
file 12003635200
shmem 237568
slab_unreclaimable 7578864'
assert_eq "anon plus swap"   "1579700224" "$(mem_from_stat 73412608 <<<"$REAL_STAT")"
assert_eq "ignores page cache" "1506287616" "$(mem_from_stat 0 <<<"$REAL_STAT")"
assert_eq "missing anon"     "512"        "$(mem_from_stat 512 <<<"file 999")"
assert_eq "empty input"      "0"          "$(mem_from_stat 0 </dev/null)"
assert_eq "bad swap value"   "1506287616" "$(mem_from_stat abc <<<"$REAL_STAT")"

echo "=== parse_list_key ==="
TMP_YAML="$(mktemp)"
cat > "$TMP_YAML" <<'YAML'
services:
  - compose/db.yml
  - compose/ci.yml   # trailing comment
  - "quoted/path.yml"
networks:
  - ci-net
other_key: value
YAML
assert_eq "service count"   "3" "$(parse_list_key "$TMP_YAML" services | wc -l | tr -d ' ')"
assert_eq "first service"   "compose/db.yml" "$(parse_list_key "$TMP_YAML" services | head -1)"
assert_eq "strips comment"  "compose/ci.yml" \
                            "$(parse_list_key "$TMP_YAML" services | sed -n 2p)"
assert_eq "strips quotes"   "quoted/path.yml" "$(parse_list_key "$TMP_YAML" services | sed -n 3p)"
assert_eq "stops at key"    "1" "$(parse_list_key "$TMP_YAML" networks | wc -l | tr -d ' ')"
assert_eq "missing key"     "0" "$(parse_list_key "$TMP_YAML" nope | wc -l | tr -d ' ')"
assert_eq "missing file"    "0" "$(parse_list_key /nonexistent/x.yaml services | wc -l | tr -d ' ')"
rm -f "$TMP_YAML"

echo "=== proxy_endpoint ==="
WK_PROXY="http://203.0.113.1:1080"
assert_eq "host and port"   "203.0.113.1 1080" "$(proxy_endpoint)"
WK_PROXY="https://proxy.example:3128/"
assert_eq "https with slash" "proxy.example 3128" "$(proxy_endpoint)"
WK_PROXY="http://user:pass@proxy.example:8080"
assert_eq "strips userinfo"  "proxy.example 8080" "$(proxy_endpoint)"
WK_PROXY="http://[fd00::1]:1080"
assert_eq "ipv6"             "fd00::1 1080" "$(proxy_endpoint)"
WK_PROXY="http://noport"
assert_fails "rejects missing port" proxy_endpoint
WK_PROXY=""
assert_fails "rejects empty" proxy_endpoint

echo "=== elide ==="
assert_eq "short strings pass through" "/a/b"        "$(elide /a/b 20)"
assert_eq "long paths lose the middle" "/mnt...oject" "$(elide /mnt/data500/myproject 12)"
assert_eq "result respects the budget" "12"           "$(elide /mnt/data500/myproject 12 | awk '{print length}')"
assert_eq "tiny budgets are floored"   "8"            "$(elide /mnt/data500/very/long/path 2 | awk '{print length}')"

# =============================================================================
# Command-level tests
#
# These run the real `wk` in a subprocess with `lxc`, `docker` and `iptables`
# replaced by fakes (see test/). Besides exit codes they assert on the calls wk
# actually made — that is where most of the behaviour lives, and it is what
# catches renamed-but-not-updated functions and mis-built arguments.
# =============================================================================

FAKE_DIR="$SCRIPT_DIR/test"
chmod +x "$FAKE_DIR/fake-lxc" "$FAKE_DIR/bin/"* 2>/dev/null || true

# NOTE: no EXIT trap here on purpose — it also fires when a $( ) subshell exits,
# which would delete TMP_ROOT on the very first $(wk_rc ...). Cleaned up at the end.
TMP_ROOT="$(mktemp -d)"
CALLS="$TMP_ROOT/calls"

# Run wk in a clean subprocess. WK_SOURCE_ONLY must not leak in, or main() never runs.
wk_run() {
    : > "$CALLS"
    rm -rf "$TMP_ROOT/states"     # fresh world per invocation, so cases stay independent
    (
        unset WK_SOURCE_ONLY
        export PATH="$FAKE_DIR/bin:$PATH"
        export WK_LXC="$FAKE_DIR/fake-lxc"
        export WK_CONFIG=/nonexistent/wk-test-config.env
        export WK_FAKE_CALLS="$CALLS"
        export WK_RUN_DIR="$TMP_ROOT/run"
        export WK_TMUX=0
        bash "$WK" "$@"
    ) 2>&1
}

wk_rc() { wk_run "$@" >/dev/null 2>&1; printf '%d' "$?"; }

assert_called() {
    local desc=$1 pattern=$2
    if grep -qE -- "$pattern" "$CALLS" 2>/dev/null; then pass "$desc"
    else fail "$desc" "a call matching /$pattern/" "$(tr '\n' '|' < "$CALLS" | cut -c1-160)"; fi
}

assert_not_called() {
    local desc=$1 pattern=$2
    if grep -qE -- "$pattern" "$CALLS" 2>/dev/null; then
        fail "$desc" "no call matching /$pattern/" "$(grep -E -- "$pattern" "$CALLS" | head -1)"
    else pass "$desc"; fi
}

export WK_FAKE_CONTAINERS="lxslot1=RUNNING lxslot2=FROZEN lxslot3=STOPPED"
export WK_FAKE_BOUND="lxslot1=/data/alpha lxslot2=/data/beta"
export WK_FAKE_META="lxslot1.managed=1 lxslot2.managed=1 lxslot3.managed=1 lxslot1.note=hello"

echo ""
echo "=== command: ls ==="
out="$(wk_run ls)"
assert_match "lists every managed container" "lxslot1.*lxslot2.*lxslot3" "$(echo "$out" | tr '\n' ' ')"
assert_match "shows state"                   "RUNNING"                   "$out"
assert_match "shows the bound directory"     "/data/alpha"               "$out"
assert_match "shows the note"                "hello"                     "$out"
assert_called "queries container list"       "^list"

echo ""
echo "=== command: pause / start / stop ==="
wk_run pause lxslot1 >/dev/null
assert_called "pause issues lxc pause"       "^pause lxslot1"
wk_run start lxslot3 >/dev/null
assert_called "start issues lxc start"       "^start lxslot3"
assert_eq "pausing a stopped container is a no-op" "0" "$(wk_rc pause lxslot3)"
assert_not_called "…and does not issue pause" "^pause lxslot3"

echo ""
echo "=== command: bind ==="
BIND_DIR="$TMP_ROOT/code"; mkdir -p "$BIND_DIR"
# Ownership check must not block: point it at whatever owns the temp dir.
export WK_CODE_UID; WK_CODE_UID="$(stat -c %u "$BIND_DIR" 2>/dev/null || stat -f %u "$BIND_DIR")"
export WK_CODE_GID; WK_CODE_GID="$(stat -c %g "$BIND_DIR" 2>/dev/null || stat -f %g "$BIND_DIR")"

wk_run bind lxslot3 "$BIND_DIR" --no-up >/dev/null
assert_called "bind adds a disk device"          "config device add lxslot3"
assert_called "bind mounts at the identical path" "source=$BIND_DIR path=$BIND_DIR"
assert_called "bind records last-active"          "config set lxslot3 user.wk.last-active"

echo ""
echo "=== command: exec / note ==="
wk_run exec lxslot1 "true" >/dev/null
assert_called "exec runs inside the container"   "^exec lxslot1"
wk_run note lxslot1 "a new note" >/dev/null
assert_called "note writes user.wk.note"         "config set lxslot1 user.wk.note"

echo ""
echo "=== error paths ==="
assert_eq "unknown container fails"              "1" "$(wk_rc exec nosuch true)"
assert_match "…with a helpful message"           "no such container" "$(wk_run exec nosuch true)"
assert_eq "bind without a directory fails"       "1" "$(wk_rc bind lxslot3)"
assert_eq "bind onto a missing directory fails"  "1" "$(wk_rc bind lxslot3 /nonexistent/dir)"
assert_eq "rm without -f is refused when non-interactive" "1" "$(wk_rc rm lxslot1)"
assert_match "…and says why"                     "refusing to delete" "$(wk_run rm lxslot1)"
assert_eq "unknown command fails"                "1" "$(wk_rc bogus-command)"

out="$(wk_run bind lxslot3 "$BIND_DIR" --no-up 2>&1 || true)"
export WK_FAKE_BOUND="lxslot1=$BIND_DIR"
assert_eq "binding a directory held by another container fails" "1" "$(wk_rc bind lxslot3 "$BIND_DIR")"
assert_match "…and names the holder" "already bound to lxslot1" "$(wk_run bind lxslot3 "$BIND_DIR")"
export WK_FAKE_BOUND="lxslot1=/data/alpha lxslot2=/data/beta"

echo ""
echo "=== frozen / stopped containers are woken ==="
wk_run exec lxslot2 "true" >/dev/null      # lxslot2 is FROZEN
assert_called "exec on a frozen container starts it first" "^start lxslot2"

echo ""
echo "=== egress rules are asserted on a normal command ==="
export WK_FAKE_IPT_RULES="$TMP_ROOT/rules"; : > "$WK_FAKE_IPT_RULES"
export WK_PROXY="http://10.0.0.1:1080" WK_DIRECT_HOSTS="192.168.1.1"
wk_run exec lxslot1 "true" >/dev/null
assert_called "a normal command asserts egress rules" "iptables .*(-C|-I)"
unset WK_PROXY WK_DIRECT_HOSTS WK_FAKE_IPT_RULES

echo ""
echo "=== concurrency lock ==="
# macOS has no flock, so the suite injects one — this also covers the degrade path.
wk_run bind lxslot3 "$BIND_DIR" --no-up >/dev/null
assert_called "bind takes an exclusive lock"        "flock -x -w [0-9]+ 9"
wk_run exec lxslot1 "true" >/dev/null
assert_called "exec takes a shared lock"            "flock -s -w [0-9]+ 9"
assert_not_called "…and never an exclusive one"     "flock -x"
wk_run pause lxslot1 >/dev/null
assert_called "pause takes an exclusive lock"       "flock -x"
wk_run ls >/dev/null
assert_not_called "ls takes no lock at all"         "flock"

# A held lock must fail loudly, not continue silently.
export WK_FAKE_FLOCK_RC=1
assert_eq "a held lock makes bind fail"             "1" "$(wk_rc bind lxslot3 "$BIND_DIR" --no-up)"
out="$(wk_run bind lxslot3 "$BIND_DIR" --no-up)"
assert_match "…naming the container"                "lxslot3 is busy"   "$out"
assert_match "…and telling you how to look"         "wk ls"             "$out"
assert_not_called "…without touching the device"    "config device add"
unset WK_FAKE_FLOCK_RC

# The lock is taken once at the entry point; a nested take would self-deadlock.
wk_run bind lxslot3 "$BIND_DIR" >/dev/null 2>&1
assert_eq "bind locks exactly once (bind -> services_up must not re-lock)" \
    "1" "$(grep -c 'flock' "$CALLS" | tr -d ' ')"

echo ""
echo "=== audit trail ==="
wk_run bind lxslot3 "$BIND_DIR" --no-up >/dev/null
assert_called "bind is recorded"                    "logger -t wk -- bind lxslot3"
assert_called "…with the caller"                    "logger .*\[by "
wk_run pause lxslot1 >/dev/null
assert_called "pause is recorded"                   "logger -t wk -- pause lxslot1"
wk_run ls >/dev/null
assert_not_called "read-only commands are not"      "logger"
wk_run verify lxslot1 >/dev/null 2>&1
assert_not_called "…verify neither"                 "logger"

echo ""
echo "=== exec --retry ==="
export WK_FAKE_EXEC_RC=1
assert_eq "a failing command still fails"           "1" "$(wk_rc exec lxslot1 false)"
wk_run exec lxslot1 false >/dev/null 2>&1
assert_eq "without --retry it runs once"            "1" "$(grep -c '^exec lxslot1 -- bash -lc cd' "$CALLS" | tr -d ' ')"
wk_run exec --retry 2 lxslot1 false >/dev/null 2>&1
assert_eq "--retry 2 means three attempts"          "3" "$(grep -c '^exec lxslot1 -- bash -lc cd' "$CALLS" | tr -d ' ')"
unset WK_FAKE_EXEC_RC

echo ""
echo "=== image cache ==="
CACHE="$TMP_ROOT/cache"; mkdir -p "$CACHE"
export WK_IMAGE_CACHE="$CACHE"
printf 'x%.0s' $(seq 1 3000) > "$CACHE/old_image.tar"
printf 'x%.0s' $(seq 1 3000) > "$CACHE/new_image.tar"
out="$(wk_run cache ls)"
assert_match "cache ls lists the tars"              "old_image.tar"  "$out"
assert_match "…and reports a total"                 "total"          "$out"
export WK_CACHE_MAX_GB=0
wk_run cache prune >/dev/null
assert_eq "prune trims to the limit"                "0" "$(ls "$CACHE"/*.tar 2>/dev/null | wc -l | tr -d ' ')"
unset WK_CACHE_MAX_GB WK_IMAGE_CACHE

echo ""
echo "=== warm --from (cross-container copy) ==="
export WK_WARM_IMAGES="repo/img:1"
wk_run warm lxslot3 --from lxslot1 >/dev/null 2>&1
assert_called "streams from the source container"   "^exec lxslot1 -- docker save repo/img:1"
assert_called "…into the destination"               "^exec lxslot3 -- docker load"
assert_not_called "…without touching the host cache" "^docker image save"
unset WK_WARM_IMAGES

echo ""
echo "=== WK_SEED_PATHS (extra dotfiles) ==="
SEED_HOME="$TMP_ROOT/home"; mkdir -p "$SEED_HOME"
printf 'set -g mouse on\n' > "$SEED_HOME/.tmux.conf"
export WK_AUTH_HOME="$SEED_HOME"

export WK_SEED_PATHS=".tmux.conf"
wk_run auth lxslot1 >/dev/null 2>&1
assert_called "seeds the extra dotfile"        "exec lxslot1 -- tar"
out="$(wk_run auth lxslot1 2>&1)"
assert_match "…and says what it is doing"      "seeding credentials and config" "$out"

export WK_SEED_PATHS=".tmux.conf .nonexistent-file"
out="$(wk_run auth lxslot1 2>&1)"
assert_match "warns about a listed-but-missing path" "does not exist" "$out"
assert_eq "…but still succeeds"                "0" "$(wk_rc auth lxslot1)"

unset WK_SEED_PATHS WK_AUTH_HOME

rm -rf "$TMP_ROOT"

echo ""
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
