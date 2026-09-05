#!/usr/bin/env bash
set -u

SCRIPT="${1:-./install.sh}"
[ -f "$SCRIPT" ] || { echo "usage: test-install.sh [path/to/install.sh]"; exit 2; }

pass=0; fail=0
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_off=$'\033[0m'

expect_fail() {
  local what="$1"; shift
  local out rc
  out="$(bash "$SCRIPT" "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s ok  %s%s\n' "$c_grn" "$what" "$c_off"; pass=$((pass+1))
  else
    printf '%s FAIL%s %s — exited 0, should have refused\n' "$c_red" "$c_off" "$what"; fail=$((fail+1))
  fi
}

expect_ok() {
  local what="$1"; shift
  if bash "$SCRIPT" "$@" >/dev/null 2>&1; then
    printf '%s ok  %s%s\n' "$c_grn" "$what" "$c_off"; pass=$((pass+1))
  else
    printf '%s FAIL%s %s — exited non-zero\n' "$c_red" "$c_off" "$what"; fail=$((fail+1))
  fi
}

echo "argument handling"
expect_fail "--admin with no value"        --admin
expect_fail "--admin with an empty value"  --admin ""
expect_fail "--dir with no value"          --dir
expect_fail "--ref with no value"          --ref
expect_fail "--sha256 with no value"       --sha256
expect_fail "--ref without --sha256"       --ref main
expect_fail "an unknown option"            --nope
expect_fail "an admin name with a slash"   --admin ../etc
expect_ok   "--help"                       --help

echo
echo "the pinned checksum matches the template beside it"
if [ -f "$(dirname "$SCRIPT")/index.html" ]; then
  pinned="$(grep -oE '^EXPECT_SHA256="[a-f0-9]+"' "$SCRIPT" | cut -d'"' -f2)"
  actual="$( { sha256sum 2>/dev/null || shasum -a 256; } < "$(dirname "$SCRIPT")/index.html" | cut -d' ' -f1)"
  if [ -n "$pinned" ] && [ "$pinned" = "$actual" ]; then
    printf '%s ok  pinned %s…%s\n' "$c_grn" "${pinned:0:16}" "$c_off"; pass=$((pass+1))
  else
    printf '%s FAIL%s pinned=%s actual=%s\n' "$c_red" "$c_off" "${pinned:-none}" "$actual"; fail=$((fail+1))
  fi
else
  echo " skip  no index.html beside the installer"
fi

echo
echo "the env editor keeps commented examples commented"
tmp="$(mktemp -d)"
printf 'A=1\nKEY="old"\n# KEY="commented example"\nB=2\n' > "$tmp/.env"
awk -v key="KEY" -v val="new" '
  $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { if (!done) { print key "=\"" val "\""; done = 1 } next }
  { print }
  END { if (!done) print key "=\"" val "\"" }
' "$tmp/.env" > "$tmp/out"
active="$(grep -cE '^[[:space:]]*KEY[[:space:]]*=' "$tmp/out")"
commented="$(grep -cE '^#[[:space:]]*KEY' "$tmp/out")"
value="$(grep -E '^KEY=' "$tmp/out")"
if [ "$active" = 1 ] && [ "$commented" = 1 ] && [ "$value" = 'KEY="new"' ]; then
  printf '%s ok  one active line, the example untouched%s\n' "$c_grn" "$c_off"; pass=$((pass+1))
else
  printf '%s FAIL%s active=%s commented=%s value=%s\n' "$c_red" "$c_off" "$active" "$commented" "$value"; fail=$((fail+1))
fi
rm -rf "$tmp"

echo
printf 'passed %s, failed %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
