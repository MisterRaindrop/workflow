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

assert_no_match() {
    local desc=$1 pattern=$2 actual=$3
    if grep -qE -- "$pattern" <<<"$actual"; then
        fail "$desc" "no match for /$pattern/" "$(tr '\n' '|' <<<"$actual" | cut -c1-160)"
    else pass "$desc"; fi
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

# `source "$WK"` above ran wk's own variable defaults in this shell, so
# WK_DATA_ROOT is already /var/lib/wk here. Any `${WK_DATA_ROOT:-sandbox}`
# fallback would therefore resolve to the production path, and a test would try
# to mkdir it. Set them outright instead; wk_run only exports what it finds, so
# a test that wants a different value (see the cache tests) just assigns it.
WK_DATA_ROOT="$TMP_ROOT/data"
WK_IMAGE_CACHE="$TMP_ROOT/data/image-cache"

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
        # Whatever the suite currently has these set to — sandbox paths by
        # default, or a case-specific directory. Never wk's real defaults.
        export WK_DATA_ROOT WK_IMAGE_CACHE
        export WK_TMUX=0
        # The human `ls` table sizes its CODE column to the terminal, so an
        # unpinned width makes assertions about elision depend on whoever runs
        # them: an interactive shell here reports COLUMNS=0 (wk floors the
        # budget at 20, so everything elides), while CI has no tty at all and
        # `tput cols` then answers 100 (so a 60-char path fits and nothing
        # elides). Same code, opposite results. Pin it; cases that care override.
        export COLUMNS="${WK_TEST_COLUMNS:-80}"
        # </dev/null: the fake lxc drains piped stdin (like the real client), so
        # wk must never inherit the harness's stdin — a held-open one hangs it.
        bash "$WK" "$@" </dev/null
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
echo "=== config vs environment precedence ==="
# The config file is the host default; a WK_* already in the environment is a
# deliberate override for one command. Sourcing the file used to clobber it, so
# `WK_WARM_IMAGES=... wk warm` silently warmed nothing.
CFG="$TMP_ROOT/precedence.env"
printf 'WK_WARM_IMAGES=""\nWK_POOL=from-config\nWK_MEM_SAFETY=55\n' > "$CFG"
probe() {
    ( unset WK_SOURCE_ONLY
      export WK_CONFIG="$CFG"
      [[ -n "${2:-}" ]] && export "$2"
      WK_SOURCE_ONLY=1 bash -c "source '$WK'; printf '%s' \"\${$1}\"" )
}
assert_eq "environment beats the config file"   "env-wins" "$(probe WK_WARM_IMAGES 'WK_WARM_IMAGES=env-wins')"
assert_eq "config still supplies a default"     "from-config" "$(probe WK_POOL)"
assert_eq "…and is overridable too"             "other" "$(probe WK_POOL 'WK_POOL=other')"
assert_eq "numeric settings behave the same"    "55" "$(probe WK_MEM_SAFETY)"
assert_eq "an empty config value is a default"  "" "$(probe WK_WARM_IMAGES)"

echo ""
echo "=== ls --porcelain (machine-readable) ==="
out="$(wk_run ls --porcelain)"
assert_eq "one line per container"        "3" "$(grep -c . <<<"$out")"
assert_eq "tab separated, six fields"     "6" "$(head -1 <<<"$out" | awk -F'\t' '{print NF}')"
assert_eq "no header row"                 "lxslot1" "$(head -1 <<<"$out" | cut -f1)"
assert_eq "state in field 2"              "RUNNING" "$(head -1 <<<"$out" | cut -f2)"
# The whole point: paths must arrive whole, since the human table elides them.
assert_eq "full path, never elided"       "/data/alpha" "$(head -1 <<<"$out" | cut -f5)"
assert_eq "unbound reads as a dash"       "-" "$(sed -n 3p <<<"$out" | cut -f5)"
assert_eq "note preserved"                "hello" "$(head -1 <<<"$out" | cut -f6)"

# A long path must survive verbatim — this is the regression that broke bc.
export WK_FAKE_BOUND="lxslot1=/mnt/data500/a-very-long-directory-name/nested/deeper/project"
assert_eq "long paths are not truncated" \
    "/mnt/data500/a-very-long-directory-name/nested/deeper/project" \
    "$(wk_run ls --porcelain | head -1 | cut -f5)"
# At 80 columns a 60-char path cannot fit, so it must lose its middle…
assert_match "…while the human table does elide them" "\.\.\." "$(wk_run ls)"
# …and given room it must arrive whole. Asserting only the first direction is
# how this slipped through: it passes on any terminal that happens to be narrow.
assert_no_match "…and leaves it whole when there is room" "\.\.\." \
    "$(WK_TEST_COLUMNS=200 wk_run ls)"
export WK_FAKE_BOUND="lxslot1=/data/alpha lxslot2=/data/beta"

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
echo "=== service groups (.wk.yaml) ==="
GDIR="$TMP_ROOT/grouped"; mkdir -p "$GDIR"
cat > "$GDIR/.wk.yaml" <<'YAML'
services:
  - services/datalake.yml
services_ci:
  - services/mysql.yml
  - services/hive.yml
networks:
  - share-net
smoke_services:
  - polaris
  - minio
smoke_services_ci:
  - mysql
YAML
assert_eq "default group reads services"    "services/datalake.yml" \
          "$(WK_SOURCE_ONLY=1 bash -c "source '$WK'; service_files '$GDIR'")"
assert_eq "a named group reads its own key" "2" \
          "$(WK_SOURCE_ONLY=1 bash -c "source '$WK'; service_files '$GDIR' ci" | wc -l | tr -d ' ')"
assert_eq "…and does not leak the default"  "services/mysql.yml" \
          "$(WK_SOURCE_ONLY=1 bash -c "source '$WK'; service_files '$GDIR' ci" | head -1)"
assert_eq "smoke names follow the group"    "mysql" \
          "$(WK_SOURCE_ONLY=1 bash -c "source '$WK'; smoke_services '$GDIR' ci")"
assert_eq "declared groups are listable"    "ci" \
          "$(WK_SOURCE_ONLY=1 bash -c "source '$WK'; service_groups '$GDIR'")"
assert_eq "an unknown group finds nothing"  "0" \
          "$(WK_SOURCE_ONLY=1 bash -c "source '$WK'; service_files '$GDIR' nope" | wc -l | tr -d ' ')"

echo ""
echo "=== WK_MOUNTS: share a host directory instead of copying it ==="
MNT_A="$TMP_ROOT/tool"; MNT_B="$TMP_ROOT/vault"; mkdir -p "$MNT_A" "$MNT_B"
(
  export WK_MOUNTS="$MNT_A:/opt/tool:ro $MNT_B:/root/vault"
  wk_run mount lxslot1 >/dev/null 2>&1
)
assert_called "read-only entries pass readonly"  "device add lxslot1 wk-m-opt-tool disk source=.*/tool path=/opt/tool readonly=true"
assert_called "read-write entries do not"        "device add lxslot1 wk-m-root-vault disk source=.*/vault path=/root/vault$"
# The device name comes from the target path, so reordering the list cannot make
# an existing device point somewhere else.
(
  export WK_MOUNTS="$MNT_B:/root/vault $MNT_A:/opt/tool:ro"
  wk_run mount lxslot1 >/dev/null 2>&1
)
assert_called "names follow the target, not order" "device add lxslot1 wk-m-opt-tool"
out="$(
  export WK_MOUNTS="/nope/missing:/opt/x:ro"
  wk_run mount lxslot1 2>&1
)"
assert_match "a missing source is skipped"       "not on this host" "$out"
# Same path on both sides is the default, and the reason it is: a host tool
# refers to itself by absolute path, so the config seeded with the credentials
# only resolves if the path matches.
(
  export WK_MOUNTS="$MNT_A"
  wk_run mount lxslot1 >/dev/null 2>&1
)
assert_called "one path means mount it at itself" "disk source=.*/tool path=.*/tool$"
(
  export WK_MOUNTS="$MNT_A:ro"
  wk_run mount lxslot1 >/dev/null 2>&1
)
assert_called "…and :ro still applies"           "disk source=.*/tool path=.*/tool readonly=true"
out="$(
  export WK_MOUNTS="$MNT_A:relative/target"
  wk_run mount lxslot1 2>&1
)"
assert_match "a relative target is refused"      "cannot read" "$out"

