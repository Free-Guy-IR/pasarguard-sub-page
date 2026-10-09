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
if grep -q 'move_into_place "\$ENV_TMP" "\$ENV_FILE"' "$SCRIPT" && ! grep -qE '(cp|cat|tee)[^|]*> ?"\$ENV_FILE"' "$SCRIPT"; then
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
if [ -n "${CURL_SWAP_ENV:-}" ]; then rm -f "$CURL_SWAP_ENV"; ln -s "$CURL_SWAP_TO" "$CURL_SWAP_ENV"; fi
[ -z "${CURL_DONE:-}" ] || : > "$CURL_DONE"
EOF
  cat > "$LC/bin/mv" <<'EOF'
#!/usr/bin/env bash
for last in "$@"; do :; done
src=""
for a in "$@"; do case "$a" in -*) ;; *) src="$a"; break ;; esac; done
staged=0
case "${src##*/}" in .index.html.*) [ "$last" = "${MV_STAGE_TO:-}" ] && staged=1 ;; esac
if [ "$staged" = 1 ] && [ -n "${MV_FAIL_ONCE:-}" ] && [ ! -e "$MV_FAIL_ONCE" ]; then
  : > "$MV_FAIL_ONCE"
  exit 1
fi
if [ "${last##*/}" = ".subpage-backups.sha256" ] && [ -n "${MV_EDIT_PAGE:-}" ] && [ ! -e "$MV_EDIT_PAGE.done" ]; then
  : > "$MV_EDIT_PAGE.done"
  printf 'LIVE PAGE changed mid-install\n' > "$MV_EDIT_PAGE"
fi
case "${src##*/}" in
  .env.*) if [ "${last##*/}" = .env ] && [ "${MV_KILL_PRE_ENV:-}" = 1 ]; then kill -9 "$PPID"; exit 1; fi ;;
esac
/bin/mv "$@" || exit $?
if [ "${last##*/}" = ".subpage-backups.sha256" ] && [ "${MV_KILL_MANIFEST:-}" = 1 ]; then kill -9 "$PPID"; fi
if [ "$staged" = 1 ] && [ -n "${MV_TAMPER:-}" ] && [ ! -e "$MV_TAMPER" ]; then
  : > "$MV_TAMPER"
  newest="$(ls -1 "${last%/*}"/index.html.bak-* | sort | tail -n1)"
  printf 'TAMPERED AFTER RECORD\n' > "$newest"
fi
if [ "$staged" = 1 ] && [ -n "${MV_EDIT_ENV:-}" ]; then printf 'EDITED_MEANWHILE=1\n' >> "$MV_EDIT_ENV"; fi
if [ "$staged" = 1 ] && [ "${MV_KILL:-}" = 1 ]; then kill -9 "$PPID"; fi
case "${src##*/}" in
  .env.*) [ "${last##*/}" = .env ] && [ "${MV_KILL_ENV:-}" = 1 ] && kill -9 "$PPID" ;;
esac
exit 0
EOF
  cat > "$LC/bin/stat" <<'EOF'
#!/usr/bin/env bash
for last in "$@"; do :; done
if [ -n "${PAUSE_PATH:-}" ] && [ "$last" = "$PAUSE_PATH" ] && [ ! -e "$PAUSE_DIR/paused" ]; then
  : > "$PAUSE_DIR/paused"
  n=0
  while [ ! -e "$PAUSE_DIR/go" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n+1)); done
fi
out="$(/usr/bin/stat "$@")" || exit $?
if [ -n "${SWAP_TARGET:-}" ]; then
  if [ "$last" = "$SWAP_TARGET" ] && [ ! -e "$SWAP_STATE/one" ]; then
    : > "$SWAP_STATE/one"
    rm -f "$SWAP_TARGET"
    ln "$SWAP_SECRET" "$SWAP_TARGET"
  elif [ "${last#/dev/fd/}" != "$last" ] && [ -e "$SWAP_STATE/one" ] && [ ! -e "$SWAP_STATE/two" ]; then
    : > "$SWAP_STATE/two"
    rm -f "$SWAP_TARGET"
    printf 'FRESH SINGLE LINK FILE\n' > "$SWAP_TARGET"
  fi
fi
printf '%s\n' "$out"
EOF
  cat > "$LC/bin/date" <<'EOF'
#!/usr/bin/env bash
if [ -n "${DATE_SEQ:-}" ] && [ "$*" = "+%Y%m%d-%H%M%S" ]; then
  n="$(cat "$DATE_SEQ.n" 2>/dev/null || echo 0)"
  n=$((n + 1))
  printf '%s\n' "$n" > "$DATE_SEQ.n"
  line="$(sed -n "${n}p" "$DATE_SEQ")"
  [ -n "$line" ] || line="$(tail -n1 "$DATE_SEQ")"
  printf '%s\n' "$line"
  exit 0
fi
exec /bin/date "$@"
EOF
  cat > "$LC/bin/cat" <<'EOF'
#!/usr/bin/env bash
if [ -n "${CAT_MODE_LOG:-}" ] && [ -n "${CAT_MODE_DIR:-}" ] && [ -f /dev/fd/1 ]; then
  exec 9>&1
  ino="$(/usr/bin/stat -L -c '%i' /dev/fd/9 2>/dev/null || /usr/bin/stat -L -f '%i' /dev/fd/9 2>/dev/null)"
  exec 9>&-
  for f in "$CAT_MODE_DIR"/.index.html.*; do
    [ -f "$f" ] || continue
    fm="$(/usr/bin/stat -c '%i %a' "$f" 2>/dev/null || /usr/bin/stat -f '%i %Lp' "$f" 2>/dev/null)"
    [ "${fm%% *}" != "$ino" ] || printf '%s\n' "$fm" >> "$CAT_MODE_LOG"
  done
fi
exec /bin/cat "$@"
EOF
  chmod +x "$LC/bin/id" "$LC/bin/curl" "$LC/bin/stat" "$LC/bin/mv" "$LC/bin/date" "$LC/bin/cat"
}

install_gnu_stat_shim() {
  cat > "$LC/bin/stat" <<'EOF'
#!/usr/bin/env bash
follow=""
if [ "$1" = "-L" ]; then follow="-L"; shift; fi
if [ "$1" = "-c" ]; then
  fmt="$2"; path="$3"
  if all="$(LC_ALL=C /usr/bin/stat $follow -c '%F|%i|%s|%h|%a' "$path" 2>/dev/null)"; then
    c="${all%%|*}"
    rest="${all#*|}"
    ino="${rest%%|*}"; rest="${rest#*|}"
    sz="${rest%%|*}"; rest="${rest#*|}"
    lnk="${rest%%|*}"; mode="${rest#*|}"
  else
    ft="$(LC_ALL=C /usr/bin/stat $follow -f '%HT' "$path" 2>/dev/null)" || exit 1
    ino="$(/usr/bin/stat $follow -f '%i' "$path" 2>/dev/null)"
    sz="$(/usr/bin/stat $follow -f '%z' "$path" 2>/dev/null)"
    lnk="$(/usr/bin/stat $follow -f '%l' "$path" 2>/dev/null)"
    mode="$(/usr/bin/stat $follow -f '%Lp' "$path" 2>/dev/null)"
    case "$ft" in
      'Regular File') c='regular file' ;;
      'Symbolic Link') c='symbolic link' ;;
      'Directory') c='directory' ;;
      *) c="$ft" ;;
    esac
  fi
  case "$c" in
    'regular file') loc='reguläre Datei' ;;
    'regular empty file') loc='reguläre leere Datei' ;;
    'symbolic link') loc='symbolische Verknüpfung' ;;
    'directory') loc='Verzeichnis' ;;
    *) loc="$c" ;;
  esac
  if [ "${LC_ALL:-}" = C ] || [ "${LC_ALL:-}" = POSIX ]; then F="$c"
  elif [ -n "${STAT_LOCALIZED:-}" ]; then F="$loc"
  else F="$c"; fi
  out="$fmt"
  out="${out//%F/$F}"
  out="${out//%i/$ino}"
  out="${out//%s/$sz}"
  out="${out//%h/$lnk}"
  out="${out//%a/$mode}"
  printf '%s\n' "$out"
  exit 0
fi
exec /usr/bin/stat "$@"
EOF
  chmod +x "$LC/bin/stat"
}

