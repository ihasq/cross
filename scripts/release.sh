#!/bin/bash
set -Eeuo pipefail

unset CDPATH
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo"

sha256sum cross.sh > SHA256SUMS
bash tests/static.sh

if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git diff --check
  if [[ -n "$(git status --short)" ]]; then
    echo 'release tree is not clean' >&2
    exit 1
  fi
fi

printf 'release artifacts refreshed: SHA256SUMS\n'
