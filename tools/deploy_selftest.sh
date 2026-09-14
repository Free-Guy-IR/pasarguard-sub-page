#!/usr/bin/env bash
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
SCRIPT=${DEPLOY_SCRIPT:-$HERE/deploy_template.sh}
pass=0
fail=0

note() { printf "    %-6s: %s\n" "$1" "$2"; }
ok()   { note "ok" "$1"; }
bad()  { note "FAIL" "$1"; fail=$((fail + 1)); }

sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d" " -f1
  else shasum -a 256 "$1" | cut -d" " -f1; fi
}

make_sandbox() {
  local root
  root=$(mktemp -d)
  mkdir -p "$root/bin" "$root/remote" "$root/shims"
  printf 'LIVE-ORIGINAL\n' > "$root/remote/index.html"
  printf 'NEW-TEMPLATE\n'  > "$root/new.html"

  cat > "$root/bin/scp" <<SCPEOF
#!/usr/bin/env bash
if [ -n "\${SCP_FAILS:-}" ]; then exit 1; fi
args=()
for a in "\$@"; do [ "\$a" = "-q" ] || args+=("\$a"); done
src=\${args[0]}
dst=\${args[1]#*:}
cp "\$src" "\$dst" || exit 1
if [ -n "\${UPLOAD_CORRUPT:-}" ]; then printf 'CORRUPTED\n' > "\$dst"; fi
if [ -n "\${TRUNCATE_STREAM:-}" ]; then :; fi
SCPEOF
  chmod +x "$root/bin/scp"

  cat > "$root/bin/ssh" <<SSHEOF
#!/usr/bin/env bash
shift
cmd="\$*"
export PATH="$root/shims:\$PATH"
if [ -n "\${TRUNCATE_STREAM:-}" ]; then
  head -c 40 | bash -s
  exit \$?
fi
if [ -n "\${TAMPER_PAYLOAD:-}" ]; then
  raw=\$(cat)
  decoded=\$(printf '%s' "\$raw" | { base64 -d 2>/dev/null || base64 -D 2>/dev/null; })
  printf '%s\necho TAMPERED-SCRIPT-RAN\n' "\$decoded" | base64 | tr -d '\n' | bash -c "\$cmd"
  exit \$?
fi
bash -c "\$cmd"
SSHEOF
  chmod +x "$root/bin/ssh"

  cat > "$root/shims/cp" <<'CPEOF'
#!/usr/bin/env bash
real=/bin/cp
if [ -n "${CP_FAILS:-}" ]; then exit 1; fi
if [ -n "${CP_CORRUPTS:-}" ]; then
  dest=${!#}
  printf 'BACKUP-DAMAGE\n' > "$dest"
  exit 0
fi
if [ -n "${RESTORE_FAILS:-}" ]; then
  for a in "$@"; do case "$a" in *.restore.*) exit 1 ;; esac; done
fi
exec "$real" "$@"
CPEOF
  chmod +x "$root/shims/cp"

  cat > "$root/shims/mv" <<'MVEOF'
#!/usr/bin/env bash
real=/bin/mv
if [ -n "${MV_CORRUPTS:-}" ]; then
  case "$1" in
    */.incoming.*)
      "$real" "$@" || exit 1
      printf 'MOVE-DAMAGE\n' >> "${!#}"
      exit 0
      ;;
  esac
fi
exec "$real" "$@"
MVEOF
  chmod +x "$root/shims/mv"

  cat > "$root/shims/rm" <<'RMEOF'
#!/usr/bin/env bash
real=/bin/rm
if [ -n "${RM_FAILS:-}" ]; then
  for a in "$@"; do case "$a" in *index.html.bak-*) exit 1 ;; esac; done
fi
exec "$real" "$@"
RMEOF
  chmod +x "$root/shims/rm"

  cat > "$root/shims/chmod" <<'CHEOF'
#!/usr/bin/env bash
real=/bin/chmod
if [ -n "${CHMOD_FAILS:-}" ]; then exit 1; fi
exec "$real" "$@"
CHEOF
  chmod +x "$root/shims/chmod"

  echo "$root"
}

run_case() {
  local title=$1; shift
  echo "CASE $title"
  local root status
  root=$(make_sandbox)
  export PATH="$root/bin:$PATH"
  local cur
  cur=$(sha "$root/remote/index.html")
  "$@" "$root" "$cur"
  status=$?
  rm -rf "$root"
  if [ "$status" -eq 0 ]; then echo "  PASS $title"; pass=$((pass + 1)); else echo "  FAIL $title"; fi
  echo
}

