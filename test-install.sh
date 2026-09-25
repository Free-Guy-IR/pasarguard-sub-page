#!/usr/bin/env bash
set -u

SCRIPT="${1:-./install.sh}"
[ -f "$SCRIPT" ] || { echo "usage: test-install.sh [path/to/install.sh]"; exit 2; }

pass=0; fail=0
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_off=$'\033[0m'

expect_fail() {
  local what="$1" reason="$2"; shift 2
  local out rc
  out="$(bash "$SCRIPT" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s FAIL%s %s — exited 0, should have refused\n' "$c_red" "$c_off" "$what"; fail=$((fail+1))
  elif ! printf '%s' "$out" | grep -qE "$reason"; then
    printf '%s FAIL%s %s — refused, but not with /%s/: %s\n' "$c_red" "$c_off" "$what" "$reason" "$(printf '%s' "$out" | head -1)"; fail=$((fail+1))
  else
    printf '%s ok  %s%s\n' "$c_grn" "$what" "$c_off"; pass=$((pass+1))
  fi
}

expect_parses() {
  local what="$1"; shift
  local out
  out="$(bash "$SCRIPT" "$@" 2>&1)"
  if printf '%s' "$out" | grep -qE 'needs a value|needs a non-empty|also needs --sha256|must be 64 lowercase|unknown option'; then
    printf '%s FAIL%s %s — rejected while parsing: %s\n' "$c_red" "$c_off" "$what" "$(printf '%s' "$out" | head -1)"; fail=$((fail+1))
  else
    printf '%s ok  %s%s\n' "$c_grn" "$what" "$c_off"; pass=$((pass+1))
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
expect_fail "--admin with no value"        'needs a value'           --admin
expect_fail "--admin with an empty value"  'needs a non-empty value' --admin ""
expect_fail "--dir with no value"          'needs a value'           --dir
expect_fail "--ref with no value"          'needs a value'           --ref
expect_fail "--sha256 with no value"       'needs a value'           --sha256
expect_fail "--ref without --sha256"       'also needs --sha256'     --ref main
expect_fail "an unknown option"            'unknown option'          --nope
expect_fail "an admin name with a slash"   'may only contain'        --admin ../etc
expect_fail "an admin name of .."          'may not be \. or \.\.'   --admin ..
expect_fail "an admin name of ."           'may not be \. or \.\.'   --admin .
expect_ok   "--help"                       --help

echo
echo "the order of --ref and --sha256 does not matter"
expect_parses "--ref then --sha256"        --ref main --sha256 0000000000000000000000000000000000000000000000000000000000000000
expect_parses "--sha256 then --ref"        --sha256 0000000000000000000000000000000000000000000000000000000000000000 --ref main

echo
echo "the hash has to look like a hash"
expect_fail "a short hash"                 'must be 64 lowercase' --ref main --sha256 abc123
expect_fail "a hash with non-hex in it"    'must be 64 lowercase' --ref main --sha256 zzzz000000000000000000000000000000000000000000000000000000000000
expect_fail "an uppercase hash"            'must be 64 lowercase' --ref main --sha256 ABCDEF0000000000000000000000000000000000000000000000000000000000

echo
echo "the installer applies the env change in a way docker actually picks up"
if grep -q 'docker compose up -d pasarguard' "$SCRIPT" && ! grep -q 'docker compose restart pasarguard' "$SCRIPT"; then
  printf '%s ok  uses up -d, not restart%s\n' "$c_grn" "$c_off"; pass=$((pass+1))
else
  printf '%s FAIL%s still uses `docker compose restart`, which does not re-read .env\n' "$c_red" "$c_off"; fail=$((fail+1))
fi

echo
echo "the READMEs recreate the container instead of restarting it"
readmes="$(ls "$(dirname "$SCRIPT")"/README*.md 2>/dev/null)"
if [ -z "$readmes" ]; then
  echo " skip  no README beside the installer"
elif hits="$(grep -nE '^[[:space:]]*(cd [^&]+&&[[:space:]]*)?docker compose restart' $readmes)"; then
  printf '%s FAIL%s a README still tells people to run docker compose restart, which does not re-read .env: %s\n' "$c_red" "$c_off" "$(printf '%s' "$hits" | tr '\n' ' ')"; fail=$((fail+1))
else
  printf '%s ok  every README uses docker compose up -d%s\n' "$c_grn" "$c_off"; pass=$((pass+1))
fi

echo
echo "rollback also restores the env file it backed up"
if grep -q 'restored \$ENV_FILE' "$SCRIPT" || grep -q 'cp -p "\$EB" "\$ENV_FILE"' "$SCRIPT"; then
  printf '%s ok  rollback restores .env%s\n' "$c_grn" "$c_off"; pass=$((pass+1))
else
  printf '%s FAIL%s rollback leaves the .env changes in place\n' "$c_red" "$c_off"; fail=$((fail+1))
fi

echo
echo "the env file is written atomically"
if grep -q 'mv -f "\$tmp" "\$ENV_FILE"' "$SCRIPT"; then
  printf '%s ok  atomic mv%s\n' "$c_grn" "$c_off"; pass=$((pass+1))
else
  printf '%s FAIL%s truncate-then-copy can destroy .env if interrupted\n' "$c_red" "$c_off"; fail=$((fail+1))
fi

echo
echo "the pinned checksum matches the template beside it"
if [ -f "$(dirname "$SCRIPT")/index.html" ]; then
  pinned="$(grep -oE '^EXPECT_SHA256="[a-f0-9]+"' "$SCRIPT" | head -n1 | cut -d'"' -f2)"
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
echo "the default ref is immutable, published with this installer, and serves the pinned page"
dir="$(dirname "$SCRIPT")"
ref="$(sed -nE 's/^REF="\$\{REF:-([^}]+)\}"$/\1/p' "$SCRIPT" | head -n1)"
pinned="$(grep -oE '^EXPECT_SHA256="[a-f0-9]+"' "$SCRIPT" | head -n1 | cut -d'"' -f2)"
if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -n "${CI:-}" ]; then
    printf '%s FAIL%s not a git checkout, so the default ref cannot be checked\n' "$c_red" "$c_off"; fail=$((fail+1))
  else
    echo " skip  not a git checkout, the default ref cannot be resolved here"
  fi
