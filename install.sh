#!/usr/bin/env bash
set -euo pipefail
umask 022

REPO="Free-Guy-IR/pasarguard-sub-page"
REF="${REF:-dcebea305381530336e6905eebefb6f565b3cc54}"
EXPECT_SHA256="eb9d0d4997bb3ac076dc2a911777bdf78e6d3e1df6dc036bf97d887849138952"

PANEL_DIR="${PANEL_DIR:-/opt/pasarguard}"
TPL_DIR="${TPL_DIR:-/var/lib/pasarguard/templates}"
ADMIN=""
DRY=0

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s!%s %s\n' "$c_yel" "$c_off" "$*"; }
die()  { printf '%s✗%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
plan() { printf '%s· would %s%s\n' "$c_dim" "$*" "$c_off"; }

usage() {
  cat <<'EOF'
Install the PasarGuard subscription page.

  install.sh                    install as the panel-wide page
  install.sh --admin NAME       install a copy for one admin, and print how to point them at it
  install.sh --dir PATH         panel directory (default /opt/pasarguard)
  install.sh --ref TAG --sha256 H
                                install a different tag or commit, with its hash
  install.sh --dry-run          print every change it would make, and make none
  install.sh --rollback         restore the newest backup and restart
  install.sh --admin NAME --rollback
                                roll back that admin's page, not the panel-wide one

Environment: PANEL_DIR, TPL_DIR, REF
EOF
}

need_value() {
  [ "$2" -ge 2 ] || die "$1 needs a value"
  [ -n "$3" ] || die "$1 needs a non-empty value"
}

check_admin() {
  case "$1" in
    *[!A-Za-z0-9_.-]*) die "admin name may only contain letters, digits, dot, dash and underscore" ;;
  esac
  case "$1" in
    .|..) die "admin name may not be . or .. — that would write outside the templates directory" ;;
  esac
}

ROLLBACK=0
REF_OVERRIDDEN=0
SHA_OVERRIDDEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --admin)    need_value "$1" "$#" "${2:-}"; check_admin "$2"; ADMIN="$2"; shift 2 ;;
    --dir)      need_value "$1" "$#" "${2:-}"; PANEL_DIR="$2"; shift 2 ;;
    --ref)      need_value "$1" "$#" "${2:-}"; REF="$2"; REF_OVERRIDDEN=1; shift 2 ;;
    --sha256)   need_value "$1" "$#" "${2:-}"; EXPECT_SHA256="$2"; SHA_OVERRIDDEN=1; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    --rollback) ROLLBACK=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

if ! printf '%s' "$EXPECT_SHA256" | grep -qE '^[0-9a-f]{64}$'; then
  die "--sha256 must be 64 lowercase hex characters (got: ${EXPECT_SHA256:-nothing})"
fi

if [ "$REF_OVERRIDDEN" = 1 ] && [ "$SHA_OVERRIDDEN" = 0 ]; then
  die "--ref also needs --sha256 <hash>
A ref such as a branch name can change under you, and this installs the file
as root. Take the hash of the file you mean and pass it:
  curl -fsSL https://raw.githubusercontent.com/$REPO/$REF/index.html | sha256sum"
fi

[ "$(id -u)" -eq 0 ] || die "run this as root"
command -v curl >/dev/null || die "curl is required"
command -v sha256sum >/dev/null || die "sha256sum is required"

case "$TPL_DIR$PANEL_DIR" in
  *'"'*) die "paths may not contain a double quote" ;;
  *[![:print:]]*) die "paths may only contain printable characters" ;;
esac

ENV_FILE="$PANEL_DIR/.env"
[ -f "$ENV_FILE" ] || die "no .env at $ENV_FILE — pass --dir if the panel lives elsewhere"

if [ -n "$ADMIN" ]; then
  SUBDIR="$ADMIN"
else
  SUBDIR="subscription"
fi
TARGET="$TPL_DIR/$SUBDIR/index.html"

restart_panel() {
  if command -v docker >/dev/null && [ -f "$PANEL_DIR/docker-compose.yml" ]; then
    (cd "$PANEL_DIR" && docker compose up -d pasarguard >/dev/null 2>&1) \
      && ok "panel recreated with the new environment" \
      || warn "could not restart automatically — run: cd $(printf '%q' "$PANEL_DIR") && docker compose up -d pasarguard"
  else
    warn "restart the panel yourself so it picks up the change"
  fi
}