echo ""
echo "=== warm: read the cache in place, do not copy it in ==="
# Copying a 13GB tar into the container cost 95 seconds against 63 for the load
# itself, plus 13GB of transient space there. Mounting the cache read-only
# removes both.
WARM_CACHE="$TMP_ROOT/warmcache"; mkdir -p "$WARM_CACHE"
printf 'x' > "$WARM_CACHE/repo_img__tag.tar"
(
  export WK_IMAGE_CACHE="$WARM_CACHE" WK_WARM_IMAGES="repo/img:tag" WK_FAKE_NO_IMAGES=1
  wk_run warm lxslot1 >/dev/null 2>&1
)
assert_called "mounts the cache read-only"      "device add lxslot1 wk-images disk .*readonly=true"
assert_called "loads straight from the mount"   "docker image load -i /mnt/wk-images/repo_img__tag.tar"
assert_not_called "…and never pushes the tar"   "^file push"
# An image already in the container is not reloaded. A tar's contents cannot
# change unless someone replaces it, so asking the container what it has beats
# hashing the file — and WK_REFRESH_IMAGE_CACHE is how you say it was replaced.
out="$(
  export WK_IMAGE_CACHE="$WARM_CACHE" WK_WARM_IMAGES="repo/img:tag"
  wk_run warm lxslot1 2>&1
)"
assert_match "an image already there is skipped" "already in lxslot1" "$out"
assert_not_called "…nothing is loaded again"     "docker image load"

