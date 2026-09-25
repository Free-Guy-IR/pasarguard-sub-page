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

ENV_FILE="$PANEL_DIR/.env"
[ -f "$ENV_FILE" ] || die "no .env at $ENV_FILE — pass --dir if the panel lives elsewhere"

case "$TPL_DIR$PANEL_DIR" in
  *'"'*) die "paths may not contain a double quote" ;;
esac

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
      || warn "could not restart automatically — run: cd $PANEL_DIR && docker compose up -d pasarguard"
  else
    warn "restart the panel yourself so it picks up the change"
  fi
}

newest_backup() {
  ls -1 "$TPL_DIR/$SUBDIR"/index.html.bak-* 2>/dev/null | sort | tail -1
}

mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

MANIFEST="$PANEL_DIR/.subpage-backups.sha256"
LOCK_DIR="$PANEL_DIR/.subpage-install.lock"
LOCK_HELD=""
STAGE=""
ENV_TMP=""
PAGE_TMP=""
MANIFEST_TMP=""
CAPTURE_ERR=""
CAPTURED_MODE=""
RECORDED=""

snapshot_of() {
  local s
  if s="$(stat -c '%F|%i|%s|%h|%a' "$1" 2>/dev/null)"; then
    case "$s" in
      'regular file|'*|'regular empty file|'*) printf 'file|%s\n' "${s#*|}" ;;
      'symbolic link|'*) printf 'link|%s\n' "${s#*|}" ;;
      *) printf 'other|%s\n' "${s#*|}" ;;
    esac
  elif s="$(stat -f '%HT|%i|%z|%l|%Lp' "$1" 2>/dev/null)"; then
    case "$s" in
      'Regular File|'*) printf 'file|%s\n' "${s#*|}" ;;
      'Symbolic Link|'*) printf 'link|%s\n' "${s#*|}" ;;
      *) printf 'other|%s\n' "${s#*|}" ;;
    esac
  else
    return 1
  fi
}

open_identity() { stat -L -c '%i|%s' "/dev/fd/$1" 2>/dev/null || stat -L -f '%i|%z' "/dev/fd/$1" 2>/dev/null; }

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
}

recorded_hash() {
  RECORDED=""
  [ -e "$MANIFEST" ] || [ -L "$MANIFEST" ] || return 0
  MANIFEST_TMP="$(mktemp)"
  capture_file "$MANIFEST" "$MANIFEST_TMP" || die "refusing to trust the checksum list $MANIFEST: $CAPTURE_ERR"
  RECORDED="$(awk -v key="$1" 'NF == 2 && $2 == key && length($1) == 64 && $1 !~ /[^0-9a-f]/ { hash = $1 } END { if (hash != "") print hash }' "$MANIFEST_TMP")"
  rm -f "$MANIFEST_TMP"
  MANIFEST_TMP=""
}

move_into_place() {
  local help
  help="$(mv --help 2>&1 || true)"
  case "$help" in
    *--no-target-directory*) mv -fT "$1" "$2" ;;
    *) [ ! -d "$2" ] || die "$2 is a directory"; mv -f "$1" "$2" ;;
  esac
}

record_backup() {
  local backup="$1" hash
  PAGE_TMP="$(mktemp)"
  if ! capture_file "$backup" "$PAGE_TMP"; then
    warn "kept the previous page at $backup but did not record its checksum ($CAPTURE_ERR), so --rollback will refuse it"
    rm -f "$PAGE_TMP"
    PAGE_TMP=""
    return 0
  fi
  hash="$(sha256_of "$PAGE_TMP")"
  rm -f "$PAGE_TMP"
  PAGE_TMP=""
  MANIFEST_TMP="$(mktemp "$PANEL_DIR/.subpage-backups.XXXXXXXXXX")"
  if [ -e "$MANIFEST" ] || [ -L "$MANIFEST" ]; then
    if ! capture_file "$MANIFEST" "$MANIFEST_TMP"; then
      warn "starting a new checksum list, because $MANIFEST could not be trusted: $CAPTURE_ERR"
      : > "$MANIFEST_TMP"
    fi
  fi
  printf '%s  %s\n' "$hash" "$SUBDIR/${backup##*/}" >> "$MANIFEST_TMP"
  chmod 600 "$MANIFEST_TMP"
  move_into_place "$MANIFEST_TMP" "$MANIFEST"
  MANIFEST_TMP=""
}

lock_holder() {
  local holder
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  case "$holder" in
    ''|*[!0-9]*) printf '' ;;
    *) printf '%s' "$holder" ;;
  esac
}