elif [ -z "$ref" ]; then
  printf '%s FAIL%s no REF="${REF:-...}" default in the installer\n' "$c_red" "$c_off"; fail=$((fail+1))
elif ! printf '%s' "$ref" | grep -qE '^[0-9a-f]{40}$' \
     && ! git -C "$dir" show-ref --verify --quiet "refs/tags/$ref"; then
  printf '%s FAIL%s REF=%s is neither a full commit hash nor a tag here, and anything else can move under the pin\n' "$c_red" "$c_off" "$ref"; fail=$((fail+1))
elif ! commit="$(git -C "$dir" rev-parse --verify --quiet "$ref^{commit}")"; then
  printf '%s FAIL%s REF=%s does not exist in this repository\n' "$c_red" "$c_off" "$ref"; fail=$((fail+1))
elif ! git -C "$dir" merge-base --is-ancestor "$commit" HEAD; then
  printf '%s FAIL%s REF=%s is not in the history of this commit, so publishing the installer does not publish it\n' "$c_red" "$c_off" "$ref"; fail=$((fail+1))
else
  served="$(git -C "$dir" show "$commit:index.html" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)"
  if [ -n "$pinned" ] && [ "$served" = "$pinned" ]; then
    printf '%s ok  %s serves the pinned %s…%s\n' "$c_grn" "${ref:0:12}" "${pinned:0:16}" "$c_off"; pass=$((pass+1))
  else
    printf '%s FAIL%s REF=%s serves index.html %s but the installer expects %s\n' "$c_red" "$c_off" "$ref" "$served" "${pinned:-none}"; fail=$((fail+1))
  fi
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
echo "a planted symbolic link never makes the installer write, copy or chmod outside the templates directory"
if ! command -v perl >/dev/null 2>&1; then
  printf '%s FAIL%s perl is needed to plant backup names ahead of the clock\n' "$c_red" "$c_off"; fail=$((fail+1))