echo ""
echo "=== Docker's proxy is configured whether or not Docker was just installed ==="
# Installing Docker and wiring its proxy are separate jobs. Tied together, a
# container that already had Docker never got /root/.docker/config.json, so
# `docker run` passed no proxy to anything it started.
(
  export WK_PROXY="http://10.0.0.1:1080"
  wk_run new lxslot8 --from lxslot1 >/dev/null 2>&1
)
assert_called "a clone gets it too"              "exec lxslot8 -- bash -s http://10.0.0.1:1080"
# And every container, when run without a name — the loop is the form actually
# used to bring an existing fleet up to date.
(
  export WK_PROXY="http://10.0.0.1:1080"
  wk_run mount >/dev/null 2>&1
)
assert_called "…and so does each of a fleet"     "exec lxslot3 -- bash -s http://10.0.0.1:1080"
(
  # Unset, not empty: wk falls back through HTTPS_PROXY/HTTP_PROXY, so an empty
  # WK_PROXY does not mean "no proxy" if the environment has one.
  unset WK_PROXY HTTPS_PROXY HTTP_PROXY https_proxy http_proxy
  wk_run mount lxslot1 >/dev/null 2>&1
)
assert_not_called "…and nothing to do without a proxy" "bash -s http"

echo ""
echo "=== new --from: clone instead of provision ==="
# Cloning replaces ~26 minutes of apt and image loading with a copy. What must
# not be inherited is the source's identity or its bound checkout.
CLONE_HOME="$TMP_ROOT/clonehome"; mkdir -p "$CLONE_HOME/.codex"
printf '{}' > "$CLONE_HOME/.codex/auth.json"
export WK_AUTH_HOME="$CLONE_HOME"
wk_run new lxslot9 --from lxslot1 >/dev/null 2>&1
assert_called "clones with --stateless"          "^copy lxslot1 lxslot9 --stateless"
assert_called "drops the inherited code mount"   "config device remove lxslot9 wk-source"
assert_called "clears the copied machine-id"     "file push - lxslot9/etc/machine-id"
assert_called "re-seeds credentials"             "exec lxslot9 -- tar"
# The point of cloning is that none of the provisioning runs. `bash -s` is no
# longer a proxy for that (seeding shell config uses it too), so assert on what
# the provisioning would say.
out="$(wk_run new lxslot9 --from lxslot1 2>&1)"
assert_eq "…and installs nothing"                "0" \
          "$(grep -c 'installing \(Docker\|tools\)' <<<"$out" | tr -d ' ')"