run_linked() {
  LOUT="$(env -i HOME="$LC" PATH="$LC/bin:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$LC/private" \
    TPL_DIR="$LC/tpl" FAKE_PAGE="$LINKPAGE" bash "$SELF" --dir "$LC/panel" "$@" 2>&1)"
  LRC=$?
}

run_seamed() {
  local seam="$1"; shift
  LOUT="$(env -i HOME="$LC" PATH="$LC/bin:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$LC/private" \
    TPL_DIR="$LC/tpl" FAKE_PAGE="$LINKPAGE" $seam bash "$SELF" --dir "$LC/panel" "$@" 2>&1)"
  LRC=$?
}

start_seamed() {
  local log="$1" seam="$2"; shift 2
  env -i HOME="$LC" PATH="$LC/bin:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$LC/private" \
    TPL_DIR="$LC/tpl" FAKE_PAGE="$LINKPAGE" $seam bash "$SELF" --dir "$LC/panel" "$@" > "$log" 2>&1 &
  STARTED=$!
}

newest_page_backup() {
  ls -1 "$LC/tpl/subscription"/index.html.bak-* 2>/dev/null | sort | tail -n1
}

newest_env_backup() {
  ls -1 "$LC/panel"/.env.bak-* 2>/dev/null | sort | tail -n1
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
run_linked
rm "$LC/tpl/subscription/index.html"
ln -s "$LC/host/secret" "$LC/tpl/subscription/index.html"
run_linked --rollback
lexpect "$(host_intact && echo 1)" "rollback over a live page that is a link: the file it points at is untouched (exit $LRC)"
lexpect "$([ "$LRC" -eq 0 ] && [ ! -L "$LC/tpl/subscription/index.html" ] && grep -q '^LIVE PAGE rollback-live-is-a-link$' "$LC/tpl/subscription/index.html" && echo 1)" \
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

echo
echo "rollback publishes only bytes this installer backed up"

link_case two-swap
run_linked
backup="$(newest_page_backup)"
mkdir -p "$LC/swap"
run_seamed "SWAP_TARGET=$backup SWAP_SECRET=$LC/host/secret SWAP_STATE=$LC/swap" --rollback
swaps="$(ls "$LC/swap" | tr '\n' ' ')"
lexpect "$([ -e "$LC/swap/one" ] && echo 1)" "two-swap race: the seam swapped the backup for a hard link to a secret after its first check (swaps: $swaps)"
lexpect "$([ "$LRC" -ne 0 ] && echo 1)" \
  "two-swap race: a backup swapped to a hard link of a secret and back to a single-link file between checks is refused (exit $LRC: $(printf '%s' "$LOUT" | grep -E 'refusing|restored|changed' | head -n1))"
lexpect "$(! grep -qF 'HOST SECRET' "$LC/tpl/subscription/index.html" && [ -z "$(leaked_into_tpl)" ] && echo 1)" \
  "two-swap race: the secret never goes live (live page: $(head -c 40 "$LC/tpl/subscription/index.html" | tr '\n' ' '))"
lexpect "$(host_intact && echo 1)" "two-swap race: the secret itself is untouched"

link_case legacy-backup
cp "$LINKPAGE" "$LC/tpl/subscription/index.html.bak-99991231-235959"
run_linked --rollback
lexpect "$([ "$LRC" -ne 0 ] && grep -q '^LIVE PAGE legacy-backup$' "$LC/tpl/subscription/index.html" && printf '%s' "$LOUT" | grep -q 'no checksum on record' && printf '%s' "$LOUT" | grep -qF "index.html.bak-99991231-235959" && echo 1)" \
  "a backup with no checksum on record is refused, named by its timestamp, and the live page is untouched (exit $LRC: $(printf '%s' "$LOUT" | grep -E 'refusing|restored' | head -n1))"
lexpect "$(! printf '%s' "$LOUT" | grep -qE '^[[:space:]]*(cp|mv|cat|install)[[:space:]]' && echo 1)" \
  "the refusal prints no shell command built from a file name: $(printf '%s' "$LOUT" | grep -E '^[[:space:]]*(cp|mv|cat|install)[[:space:]]' | head -n1)"

link_case planted-newer-backup
run_linked
cp "$LINKPAGE" "$LC/tpl/subscription/index.html.bak-99991231-235959"
run_linked --rollback
lexpect "$([ "$LRC" -eq 0 ] && grep -q '^LIVE PAGE planted-newer-backup$' "$LC/tpl/subscription/index.html" && echo 1)" \
  "a planted, well-formed backup name newer than every recorded backup does not block rollback to the newest recorded one (exit $LRC: $(printf '%s' "$LOUT" | grep -E 'refusing|restored' | head -n1))"

echo
echo "a hostile backup name never reaches a printed command or the raw terminal"
paste_hints() {
  mkdir -p "$LC/paste"
  printf '%s\n' "$LOUT" | grep -E '^[[:space:]]+cp ' | while IFS= read -r line; do
    (cd "$LC/paste" && env -i PATH=/usr/bin:/bin bash -c "$line" >/dev/null 2>&1)
  done
}
hostile_case() {
  local label="$1" name="$2" payload="$3" marker="$4"
  link_case "hostile-$label"
  run_linked
  cp "$LINKPAGE" "$LC/tpl/subscription/$name"
  run_linked --rollback
  paste_hints
  lexpect "$([ ! -e "$LC/paste/$marker" ] && echo 1)" \
    "a backup name with $label: pasting what the installer printed runs nothing ($(ls "$LC/paste" | tr '\n' ' '))"
  lexpect "$(! printf '%s' "$LOUT" | grep -qF "$payload" && echo 1)" \
    "a backup name with $label: its raw bytes never reach the terminal"
  lexpect "$([ "$LRC" -eq 0 ] && grep -q "^LIVE PAGE hostile-$label\$" "$LC/tpl/subscription/index.html" && echo 1)" \
    "a backup name with $label: rollback still restores the newest recorded backup (exit $LRC: $(printf '%s' "$LOUT" | grep -E 'refusing|restored' | head -n1 | LC_ALL=C tr -c ' -~' '?'))"
}
hostile_case "a double quote" 'index.html.bak-99999999"; touch "QUOTE_MARKER' 'touch "QUOTE_MARKER' QUOTE_MARKER
hostile_case "a command substitution" 'index.html.bak-99999999-$(touch DOLLAR_MARKER)' '$(touch DOLLAR_MARKER)' DOLLAR_MARKER
hostile_case "a newline" "$(printf 'index.html.bak-99999999-999999\nINJECTED LINE touch NEWLINE_MARKER')" 'INJECTED LINE' NEWLINE_MARKER
hostile_case "an escape sequence" "$(printf 'index.html.bak-99999999-999999\033]0;PWNED\007')" "$(printf '\033]0;PWNED')" ESC_MARKER

link_case hostile-directory
esc_tpl="$LC/tpl$(printf '\033]0;PWNED\007')"
run_seamed "TPL_DIR=$esc_tpl"
lexpect "$([ "$LRC" -ne 0 ] && ! printf '%s' "$LOUT" | grep -qF "$(printf '\033]0;PWNED')" && [ ! -e "$esc_tpl" ] && echo 1)" \
  "a templates directory with an escape sequence in its path is refused before anything is printed or created (exit $LRC)"

echo
echo "a .env that is a symbolic link is never turned into a wider-mode copy of its target"
link_case env-link-install
printf 'DB_PASSWORD=hunter2\n' > "$LC/host/envfile"
chmod 600 "$LC/host/envfile"
ENV_HOST_SHA="$(lsha "$LC/host/envfile")"
rm -f "$LC/panel/.env"
ln -s "$LC/host/envfile" "$LC/panel/.env"
run_linked
widened=""
for f in "$LC/panel"/.env*; do
  if [ -f "$f" ] && [ ! -L "$f" ] && grep -q 'hunter2' "$f" && [ "$(lmode "$f")" != 600 ]; then widened="$widened ${f##*/}:$(lmode "$f")"; fi
done
lexpect "$([ -z "$widened" ] && echo 1)" \
  "installing over a .env link leaves no copy of its secrets with a wider mode (exit $LRC, found:$widened, said: $(printf '%s' "$LOUT" | grep -E 'permissions|symbolic' | head -n1))"
lexpect "$([ "$(lsha "$LC/host/envfile")" = "$ENV_HOST_SHA" ] && [ "$(lmode "$LC/host/envfile")" = 600 ] && echo 1)" \
  "installing over a .env link leaves the file it points at untouched"

link_case tampered-backup
run_linked
backup="$(newest_page_backup)"
printf 'TAMPERED AFTER BACKUP\n' > "$backup"
run_linked --rollback
lexpect "$([ "$LRC" -ne 0 ] && ! grep -q 'TAMPERED' "$LC/tpl/subscription/index.html" && echo 1)" \
  "a backup whose bytes changed after it was recorded is refused (exit $LRC: $(printf '%s' "$LOUT" | grep -E 'refusing|restored' | head -n1))"

link_case forged-manifest
run_linked
backup="$(newest_page_backup)"
printf 'ATTACKER PAGE\n' > "$LC/host/attacker"
forged="$(lsha "$LC/host/attacker")"
rm -f "$backup"
cp "$LC/host/attacker" "$backup"
printf '%s  subscription/%s\n' "$forged" "$(basename "$backup")" > "$LC/host/forged-manifest"
rm -f "$LC/panel/.subpage-backups.sha256"
ln -s "$LC/host/forged-manifest" "$LC/panel/.subpage-backups.sha256"
run_linked --rollback
lexpect "$([ "$LRC" -ne 0 ] && ! grep -q 'ATTACKER PAGE' "$LC/tpl/subscription/index.html" && echo 1)" \
  "a checksum list that is a symbolic link is not trusted (exit $LRC: $(printf '%s' "$LOUT" | grep -E 'refusing|restored' | head -n1))"

link_case edited-manifest
run_linked
backup="$(newest_page_backup)"
printf 'ATTACKER PAGE\n' > "$LC/host/attacker"
rm -f "$backup"
cp "$LC/host/attacker" "$backup"
awk -v name="subscription/$(basename "$backup")" -v forged="$(lsha "$LC/host/attacker")" \
  '$2 == name { $1 = forged } { print $1 "  " $2 }' "$LC/panel/.subpage-backups.sha256" > "$LC/panel/.subpage-backups.sha256.new" 2>/dev/null \
  && ln -f "$LC/panel/.subpage-backups.sha256.new" "$LC/host/manifest-second-name" \
  && mv -f "$LC/panel/.subpage-backups.sha256.new" "$LC/panel/.subpage-backups.sha256"
run_linked --rollback
lexpect "$([ "$LRC" -ne 0 ] && ! grep -q 'ATTACKER PAGE' "$LC/tpl/subscription/index.html" && echo 1)" \
  "a checksum list that is also reachable under another name is not trusted (exit $LRC: $(printf '%s' "$LOUT" | grep -E 'refusing|restored' | head -n1))"

link_case wrong-checksum
run_linked
backup="$(newest_page_backup)"
awk -v name="subscription/$(basename "$backup")" \
  '$2 == name { $1 = "0000000000000000000000000000000000000000000000000000000000000000" } { print $1 "  " $2 }' \
  "$LC/panel/.subpage-backups.sha256" > "$LC/private/manifest" && cat "$LC/private/manifest" > "$LC/panel/.subpage-backups.sha256"
run_linked --rollback
lexpect "$([ "$LRC" -ne 0 ] && grep -q '<!DOCTYPE html>' "$LC/tpl/subscription/index.html" && printf '%s' "$LOUT" | grep -q 'do not match' && echo 1)" \
  "a recorded checksum that does not match the backup refuses the rollback (exit $LRC: $(printf '%s' "$LOUT" | grep -E 'refusing|restored' | head -n1))"

link_case env-backup-is-a-link
run_linked
envbak="$(newest_env_backup)"
rm -f "$envbak"
ln -s "$LC/host/secret" "$envbak"
run_linked --rollback
lexpect "$(! grep -qF 'HOST SECRET' "$LC/panel/.env" && [ ! -L "$LC/panel/.env" ] && host_intact && echo 1)" \
  "rollback never copies what a planted .env backup link points at into .env (exit $LRC: $(printf '%s' "$LOUT" | grep -E 'refusing|restored' | tail -n1))"

link_case env-is-a-link
run_linked
printf 'HOST ENV FILE\n' > "$LC/host/envfile"
HOST_ENV_SHA="$(lsha "$LC/host/envfile")"
rm -f "$LC/panel/.env"
ln -s "$LC/host/envfile" "$LC/panel/.env"
run_linked --rollback
lexpect "$([ "$(lsha "$LC/host/envfile")" = "$HOST_ENV_SHA" ] && echo 1)" \
  "rollback never writes through a .env that is a link (exit $LRC: $(printf '%s' "$LOUT" | grep -E 'refusing|restored' | tail -n1))"
lexpect "$([ "$LRC" -eq 0 ] && grep -q '^LIVE PAGE env-is-a-link$' "$LC/tpl/subscription/index.html" \
  && [ "$(readlink "$LC/panel/.env")" = "$LC/host/envfile" ] && printf '%s' "$LOUT" | grep -qF "left $LC/panel/.env as it is" && echo 1)" \
  "rollback over a .env that is a link restores the page, and leaves the link in place with a warning instead of replacing it"

echo
echo "install and rollback do not interleave"

link_case concurrent
run_linked
older="$(newest_page_backup)"
sleep 1
mkdir -p "$LC/pause"
start_seamed "$LC/rollback.log" "PAUSE_PATH=$older PAUSE_DIR=$LC/pause" --rollback
rollback_pid=$STARTED
n=0
while [ ! -e "$LC/pause/paused" ] && [ "$n" -lt 200 ]; do sleep 0.1; n=$((n+1)); done
start_seamed "$LC/install.log" "NO_SEAM=1"
install_pid=$STARTED
n=0
while kill -0 "$install_pid" 2>/dev/null && [ "$n" -lt 40 ]; do sleep 0.1; n=$((n+1)); done
if kill -0 "$install_pid" 2>/dev/null; then install_waited=1; else install_waited=0; fi
: > "$LC/pause/go"
wait "$rollback_pid"; rollback_rc=$?
wait "$install_pid"; install_rc=$?
lexpect "$([ -e "$LC/pause/paused" ] && echo 1)" "concurrent install and rollback: the rollback was held after choosing its backup"
lexpect "$([ "$install_waited" = 1 ] && echo 1)" \
  "concurrent install and rollback: the install waited for the rollback instead of running in the middle of it"
lexpect "$([ "$rollback_rc" -eq 0 ] && [ "$install_rc" -eq 0 ] && [ "$(lsha "$LC/tpl/subscription/index.html")" = "$(lsha "$LINKPAGE")" ] && echo 1)" \
  "concurrent install and rollback: the page the install put live stays live, not the older snapshot (rollback $rollback_rc, install $install_rc, live: $(head -c 40 "$LC/tpl/subscription/index.html" | tr '\n' ' '))"

link_case install-then-rollback
run_linked
sleep 1
printf 'LIVE PAGE edited by hand\n' > "$LC/tpl/subscription/index.html"
mkdir -p "$LC/pause"
start_seamed "$LC/install.log" "PAUSE_PATH=$LC/panel/.subpage-backups.sha256 PAUSE_DIR=$LC/pause"
install_pid=$STARTED
n=0
while [ ! -e "$LC/pause/paused" ] && kill -0 "$install_pid" 2>/dev/null && [ "$n" -lt 200 ]; do sleep 0.1; n=$((n+1)); done
start_seamed "$LC/rollback.log" "NO_SEAM=1" --rollback
rollback_pid=$STARTED
n=0
while kill -0 "$rollback_pid" 2>/dev/null && [ "$n" -lt 40 ]; do sleep 0.1; n=$((n+1)); done
if kill -0 "$rollback_pid" 2>/dev/null; then rollback_waited=1; else rollback_waited=0; fi
: > "$LC/pause/go"
wait "$install_pid"; install_rc=$?
wait "$rollback_pid"; rollback_rc=$?
lexpect "$([ "$rollback_waited" = 1 ] && echo 1)" \
  "concurrent install then rollback: the rollback waited for the install to record its backup"
lexpect "$([ "$install_rc" -eq 0 ] && [ "$rollback_rc" -eq 0 ] && grep -q '^LIVE PAGE edited by hand$' "$LC/tpl/subscription/index.html" && echo 1)" \
  "concurrent install then rollback: the rollback restores the page that install replaced (install $install_rc, rollback $rollback_rc: $(grep -E 'refusing|restored' "$LC/rollback.log" | head -n1))"

echo
echo "a lock left behind is taken over only when its holder is gone"

link_case stale-lock
( exit 0 ) &
dead_pid=$!
wait "$dead_pid"
mkdir "$LC/panel/.subpage-install.lock"
printf '%s\n' "$dead_pid" > "$LC/panel/.subpage-install.lock/pid"
run_linked
lexpect "$([ "$LRC" -eq 0 ] && printf '%s' "$LOUT" | grep -q "took over the lock left by process $dead_pid" && [ ! -e "$LC/panel/.subpage-install.lock" ] && echo 1)" \
  "a lock whose holder has exited is taken over, and released afterwards (exit $LRC: $(printf '%s' "$LOUT" | grep -E 'lock' | head -n1))"

link_case live-lock
sleep 30 &
holder_pid=$!
mkdir "$LC/panel/.subpage-install.lock"
printf '%s\n' "$holder_pid" > "$LC/panel/.subpage-install.lock/pid"
start_seamed "$LC/install.log" "NO_SEAM=1"
install_pid=$STARTED
n=0
while kill -0 "$install_pid" 2>/dev/null && [ "$n" -lt 30 ]; do sleep 0.1; n=$((n+1)); done
if kill -0 "$install_pid" 2>/dev/null && [ "$(cat "$LC/panel/.subpage-install.lock/pid" 2>/dev/null)" = "$holder_pid" ] \
   && grep -q '^LIVE PAGE live-lock$' "$LC/tpl/subscription/index.html"; then held=1; else held=0; fi
kill "$holder_pid" 2>/dev/null
wait "$holder_pid" 2>/dev/null
wait "$install_pid"; install_rc=$?
lexpect "$([ "$held" = 1 ] && echo 1)" \
  "a lock held by a running process is left alone, and the install waits without touching the page"
lexpect "$([ "$install_rc" -eq 0 ] && [ "$(lsha "$LC/tpl/subscription/index.html")" = "$(lsha "$LINKPAGE")" ] && [ ! -e "$LC/panel/.subpage-install.lock" ] && echo 1)" \
  "once that holder exits, the install takes the lock, finishes and releases it (exit $install_rc)"

echo
echo "a .env swapped for a link after the early check is refused before a byte of it is read"

secret_copies() {
  find "$LC" -type f ! -path "$LC/host/*" -exec grep -lF "HOST SECRET" {} + 2>/dev/null
}

untouched_since_link() {
  grep -q "^LIVE PAGE $1\$" "$LC/tpl/subscription/index.html" \
    && [ "$(readlink "$LC/panel/.env")" = "$LC/host/secret" ] \
    && [ -z "$(ls -A "$LC/tpl/subscription" | grep -vxF 'index.html')" ] \
    && [ -z "$(ls -A "$LC/panel" | grep -vxF '.env')" ]
}

link_case env-swapped-during-download
run_seamed "CURL_SWAP_ENV=$LC/panel/.env CURL_SWAP_TO=$LC/host/secret CURL_DONE=$LC/swapped"
lexpect "$([ -e "$LC/swapped" ] && echo 1)" "swap during the download: the seam replaced .env with a link to a secret"
lexpect "$([ "$LRC" -ne 0 ] && printf '%s' "$LOUT" | grep -q 'symbolic link' && echo 1)" \
  "swap during the download: the install refuses (exit $LRC: $(printf '%s' "$LOUT" | grep -E 'refusing|symbolic|updated' | head -n1))"
lexpect "$([ -z "$(secret_copies)" ] && host_intact && echo 1)" \
  "swap during the download: no byte of the file the link points at is copied anywhere: $(secret_copies | tr '\n' ' ')"
lexpect "$(untouched_since_link env-swapped-during-download && echo 1)" \
  "swap during the download: nothing was changed (panel: $(ls -A "$LC/panel" | tr '\n' ' '), templates: $(ls -A "$LC/tpl/subscription" | tr '\n' ' '))"

link_case env-swapped-during-lock-wait
sleep 30 &
holder_pid=$!
mkdir "$LC/panel/.subpage-install.lock"
printf '%s\n' "$holder_pid" > "$LC/panel/.subpage-install.lock/pid"
start_seamed "$LC/install.log" "CURL_DONE=$LC/downloaded"
install_pid=$STARTED
n=0
while [ ! -e "$LC/downloaded" ] && kill -0 "$install_pid" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done
sleep 1
if [ -e "$LC/downloaded" ] && kill -0 "$install_pid" 2>/dev/null \
   && [ "$(cat "$LC/panel/.subpage-install.lock/pid" 2>/dev/null)" = "$holder_pid" ]; then lock_waiting=1; else lock_waiting=0; fi
rm -f "$LC/panel/.env"
ln -s "$LC/host/secret" "$LC/panel/.env"
kill "$holder_pid" 2>/dev/null
wait "$holder_pid" 2>/dev/null
wait "$install_pid"; install_rc=$?
LOUT="$(cat "$LC/install.log")"
lexpect "$([ "$lock_waiting" = 1 ] && echo 1)" "swap during the lock wait: the install had downloaded and was waiting on the lock when .env became a link"
lexpect "$([ "$install_rc" -ne 0 ] && printf '%s' "$LOUT" | grep -q 'symbolic link' && echo 1)" \
  "swap during the lock wait: the install refuses once it holds the lock (exit $install_rc: $(printf '%s' "$LOUT" | grep -E 'refusing|symbolic|updated' | head -n1))"
lexpect "$([ -z "$(secret_copies)" ] && host_intact && echo 1)" \
  "swap during the lock wait: no byte of the file the link points at is copied anywhere: $(secret_copies | tr '\n' ' ')"
lexpect "$(untouched_since_link env-swapped-during-lock-wait && echo 1)" \
  "swap during the lock wait: nothing was changed (panel: $(ls -A "$LC/panel" | tr '\n' ' '), templates: $(ls -A "$LC/tpl/subscription" | tr '\n' ' '))"

echo
echo "an install records its .env backup next to its page backup, under one stamp"

manifest_hash() {
  awk -v key="$1" 'NF == 2 && $2 == key { h = $1 } END { print h }' "$LC/panel/.subpage-backups.sha256" 2>/dev/null
}

link_case paired-backups
printf 'A=1\nORIGINAL_ENV=1\n' > "$LC/panel/.env"
chmod 640 "$LC/panel/.env"
orig_env_sha="$(lsha "$LC/panel/.env")"
run_linked
pagebak="$(newest_page_backup)"
envbak="$(newest_env_backup)"
stamp="${pagebak##*index.html.bak-}"
lexpect "$([ "$LRC" -eq 0 ] && [ -n "$pagebak" ] && [ "$envbak" = "$LC/panel/.env.bak-$stamp" ] && echo 1)" \
  "the page backup and the .env backup share one stamp (page: ${pagebak##*/}, env: ${envbak##*/})"
lexpect "$([ "$(lsha "$envbak")" = "$orig_env_sha" ] && [ "$(lmode "$envbak")" = 640 ] && echo 1)" \
  "the .env backup holds the .env bytes from before the install, with its mode ($(lmode "$envbak"))"
lexpect "$([ "$(manifest_hash "subscription/${pagebak##*/}")" = "$(lsha "$pagebak")" ] \
  && [ "$(manifest_hash ".env.bak-$stamp@subscription/index.html.bak-$stamp")" = "$orig_env_sha" ] && echo 1)" \
  "the checksum list records the page backup and, paired with it, the .env backup: $(tr '\n' ' ' < "$LC/panel/.subpage-backups.sha256" 2>/dev/null)"
lexpect "$([ -n "$(manifest_hash ".env@subscription/index.html.bak-$stamp")" ] \
  && [ "$(manifest_hash ".env@subscription/index.html.bak-$stamp")" = "$(lsha "$LC/panel/.env")" ] && echo 1)" \
  "the checksum list also records, paired with the page backup, the .env that install wrote"
lexpect "$([ "$(lmode "$LC/panel/.env")" = 640 ] && grep -qxF "CUSTOM_TEMPLATES_DIRECTORY=\"$LC/tpl/\"" "$LC/panel/.env" \
  && grep -qxF 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' "$LC/panel/.env" && grep -qx 'ORIGINAL_ENV=1' "$LC/panel/.env" && echo 1)" \
  "the new .env keeps its mode (640) and carries both settings and the earlier lines"
lexpect "$([ -z "$(ls -A "$LC/panel" | grep -vE '^(\.env|\.env\.bak-[0-9-]+|\.subpage-backups\.sha256)$')" ] && echo 1)" \
  "no temporary file is left beside .env: $(ls -A "$LC/panel" | tr '\n' ' ')"

echo
echo "rollback restores only the .env backed up with the page it restores"

link_case env-pair-with-newer-unpaired
printf 'A=1\nORIGINAL_ENV=1\n' > "$LC/panel/.env"
orig_env_sha="$(lsha "$LC/panel/.env")"
run_linked
printf 'UNRECORDED NEWER PAGE\n' > "$LC/tpl/subscription/index.html.bak-99991231-235959"
printf 'PLANTED_ENV=1\n' > "$LC/panel/.env.bak-99991231-235959"
run_linked --rollback
lexpect "$([ "$LRC" -eq 0 ] && grep -qx 'LIVE PAGE env-pair-with-newer-unpaired' "$LC/tpl/subscription/index.html" && echo 1)" \
  "a newer unrecorded page backup and a newer .env backup: the recorded page is restored (exit $LRC: $(printf '%s' "$LOUT" | grep -E 'refusing|restored' | head -n1))"
lexpect "$([ "$(lsha "$LC/panel/.env")" = "$orig_env_sha" ] && ! grep -q PLANTED_ENV "$LC/panel/.env" && echo 1)" \
  "a newer unrecorded page backup and a newer .env backup: .env is the one backed up with that page ($(tr '\n' ' ' < "$LC/panel/.env"))"

link_case env-pair-missing-planted-newer
run_linked
env_after_install="$(lsha "$LC/panel/.env")"
rm -f "$(newest_env_backup)"
printf 'PLANTED_ENV=1\n' > "$LC/panel/.env.bak-99991231-235959"
run_linked --rollback
lexpect "$([ "$LRC" -eq 0 ] && grep -qx 'LIVE PAGE env-pair-missing-planted-newer' "$LC/tpl/subscription/index.html" && echo 1)" \
  "the paired .env backup is gone and a newer unrecorded one is planted: the page is still restored (exit $LRC)"
lexpect "$([ "$(lsha "$LC/panel/.env")" = "$env_after_install" ] && ! grep -q PLANTED_ENV "$LC/panel/.env" \
  && printf '%s' "$LOUT" | grep -qF "left $LC/panel/.env as it is" && echo 1)" \
  "the paired .env backup is gone and a newer unrecorded one is planted: .env is left alone, with a warning ($(printf '%s' "$LOUT" | grep -E 'env' | tail -n1))"

link_case env-pair-tampered
run_linked
env_after_install="$(lsha "$LC/panel/.env")"
printf 'TAMPERED_ENV=1\n' >> "$(newest_env_backup)"
run_linked --rollback
lexpect "$([ "$LRC" -eq 0 ] && grep -qx 'LIVE PAGE env-pair-tampered' "$LC/tpl/subscription/index.html" && echo 1)" \
  "a paired .env backup whose bytes changed: the page is still restored (exit $LRC)"
lexpect "$([ "$(lsha "$LC/panel/.env")" = "$env_after_install" ] && printf '%s' "$LOUT" | grep -qF "left $LC/panel/.env as it is" && echo 1)" \
  "a paired .env backup whose bytes changed: .env is left alone, with a warning ($(printf '%s' "$LOUT" | grep -E 'env' | tail -n1))"

link_case env-pair-not-recorded
run_linked
env_after_install="$(lsha "$LC/panel/.env")"
awk 'NF == 2 && $2 !~ /@/' "$LC/panel/.subpage-backups.sha256" > "$LC/private/manifest" && cat "$LC/private/manifest" > "$LC/panel/.subpage-backups.sha256"
run_linked --rollback
lexpect "$([ "$LRC" -eq 0 ] && grep -qx 'LIVE PAGE env-pair-not-recorded' "$LC/tpl/subscription/index.html" \
  && [ "$(lsha "$LC/panel/.env")" = "$env_after_install" ] && printf '%s' "$LOUT" | grep -qF "left $LC/panel/.env as it is" && echo 1)" \
  "a page backup with no .env checksum recorded beside it (an older installer's): the page is restored and .env is left alone (exit $LRC)"

link_case env-pair-swapped-during-rollback
run_linked
env_after_install="$(lsha "$LC/panel/.env")"
mkdir -p "$LC/swap"
run_seamed "SWAP_TARGET=$(newest_env_backup) SWAP_SECRET=$LC/host/secret SWAP_STATE=$LC/swap" --rollback
lexpect "$([ -e "$LC/swap/one" ] && echo 1)" "a paired .env backup swapped mid-rollback: the seam swapped it for a hard link to a secret ($(ls "$LC/swap" | tr '\n' ' '))"
lexpect "$(! grep -qF 'HOST SECRET' "$LC/panel/.env" && [ "$(lsha "$LC/panel/.env")" = "$env_after_install" ] && host_intact \
  && [ -z "$(find "$LC/private" -type f -exec grep -lF 'HOST SECRET' {} + 2>/dev/null)" ] && echo 1)" \
  "a paired .env backup swapped mid-rollback: .env is left alone and the secret is copied nowhere"
lexpect "$([ "$LRC" -eq 0 ] && grep -qx 'LIVE PAGE env-pair-swapped-during-rollback' "$LC/tpl/subscription/index.html" && echo 1)" \
  "a paired .env backup swapped mid-rollback: the page is still restored (exit $LRC: $(printf '%s' "$LOUT" | grep -E 'refusing|restored|left' | tail -n1))"

echo
echo "an install that dies around the replace never leaves rollback pointing at an older page"

link_case replace-fails
run_linked
sleep 1
printf 'LIVE PAGE edited by hand\n' > "$LC/tpl/subscription/index.html"
mkdir -p "$LC/mvstate"
run_seamed "MV_STAGE_TO=$LC/tpl/subscription/index.html MV_FAIL_ONCE=$LC/mvstate/failed"
failed_rc=$LRC
run_linked --rollback
lexpect "$([ -e "$LC/mvstate/failed" ] && [ "$failed_rc" -ne 0 ] && echo 1)" "a replace that fails: the seam failed the move of the new page into place (install exit $failed_rc)"
lexpect "$([ "$LRC" -eq 0 ] && grep -qx 'LIVE PAGE edited by hand' "$LC/tpl/subscription/index.html" && echo 1)" \
  "a replace that fails: rollback restores the page that was live before the failed install, not an older one (exit $LRC, live: $(head -c 40 "$LC/tpl/subscription/index.html" | tr '\n' ' '))"

link_case killed-after-replace
run_linked
sleep 1
printf 'LIVE PAGE edited by hand\n' > "$LC/tpl/subscription/index.html"
run_seamed "MV_STAGE_TO=$LC/tpl/subscription/index.html MV_KILL=1"
killed_rc=$LRC
killed_live_sha="$(lsha "$LC/tpl/subscription/index.html")"
run_linked --rollback
lexpect "$([ "$killed_rc" -ne 0 ] && [ "$killed_live_sha" = "$(lsha "$LINKPAGE")" ] && echo 1)" \
  "an install killed right after the replace: the new page was live when it died (install exit $killed_rc)"
lexpect "$([ "$LRC" -eq 0 ] && grep -qx 'LIVE PAGE edited by hand' "$LC/tpl/subscription/index.html" && echo 1)" \
  "an install killed right after the replace: rollback restores the page it replaced, not an older one (exit $LRC, live: $(head -c 40 "$LC/tpl/subscription/index.html" | tr '\n' ' '))"

link_case backup-tampered-before-verify
run_linked
sleep 1
printf 'LIVE PAGE edited by hand\n' > "$LC/tpl/subscription/index.html"
mkdir -p "$LC/mvstate"
run_seamed "MV_STAGE_TO=$LC/tpl/subscription/index.html MV_TAMPER=$LC/mvstate/tampered"
tampered_out="$LOUT"
tampered_bak="$(newest_page_backup)"
run_linked --rollback
lexpect "$([ -e "$LC/mvstate/tampered" ] && grep -q 'TAMPERED AFTER RECORD' "$tampered_bak" && echo 1)" \
  "a backup rewritten between the record and the replace: the seam rewrote ${tampered_bak##*/}"
lexpect "$([ -z "$(manifest_hash "subscription/${tampered_bak##*/}")" ] && printf '%s' "$tampered_out" | grep -q 'changed after its checksum was recorded' && echo 1)" \
  "a backup rewritten between the record and the replace: the install notices, warns and drops its record ($(printf '%s' "$tampered_out" | grep -E 'changed|recorded' | head -n1))"
lexpect "$([ -z "$(manifest_hash "subscription/${tampered_bak##*/}")" ] && [ -z "$(manifest_hash ".env.bak-${tampered_bak##*index.html.bak-}@subscription/${tampered_bak##*/}")" ] \
  && [ -n "$(manifest_hash ".env@subscription/${tampered_bak##*/}")" ] && echo 1)" \
  "a backup rewritten between the record and the replace: its page and .env-backup records go, but the marker that this install changed .env stays ($(tr '\n' ' ' < "$LC/panel/.subpage-backups.sha256"))"
lexpect "$(! grep -q 'TAMPERED' "$LC/tpl/subscription/index.html" && echo 1)" \
  "a backup rewritten between the record and the replace: rollback never puts those bytes live (exit $LRC)"

echo
echo "rollback never throws away .env changes made after the install it undoes"

link_case env-edited-after-install
printf 'A=1\nORIGINAL_ENV=1\n' > "$LC/panel/.env"
run_linked
install_rc=$LRC
printf 'EDITED_AFTER_INSTALL=1\n' >> "$LC/panel/.env"
edited_sha="$(lsha "$LC/panel/.env")"
run_linked --rollback
lexpect "$([ "$install_rc" -eq 0 ] && [ "$LRC" -eq 0 ] && grep -qx 'LIVE PAGE env-edited-after-install' "$LC/tpl/subscription/index.html" && echo 1)" \
  ".env edited after the install: the page is still restored (install $install_rc, rollback $LRC)"
lexpect "$([ "$(lsha "$LC/panel/.env")" = "$edited_sha" ] && grep -qx 'EDITED_AFTER_INSTALL=1' "$LC/panel/.env" \
  && printf '%s' "$LOUT" | grep -qF "left $LC/panel/.env as it is" && echo 1)" \
  ".env edited after the install: the edit is kept and rollback warns instead of restoring the older .env ($(printf '%s' "$LOUT" | grep -E 'env' | tail -n1))"

link_case env-edited-during-rollback
printf 'A=1\nORIGINAL_ENV=1\n' > "$LC/panel/.env"
run_linked
run_seamed "MV_STAGE_TO=$LC/tpl/subscription/index.html MV_EDIT_ENV=$LC/panel/.env" --rollback
lexpect "$([ "$LRC" -eq 0 ] && grep -qx 'LIVE PAGE env-edited-during-rollback' "$LC/tpl/subscription/index.html" && echo 1)" \
  ".env edited while rollback restores the page: the page is still restored (exit $LRC)"
lexpect "$(grep -qx 'EDITED_MEANWHILE=1' "$LC/panel/.env" && printf '%s' "$LOUT" | grep -qF "left $LC/panel/.env as it is" && echo 1)" \
  ".env edited while rollback restores the page: the edit is kept and rollback warns ($(printf '%s' "$LOUT" | grep -E 'env' | tail -n1))"

link_case env-edited-during-install
printf 'A=1\nORIGINAL_ENV=1\n' > "$LC/panel/.env"
run_linked
sleep 1
printf 'LIVE PAGE edited by hand\n' > "$LC/tpl/subscription/index.html"
run_seamed "MV_STAGE_TO=$LC/tpl/subscription/index.html MV_EDIT_ENV=$LC/panel/.env"
during_rc=$LRC
during_out="$LOUT"
edited_sha="$(lsha "$LC/panel/.env")"
during_kept="$(grep -qx 'EDITED_MEANWHILE=1' "$LC/panel/.env" && echo 1)"
run_linked --rollback
lexpect "$([ "$during_rc" -ne 0 ] && printf '%s' "$during_out" | grep -q 'changed while the page was being installed' && [ "$during_kept" = 1 ] && echo 1)" \
  ".env edited while the install replaces the page: the install leaves .env alone and says so (exit $during_rc)"
lexpect "$([ "$LRC" -eq 0 ] && grep -qx 'LIVE PAGE edited by hand' "$LC/tpl/subscription/index.html" \
  && [ "$(lsha "$LC/panel/.env")" = "$edited_sha" ] && printf '%s' "$LOUT" | grep -qF "left $LC/panel/.env as it is" && echo 1)" \
  ".env edited while the install replaces the page: rollback restores the page that install replaced and keeps the edit (exit $LRC)"

link_case marker-not-written-before-env
printf 'A=1\n' > "$LC/panel/.env"
run_seamed "MV_STAGE_TO=$LC/tpl/subscription/index.html MV_EDIT_ENV=$LC/panel/.env"
died_rc=$LRC
pb="$(newest_page_backup)"
s="${pb##*index.html.bak-}"
lexpect "$([ "$died_rc" -ne 0 ] && [ -n "$(manifest_hash "subscription/index.html.bak-$s")" ] \
  && [ -z "$(manifest_hash ".env@subscription/index.html.bak-$s")" ] && echo 1)" \
  "an install that stops before it writes .env records no marker claiming it changed .env (exit $died_rc: $(tr '\n' ' ' < "$LC/panel/.subpage-backups.sha256"))"

link_case crash-after-env-keeps-marker
printf 'A=1\n' > "$LC/panel/.env"
mkdir -p "$LC/tpl/alice"
printf 'LIVE PAGE alice\n' > "$LC/tpl/alice/index.html"
run_linked --admin alice
env_after_alice="$(lsha "$LC/panel/.env")"
run_seamed "MV_KILL_ENV=1" --admin bob
bob_rc=$LRC
run_linked --admin alice --rollback
lexpect "$([ "$bob_rc" -ne 0 ] && grep -q '^CUSTOM_TEMPLATES_DIRECTORY=' "$LC/panel/.env" && echo 1)" \
  "a later install killed the instant after it changed .env still left a marker, so an earlier admin's rollback does not strip the shared .env (bob $bob_rc, exit $LRC: $(printf '%s' "$LOUT" | grep -E 'later|restored|left' | tail -n1))"
lexpect "$([ "$LRC" -eq 0 ] && grep -qx 'LIVE PAGE alice' "$LC/tpl/alice/index.html" && echo 1)" \
  "a later install killed the instant after it changed .env: alice's page is still rolled back (exit $LRC)"

link_case env-unchanged-since-install
printf 'A=1\nORIGINAL_ENV=1\n' > "$LC/panel/.env"
orig_env_sha="$(lsha "$LC/panel/.env")"
run_linked
run_linked --rollback
lexpect "$([ "$LRC" -eq 0 ] && [ "$(lsha "$LC/panel/.env")" = "$orig_env_sha" ] && printf '%s' "$LOUT" | grep -qF "restored $LC/panel/.env from" && echo 1)" \
  ".env untouched since the install: rollback restores the .env from before it (exit $LRC)"

link_case env-not-reached
printf 'A=1\nORIGINAL_ENV=1\n' > "$LC/panel/.env"
orig_env_sha="$(lsha "$LC/panel/.env")"
run_seamed "MV_STAGE_TO=$LC/tpl/subscription/index.html MV_KILL=1"
killed_rc=$LRC
run_linked --rollback
lexpect "$([ "$killed_rc" -ne 0 ] && [ "$LRC" -eq 0 ] && grep -qx 'LIVE PAGE env-not-reached' "$LC/tpl/subscription/index.html" \
  && [ "$(lsha "$LC/panel/.env")" = "$orig_env_sha" ] && printf '%s' "$LOUT" | grep -qF 'already holds what it held before that install' && echo 1)" \
  "an install killed before it wrote .env: rollback restores the page and reports .env needs nothing (install $killed_rc, rollback $LRC)"

echo
echo "a backup name already taken for this second makes the install wait for a free one"

link_case stamp-taken
printf 'NOT OURS\n' > "$LC/panel/.env.bak-20300101-000000"
printf '20300101-000000\n20300101-000001\n' > "$LC/private/clock"
run_seamed "DATE_SEQ=$LC/private/clock"
lexpect "$([ "$LRC" -eq 0 ] && [ -f "$LC/tpl/subscription/index.html.bak-20300101-000001" ] && [ -f "$LC/panel/.env.bak-20300101-000001" ] \
  && [ "$(manifest_hash ".env.bak-20300101-000001@subscription/index.html.bak-20300101-000001")" = "$(lsha "$LC/panel/.env.bak-20300101-000001")" ] && echo 1)" \
  "a .env backup name taken for this second: the install waits for the next second and pairs both backups under it (exit $LRC: $(printf '%s' "$LOUT" | grep -E 'kept|taken|refusing' | head -n1))"
lexpect "$(grep -qx 'NOT OURS' "$LC/panel/.env.bak-20300101-000000" && [ ! -e "$LC/tpl/subscription/index.html.bak-20300101-000000" ] && echo 1)" \
  "a .env backup name taken for this second: the file already there is left untouched and no backup is made under its stamp"

link_case same-second-installs
printf '20300101-000000\n20300101-000000\n20300101-000001\n20300101-000001\n20300101-000002\n' > "$LC/private/clock"
run_seamed "DATE_SEQ=$LC/private/clock"
first_rc=$LRC
env_before_second="$(lsha "$LC/panel/.env")"
run_seamed "DATE_SEQ=$LC/private/clock" --admin bob
second_rc=$LRC
second_out="$LOUT"
run_seamed "DATE_SEQ=$LC/private/clock"
third_rc=$LRC
lexpect "$([ "$first_rc" -eq 0 ] && [ "$second_rc" -eq 0 ] && [ -f "$LC/tpl/bob/index.html" ] && echo 1)" \
  "a second install in the same second, for another admin, succeeds (first $first_rc, second $second_rc: $(printf '%s' "$second_out" | grep -E 'refusing|could not|taken' | head -n1))"
lexpect "$([ "$third_rc" -eq 0 ] && [ -f "$LC/tpl/subscription/index.html.bak-20300101-000000" ] && [ -f "$LC/tpl/subscription/index.html.bak-20300101-000002" ] \
  && [ "$(lsha "$LC/panel/.env.bak-20300101-000002")" = "$env_before_second" ] \
  && [ "$(manifest_hash ".env.bak-20300101-000002@subscription/index.html.bak-20300101-000002")" = "$env_before_second" ] && echo 1)" \
  "a third install whose second is taken waits for the next one and keeps its own paired backups (exit $third_rc)"

echo
echo "the installer reads a GNU stat under LC_ALL=C, so a localized file-type word never fools it"

link_case gnu-locale-c
install_gnu_stat_shim
run_seamed "STAT_LOCALIZED=1 LANG=de_DE.UTF-8"
lexpect "$([ "$LRC" -eq 0 ] && [ "$(lsha "$LC/tpl/subscription/index.html")" = "$(lsha "$LINKPAGE")" ] && echo 1)" \
  "a GNU host whose stat says 'reguläre Datei' in a German locale still installs, because the installer pins LC_ALL=C (exit $LRC: $(printf '%s' "$LOUT" | grep -E 'installed|refusing|regular' | head -n1))"

link_case gnu-locale-proof
install_gnu_stat_shim
LOUT="$(env -i HOME="$LC" PATH="$LC/bin:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$LC/private" \
  TPL_DIR="$LC/tpl" FAKE_PAGE="$LINKPAGE" STAT_LOCALIZED=1 LANG=de_DE.UTF-8 \
  bash -c 'LC_ALL= stat -c "%F" "$0"' "$LC/tpl/subscription/index.html" 2>&1)"
lexpect "$([ "$LOUT" = 'reguläre Datei' ] && echo 1)" \
  "the shim proves the hazard: without LC_ALL=C that stat returns a localized type ($LOUT)"

echo
echo "an in-place write to the page between the backup and the replace is never silently lost"

link_case page-edited-mid-install
run_seamed "MV_EDIT_PAGE=$LC/tpl/subscription/index.html"
mid_rc=$LRC
lexpect "$([ "$mid_rc" -ne 0 ] && printf '%s' "$LOUT" | grep -q 'changed after this run backed it up' && echo 1)" \
  "the page edited between its backup and the replace: the install aborts instead of losing the edit (exit $mid_rc: $(printf '%s' "$LOUT" | grep -E 'left|changed|installed' | tail -n1))"
lexpect "$(grep -qx 'LIVE PAGE changed mid-install' "$LC/tpl/subscription/index.html" && echo 1)" \
  "the page edited between its backup and the replace: that edit is what is live, not an older page (live: $(head -c 40 "$LC/tpl/subscription/index.html" | tr '\n' ' '))"
lexpect "$([ -z "$(ls "$LC/tpl/subscription"/index.html.bak-* 2>/dev/null)" ] && [ -z "$(ls "$LC/panel"/.env.bak-* 2>/dev/null)" ] && [ ! -s "$LC/panel/.subpage-backups.sha256" ] && echo 1)" \
  "the page edited between its backup and the replace: the aborted run discarded its own backups and recorded nothing (tpl: $(ls -A "$LC/tpl/subscription" | tr '\n' ' '), panel: $(ls -A "$LC/panel" | tr '\n' ' '))"

echo
echo "the new .env keeps the exact mode of the one it replaces, and the message tells the truth"

link_case env-mode-755
printf 'A=1\n' > "$LC/panel/.env"
chmod 755 "$LC/panel/.env"
run_linked
lexpect "$([ "$LRC" -eq 0 ] && [ "$(lmode "$LC/panel/.env")" = 755 ] && printf '%s' "$LOUT" | grep -qF 'permissions kept at 755' && echo 1)" \
  "a 0755 .env stays 0755 after the install, and the installer says 755 (exit $LRC, mode $(lmode "$LC/panel/.env"): $(printf '%s' "$LOUT" | grep -E 'permissions' | head -n1))"
lexpect "$([ "$(lmode "$(newest_env_backup)")" = 755 ] && echo 1)" \
  "the .env backup also keeps 0755 ($(lmode "$(newest_env_backup)"))"

link_case rollback-keeps-page-mode
chmod 600 "$LC/tpl/subscription/index.html"
run_linked
bak="$(newest_page_backup)"
run_seamed "CAT_MODE_DIR=$LC/tpl/subscription CAT_MODE_LOG=$LC/private/cat-modes" --rollback
created_mode="$(awk '{ m = $2 } END { print m }' "$LC/private/cat-modes" 2>/dev/null)"
lexpect "$([ "$LRC" -eq 0 ] && [ "$(lmode "$bak")" = 600 ] && [ "$(lmode "$LC/tpl/subscription/index.html")" = 600 ] && echo 1)" \
  "rollback restores the page with the 0600 mode it had before the install, not a widened one (backup $(lmode "$bak"), live $(lmode "$LC/tpl/subscription/index.html"))"
lexpect "$([ "$created_mode" = 600 ] && echo 1)" \
  "rollback creates the staged page at 0600 from the start, so it is never readable wider even before the rename (created ${created_mode:-unseen})"

echo
echo "a per-admin install prints a rollback command scoped to that admin"

link_case admin-rollback-hint
mkdir -p "$LC/tpl/alice"
printf 'LIVE PAGE alice\n' > "$LC/tpl/alice/index.html"
run_linked --admin alice
lexpect "$([ "$LRC" -eq 0 ] && printf '%s' "$LOUT" | grep -qF -- '--admin alice --rollback' && echo 1)" \
  "the hint names the admin, so pasting it rolls back alice's page, not the panel-wide one (exit $LRC: $(printf '%s' "$LOUT" | grep -F -- '--rollback' | head -n1))"
lexpect "$(bash "$SELF" --help 2>&1 | grep -qF -- '--admin NAME --rollback' && echo 1)" \
  "the usage text documents --admin NAME --rollback"

echo
echo "a later install of another page is not undone by rolling back an earlier one"

link_case later-install-protects-env
printf 'A=1\n' > "$LC/panel/.env"
mkdir -p "$LC/tpl/alice"
printf 'LIVE PAGE alice old\n' > "$LC/tpl/alice/index.html"
run_linked --admin alice
alice_bak="$(ls "$LC/tpl/alice"/index.html.bak-* 2>/dev/null | head -n1)"
run_linked
env_after_subscription="$(lsha "$LC/panel/.env")"
run_linked --admin alice --rollback
lexpect "$([ "$LRC" -eq 0 ] && grep -qx 'LIVE PAGE alice old' "$LC/tpl/alice/index.html" && echo 1)" \
  "alice's page is still rolled back (exit $LRC: $(printf '%s' "$LOUT" | grep -E 'restored|refusing|left' | tail -n1))"
lexpect "$([ "$(lsha "$LC/panel/.env")" = "$env_after_subscription" ] && grep -q '^CUSTOM_TEMPLATES_DIRECTORY=' "$LC/panel/.env" \
  && printf '%s' "$LOUT" | grep -qF "left $LC/panel/.env as it is" && echo 1)" \
  "rolling back alice leaves .env as the later panel-wide install needs it, with a warning ($(printf '%s' "$LOUT" | grep -E 'later|env' | tail -n1))"

link_case rollback-warns-newer-unbacked-install
printf 'A=1\n' > "$LC/panel/.env"
run_linked
run_linked
rm "$LC/tpl/subscription/index.html"
ln -s "$LC/host/secret" "$LC/tpl/subscription/index.html"
run_linked
run_linked --rollback
lexpect "$([ "$LRC" -eq 0 ] && printf '%s' "$LOUT" | grep -q 'installed again at' && echo 1)" \
  "when the newest install kept no page backup, rollback warns that it is restoring an older page (exit $LRC: $(printf '%s' "$LOUT" | grep -E 'installed again|restored' | head -n1))"

echo
echo "an install killed at any step boundary leaves a state that both a rollback and a rerun finish cleanly"

manifest_consistent() {
  local h k f bad=0
  [ -f "$LC/panel/.subpage-backups.sha256" ] || return 0
  while read -r h k; do
    case "$k" in
      .env@*) continue ;;
      index.html@*) continue ;;
      .env.bak-*@*) f="$LC/panel/${k%%@*}" ;;
      */index.html.bak-*) f="$LC/tpl/$k" ;;
      *) bad=1; continue ;;
    esac
    if [ ! -f "$f" ] || [ "$(lsha "$f")" != "$h" ]; then bad=1; fi
  done < "$LC/panel/.subpage-backups.sha256"
  return $bad
}

