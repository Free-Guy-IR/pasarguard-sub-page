#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: deploy_template.sh <ssh-host> <remote-dir> <local-file> <expected-current-sha256|NEW>" >&2
  exit 64
}

host=${1:-}; dir=${2:-}; local_file=${3:-}; expect_cur=${4:-}
[ -z "$host" ] || [ -z "$dir" ] || [ -z "$local_file" ] || [ -z "$expect_cur" ] && usage
[ -f "$local_file" ] || { echo "DEPLOY-ABORT local file not found: $local_file" >&2; exit 65; }

want=$(shasum -a 256 "$local_file" | cut -d" " -f1)
echo "  local file sha256 : $want"

scp -q "$local_file" "$host:$dir/.incoming.$$" || {
  echo "DEPLOY-ABORT upload failed" >&2
  ssh "$host" "rm -f '$dir/.incoming.$$'" || true
  exit 66
}

ssh "$host" "EXPECT_CUR='$expect_cur' WANT='$want' DIR='$dir' TMP='$dir/.incoming.$$' bash -s" <<'REMOTE'
set -euo pipefail

cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

live="$DIR/index.html"
stamp=$(date +%Y%m%d-%H%M%S)
backup="$DIR/index.html.bak-$stamp"

got=$(sha256sum "$TMP" | cut -d' ' -f1)
if [ "$got" != "$WANT" ]; then
  echo "DEPLOY-ABORT upload corrupted: got $got"
  exit 67
fi

if [ ! -f "$live" ]; then
  echo "DEPLOY-ABORT no live template at $live"
  exit 68
fi

cur=$(sha256sum "$live" | cut -d' ' -f1)
if [ "$EXPECT_CUR" != "NEW" ] && [ "$cur" != "$EXPECT_CUR" ]; then
  echo "DEPLOY-ABORT live template is not what was expected"
  echo "  expected $EXPECT_CUR"
  echo "  found    $cur"
  exit 69
fi

if [ "$cur" = "$WANT" ]; then
  echo "DEPLOY-NOOP live template already matches"
  exit 0
fi

cp -a "$live" "$backup"
backup_sha=$(sha256sum "$backup" | cut -d' ' -f1)
if [ "$backup_sha" != "$cur" ]; then
  echo "DEPLOY-ABORT backup did not verify, nothing was replaced"
  rm -f "$backup"
  exit 70
fi
echo "  backup verified   : $(basename "$backup") ($backup_sha)"

mv "$TMP" "$live"
chmod 644 "$live"

now=$(sha256sum "$live" | cut -d' ' -f1)
if [ "$now" != "$WANT" ]; then
  echo "DEPLOY-FAILED live is $now, restoring $(basename "$backup")"
  cp -a "$backup" "$live"
  restored=$(sha256sum "$live" | cut -d' ' -f1)
  if [ "$restored" = "$cur" ]; then
    echo "DEPLOY-ROLLED-BACK live is back to $restored"
  else
    echo "DEPLOY-ROLLBACK-FAILED live is $restored, expected $cur"
  fi
  exit 71
fi

echo "DEPLOY-OK live=$now rollback=$(basename "$backup")"
REMOTE