assert_match "…it says it is cloning"            "cloning lxslot1 into lxslot9" "$out"
unset WK_AUTH_HOME
out="$(wk_run new lxslot1 --from lxslot2 2>&1)"
assert_match "refuses to overwrite an existing"  "already exists" "$out"
out="$(wk_run new lxslot9 --from nosuch 2>&1)"
assert_match "…and an unknown source"            "no such container" "$out"

echo ""
echo "=== the group reaches the guest that starts the services ==="
# The guest turns the group into a compose project name (-p). Sharing one
# project makes compose report the other group's containers as orphans, and a
# single --remove-orphans would then delete a running stack. The fake cannot see
# inside the guest, so assert on what the guest is handed: its last argument.
export WK_FAKE_BOUND="lxslot1=$GDIR lxslot2=/data/beta"
wk_run up lxslot1 >/dev/null 2>&1
assert_match "the default group starts its own files"  "services/datalake.yml" "$(tr '\n' ' ' < "$CALLS")"
assert_not_called "…and is not named as a group"       "bash -s .*datalake.yml ci"
wk_run up -g ci lxslot1 >/dev/null 2>&1
assert_match "a named group starts the other files"    "services/mysql.yml" "$(tr '\n' ' ' < "$CALLS")"
assert_match "…and its name reaches the guest"         "services/hive.yml ci" "$(tr '\n' ' ' < "$CALLS")"
export WK_FAKE_BOUND="lxslot1=/data/alpha lxslot2=/data/beta"

echo ""
echo "=== smoke: healthchecks and the probe image ==="
# The guest script is what decides ready-vs-running, so assert on the arguments
# it is handed — a dropped one silently disables a check.
# Point the fixture's bound dir at the .wk.yaml written above, so smoke has
# services to look for at all.
export WK_FAKE_BOUND="lxslot1=$GDIR lxslot2=/data/beta"
# The service list is multi-line, so the recorded call spans lines — match the
# flattened log rather than a single line of it.
calls_flat() { tr '\n' ' ' < "$CALLS"; }
wk_run smoke lxslot1 >/dev/null 2>&1
assert_match "smoke passes the probe image"      "bash -s polaris minio .* busybox:1.36" "$(calls_flat)"
wk_run smoke --wait 90 lxslot1 >/dev/null 2>&1
assert_match "…and the wait budget"              " 90 busybox:1.36" "$(calls_flat)"
wk_run smoke -w 2m lxslot1 >/dev/null 2>&1
assert_match "…accepting a duration"             " 120 busybox:1.36" "$(calls_flat)"
(
  export WK_PROBE_IMAGE=alpine:3.20
  wk_run smoke lxslot1 >/dev/null 2>&1
)
assert_match "WK_PROBE_IMAGE is honoured"        "alpine:3.20" "$(calls_flat)"
wk_run up --wait 30 lxslot1 >/dev/null 2>&1
assert_called "up --wait polls for health"       "exec lxslot1 -- bash -s polaris"
export WK_FAKE_BOUND="lxslot1=/data/alpha lxslot2=/data/beta"

echo ""
echo "=== readiness: a broken probe is not a broken service ==="
# wait_healthy parses `health_states` output on the host, so feed it directly.
# The verdicts it must tell apart are what decides where a reader looks next.
ready_out() {
    WK_FAKE_HEALTH="$1" WK_SOURCE_ONLY=1 bash -c '
        source "$1"
        health_states()  { printf "%s\n" "$WK_FAKE_HEALTH"; }
        bound_dir()      { printf "%s" "/tmp"; }
        smoke_services() { printf "polaris\nminio\n"; }
        wait_healthy lxslot1 "" 0
    ' _ "$WK" 2>&1
}
out="$(ready_out 'polaris healthy
minio healthy')"
assert_match "all healthy is ready"          "services ready" "$out"
out="$(ready_out 'polaris none
minio healthy')"
assert_match "no healthcheck is not a fault" "services ready" "$out"
out="$(ready_out 'polaris broken-probe
minio healthy')"
assert_match "a broken probe still reports ready" "services ready" "$out"
assert_match "…and names the compose file as the cause" "CMD-SHELL was meant" "$out"
out="$(ready_out 'polaris unhealthy
minio healthy')"
assert_match "a genuinely unhealthy service fails" "not healthy: polaris" "$out"
out="$(ready_out 'polaris missing
minio healthy')"
assert_match "a missing container fails"     "polaris\(missing\)" "$out"
out="$(ready_out 'polaris starting
minio healthy')"
assert_match "still starting fails with 0 budget" "still starting" "$out"