take_lock() {
  local tries=0 holder
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    [ ! -L "$LOCK_DIR" ] || die "$LOCK_DIR is a symbolic link; refusing to use it as a lock"
    holder="$(lock_holder)"
    if [ -n "$holder" ] && ! ps -p "$holder" >/dev/null 2>&1 && mkdir "$LOCK_DIR/takeover" 2>/dev/null; then
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
    [ "$tries" -le 1200 ] || die "another install or rollback still holds $LOCK_DIR (process ${holder:-not recorded yet}).
If you are sure none is running, remove the lock and try again:
  rm -f \"$LOCK_DIR/pid\"; rmdir \"$LOCK_DIR\""
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
  [ -z "$PAGE_TMP" ] || rm -f "$PAGE_TMP"
  [ -z "$MANIFEST_TMP" ] || rm -f "$MANIFEST_TMP"
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
    say "restoring $B"
    plan "copy $B over $TARGET, if its checksum matches the one recorded when it was backed up"
    exit 0
  fi
  take_lock
  refuse_linked_dirs
  B="$(newest_backup)" || true
  [ -n "${B:-}" ] || die "no backup found in $TPL_DIR/$SUBDIR"
  EB="$(ls -1 "$PANEL_DIR"/.env.bak-* 2>/dev/null | sort | tail -1 || true)"
  say "restoring $B"
  recorded_hash "$SUBDIR/${B##*/}"
  [ -n "$RECORDED" ] || die "refusing to restore $B: there is no checksum on record for it in $MANIFEST,
so it cannot be told apart from a file planted in $TPL_DIR/$SUBDIR (backups made by
an older installer have none). Look at it first; if it is the page you want, restore it by hand:
  cp \"$B\" \"$TARGET\""
  TMP="$(mktemp)"
  capture_file "$B" "$TMP" || die "refusing to restore $B: $CAPTURE_ERR"
  [ "$(sha256_of "$TMP")" = "$RECORDED" ] \
    || die "refusing to restore $B: its bytes do not match the checksum recorded when it was backed up"
  if [ -n "${EB:-}" ]; then
    ENV_TMP="$(mktemp "$PANEL_DIR/.env.XXXXXXXXXX")"
    capture_file "$EB" "$ENV_TMP" || die "refusing to restore $EB: $CAPTURE_ERR"
    chmod "$CAPTURED_MODE" "$ENV_TMP"
  fi
  new_stage
  ( set -o noclobber; cat "$TMP" > "$STAGE" ) || die "could not create a new file in $TPL_DIR/$SUBDIR"
  replace_target
  ok "restored $TARGET"
  if [ -n "${EB:-}" ]; then
    move_into_place "$ENV_TMP" "$ENV_FILE"
    ENV_TMP=""
    ok "restored $ENV_FILE from $EB"
  fi
  release_lock
  restart_panel
  exit 0
fi

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
  grep -nE '^[[:space:]]*(CUSTOM_TEMPLATES_DIRECTORY|SUBSCRIPTION_PAGE_TEMPLATE)[[:space:]]*=' "$ENV_FILE" \
    | sed "s/^/${c_dim}  existing active line: /;s/$/${c_off}/" || true
  plan "restart the panel"
  [ -n "$ADMIN" ] && plan "print the Subscription Template path for '$ADMIN'"
  exit 0
fi

take_lock
refuse_linked_dirs
mkdir -p "$TPL_DIR/$SUBDIR"
refuse_linked_dirs
new_stage
( set -o noclobber; cat "$TMP" > "$STAGE" ) || die "could not create a new file in $TPL_DIR/$SUBDIR"
BACKUP=""
if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
  BACKUP="$TARGET.bak-$(date +%Y%m%d-%H%M%S)"
  ln -P "$TARGET" "$BACKUP" 2>/dev/null \
    || die "could not keep the previous page as $BACKUP: something of that name is already there. Nothing was changed."
  ok "kept the previous page at $BACKUP"
fi
replace_target
ok "installed $TARGET"
[ -z "$BACKUP" ] || record_backup "$BACKUP"

set_env() {
  local key="$1" val="$2" tmp
  tmp="$(mktemp)"
  awk -v key="$key" -v val="$val" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      if (!done) { print key "=\"" val "\""; done = 1 }
      next
    }
    { print }
    END { if (!done) print key "=\"" val "\"" }
  ' "$ENV_FILE" > "$tmp"
  chmod "$(mode_of "$ENV_FILE")" "$tmp"
  mv -f "$tmp" "$ENV_FILE"
}

BEFORE_MODE="$(mode_of "$ENV_FILE")"
cp -p "$ENV_FILE" "$ENV_FILE.bak-$(date +%Y%m%d-%H%M%S)"
set_env CUSTOM_TEMPLATES_DIRECTORY "$TPL_DIR/"
[ -n "$ADMIN" ] || set_env SUBSCRIPTION_PAGE_TEMPLATE "subscription/index.html"
chmod "$BEFORE_MODE" "$ENV_FILE"
ok "updated $ENV_FILE (permissions kept at $BEFORE_MODE)"

DUPES="$(grep -cE '^[[:space:]]*CUSTOM_TEMPLATES_DIRECTORY[[:space:]]*=' "$ENV_FILE" || true)"
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
  say "    $0 --rollback"
  say "${c_dim}or: cp \"$BACKUP\" \"$TARGET\"${c_off}"
fi