stamp_ok() {
  case "$1" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) return 0 ;;
  esac
  return 1
}

stamp_text() {
  printf '%s-%s-%s %s:%s:%s' "${1:0:4}" "${1:4:2}" "${1:6:2}" "${1:9:2}" "${1:11:2}" "${1:13:2}"
}

backups_newest_first() {
  local f base
  for f in "$1/$2"*; do
    base="${f##*/}"
    if stamp_ok "${base#"$2"}"; then printf '%s\n' "$base"; fi
  done | sort -r
}

newest_backup() {
  local name
  for name in $(backups_newest_first "$TPL_DIR/$SUBDIR" index.html.bak-); do
    printf '%s\n' "$TPL_DIR/$SUBDIR/$name"
    return 0
  done
}

MANIFEST="$PANEL_DIR/.subpage-backups.sha256"
LOCK_DIR="$PANEL_DIR/.subpage-install.lock"
LOCK_HELD=""
STAGE=""
ENV_TMP=""
ENV_ORIG=""
ENV_WORK=""
ENV_NOW=""
PAGE_TMP=""
COPY_TMP=""
DISCARD_PAGE_BAK=""
DISCARD_ENV_BAK=""
MANIFEST_TMP=""
MANIFEST_COPY=""
CAPTURE_ERR=""
CAPTURED_MODE=""
CAPTURED_ID=""
RECORDED=""

snapshot_of() {
  local s
  if s="$(LC_ALL=C stat -c '%F|%i|%s|%h|%a' "$1" 2>/dev/null)"; then
    case "$s" in
      'regular file|'*|'regular empty file|'*) printf 'file|%s\n' "${s#*|}" ;;
      'symbolic link|'*) printf 'link|%s\n' "${s#*|}" ;;
      *) printf 'other|%s\n' "${s#*|}" ;;
    esac
  elif s="$(LC_ALL=C stat -f '%HT|%i|%z|%l|%Lp' "$1" 2>/dev/null)"; then
    case "$s" in
      'Regular File|'*) printf 'file|%s\n' "${s#*|}" ;;
      'Symbolic Link|'*) printf 'link|%s\n' "${s#*|}" ;;
      *) printf 'other|%s\n' "${s#*|}" ;;
    esac
  else
    return 1
  fi
}

open_identity() { LC_ALL=C stat -L -c '%i|%s' "/dev/fd/$1" 2>/dev/null || LC_ALL=C stat -L -f '%i|%z' "/dev/fd/$1" 2>/dev/null; }

sha256_of() { sha256sum < "$1" | cut -d' ' -f1; }

capture_file() {
  local path="$1" out="$2" snap kind ino size links mode opened
  CAPTURE_ERR=""
  if ! snap="$(snapshot_of "$path")"; then CAPTURE_ERR="it could not be examined"; return 1; fi
  IFS='|' read -r kind ino size links mode <<EOF
$snap
EOF
  case "$kind" in
    file) ;;
    link) CAPTURE_ERR="it is a symbolic link"; return 1 ;;
    *) CAPTURE_ERR="it is not a regular file"; return 1 ;;
  esac
  if [ "$links" != 1 ]; then
    CAPTURE_ERR="it is also reachable under another name (a hard link), so it is not a file this installer made"
    return 1
  fi
  if ! exec 4<"$path"; then CAPTURE_ERR="it could not be opened"; return 1; fi
  opened="$(open_identity 4 || true)"
  if [ "$opened" != "$ino|$size" ]; then
    exec 4<&-
    CAPTURE_ERR="it changed while it was being opened"
    return 1
  fi
  if ! cat <&4 > "$out"; then exec 4<&-; CAPTURE_ERR="it could not be read"; return 1; fi
  exec 4<&-
  if [ "$(wc -c < "$out" | tr -d ' ')" != "$size" ]; then CAPTURE_ERR="it changed while it was being read"; return 1; fi
  CAPTURED_MODE="$mode"
  CAPTURED_ID="$ino|$size"
}

load_manifest() {
  MANIFEST_COPY=""
  [ -e "$MANIFEST" ] || [ -L "$MANIFEST" ] || return 0
  MANIFEST_COPY="$(mktemp)"
  capture_file "$MANIFEST" "$MANIFEST_COPY" || die "refusing to trust the checksum list $MANIFEST: $CAPTURE_ERR"
}