case_happy() {
  local root=$1 cur=$2 bad_before=$fail out rc
  out=$("$SCRIPT" fakehost "$root/remote" "$root/new.html" "$cur" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "exit 0" || bad "exit was $rc"
  echo "$out" | grep -q "DEPLOY-OK" && ok "reported DEPLOY-OK" || bad "no DEPLOY-OK: $out"
  grep -q "NEW-TEMPLATE" "$root/remote/index.html" && ok "live file replaced" || bad "live file not replaced"
  ls "$root"/remote/index.html.bak-* >/dev/null 2>&1 && ok "backup kept" || bad "no backup"
  ls "$root"/remote/.incoming.* >/dev/null 2>&1 && bad "temp file left behind" || ok "temp file cleaned up"
  [ "$fail" -eq "$bad_before" ]
}

case_backup_fails() {
  local root=$1 cur=$2 bad_before=$fail out rc
  out=$(CP_FAILS=1 "$SCRIPT" fakehost "$root/remote" "$root/new.html" "$cur" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && ok "exit non-zero ($rc)" || bad "exit was 0 despite a failed backup"
  grep -q "LIVE-ORIGINAL" "$root/remote/index.html" && ok "live file untouched" || bad "live file was replaced without a backup"
  echo "$out" | grep -q "DEPLOY-ABORT" && ok "gave a verdict" || bad "no verdict: $out"
  [ "$fail" -eq "$bad_before" ]
}

case_backup_does_not_verify() {
  local root=$1 cur=$2 bad_before=$fail out rc
  out=$(CP_CORRUPTS=1 "$SCRIPT" fakehost "$root/remote" "$root/new.html" "$cur" 2>&1); rc=$?
  [ "$rc" -eq 70 ] && ok "exit 70" || bad "exit was $rc, expected 70"
  echo "$out" | grep -q "backup did not verify" && ok "said the backup did not verify" || bad "no backup-verify message: $out"
  grep -q "LIVE-ORIGINAL" "$root/remote/index.html" && ok "live file untouched" || bad "live file was replaced"
  ls "$root"/remote/index.html.bak-* >/dev/null 2>&1 && bad "left the bad backup behind" || ok "removed the bad backup"
  [ "$fail" -eq "$bad_before" ]
}

case_wrong_current() {
  local root=$1 cur=$2 bad_before=$fail out rc
  out=$("$SCRIPT" fakehost "$root/remote" "$root/new.html" \
        "0000000000000000000000000000000000000000000000000000000000000000" 2>&1); rc=$?
  [ "$rc" -eq 69 ] && ok "exit 69" || bad "exit was $rc, expected 69"
  echo "$out" | grep -q "not what was expected" && ok "refused a surprising live state" || bad "no refusal message"
  echo "$out" | grep -q "DEPLOY-UNKNOWN" && bad "a clean refusal was reported as an unknown state" || ok "not muddled with an unknown state"
  grep -q "LIVE-ORIGINAL" "$root/remote/index.html" && ok "live file untouched" || bad "live file was replaced"
  [ "$fail" -eq "$bad_before" ]
}

case_guard_cannot_be_quoted_away() {
  local root=$1 cur=$2 bad_before=$fail out rc
  out=$("$SCRIPT" fakehost "$root/remote" "$root/new.html" \
        "0000000000000000000000000000000000000000000000000000000000000000' EXPECT_CUR='NEW" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && ok "exit non-zero ($rc)" || bad "a quote in the checksum turned the guard off"
  grep -q "LIVE-ORIGINAL" "$root/remote/index.html" && ok "live file untouched" || bad "live file was replaced"
  echo "$out" | grep -q "not a sha256\|not 64 hex" && ok "rejected the value outright" || bad "did not reject it: $out"
  [ "$fail" -eq "$bad_before" ]
}

case_upload_fails() {
  local root=$1 cur=$2 bad_before=$fail out rc
  out=$(SCP_FAILS=1 "$SCRIPT" fakehost "$root/remote" "$root/new.html" "$cur" 2>&1); rc=$?
  [ "$rc" -eq 66 ] && ok "exit 66" || bad "exit was $rc, expected 66"
  grep -q "LIVE-ORIGINAL" "$root/remote/index.html" && ok "live file untouched" || bad "live file was replaced"
  [ "$fail" -eq "$bad_before" ]
}

case_upload_corrupted() {
  local root=$1 cur=$2 bad_before=$fail out rc
  out=$(UPLOAD_CORRUPT=1 "$SCRIPT" fakehost "$root/remote" "$root/new.html" "$cur" 2>&1); rc=$?
  [ "$rc" -eq 67 ] && ok "exit 67" || bad "exit was $rc, expected 67"
  echo "$out" | grep -q "upload corrupted" && ok "said the upload was corrupted" || bad "no corrupted-upload message: $out"
  grep -q "LIVE-ORIGINAL" "$root/remote/index.html" && ok "live file untouched" || bad "live file was replaced"
  ls "$root"/remote/.incoming.* >/dev/null 2>&1 && bad "temp file left behind" || ok "temp file cleaned up"
  [ "$fail" -eq "$bad_before" ]
}

case_noop() {
  local root=$1 cur=$2 bad_before=$fail out rc newcur
  cp "$root/new.html" "$root/remote/index.html"
  newcur=$(sha "$root/remote/index.html")
  out=$("$SCRIPT" fakehost "$root/remote" "$root/new.html" "$newcur" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "exit 0" || bad "exit was $rc"
  echo "$out" | grep -q "DEPLOY-NOOP" && ok "recognised an identical file" || bad "no DEPLOY-NOOP: $out"
  ls "$root"/remote/index.html.bak-* >/dev/null 2>&1 && bad "made a pointless backup" || ok "no pointless backup"
  [ "$fail" -eq "$bad_before" ]
}

case_post_replace_mismatch_rollback_ok() {
  local root=$1 cur=$2 bad_before=$fail out rc
  out=$(MV_CORRUPTS=1 "$SCRIPT" fakehost "$root/remote" "$root/new.html" "$cur" 2>&1); rc=$?
  [ "$rc" -eq 71 ] && ok "exit 71" || bad "exit was $rc, expected 71"
  echo "$out" | grep -q "DEPLOY-ROLLED-BACK" && ok "reported a rollback" || bad "no DEPLOY-ROLLED-BACK: $out"
  [ "$(sha "$root/remote/index.html")" = "$cur" ] && ok "live file is the original again" || bad "live file is not the original"
  [ "$fail" -eq "$bad_before" ]
}

case_rollback_fails() {
  local root=$1 cur=$2 bad_before=$fail out rc
  out=$(MV_CORRUPTS=1 RESTORE_FAILS=1 "$SCRIPT" fakehost "$root/remote" "$root/new.html" "$cur" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && ok "exit non-zero ($rc)" || bad "exit was 0 after a failed rollback"
  echo "$out" | grep -q "DEPLOY-ROLLBACK-FAILED" && ok "said the rollback failed" || bad "no DEPLOY-ROLLBACK-FAILED: $out"
  ls "$root"/remote/index.html.bak-* >/dev/null 2>&1 && ok "backup still on disk for a manual restore" || bad "no backup left"
  ls "$root"/remote/index.html.restore.* >/dev/null 2>&1 && bad "left a half-written restore file" || ok "no half-written restore file"
  [ "$fail" -eq "$bad_before" ]
}

case_chmod_fails_before_the_point_of_no_return() {
  local root=$1 cur=$2 bad_before=$fail out rc
  out=$(CHMOD_FAILS=1 "$SCRIPT" fakehost "$root/remote" "$root/new.html" "$cur" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && ok "exit non-zero ($rc)" || bad "exit was 0 despite a failed chmod"
  grep -q "LIVE-ORIGINAL" "$root/remote/index.html" && ok "live file untouched" || bad "the live file was replaced anyway"
  echo "$out" | grep -qE "DEPLOY-(ABORT|FAILED|ROLLED-BACK|ROLLBACK-FAILED|UNKNOWN)" && ok "gave a verdict" || bad "no verdict at all: $out"
  [ "$fail" -eq "$bad_before" ]
}

case_prune_failure_does_not_fail_the_deploy() {
  local root=$1 cur=$2 bad_before=$fail out rc
  printf 'STALE\n' > "$root/remote/index.html.bak-20260101-000001"
  out=$(RM_FAILS=1 "$SCRIPT" fakehost "$root/remote" "$root/new.html" "$cur" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "exit 0 - housekeeping cannot fail a verified deploy" || bad "exit was $rc after a verified deploy"
  echo "$out" | grep -q "DEPLOY-OK" && ok "still reported DEPLOY-OK" || bad "no DEPLOY-OK: $out"
  echo "$out" | grep -q "WARN could not remove" && ok "warned about the file it could not remove" || bad "no warning"
  grep -q "NEW-TEMPLATE" "$root/remote/index.html" && ok "live file is the new one" || bad "live file is wrong"
  [ "$fail" -eq "$bad_before" ]
}

case_keeps_one_backup() {
  local root=$1 cur=$2 bad_before=$fail out rc n keptsha
  printf 'STALE-ONE\n'   > "$root/remote/index.html.bak-20260101-000001"
  printf 'STALE-TWO\n'   > "$root/remote/index.html.bak-20260101-000002"
  printf 'KEEP-ME\n'     > "$root/remote/index.html.bak-KNOWN-GOOD"
  out=$("$SCRIPT" fakehost "$root/remote" "$root/new.html" "$cur" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "exit 0" || bad "exit was $rc"
  n=$(ls "$root"/remote/index.html.bak-2* 2>/dev/null | wc -l | tr -d " ")
  [ "$n" -eq 1 ] && ok "one timestamped backup remains" || bad "$n timestamped backups remain, expected 1"
  keptsha=$(sha "$(ls "$root"/remote/index.html.bak-2*)")
  [ "$keptsha" = "$cur" ] && ok "the one kept is the file that was live" || bad "the kept backup is not the previous live file"
  [ -f "$root/remote/index.html.bak-KNOWN-GOOD" ] && ok "an operator's own copy was left alone" || bad "deleted a backup this tool did not make"
  echo "$out" | grep -q "older backups removed: 2" && ok "reported what it removed" || bad "did not report the removals: $out"
  [ "$fail" -eq "$bad_before" ]
}

case_tampered_delivery() {
  local root=$1 cur=$2 bad_before=$fail out rc
  out=$(TAMPER_PAYLOAD=1 "$SCRIPT" fakehost "$root/remote" "$root/new.html" "$cur" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && ok "exit non-zero ($rc)" || bad "an altered script was accepted"
  echo "$out" | grep -q "TAMPERED-SCRIPT-RAN" && bad "the altered script was executed" || ok "the altered script never ran"
  echo "$out" | grep -q "did not arrive intact" && ok "said the script did not arrive intact" || bad "no such message: $out"
  grep -q "LIVE-ORIGINAL" "$root/remote/index.html" && ok "live file untouched" || bad "live file was replaced"
  [ "$fail" -eq "$bad_before" ]
}

case_short_checksum_argument() {
  local root=$1 cur=$2 bad_before=$fail out rc
  out=$("$SCRIPT" fakehost "$root/remote" "$root/new.html" "${cur:0:63}" 2>&1); rc=$?
  [ "$rc" -eq 64 ] && ok "exit 64" || bad "exit was $rc, expected 64"
  echo "$out" | grep -q "not 64 hex characters" && ok "named the problem" || bad "no length message: $out"
  grep -q "LIVE-ORIGINAL" "$root/remote/index.html" && ok "live file untouched" || bad "live file was replaced"
  [ "$fail" -eq "$bad_before" ]
}

case_truncated_delivery() {
  local root=$1 cur=$2 bad_before=$fail out rc
  out=$(TRUNCATE_STREAM=1 "$SCRIPT" fakehost "$root/remote" "$root/new.html" "$cur" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && ok "exit non-zero ($rc)" || bad "a half-delivered script reported success"
  grep -q "LIVE-ORIGINAL" "$root/remote/index.html" && ok "live file untouched" || bad "live file was replaced by a half-run script"
  echo "$out" | grep -qE "did not arrive intact|DEPLOY-UNKNOWN" && ok "said the delivery was not intact" || bad "no such message: $out"
  [ "$fail" -eq "$bad_before" ]
}

case_bad_host() {
  local root=$1 cur=$2 bad_before=$fail out rc
  out=$("$SCRIPT" "-oProxyCommand=touch $root/pwned" "$root/remote" "$root/new.html" "$cur" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && ok "exit non-zero ($rc)" || bad "accepted a host that looks like an ssh option"
  [ -e "$root/pwned" ] && bad "the option was acted on" || ok "the option was never acted on"
  grep -q "LIVE-ORIGINAL" "$root/remote/index.html" && ok "live file untouched" || bad "live file was replaced"
  [ "$fail" -eq "$bad_before" ]
}

echo "preflight"
bash -n "$SCRIPT" && ok "syntax" || bad "syntax"
echo

run_case "(a) happy path"                          case_happy
run_case "(b) backup command fails"                case_backup_fails
run_case "(c) live file is not what we expect"     case_wrong_current
run_case "(d) upload fails"                        case_upload_fails
run_case "(e) identical file -> no-op"             case_noop
run_case "(f) upload lands corrupted"              case_upload_corrupted
run_case "(g) backup does not verify"              case_backup_does_not_verify
run_case "(h) mv corrupts -> rollback succeeds"    case_post_replace_mismatch_rollback_ok
run_case "(i) mv corrupts -> rollback also fails"  case_rollback_fails
run_case "(j) older backups pruned to one"         case_keeps_one_backup
run_case "(k) chmod fails before the mv"           case_chmod_fails_before_the_point_of_no_return
run_case "(l) a failed prune cannot fail a deploy" case_prune_failure_does_not_fail_the_deploy
run_case "(m) the script arrives truncated"        case_truncated_delivery
run_case "(n) a quote cannot disable the guard"    case_guard_cannot_be_quoted_away
run_case "(o) a host that looks like an option"    case_bad_host
run_case "(p) the script arrives altered"          case_tampered_delivery
run_case "(q) a checksum one character short"      case_short_checksum_argument

echo "================================================"
echo "cases passed: $pass   assertion failures: $fail"
[ "$fail" -eq 0 ] && [ "$pass" -eq 17 ] && { echo "SELFTEST=PASS"; exit 0; }
echo "SELFTEST=FAIL"
exit 1