for boundary in MV_KILL_MANIFEST MV_KILL MV_KILL_PRE_ENV MV_KILL_ENV; do
  for next_step in rollback rerun; do
    link_case "kill-$boundary-$next_step"
    printf 'A=1\n' > "$LC/panel/.env"
    e0="$(lsha "$LC/panel/.env")"
    p0="$(lsha "$LC/tpl/subscription/index.html")"
    run_seamed "MV_STAGE_TO=$LC/tpl/subscription/index.html $boundary=1"
    killed_rc=$LRC
    pb="$(newest_page_backup)"
    s="${pb##*index.html.bak-}"
    at_page="$(lsha "$LC/tpl/subscription/index.html")"
    at_env="$(lsha "$LC/panel/.env")"
    at_marker=0
    [ -z "$(manifest_hash ".env@subscription/index.html.bak-$s")" ] || at_marker=1
    new_page="$(lsha "$LINKPAGE")"
    case "$boundary" in
      MV_KILL_MANIFEST) ok_state="$([ "$at_page" = "$p0" ] && [ "$at_env" = "$e0" ] && [ "$at_marker" = 0 ] && echo 1)" ;;
      MV_KILL) ok_state="$([ "$at_page" = "$new_page" ] && [ "$at_env" = "$e0" ] && [ "$at_marker" = 0 ] && echo 1)" ;;
      MV_KILL_PRE_ENV) ok_state="$([ "$at_page" = "$new_page" ] && [ "$at_env" = "$e0" ] && [ "$at_marker" = 1 ] && echo 1)" ;;
      MV_KILL_ENV) ok_state="$([ "$at_page" = "$new_page" ] && [ "$at_env" != "$e0" ] && [ "$at_marker" = 1 ] && echo 1)" ;;
    esac
    lexpect "$([ "$killed_rc" -ne 0 ] && [ "$ok_state" = 1 ] && echo 1)" \
      "killed at $boundary: the kill landed exactly at that step (page $([ "$at_page" = "$p0" ] && echo old || echo new), .env $([ "$at_env" = "$e0" ] && echo old || echo new), .env record $at_marker, install $killed_rc)"
    if [ "$next_step" = rollback ]; then
      run_linked --rollback
      lexpect "$([ "$killed_rc" -ne 0 ] && [ "$LRC" -eq 0 ] && [ "$(lsha "$LC/tpl/subscription/index.html")" = "$p0" ] \
        && [ "$(lsha "$LC/panel/.env")" = "$e0" ] && manifest_consistent && [ ! -e "$LC/panel/.subpage-install.lock" ] && echo 1)" \
        "killed at $boundary, then rollback: the page and .env are exactly what they were before that install, and every record matches its file (install $killed_rc, rollback $LRC: $(printf '%s' "$LOUT" | grep -E 'restored|left|already|refusing' | tail -n1 | LC_ALL=C tr -c ' -~' '?'))"
    else
      run_linked
      lexpect "$([ "$killed_rc" -ne 0 ] && [ "$LRC" -eq 0 ] && [ "$(lsha "$LC/tpl/subscription/index.html")" = "$(lsha "$LINKPAGE")" ] \
        && grep -qxF "CUSTOM_TEMPLATES_DIRECTORY=\"$LC/tpl/\"" "$LC/panel/.env" && grep -qxF 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' "$LC/panel/.env" \
        && manifest_consistent && [ ! -e "$LC/panel/.subpage-install.lock" ] && echo 1)" \
        "killed at $boundary, then a rerun: the install completes, .env carries both settings, and every record matches its file (install $killed_rc, rerun $LRC: $(printf '%s' "$LOUT" | grep -E 'installed|refusing|left|lock' | tail -n1 | LC_ALL=C tr -c ' -~' '?'))"
    fi
  done