else
SELF="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"
SROOT="$(dirname "$SELF")"
LINKWORK="$(mktemp -d)"
LINKPAGE="$LINKWORK/page.html"
LREF="$(sed -nE 's/^REF="\$\{REF:-([^}]+)\}"$/\1/p' "$SELF" | head -n1)"
git -C "$SROOT" show "$LREF:index.html" > "$LINKPAGE" 2>/dev/null || cp "$SROOT/index.html" "$LINKPAGE"
lsha() { { sha256sum 2>/dev/null || shasum -a 256; } < "$1" | cut -d' ' -f1; }
lmode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
lok()  { printf '%s ok  %s%s\n' "$c_grn" "$1" "$c_off"; pass=$((pass+1)); }
lbad() { printf '%s FAIL%s %s\n' "$c_red" "$c_off" "$1"; fail=$((fail+1)); }
lexpect() { if [ "$1" = 1 ]; then lok "$2"; else lbad "$2"; fi; }

link_case() {
  LC="$LINKWORK/$1"
  mkdir -p "$LC/bin" "$LC/tpl/subscription" "$LC/panel" "$LC/host" "$LC/private"
  printf 'LIVE PAGE %s\n' "$1" > "$LC/tpl/subscription/index.html"
  printf 'A=1\n' > "$LC/panel/.env"
  printf 'root:HOST SECRET %s\n' "$1" > "$LC/host/secret"
  chmod 600 "$LC/host/secret"
  HOST_SHA="$(lsha "$LC/host/secret")"
  printf '#!/bin/sh\nif [ "$1" = "-u" ]; then echo 0; else exec /usr/bin/id "$@"; fi\n' > "$LC/bin/id"
  cat > "$LC/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; --proto) shift 2 ;; *) shift ;; esac; done
[ -n "$out" ] || exit 2
cp "$FAKE_PAGE" "$out"
EOF
  chmod +x "$LC/bin/id" "$LC/bin/curl"
}

run_linked() {
  LOUT="$(env -i HOME="$LC" PATH="$LC/bin:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$LC/private" \
    TPL_DIR="$LC/tpl" FAKE_PAGE="$LINKPAGE" bash "$SELF" --dir "$LC/panel" "$@" 2>&1)"
  LRC=$?
}

host_intact() {
  [ "$(lsha "$LC/host/secret")" = "$HOST_SHA" ] && [ "$(lmode "$LC/host/secret")" = 600 ]
}

leaked_into_tpl() {
  grep -rlF "HOST SECRET" "$LC/tpl" 2>/dev/null | while read -r f; do [ -L "$f" ] || echo "$f"; done
}

link_case planted-backups
for k in $(seq -3 40); do
  ln -s "$LC/host/secret" "$LC/tpl/subscription/index.html.bak-$(perl -MPOSIX -e "print strftime('%Y%m%d-%H%M%S', localtime(time + $k))")"
done
run_linked
lexpect "$(host_intact && echo 1)" "planted index.html.bak-<time> links: the file they point at is untouched (exit $LRC)"
lexpect "$(grep -q 'LIVE PAGE planted-backups' "$LC/tpl/subscription/index.html" || [ "$(lsha "$LC/tpl/subscription/index.html")" = "$(lsha "$LINKPAGE")" ] && echo 1)" \
  "planted index.html.bak-<time> links: the live page is either untouched or the new page"

link_case live-is-a-link
rm "$LC/tpl/subscription/index.html"
ln -s "$LC/host/secret" "$LC/tpl/subscription/index.html"
run_linked
lexpect "$(host_intact && echo 1)" "a live page that is a link: the file it points at is untouched (exit $LRC)"
lexpect "$([ -z "$(leaked_into_tpl)" ] && echo 1)" "a live page that is a link: nothing it points at is copied into the templates directory: $(leaked_into_tpl)"
lexpect "$([ "$LRC" -eq 0 ] && [ ! -L "$LC/tpl/subscription/index.html" ] && [ "$(lsha "$LC/tpl/subscription/index.html")" = "$(lsha "$LINKPAGE")" ] && echo 1)" \
  "a live page that is a link: it is replaced by the new page"

link_case dir-is-a-link
mkdir -p "$LC/host/elsewhere"
rm -rf "$LC/tpl/subscription"
ln -s "$LC/host/elsewhere" "$LC/tpl/subscription"
run_linked
lexpect "$([ "$LRC" -ne 0 ] && [ -z "$(ls -A "$LC/host/elsewhere")" ] && echo 1)" \
  "a templates subdirectory that is a link: refused, nothing written where it points (exit $LRC, found: $(ls -A "$LC/host/elsewhere" | tr '\n' ' '))"

