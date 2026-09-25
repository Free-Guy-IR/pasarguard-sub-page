#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
bad() { printf 'FAIL %s\n' "$*"; fail=1; }
PACKAGE_MANAGERS='(^|[^a-z])(bun|npm|npx|yarn|pnpm)([^a-z]|$)|setup-bun|setup-node'

shopt -s nullglob
workflows=("$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml)
[ "${#workflows[@]}" -gt 0 ] || { echo "FAIL no workflows found"; exit 1; }

for wf in "${workflows[@]}"; do
  name="${wf#"$ROOT"/}"

  while IFS= read -r line; do
    target="$(printf '%s' "$line" | sed -E 's/^[[:space:]-]*uses:[[:space:]]*//; s/[[:space:]].*$//; s/["'\'']//g')"
    case "$target" in
      ./*) continue ;;
    esac
    pin="${target##*@}"
    if [ "$pin" = "$target" ] || ! printf '%s' "$pin" | grep -qE '^[0-9a-f]{40}$'; then
      bad "$name: '$target' is not pinned to a full commit hash"
    fi
  done < <(grep -E '^[[:space:]-]*uses:' "$wf")

  checkouts="$(grep -cE '^[[:space:]-]*uses:[[:space:]]*actions/checkout@' "$wf")"
  kept="$(grep -cE '^[[:space:]]*persist-credentials:[[:space:]]*false[[:space:]]*$' "$wf")"
  if [ "$checkouts" -ne "$kept" ]; then
    bad "$name: $checkouts checkout step(s) but $kept with persist-credentials: false"
  fi

  if grep -qE '^permissions:[[:space:]]*\{\}[[:space:]]*$' "$wf"; then
    :
  elif ! grep -qE '^permissions:' "$wf"; then
    bad "$name: no workflow-level permissions, so every job gets the repository default"
  else
    block="$(awk '/^permissions:/{p=1;next} p&&/^[^[:space:]]/{exit} p&&NF{print}' "$wf")"
    if [ -z "$block" ] || printf '%s\n' "$block" | grep -qvE '^[[:space:]]+[a-z-]+:[[:space:]]*(read|none)[[:space:]]*$'; then
      bad "$name: the workflow-level permissions grant more than read"
    fi
  fi

  if hit="$(grep -nE "$PACKAGE_MANAGERS" "$wf" | head -n1)" && [ -n "$hit" ]; then
    bad "$name: installs or runs a JavaScript package manager: $hit"
  fi

  if grep -nE '\$\{\{[[:space:]]*github\.event\.' "$wf" \
     | grep -qvE '^[0-9]+:[[:space:]]*[A-Z_]+:[[:space:]]*\$\{\{'; then
    bad "$name: a github.event value is expanded outside an env: entry"
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "ok  ${#workflows[@]} workflow(s): actions pinned by commit, no persisted credentials, least-privilege defaults, no package manager"
fi
exit "$fail"