done

echo
echo "rollback keeps a copy of a page customised after the install"

link_case rollback-keeps-customised-page
run_linked
printf 'CUSTOMISED BY HAND\n' > "$LC/tpl/subscription/index.html"
chmod 640 "$LC/tpl/subscription/index.html"
run_linked --rollback
kept="$(ls -1 "$LC/tpl/subscription"/index.html.before-rollback-* 2>/dev/null | head -n1)"
lexpect "$([ "$LRC" -eq 0 ] && grep -qx 'LIVE PAGE rollback-keeps-customised-page' "$LC/tpl/subscription/index.html" && echo 1)" \
  "a page customised after the install: rollback still restores the backup (exit $LRC)"
lexpect "$([ -n "$kept" ] && grep -qx 'CUSTOMISED BY HAND' "$kept" && [ "$(lmode "$kept")" = 640 ] && printf '%s' "$LOUT" | grep -qF "$kept" && echo 1)" \
  "a page customised after the install: rollback keeps it with its mode and says where (kept: ${kept##*/})"
run_linked --rollback
lexpect "$([ "$LRC" -eq 0 ] && grep -qx 'LIVE PAGE rollback-keeps-customised-page' "$LC/tpl/subscription/index.html" && [ -n "$kept" ] && grep -qx 'CUSTOMISED BY HAND' "$kept" && echo 1)" \
  "a later rollback never restores the kept copy, and the copy stays in place (exit $LRC)"

