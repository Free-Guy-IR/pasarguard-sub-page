#!/usr/bin/env bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/Free-Guy-IR/pasarguard-sub-page/main"
PANEL_DIR="${PANEL_DIR:-/opt/pasarguard}"
TPL_DIR="${TPL_DIR:-/var/lib/pasarguard/templates}"
ADMIN=""

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s!%s %s\n' "$c_yel" "$c_off" "$*"; }
die()  { printf '%s✗%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Install the PasarGuard subscription page.

  install.sh                 install as the panel-wide page
  install.sh --admin NAME    install as a copy for one admin, and print how to point them at it
  install.sh --dir PATH      panel directory (default /opt/pasarguard)

Environment: PANEL_DIR, TPL_DIR
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --admin) ADMIN="${2:-}"; shift 2 ;;
    --dir)   PANEL_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run this as root"
command -v curl >/dev/null || die "curl is required"

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
mkdir -p "$TPL_DIR/$SUBDIR"

if [ -f "$TARGET" ]; then
  BACKUP="$TARGET.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$TARGET" "$BACKUP"
  ok "kept the previous page at $BACKUP"
fi

say "downloading the page…"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP" "$REPO_RAW/index.html" \
  || die "download failed — check the server's connectivity to github.com"
grep -q 'user.username' "$TMP" || die "what downloaded is not the template; refusing to install it"
mv "$TMP" "$TARGET"
trap - EXIT
chmod 644 "$TARGET"
ok "installed $TARGET"

set_env() {
  local key="$1" val="$2"
  if grep -qE "^[#[:space:]]*${key}[[:space:]]*=" "$ENV_FILE"; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]]*=.*|${key}=\"${val}\"|" "$ENV_FILE"
  else
    printf '%s="%s"\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

BEFORE_MODE="$(stat -c '%a' "$ENV_FILE")"
cp "$ENV_FILE" "$ENV_FILE.bak-$(date +%Y%m%d-%H%M%S)"
set_env CUSTOM_TEMPLATES_DIRECTORY "$TPL_DIR/"
[ -n "$ADMIN" ] || set_env SUBSCRIPTION_PAGE_TEMPLATE "subscription/index.html"
chmod "$BEFORE_MODE" "$ENV_FILE"
ok "updated $ENV_FILE (permissions kept at $BEFORE_MODE)"

COMPOSE="$PANEL_DIR/docker-compose.yml"
if [ -f "$COMPOSE" ] && ! grep -q "$TPL_DIR" "$COMPOSE"; then
  warn "the templates directory is not mounted into the container."
  say  "${c_dim}Add this under the pasarguard service and re-run 'docker compose up -d':${c_off}"
  say  "${c_dim}  volumes:${c_off}"
  say  "${c_dim}    - $TPL_DIR:$TPL_DIR${c_off}"
fi

if command -v docker >/dev/null && [ -f "$COMPOSE" ]; then
  say "restarting the panel…"
  (cd "$PANEL_DIR" && docker compose restart pasarguard >/dev/null 2>&1) \
    && ok "panel restarted" \
    || warn "could not restart automatically — run: cd $PANEL_DIR && docker compose restart pasarguard"
else
  warn "restart the panel yourself so it picks up the .env change"
fi

say ""
if [ -n "$ADMIN" ]; then
  ok "the page for '$ADMIN' is ready"
  say ""
  say "One step left, in the panel: Admins → $ADMIN → Subscription Template →"
  say ""
  say "    $SUBDIR/index.html"
  say ""
  say "${c_dim}That path is relative to $TPL_DIR, not an absolute path.${c_off}"
  say "${c_dim}Change the --hue value at the top of $TARGET to give this admin its own colour.${c_off}"
else
  ok "done — open any user's subscription link in a browser to see it"
fi