echo ""
echo "=== verify: two severities ==="
# A container that builds but has no agent CLIs is not the same failure as one
# with no Docker. Conflating them is what made a good build container look dead.
export WK_FAKE_MISSING="codex claude"
assert_eq "missing agent CLIs is exit 1"            "1" "$(wk_rc verify lxslot1)"
out="$(wk_run verify lxslot1)"
assert_match "…and says builds still work"          "builds still can" "$out"
export WK_FAKE_MISSING="make"
assert_eq "a missing make is exit 2"                "2" "$(wk_rc verify lxslot1)"
out="$(wk_run verify lxslot1)"
assert_match "…named as unable to build"            "cannot build" "$out"

# A CLI the host does not have either is not the container's fault, and saying
# so sends the reader to the right place. (This host really has no claude-code.)
export WK_FAKE_MISSING="codex claude"
NO_CLI_BIN="$TMP_ROOT/nocli"; mkdir -p "$NO_CLI_BIN"
for _stub in docker flock ip iptables logger sleep; do
    ln -sf "$FAKE_DIR/bin/$_stub" "$NO_CLI_BIN/$_stub"
done
printf '#!/usr/bin/env bash\nprintf %%s "%s/empty-node-root"\n' "$TMP_ROOT" > "$NO_CLI_BIN/npm"
chmod +x "$NO_CLI_BIN/npm"
out="$(
    unset WK_SOURCE_ONLY
    PATH="$NO_CLI_BIN:/usr/bin:/bin" WK_LXC="$FAKE_DIR/fake-lxc" \
    WK_CONFIG=/nonexistent/wk-test-config.env WK_FAKE_CALLS="$CALLS" \
    WK_RUN_DIR="$TMP_ROOT/run" WK_TMUX=0 bash "$WK" verify lxslot1 2>&1 </dev/null
)"
assert_match "a host-side gap is named as such"     "host has none either" "$out"
unset WK_FAKE_MISSING
assert_eq "a complete container is exit 0"          "0" "$(wk_rc verify lxslot1)"

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

# One entry larger than the whole limit must not take the rest with it. The
# limit is per-cache, not per-file, and the biggest tar is often the most
# recently read — so it sorts first and, with a naive running total, deletes
# everything behind it. Measured on a real cache: a 12.4G tar against a 6G
# limit emptied 19.4G down to nothing.
rm -f "$CACHE"/*.tar
dd if=/dev/zero of="$CACHE/huge.tar" bs=1024 count=3000 2>/dev/null
printf 'x' > "$CACHE/small1.tar"
printf 'x' > "$CACHE/small2.tar"
touch -a -t 203001010000 "$CACHE/huge.tar"      # most recently used, so it sorts first
out="$(WK_CACHE_MAX_BYTES=$((1024 * 1024)) wk_run cache prune 2>&1)"
assert_eq "an oversized entry does not take the rest" "2" \
          "$(ls "$CACHE"/small*.tar 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "…and it is the one that goes"             "0" \
          "$(ls "$CACHE"/huge.tar 2>/dev/null | wc -l | tr -d ' ')"
unset WK_IMAGE_CACHE

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
# wk installs tmux, so its config travels with it — without depending on each
# host remembering to list it.
printf 'set -g mouse on\n' > "$SEED_HOME/.tmux.conf"
out="$(WK_SEED_PATHS="" wk_run auth lxslot1 2>&1)"
assert_match "…and tmux.conf without being asked" "seeding credentials" "$out"
# Present is not the same as in effect: tmux reads its config only when the
# server starts, and a login lands on whatever server is already running.
assert_called "…then reloads what is running"      "exec lxslot1 -- bash -s"
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