link_case rollback-no-copy-when-unchanged
run_linked
run_linked --rollback
lexpect "$([ "$LRC" -eq 0 ] && [ -z "$(ls "$LC/tpl/subscription"/index.html.before-rollback-* 2>/dev/null)" ] && echo 1)" \
  "a page left as the install put it: rollback makes no extra copy ($(ls -A "$LC/tpl/subscription" | tr '\n' ' '))"

link_case rollback-keep-copy-blocked
run_linked
printf 'CUSTOMISED BY HAND\n' > "$LC/tpl/subscription/index.html"
printf 'NOT OURS\n' > "$LC/tpl/subscription/index.html.before-rollback-20300101-000000"
printf '20300101-000000\n' > "$LC/private/clock"
run_seamed "DATE_SEQ=$LC/private/clock" --rollback
lexpect "$([ "$LRC" -ne 0 ] && grep -qx 'CUSTOMISED BY HAND' "$LC/tpl/subscription/index.html" \
  && grep -qx 'NOT OURS' "$LC/tpl/subscription/index.html.before-rollback-20300101-000000" && echo 1)" \
  "a customised page that cannot be copied aside is not replaced, and the file already there is untouched (exit $LRC: $(printf '%s' "$LOUT" | grep -E 'copy|refusing|restored' | tail -n1))"

rm -rf "$LINKWORK"
fi

echo
printf 'passed %s, failed %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
