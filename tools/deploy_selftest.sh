#!/usr/bin/env bash
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
SCRIPT="$HERE/deploy_template.sh"
pass=0
fail=0

note() { printf "    %-6s: %s\n" "$1" "$2"; }
ok()   { note "ok" "$1"; }
bad()  { note "FAIL" "$1"; fail=$((fail + 1)); }

make_sandbox() {
  root=$(mktemp -d)
  mkdir -p "$root/bin" "$root/remote"
  printf 'LIVE-ORIGINAL\n' > "$root/remote/index.html"
  printf 'NEW-TEMPLATE\n'  > "$root/new.html"

  cat > "$root/bin/scp" <<SCPEOF
#!/usr/bin/env bash
src=\$2; dst=\$3
[ "\$1" = "-q" ] || { src=\$1; dst=\$2; }
if [ -n "\${SCP_FAILS:-}" ]; then exit 1; fi
cp "\$src" "\$root_remote/\$(basename "\${dst#*:}")"
SCPEOF
  sed -i '' "s|\$root_remote|$root/remote|g" "$root/bin/scp" 2>/dev/null || sed -i "s|\$root_remote|$root/remote|g" "$root/bin/scp"
  chmod +x "$root/bin/scp"

  cat > "$root/bin/ssh" <<SSHEOF
#!/usr/bin/env bash
shift
cmd="\$*"
if [ -n "\${CP_FAILS:-}" ]; then
  export PATH="$root/badbin:\$PATH"
fi
eval "\$cmd"
SSHEOF
  chmod +x "$root/bin/ssh"

  mkdir -p "$root/badbin"
  cat > "$root/badbin/cp" <<'CPEOF'
#!/usr/bin/env bash
exit 1
CPEOF
  chmod +x "$root/badbin/cp"
  echo "$root"
}

run_case() {
  local title=$1; shift
  echo "CASE $title"
  root=$(make_sandbox)
  export PATH="$root/bin:$PATH"
  cur=$(shasum -a 256 "$root/remote/index.html" | cut -d" " -f1)
  "$@" "$root" "$cur"
  status=$?
  rm -rf "$root"
  if [ "$status" -eq 0 ]; then echo "  PASS $title"; pass=$((pass + 1)); else echo "  FAIL $title"; fi
  echo
}

case_happy() {
  local root=$1 cur=$2
  out=$("$SCRIPT" fakehost "$root/remote" "$root/new.html" "$cur" 2>&1); rc=$?
  local bad_before=$fail
  [ "$rc" -eq 0 ] && ok "exit 0" || bad "exit was $rc"
  echo "$out" | grep -q "DEPLOY-OK" && ok "reported DEPLOY-OK" || bad "no DEPLOY-OK: $out"
  grep -q "NEW-TEMPLATE" "$root/remote/index.html" && ok "live file replaced" || bad "live file not replaced"
  ls "$root"/remote/index.html.bak-* >/dev/null 2>&1 && ok "backup kept" || bad "no backup"
  ls "$root"/remote/.incoming.* >/dev/null 2>&1 && bad "temp file left behind" || ok "temp file cleaned up"
  [ "$fail" -eq "$bad_before" ]
}

case_backup_fails() {
  local root=$1 cur=$2
  local bad_before=$fail
  out=$(CP_FAILS=1 "$SCRIPT" fakehost "$root/remote" "$root/new.html" "$cur" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && ok "exit non-zero ($rc)" || bad "exit was 0 despite a failed backup"
  grep -q "LIVE-ORIGINAL" "$root/remote/index.html" && ok "live file untouched" || bad "live file was replaced without a backup"
  [ "$fail" -eq "$bad_before" ]
}

case_wrong_current() {
  local root=$1 cur=$2
  local bad_before=$fail
  out=$("$SCRIPT" fakehost "$root/remote" "$root/new.html" "0000000000000000000000000000000000000000000000000000000000000000" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && ok "exit non-zero ($rc)" || bad "exit was 0 on an unexpected live file"
  echo "$out" | grep -q "not what was expected" && ok "refused a surprising live state" || bad "no refusal message"
  grep -q "LIVE-ORIGINAL" "$root/remote/index.html" && ok "live file untouched" || bad "live file was replaced"
  [ "$fail" -eq "$bad_before" ]
}

case_upload_fails() {
  local root=$1 cur=$2
  local bad_before=$fail
  out=$(SCP_FAILS=1 "$SCRIPT" fakehost "$root/remote" "$root/new.html" "$cur" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && ok "exit non-zero ($rc)" || bad "exit was 0 on a failed upload"
  grep -q "LIVE-ORIGINAL" "$root/remote/index.html" && ok "live file untouched" || bad "live file was replaced"
  [ "$fail" -eq "$bad_before" ]
}

case_noop() {
  local root=$1 cur=$2
  local bad_before=$fail
  cp "$root/new.html" "$root/remote/index.html"
  newcur=$(shasum -a 256 "$root/remote/index.html" | cut -d" " -f1)
  out=$("$SCRIPT" fakehost "$root/remote" "$root/new.html" "$newcur" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "exit 0" || bad "exit was $rc"
  echo "$out" | grep -q "DEPLOY-NOOP" && ok "recognised an identical file" || bad "no DEPLOY-NOOP: $out"
  ls "$root"/remote/index.html.bak-* >/dev/null 2>&1 && bad "made a pointless backup" || ok "no pointless backup"
  [ "$fail" -eq "$bad_before" ]
}

echo "preflight"
bash -n "$SCRIPT" && ok "syntax" || bad "syntax"
echo

run_case "(a) happy path"                       case_happy
run_case "(b) backup fails -> nothing replaced" case_backup_fails
run_case "(c) live file is not what we expect"  case_wrong_current
run_case "(d) upload fails"                     case_upload_fails
run_case "(e) identical file -> no-op"          case_noop

echo "================================================"
echo "cases passed: $pass   assertion failures: $fail"
[ "$fail" -eq 0 ] && [ "$pass" -eq 5 ] && { echo "SELFTEST=PASS"; exit 0; }
echo "SELFTEST=FAIL"
exit 1