recorded_hash() {
  RECORDED=""
  [ -n "$MANIFEST_COPY" ] || return 0
  RECORDED="$(awk -v key="$1" 'NF == 2 && $2 == key && length($1) == 64 && $1 !~ /[^0-9a-f]/ { hash = $1 } END { if (hash != "") print hash }' "$MANIFEST_COPY")"
}

move_into_place() {
  local help
  help="$(mv --help 2>&1 || true)"
  case "$help" in
    *--no-target-directory*) mv -fT "$1" "$2" ;;
    *) [ ! -d "$2" ] || die "$2 is a directory"; mv -f "$1" "$2" ;;
  esac
}

page_key() { printf '%s/index.html.bak-%s' "$1" "$2"; }
env_backup_key() { printf '.env.bak-%s@%s' "$2" "$(page_key "$1" "$2")"; }
env_written_key() { printf '.env@%s' "$(page_key "$1" "$2")"; }

newest_install_after() {
  [ -n "$MANIFEST_COPY" ] || return 0
  awk -v after="$1" -v dir="$2" '
    NF == 2 && $2 ~ /^\.env@.+\/index\.html\.bak-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]$/ {
      key = substr($2, 6)
      stamp = substr(key, length(key) - 14)
      if (dir != "" && substr(key, 1, length(dir) + 1) != dir "/") next
      if (stamp "" > after "" && stamp "" > best "") best = stamp
    }
    END { if (best != "") print best }
  ' "$MANIFEST_COPY"
}

update_manifest() {
  local drop="$1"
  shift
  MANIFEST_TMP="$(mktemp "$PANEL_DIR/.subpage-backups.XXXXXXXXXX")"
  if [ -e "$MANIFEST" ] || [ -L "$MANIFEST" ]; then
    MANIFEST_COPY="$(mktemp)"
    if capture_file "$MANIFEST" "$MANIFEST_COPY"; then
      awk -v page="$drop" '!(NF == 2 && ($2 == page || substr($2, length($2) - length(page)) == "@" page))' "$MANIFEST_COPY" > "$MANIFEST_TMP"
    else
      warn "starting a new checksum list, because $MANIFEST could not be trusted: $CAPTURE_ERR"
    fi
    rm -f "$MANIFEST_COPY"
    MANIFEST_COPY=""
  fi
  [ $# -eq 0 ] || printf '%s\n' "$@" >> "$MANIFEST_TMP"
  chmod 600 "$MANIFEST_TMP"
  move_into_place "$MANIFEST_TMP" "$MANIFEST"
  MANIFEST_TMP=""
}

umask_for() {
  case "$1" in ''|*[!0-7]*) return 1 ;; esac
  printf '%03o' $(( 0777 & ~0$1 ))
}

write_new_file() {
  local mask
  mask="$(umask_for "$3")" || return 1
  ( umask "$mask"; set -o noclobber; cat "$1" > "$2" ) 2>/dev/null
}

env_set() {
  awk -v key="$1" -v val="$2" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      if (!done) { print key "=\"" val "\""; done = 1 }
      next
    }
    { print }
    END { if (!done) print key "=\"" val "\"" }
  '
}

rewrite_env() {
  if [ -n "$ADMIN" ]; then
    env_set CUSTOM_TEMPLATES_DIRECTORY "$TPL_DIR/"
  else
    env_set CUSTOM_TEMPLATES_DIRECTORY "$TPL_DIR/" | env_set SUBSCRIPTION_PAGE_TEMPLATE "subscription/index.html"
  fi
}

stamp_taken() {
  local f
  for f in "$TARGET.bak-$1" "$ENV_FILE.bak-$1"; do
    if [ -e "$f" ] || [ -L "$f" ]; then return 0; fi
  done
  return 1
}

free_stamp() {
  local tries=0
  STAMP="$(date +%Y%m%d-%H%M%S)"
  while stamp_taken "$STAMP"; do
    tries=$((tries + 1))
    [ "$tries" -le 5 ] || die "every backup name for the last few seconds is already taken (the newest tried was $TARGET.bak-$STAMP and $ENV_FILE.bak-$STAMP). Nothing was changed."
    sleep 1
    STAMP="$(date +%Y%m%d-%H%M%S)"
  done
}