link_case rollback-backup-is-a-link
ln -s "$LC/host/secret" "$LC/tpl/subscription/index.html.bak-99991231-235959"
run_linked --rollback
lexpect "$([ "$LRC" -ne 0 ] && grep -q 'LIVE PAGE rollback-backup-is-a-link' "$LC/tpl/subscription/index.html" && echo 1)" \
  "rollback to a backup that is a link: refused, the live page untouched (exit $LRC)"
lexpect "$([ -z "$(leaked_into_tpl)" ] && echo 1)" "rollback to a backup that is a link: nothing it points at is copied in: $(leaked_into_tpl)"

link_case rollback-backup-is-a-hard-link
ln "$LC/host/secret" "$LC/tpl/subscription/index.html.bak-99991231-235959"
run_linked --rollback
lexpect "$([ "$LRC" -ne 0 ] && grep -q 'LIVE PAGE rollback-backup-is-a-hard-link' "$LC/tpl/subscription/index.html" && echo 1)" \
  "rollback to a backup that is a hard link to another file: refused, the live page untouched (exit $LRC)"
lexpect "$(! grep -qF 'HOST SECRET' "$LC/tpl/subscription/index.html" && [ "$(lmode "$LC/host/secret")" = 600 ] && echo 1)" \
  "rollback to a backup that is a hard link to another file: its content does not go live"

link_case rollback-live-is-a-link
printf 'OLD PAGE\n' > "$LC/tpl/subscription/index.html.bak-99991231-235959"
rm "$LC/tpl/subscription/index.html"
ln -s "$LC/host/secret" "$LC/tpl/subscription/index.html"
run_linked --rollback
lexpect "$(host_intact && echo 1)" "rollback over a live page that is a link: the file it points at is untouched (exit $LRC)"
lexpect "$([ "$LRC" -eq 0 ] && [ ! -L "$LC/tpl/subscription/index.html" ] && grep -q '^OLD PAGE$' "$LC/tpl/subscription/index.html" && echo 1)" \
  "rollback over a live page that is a link: the live page is the backup, as a real file"

link_case normal
run_linked
backup="$(ls "$LC/tpl/subscription"/index.html.bak-* 2>/dev/null | head -n1)"
lexpect "$([ "$LRC" -eq 0 ] && [ "$(lsha "$LC/tpl/subscription/index.html")" = "$(lsha "$LINKPAGE")" ] && [ "$(lmode "$LC/tpl/subscription/index.html")" = 644 ] && echo 1)" \
  "a normal install: the new page is live with mode 644 (exit $LRC: $(printf '%s' "$LOUT" | tail -n1))"
lexpect "$([ -n "$backup" ] && grep -q '^LIVE PAGE normal$' "$backup" && echo 1)" "a normal install: the old page is kept as a backup"
lexpect "$([ -z "$(ls -A "$LC/tpl/subscription" | grep -vE '^index\.html(\.bak-[0-9-]+)?$')" ] && echo 1)" \
  "a normal install: no temporary file left: $(ls -A "$LC/tpl/subscription" | tr '\n' ' ')"
run_linked --rollback
lexpect "$([ "$LRC" -eq 0 ] && grep -q '^LIVE PAGE normal$' "$LC/tpl/subscription/index.html" && [ -f "$backup" ] && echo 1)" \
  "a normal rollback restores the backup and keeps it (exit $LRC)"
lexpect "$([ "$(ls -i "$LC/tpl/subscription/index.html" | awk '{print $1}')" != "$(ls -i "$backup" | awk '{print $1}')" ] && echo 1)" \
  "a normal rollback copies the backup instead of making the live page another name for it"
sleep 1
run_linked
lexpect "$([ "$LRC" -eq 0 ] && [ "$(lsha "$LC/tpl/subscription/index.html")" = "$(lsha "$LINKPAGE")" ] && echo 1)" \
  "installing again after a rollback works (exit $LRC: $(printf '%s' "$LOUT" | tail -n1))"
run_linked --rollback
lexpect "$([ "$LRC" -eq 0 ] && grep -q '^LIVE PAGE normal$' "$LC/tpl/subscription/index.html" && echo 1)" \
  "and rolling back a second time works (exit $LRC: $(printf '%s' "$LOUT" | tail -n1))"

rm -rf "$LINKWORK"
fi

echo
printf 'passed %s, failed %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
