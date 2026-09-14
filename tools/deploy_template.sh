#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: deploy_template.sh <ssh-host> <remote-dir> <local-file> <expected-current-sha256|NEW>" >&2
  exit 64
}

host=${1:-}
dir=${2:-}
local_file=${3:-}
expect_cur=${4:-}
[ -z "$host" ] || [ -z "$dir" ] || [ -z "$local_file" ] || [ -z "$expect_cur" ] && usage

case "$host" in
  -*|*[!A-Za-z0-9._@-]*) echo "DEPLOY-ABORT refusing host $host" >&2; exit 64 ;;
esac
case "$dir" in
  /*[!A-Za-z0-9._/-]*|[!/]*) echo "DEPLOY-ABORT refusing directory $dir" >&2; exit 64 ;;
  *..*) echo "DEPLOY-ABORT refusing directory $dir" >&2; exit 64 ;;
esac
if [ "$expect_cur" != "NEW" ]; then
  case "$expect_cur" in
    *[!0-9a-f]*|"") echo "DEPLOY-ABORT expected checksum is not a sha256" >&2; exit 64 ;;
  esac
  [ ${#expect_cur} -eq 64 ] || { echo "DEPLOY-ABORT expected checksum is not 64 hex characters" >&2; exit 64; }
fi
[ -f "$local_file" ] || { echo "DEPLOY-ABORT local file not found: $local_file" >&2; exit 65; }

if command -v sha256sum >/dev/null 2>&1; then
  want=$(sha256sum "$local_file" | cut -d' ' -f1)
else
  want=$(shasum -a 256 "$local_file" | cut -d' ' -f1)
fi
echo "  local file sha256 : $want"

stamp=$(date +%Y%m%d-%H%M%S)
tmp_remote="$dir/.incoming.$stamp.$$"

scp -q "$local_file" "$host:$tmp_remote" || {
  echo "DEPLOY-ABORT upload failed" >&2
  ssh "$host" "rm -f $(printf %q "$tmp_remote")" >/dev/null 2>&1 || true
  exit 66
}

remote_script=$(cat <<REMOTE
set -uo pipefail

DIR=$(printf %q "$dir")
TMP=$(printf %q "$tmp_remote")
WANT=$(printf %q "$want")
EXPECT_CUR=$(printf %q "$expect_cur")
STAMP=$(printf %q "$stamp")

hashof() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "\$1" | cut -d' ' -f1
  else shasum -a 256 "\$1" | cut -d' ' -f1; fi
}

live="\$DIR/index.html"
backup="\$DIR/index.html.bak-\$STAMP"

finish() { rm -f "\$TMP" 2>/dev/null || true; }
trap finish EXIT

got=\$(hashof "\$TMP" 2>/dev/null) || true
if [ "\$got" != "\$WANT" ]; then
  echo "DEPLOY-ABORT upload corrupted: got \${got:-nothing}"
  exit 67
fi

if [ ! -f "\$live" ]; then
  echo "DEPLOY-ABORT no live template at \$live"
  exit 68
fi

cur=\$(hashof "\$live")
if [ "\$EXPECT_CUR" != "NEW" ] && [ "\$cur" != "\$EXPECT_CUR" ]; then
  echo "DEPLOY-ABORT live template is not what was expected"
  echo "  expected \$EXPECT_CUR"
  echo "  found    \$cur"
  exit 69
fi

if [ "\$cur" = "\$WANT" ]; then
  echo "DEPLOY-NOOP live template already matches"
  exit 0
fi

if ! chmod 644 "\$TMP"; then
  echo "DEPLOY-ABORT could not set the mode on the uploaded file, nothing was replaced"
  exit 72
fi

if ! cp -a "\$live" "\$backup"; then
  echo "DEPLOY-ABORT backup failed, nothing was replaced"
  rm -f "\$backup" 2>/dev/null || true
  exit 70
fi
backup_sha=\$(hashof "\$backup")
if [ "\$backup_sha" != "\$cur" ]; then
  echo "DEPLOY-ABORT backup did not verify, nothing was replaced"
  rm -f "\$backup" 2>/dev/null || true
  exit 70
fi
echo "  backup verified   : \$(basename "\$backup") (\$backup_sha)"

if ! mv "\$TMP" "\$live"; then
  echo "DEPLOY-ABORT could not move the new file into place, nothing was replaced"
  exit 73
fi

now=\$(hashof "\$live" 2>/dev/null) || true
if [ "\$now" != "\$WANT" ]; then
  echo "DEPLOY-FAILED live is \${now:-unreadable}, restoring \$(basename "\$backup")"
  if cp -a "\$backup" "\$live.restore.\$\$" && mv "\$live.restore.\$\$" "\$live"; then
    restored=\$(hashof "\$live" 2>/dev/null) || true
    if [ "\$restored" = "\$cur" ]; then
      echo "DEPLOY-ROLLED-BACK live is back to \$restored"
    else
      echo "DEPLOY-ROLLBACK-FAILED live is \${restored:-unreadable}, expected \$cur"
    fi
  else
    rm -f "\$live.restore.\$\$" 2>/dev/null || true
    echo "DEPLOY-ROLLBACK-FAILED could not restore \$(basename "\$backup"), the live file is still wrong"
  fi
  exit 71
fi

echo "DEPLOY-OK live=\$now rollback=\$(basename "\$backup")"

pruned=0
for stale in "\$DIR"/index.html.bak-*; do
  [ -e "\$stale" ] || continue
  [ "\$stale" = "\$backup" ] && continue
  case "\$(basename "\$stale")" in
    (index.html.bak-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9])
      if rm -f "\$stale"; then
        pruned=\$((pruned + 1))
      else
        echo "  WARN could not remove \$(basename "\$stale")"
      fi
      ;;
    (*)
      echo "  kept \$(basename "\$stale") - not a backup this tool made"
      ;;
  esac
done
[ "\$pruned" -gt 0 ] && echo "  older backups removed: \$pruned"
exit 0
REMOTE
)

if command -v sha256sum >/dev/null 2>&1; then
  script_sha=$(printf '%s' "$remote_script" | sha256sum | cut -d' ' -f1)
else
  script_sha=$(printf '%s' "$remote_script" | shasum -a 256 | cut -d' ' -f1)
fi
payload=$(printf '%s' "$remote_script" | base64 | tr -d '\n')

set +e
output=$(printf '%s' "$payload" | ssh "$host" "
  set -u
  b64=\$(mktemp) || exit 74
  sh=\$(mktemp) || exit 74
  trap 'rm -f \"\$b64\" \"\$sh\"' EXIT
  cat > \"\$b64\"
  base64 -d \"\$b64\" > \"\$sh\" 2>/dev/null ||
  base64 -D \"\$b64\" > \"\$sh\" 2>/dev/null ||
  openssl base64 -d -A -in \"\$b64\" > \"\$sh\" 2>/dev/null ||
  { echo 'DEPLOY-ABORT the script did not arrive intact'; exit 75; }
  if command -v sha256sum >/dev/null 2>&1; then actual=\$(sha256sum \"\$sh\" | cut -d' ' -f1)
  else actual=\$(shasum -a 256 \"\$sh\" | cut -d' ' -f1); fi
  if [ \"\$actual\" != '$script_sha' ]; then
    echo 'DEPLOY-ABORT the script did not arrive intact'
    exit 75
  fi
  bash \"\$sh\"
" 2>&1)
rc=$?
set -e

printf '%s\n' "$output"

case "$output" in
  *DEPLOY-OK*|*DEPLOY-NOOP*)
    [ "$rc" -eq 0 ] || { echo "DEPLOY-UNKNOWN the remote reported success but exited $rc" >&2; exit "$rc"; }
    exit 0
    ;;
  *DEPLOY-ABORT*|*DEPLOY-FAILED*|*DEPLOY-ROLLED-BACK*|*DEPLOY-ROLLBACK-FAILED*)
    [ "$rc" -eq 0 ] && rc=1
    exit "$rc"
    ;;
  *)
    echo "DEPLOY-UNKNOWN the remote produced no verdict (exit $rc) - check the live file by hand before retrying" >&2
    [ "$rc" -eq 0 ] && rc=76
    exit "$rc"
    ;;
esac
