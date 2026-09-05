#!/usr/bin/env bash
set -euo pipefail

REPO="Free-Guy-IR/pasarguard-sub-page"
REF="${REF:-v1.0.0}"
EXPECT_SHA256="0e81b7388163893e7c886b556d34ce8835fd60332f085262d72a77253f47cb49"

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
  install.sh --ref TAG          install a specific tag or commit instead of the pinned one
  install.sh --dry-run          print every change it would make, and make none
  install.sh --rollback         restore the newest backup and restart

Environment: PANEL_DIR, TPL_DIR, REF
EOF
}

need_value() {
  # need_value <option> <remaining-arg-count> <value>
  [ "$2" -ge 2 ] || die "$1 needs a value"
  [ -n "$3" ] || die "$1 needs a non-empty value"
}

ROLLBACK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --admin)    need_value "$1" "$#" "${2:-}"; ADMIN="$2"; shift 2 ;;
    --dir)      need_value "$1" "$#" "${2:-}"; PANEL_DIR="$2"; shift 2 ;;
    --ref)      need_value "$1" "$#" "${2:-}"; REF="$2"; EXPECT_SHA256=""; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    --rollback) ROLLBACK=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run this as root"
command -v curl >/dev/null || die "curl is required"
command -v sha256sum >/dev/null || die "sha256sum is required"

ENV_FILE="$PANEL_DIR/.env"
[ -f "$ENV_FILE" ] || die "no .env at $ENV_FILE — pass --dir if the panel lives elsewhere"

if [ -n "$ADMIN" ]; then
  case "$ADMIN" in
    *[!A-Za-z0-9_.-]*) die "admin name may only contain letters, digits, dot, dash and underscore" ;;
  esac
  SUBDIR="$ADMIN"
else
  SUBDIR="subscription"
fi
TARGET="$TPL_DIR/$SUBDIR/index.html"

restart_panel() {
  if command -v docker >/dev/null && [ -f "$PANEL_DIR/docker-compose.yml" ]; then
    (cd "$PANEL_DIR" && docker compose restart pasarguard >/dev/null 2>&1) \
      && ok "panel restarted" \
      || warn "could not restart automatically — run: cd $PANEL_DIR && docker compose restart pasarguard"
  else
    warn "restart the panel yourself so it picks up the change"
  fi
}

newest_backup() {
  ls -1t "$TPL_DIR/$SUBDIR"/index.html.bak-* 2>/dev/null | head -1
}

if [ "$ROLLBACK" = 1 ]; then
  B="$(newest_backup)" || true
  [ -n "${B:-}" ] || die "no backup found in $TPL_DIR/$SUBDIR"
  say "restoring $B"
  if [ "$DRY" = 1 ]; then plan "copy $B over $TARGET"; exit 0; fi
  cp -p "$B" "$TARGET"
  ok "restored"
  restart_panel
  exit 0
fi

say "fetching the page (${REF})…"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP" \
  "https://raw.githubusercontent.com/$REPO/$REF/index.html" \
  || die "download failed — check this server's connectivity to github.com"

GOT="$(sha256sum "$TMP" | cut -d' ' -f1)"
if [ -n "$EXPECT_SHA256" ]; then
  [ "$GOT" = "$EXPECT_SHA256" ] || die "checksum mismatch
  expected $EXPECT_SHA256
  got      $GOT
Refusing to install. Either the download was corrupted, or the file at $REF is not the one this installer was built for."
  ok "checksum verified"
else
  warn "installing $REF without a pinned checksum (sha256 $GOT)"
fi
grep -q 'user.username' "$TMP" || die "what downloaded is not the template; refusing to install it"

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

mkdir -p "$TPL_DIR/$SUBDIR"
BACKUP=""
if [ -f "$TARGET" ]; then
  BACKUP="$TARGET.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p "$TARGET" "$BACKUP"
  ok "kept the previous page at $BACKUP"
fi
mv "$TMP" "$TARGET"
trap - EXIT
chmod 644 "$TARGET"
ok "installed $TARGET"

set_env() {
  # Replace every ACTIVE assignment of $1 with one canonical line. Commented
  # lines are left exactly as they are: an .env commonly carries commented
  # examples of the same key, and turning those into live settings would give
  # the panel two conflicting values.
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
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
}

BEFORE_MODE="$(stat -c '%a' "$ENV_FILE")"
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
