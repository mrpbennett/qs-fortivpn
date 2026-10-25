#!/usr/bin/env bash
# Test: when all gateway probes fail, the helper falls back to the first
# gateway instead of crashing with "unbound variable".
#
# Stubs systemd-run, systemctl, timeout, and openfortivpn on PATH so the
# helper never touches the real system.
#
# Run: sudo bash tests/test_failover_fallback.sh
set -euo pipefail

[[ $(id -u) == 0 ]] || { echo "This test must be run as root (sudo)."; exit 1; }

DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$DIR/scripts/omarchy-fortivpn-helper"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---- stubs ----
BIN="$WORK/bin"
mkdir -p "$BIN"

printf '#!/bin/bash\necho "OPENFORTIVPN_ARGS=$*"\nexit 0\n' > "$BIN/openfortivpn"
printf '#!/bin/bash\nwhile [[ $# -gt 0 ]]; do case "$1" in */openfortivpn|openfortivpn) exec "$@";; *) shift;; esac; done; exit 1\n' > "$BIN/systemd-run"
printf '#!/bin/bash\ncase "${2:-}" in reset-failed|stop) exit 0;; is-active) echo inactive; exit 3;; esac; exit 0\n' > "$BIN/systemctl"
printf '#!/bin/bash\nexit 1\n' > "$BIN/timeout"
chmod +x "$BIN"/*

# ---- root-owned config dir ----
CDIR="$WORK/conf"
mkdir -p "$CDIR"; chmod 700 "$CDIR"; chown root:root "$CDIR"
CFILE="$CDIR/omarchy.conf"

# ---- patched helper ----
PATCHED="$WORK/helper.sh"
sed "s|^CONF=.*|CONF=$CFILE|;s|^CONF_DIR=.*|CONF_DIR=$CDIR|;s|^PATH=.*|PATH=$BIN:/usr/sbin:/usr/bin:/sbin:/bin|" "$HELPER" > "$PATCHED"
chmod +x "$PATCHED"

passed=0
failed=0

write_conf() {
  printf 'host = %s\nport = 4443\nusername = testuser\npassword = testpass\n' "$1" > "$CFILE"
  chmod 600 "$CFILE"; chown root:root "$CFILE"
}

run_test() {
  local name="$1" hosts="$2" expected="$3"
  write_conf "$hosts"
  local out
  out=$("$PATCHED" start 2>&1) || true

  if echo "$out" | grep -qF "OPENFORTIVPN_ARGS="; then
    local got
    got=$(echo "$out" | grep "OPENFORTIVPN_ARGS=" | head -1 | sed 's/OPENFORTIVPN_ARGS=//' | awk '{print $1}')
    if [[ "$got" == "$expected" ]]; then
      echo "  ok  $name (target=$got)"
      (( passed++ )) || true
    else
      echo " FAIL $name: expected=$expected got=$got"
      (( failed++ )) || true
    fi
  elif echo "$out" | grep -qE "unbound variable|: line"; then
    echo " FAIL $name: bash error: $(echo "$out" | grep -E 'unbound|: line' | head -1)"
    (( failed++ )) || true
  else
    echo " FAIL $name: unexpected: $(echo "$out" | tail -3)"
    (( failed++ )) || true
  fi
}

echo "failover fallback tests"

run_test "single gateway" \
  "192.0.2.1" "192.0.2.1:4443"

run_test "two unreachable → fallback to first" \
  "192.0.2.1, 192.0.2.2" "192.0.2.1:4443"

run_test "three unreachable → fallback to first" \
  "192.0.2.1, 192.0.2.2, 192.0.2.3" "192.0.2.1:4443"

run_test "explicit ports → fallback to first with its port" \
  "192.0.2.1:8443, 192.0.2.2:9443" "192.0.2.1:8443"

echo ""
echo "$passed passed, $failed failed"
exit $failed