same_bytes_as() {
  local copy
  copy="$(mktemp)"
  if capture_file "$1" "$copy" && [ "$(sha256_of "$copy")" = "$2" ]; then
    rm -f "$copy"
    return 0
  fi
  rm -f "$copy"
  return 1
}

place_copy() {
  local src="$1" dst="$2" mode="$3" made placed
  COPY_TMP="$(mktemp -u "${dst%/*}/.subpage-copy.XXXXXXXXXX")"
  write_new_file "$src" "$COPY_TMP" "$mode" || return 1
  chmod "$mode" "$COPY_TMP" || return 1
  [ ! -e "$dst" ] && [ ! -L "$dst" ] || return 1
  ln -n -P "$COPY_TMP" "$dst" 2>/dev/null || return 1
  made="$(snapshot_of "$COPY_TMP")" || return 1
  placed="$(snapshot_of "$dst")" || return 1
  case "$made" in 'file|'*) ;; *) return 1 ;; esac
  [ "$made" = "$placed" ] || return 1
  rm -f "$COPY_TMP"
  COPY_TMP=""
}

lock_holder() {
  local holder
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  case "$holder" in
    ''|*[!0-9]*) printf '' ;;
    *) printf '%s' "$holder" ;;
  esac
}

process_alive() {
  kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1
}

take_lock() {
  local tries=0 holder
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    [ ! -L "$LOCK_DIR" ] || die "$LOCK_DIR is a symbolic link; refusing to use it as a lock"
    holder="$(lock_holder)"
    if [ -n "$holder" ] && ! process_alive "$holder" && mkdir "$LOCK_DIR/takeover" 2>/dev/null; then
      if [ "$(lock_holder)" = "$holder" ]; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid.$$"
        mv -f "$LOCK_DIR/pid.$$" "$LOCK_DIR/pid"
        rmdir "$LOCK_DIR/takeover"
        LOCK_HELD=1
        warn "took over the lock left by process $holder, which is no longer running"
        return 0
      fi
      rmdir "$LOCK_DIR/takeover" 2>/dev/null || true
    fi
    tries=$((tries + 1))
    [ "$tries" != 10 ] || say "waiting up to two minutes for another install or rollback (process ${holder:-not recorded yet}) to finish…"
    [ "$tries" -le 1200 ] || die "another install or rollback still holds $LOCK_DIR (process ${holder:-not recorded yet}).
A holder that has exited is taken over automatically, so the lock is either held by a running
process, carries no process number, names a process number that has since been reused, or holds
a takeover/ left by an installer that crashed while taking it over. If you are sure no install
or rollback is running, remove the whole lock directory and try again:
  rm -rf -- $(printf '%q' "$LOCK_DIR")"
    sleep 0.1
  done
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  LOCK_HELD=1
}

release_lock() {
  local tries=0
  [ -n "$LOCK_HELD" ] || return 0
  LOCK_HELD=""
  [ "$(lock_holder)" = "$$" ] || return 0
  rm -f "$LOCK_DIR/pid"
  while ! rmdir "$LOCK_DIR" 2>/dev/null && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
}

cleanup() {
  [ -z "${TMP:-}" ] || rm -f "$TMP"
  [ -z "$STAGE" ] || rm -f "$STAGE"
  [ -z "$ENV_TMP" ] || rm -f "$ENV_TMP"
  [ -z "$ENV_ORIG" ] || rm -f "$ENV_ORIG"
  [ -z "$ENV_WORK" ] || rm -f "$ENV_WORK"
  [ -z "$ENV_NOW" ] || rm -f "$ENV_NOW"
  [ -z "$PAGE_TMP" ] || rm -f "$PAGE_TMP"
  [ -z "$COPY_TMP" ] || rm -f "$COPY_TMP"
  [ -z "$DISCARD_PAGE_BAK" ] || rm -f "$DISCARD_PAGE_BAK"
  [ -z "$DISCARD_ENV_BAK" ] || rm -f "$DISCARD_ENV_BAK"
  [ -z "$MANIFEST_TMP" ] || rm -f "$MANIFEST_TMP"
  [ -z "$MANIFEST_COPY" ] || rm -f "$MANIFEST_COPY"
  release_lock
}
trap cleanup EXIT
trap 'exit 130' INT TERM

refuse_linked_dirs() {
  local d
  for d in "$TPL_DIR" "$TPL_DIR/$SUBDIR"; do
    [ ! -L "$d" ] || die "$d is a symbolic link; refusing to write through it"
  done
}

new_stage() {
  STAGE="$(mktemp -u "$TPL_DIR/$SUBDIR/.index.html.XXXXXXXXXXXX")"
  [ ! -e "$STAGE" ] && [ ! -L "$STAGE" ] || die "could not pick a new temporary name in $TPL_DIR/$SUBDIR"
}

replace_target() {
  move_into_place "$STAGE" "$TARGET"
  STAGE=""
}

if [ "$ROLLBACK" = 1 ]; then
  if [ "$DRY" = 1 ]; then
    B="$(newest_backup)" || true
    [ -n "${B:-}" ] || die "no backup found in $TPL_DIR/$SUBDIR"
    plan "restore the newest backup in $TPL_DIR/$SUBDIR whose checksum was recorded when it was backed up"
    exit 0
  fi
  take_lock
  refuse_linked_dirs
  load_manifest
  B=""
  NEWEST_UNRECORDED=""
  for name in $(backups_newest_first "$TPL_DIR/$SUBDIR" index.html.bak-); do
    recorded_hash "$SUBDIR/$name"
    if [ -n "$RECORDED" ]; then B="$TPL_DIR/$SUBDIR/$name"; break; fi
    [ -n "$NEWEST_UNRECORDED" ] || NEWEST_UNRECORDED="$name"
  done
  if [ -z "$B" ]; then
    [ -n "$NEWEST_UNRECORDED" ] || die "no backup found in $TPL_DIR/$SUBDIR"
    die "refusing to restore $NEWEST_UNRECORDED, the newest backup in $TPL_DIR/$SUBDIR
(taken at $(stamp_text "${NEWEST_UNRECORDED#index.html.bak-}")): there is no checksum on record for it in $MANIFEST,
so it cannot be told apart from a file planted there. Backups made by an older installer
have none. Check that file yourself before you copy it over index.html by hand."
  fi
  if [ -n "$NEWEST_UNRECORDED" ]; then
    warn "skipping newer backups with no checksum on record; the newest of them was taken at $(stamp_text "${NEWEST_UNRECORDED#index.html.bak-}")"
  fi
  PAGE_RECORDED="$RECORDED"
  B_STAMP="${B##*/index.html.bak-}"
  EB="$ENV_FILE.bak-$B_STAMP"
  recorded_hash "$(env_backup_key "$SUBDIR" "$B_STAMP")"
  ENV_RECORDED="$RECORDED"
  recorded_hash "$(env_written_key "$SUBDIR" "$B_STAMP")"
  ENV_WRITTEN="$RECORDED"
  LATER_HERE="$(newest_install_after "$B_STAMP" "$SUBDIR")"
  LATER_ANY="$(newest_install_after "$B_STAMP" "")"
  if [ -n "$LATER_HERE" ]; then
    warn "this page was installed again at $(stamp_text "$LATER_HERE") without a backup of the page that install replaced, so the backup restored here is the older one taken at $(stamp_text "$B_STAMP")"
  fi
  say "restoring $B"
  TMP="$(mktemp)"
  capture_file "$B" "$TMP" || die "refusing to restore $B: $CAPTURE_ERR"
  [ "$(sha256_of "$TMP")" = "$PAGE_RECORDED" ] \
    || die "refusing to restore $B: its bytes do not match the checksum recorded when it was backed up"
  ENV_KEPT=""
  ENV_ALREADY=""
  ENV_NOW_HASH=""
  if [ -z "$ENV_RECORDED" ]; then
    ENV_KEPT="no checksum for a .env backup was recorded together with this page backup (an older installer made it)"
  else
    ENV_NOW="$(mktemp)"
    if ! capture_file "$ENV_FILE" "$ENV_NOW"; then
      ENV_KEPT="it could not be compared with the .env that install wrote, because $CAPTURE_ERR"
    else
      ENV_NOW_HASH="$(sha256_of "$ENV_NOW")"
      if [ "$ENV_NOW_HASH" = "$ENV_RECORDED" ]; then
        ENV_ALREADY=1
      elif [ -n "$LATER_ANY" ]; then
        ENV_KEPT="a later install, at $(stamp_text "$LATER_ANY"), relies on it as it is"
      elif [ -z "$ENV_WRITTEN" ]; then
        ENV_KEPT="no checksum for the .env that install wrote was recorded, so it cannot tell whether your .env still matches it"
      elif [ "$ENV_NOW_HASH" != "$ENV_WRITTEN" ]; then
        ENV_KEPT="it was changed after the install this rollback undoes, and restoring $EB would throw those changes away"
      else
        ENV_TMP="$(mktemp "$PANEL_DIR/.env.XXXXXXXXXX")"
        if ! capture_file "$EB" "$ENV_TMP"; then
          ENV_KEPT="refusing $EB, the .env backup taken with this page backup: $CAPTURE_ERR"
        elif [ "$(sha256_of "$ENV_TMP")" != "$ENV_RECORDED" ]; then
          ENV_KEPT="the bytes of $EB, the .env backup taken with this page backup, do not match the checksum recorded for it"
        else
          chmod "$CAPTURED_MODE" "$ENV_TMP"
        fi
        if [ -n "$ENV_KEPT" ]; then
          rm -f "$ENV_TMP"
          ENV_TMP=""
        fi
      fi
    fi
    rm -f "$ENV_NOW"
    ENV_NOW=""
  fi
  new_stage
  ( set -o noclobber; cat "$TMP" > "$STAGE" ) || die "could not create a new file in $TPL_DIR/$SUBDIR"
  replace_target
  ok "restored $TARGET"
  if [ -z "$ENV_KEPT" ] && [ -z "$ENV_ALREADY" ] && ! same_bytes_as "$ENV_FILE" "$ENV_NOW_HASH"; then
    ENV_KEPT="it changed while the page was being restored"
    rm -f "$ENV_TMP"
    ENV_TMP=""
  fi
  if [ -n "$ENV_ALREADY" ]; then
    ok "$ENV_FILE already holds what it held before that install"
  elif [ -z "$ENV_KEPT" ]; then
    move_into_place "$ENV_TMP" "$ENV_FILE"
    ENV_TMP=""
    ok "restored $ENV_FILE from $EB"
  else
    warn "left $ENV_FILE as it is: $ENV_KEPT.
  No other .env backup is ever used in its place. Check $ENV_FILE by hand if the install you undid changed it."
  fi
  release_lock
  restart_panel
  exit 0
fi

[ ! -L "$ENV_FILE" ] || die "$ENV_FILE is a symbolic link. This installer rewrites .env through a new file and a rename,
which would replace the link with a copy of what it points at. Replace the link with the file
it points at, or point --dir at the directory that holds the real .env, then run this again."

say "fetching the page (${REF})…"
TMP="$(mktemp)"
curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP" \
  "https://raw.githubusercontent.com/$REPO/$REF/index.html" \
  || die "download failed — check this server's connectivity to github.com"

GOT="$(sha256sum "$TMP" | cut -d' ' -f1)"
[ -n "$EXPECT_SHA256" ] || die "no checksum to verify against — refusing to install"
if true; then
  [ "$GOT" = "$EXPECT_SHA256" ] || die "checksum mismatch
  expected $EXPECT_SHA256
  got      $GOT
Refusing to install. Either the download was corrupted, or the file at $REF is not the one this installer was built for."
  ok "checksum verified"
fi

for marker in 'user.username' 'user.data_limit' 'bytesformat' 'cfgModal' 'QRCode'; do
  grep -q "$marker" "$TMP" || die "the downloaded file is missing '$marker' — it is not this template; refusing to install it"
done

if [ "$DRY" = 1 ]; then
  say ""
  say "${c_dim}--- dry run, nothing will change ---${c_off}"
  [ -f "$TARGET" ] && plan "back up $TARGET" || plan "create $TARGET"
  plan "write $TARGET ($(wc -c < "$TMP") bytes, sha256 ${GOT:0:16}…)"
  plan "set CUSTOM_TEMPLATES_DIRECTORY=\"$TPL_DIR/\" in $ENV_FILE"
  [ -n "$ADMIN" ] || plan "set SUBSCRIPTION_PAGE_TEMPLATE=\"subscription/index.html\" in $ENV_FILE"
  ENV_ORIG="$(mktemp)"
  if capture_file "$ENV_FILE" "$ENV_ORIG"; then
    grep -nE '^[[:space:]]*(CUSTOM_TEMPLATES_DIRECTORY|SUBSCRIPTION_PAGE_TEMPLATE)[[:space:]]*=' "$ENV_ORIG" \
      | sed "s/^/${c_dim}  existing active line: /;s/$/${c_off}/" || true
  else
    warn "a real run would refuse to edit $ENV_FILE: $CAPTURE_ERR"
  fi
  plan "restart the panel"
  [ -n "$ADMIN" ] && plan "print the Subscription Template path for '$ADMIN'"
  exit 0
fi

take_lock
refuse_linked_dirs
mkdir -p "$TPL_DIR/$SUBDIR"
refuse_linked_dirs
ENV_ORIG="$(mktemp)"
capture_file "$ENV_FILE" "$ENV_ORIG" || die "refusing to edit $ENV_FILE: $CAPTURE_ERR.
This installer reads .env once, as a single regular file, and writes the new one through a new
file and a rename. Replace a link with the file it points at, or point --dir at the directory
that holds the real .env, then run this again. Nothing was changed."
ENV_MODE="$CAPTURED_MODE"
ENV_HASH="$(sha256_of "$ENV_ORIG")"
umask_for "$ENV_MODE" >/dev/null || die "could not read the permissions of $ENV_FILE. Nothing was changed."
ENV_WORK="$(mktemp)"
rewrite_env < "$ENV_ORIG" > "$ENV_WORK"
ENV_NEW_HASH="$(sha256_of "$ENV_WORK")"
DUPES="$(grep -cE '^[[:space:]]*CUSTOM_TEMPLATES_DIRECTORY[[:space:]]*=' "$ENV_WORK" || true)"
free_stamp
new_stage
( set -o noclobber; cat "$TMP" > "$STAGE" ) || die "could not create a new file in $TPL_DIR/$SUBDIR"
BACKUP=""
PAGE_HASH=""
PAGE_ID=""
if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
  PAGE_TMP="$(mktemp)"
  if capture_file "$TARGET" "$PAGE_TMP"; then
    PAGE_HASH="$(sha256_of "$PAGE_TMP")"
    PAGE_ID="$CAPTURED_ID"
    place_copy "$PAGE_TMP" "$TARGET.bak-$STAMP" "$CAPTURED_MODE" \
      || die "could not keep the previous page as $TARGET.bak-$STAMP: something of that name is already there, or it could not be written. Nothing was changed."
    BACKUP="$TARGET.bak-$STAMP"
    DISCARD_PAGE_BAK="$BACKUP"
  else
    warn "kept no backup of the previous $TARGET, because $CAPTURE_ERR; --rollback cannot bring it back"
  fi
  rm -f "$PAGE_TMP"
  PAGE_TMP=""
fi
ENV_BAK="$ENV_FILE.bak-$STAMP"
place_copy "$ENV_ORIG" "$ENV_BAK" "$ENV_MODE" \
  || die "could not keep the current .env as $ENV_BAK: something of that name is already there, or it could not be written. Nothing was changed."
DISCARD_ENV_BAK="$ENV_BAK"
PAGE_RECORDED=""
if [ -n "$BACKUP" ]; then
  update_manifest "$(page_key "$SUBDIR" "$STAMP")" \
    "$PAGE_HASH  $(page_key "$SUBDIR" "$STAMP")" \
    "$ENV_HASH  $(env_backup_key "$SUBDIR" "$STAMP")"
  PAGE_RECORDED=1
  DISCARD_PAGE_BAK=""
  DISCARD_ENV_BAK=""
  ok "kept the previous page at $BACKUP and the previous .env at $ENV_BAK"
fi
if [ -n "$BACKUP" ]; then
  PAGE_TMP="$(mktemp)"
  if ! capture_file "$TARGET" "$PAGE_TMP" || [ "$CAPTURED_ID" != "$PAGE_ID" ] || [ "$(sha256_of "$PAGE_TMP")" != "$PAGE_HASH" ]; then
    rm -f "$PAGE_TMP"
    PAGE_TMP=""
    update_manifest "$(page_key "$SUBDIR" "$STAMP")"
    DISCARD_PAGE_BAK="$BACKUP"
    DISCARD_ENV_BAK="$ENV_BAK"
    die "left $TARGET as it is, because it changed after this run backed it up; the backups this run made were discarded. Nothing was changed; run this again."
  fi
  rm -f "$PAGE_TMP"
  PAGE_TMP=""
fi
replace_target
DISCARD_ENV_BAK=""
ok "installed $TARGET"
[ -n "$BACKUP" ] || ok "kept the previous .env at $ENV_BAK"
if [ -n "$BACKUP" ]; then
  PAGE_TMP="$(mktemp)"
  if ! capture_file "$BACKUP" "$PAGE_TMP" || [ "$(sha256_of "$PAGE_TMP")" != "$PAGE_HASH" ]; then
    update_manifest "$(page_key "$SUBDIR" "$STAMP")"
    PAGE_RECORDED=""
    warn "$BACKUP changed after its checksum was recorded, so that record was removed and --rollback will skip it"
  fi
  rm -f "$PAGE_TMP"
  PAGE_TMP=""
fi

ENV_NOW="$(mktemp)"
capture_file "$ENV_FILE" "$ENV_NOW" || die "left $ENV_FILE as it is, because $CAPTURE_ERR.
The new page is live and the previous page and .env are kept; run this again to update $ENV_FILE."
[ "$(sha256_of "$ENV_NOW")" = "$ENV_HASH" ] || die "left $ENV_FILE as it is, because it changed while the page was being installed.
The new page is live and the previous page and .env are kept; run this again to update $ENV_FILE."
ENV_TMP="$(mktemp -u "$PANEL_DIR/.env.XXXXXXXXXX")"
write_new_file "$ENV_WORK" "$ENV_TMP" "$ENV_MODE" && chmod "$ENV_MODE" "$ENV_TMP" \
  || die "could not create a new file in $PANEL_DIR; $ENV_FILE was left as it is"
if [ "$PAGE_RECORDED" = 1 ]; then
  update_manifest "$(page_key "$SUBDIR" "$STAMP")" \
    "$PAGE_HASH  $(page_key "$SUBDIR" "$STAMP")" \
    "$ENV_HASH  $(env_backup_key "$SUBDIR" "$STAMP")" \
    "$ENV_NEW_HASH  $(env_written_key "$SUBDIR" "$STAMP")"
else
  update_manifest "$(page_key "$SUBDIR" "$STAMP")" \
    "$ENV_NEW_HASH  $(env_written_key "$SUBDIR" "$STAMP")"
fi
move_into_place "$ENV_TMP" "$ENV_FILE"
ENV_TMP=""
ok "updated $ENV_FILE (permissions kept at $ENV_MODE)"

[ "$DUPES" = 1 ] || warn "CUSTOM_TEMPLATES_DIRECTORY appears $DUPES times — check $ENV_FILE by hand"

COMPOSE="$PANEL_DIR/docker-compose.yml"
if [ -f "$COMPOSE" ] && ! grep -q "$TPL_DIR" "$COMPOSE" && ! grep -q "$(dirname "$TPL_DIR")" "$COMPOSE"; then
  warn "the templates directory is not mounted into the container."
  say  "${c_dim}Add this under the pasarguard service, then 'docker compose up -d':${c_off}"
  say  "${c_dim}  volumes:${c_off}"
  say  "${c_dim}    - $TPL_DIR:$TPL_DIR${c_off}"
fi

release_lock
restart_panel

say ""
if [ -n "$ADMIN" ]; then
  ok "the page for '$ADMIN' is ready"
  say ""
  say "One step left, in the panel: Admins → $ADMIN → Subscription Template →"
  say ""
  say "    $SUBDIR/index.html"
  say ""
  say "${c_dim}That path is relative to $TPL_DIR, not an absolute path.${c_off}"
  say "${c_dim}Change --primary at the top of $TARGET to give this admin its own colour.${c_off}"
else
  ok "done — open any user's subscription link in a browser to see it"
fi

if [ -n "$BACKUP" ]; then
  say ""
  say "To go back:"
  if [ -n "$ADMIN" ]; then
    say "    $0 --admin $(printf '%q' "$ADMIN") --rollback"
  else
    say "    $0 --rollback"
  fi
fi
