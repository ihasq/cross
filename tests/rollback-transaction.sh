#!/bin/bash
set -Eeuo pipefail

unset CDPATH
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$(mktemp -d /tmp/cross-rollback-test.XXXXXXXX)"
cleanup() { sudo rm -rf -- "$test_root"; }
trap cleanup EXIT

(
  export CROSS_PREFIX="$test_root/cross"
  # Load functions without executing the installer's final main call.
  # shellcheck disable=SC1090
  source <(sed '$d' "$repo/cross.sh")
  trap - EXIT ERR

  mkdir -p \
    "$CROSS_ROOT/lib/apk/db" \
    "$CROSS_ROOT/bin" \
    "$CROSS_ROOT/etc/apk" \
    "$CROSS_ROOT/usr/local/libexec" \
    "$CROSS_BIN" "$CROSS_ETC" "$CROSS_WORK"
  : > "$CROSS_ROOT/lib/apk/db/installed"
  printf '#!/bin/sh\nexit 0\n' > "$CROSS_ROOT/bin/busybox"
  printf '#!/bin/sh\necho apk-tools 2.14.13\n' > "$APK_COMPAT_BIN"
  chmod 0755 "$CROSS_ROOT/bin/busybox" "$APK_COMPAT_BIN"
  printf 'old-root\n' > "$CROSS_ROOT/version"
  printf 'old-bin\n' > "$CROSS_BIN/version"
  printf 'old-etc\n' > "$CROSS_ETC/version"
  printf 'complete\n' > "$CROSS_COMPLETE"

  begin_transaction
  printf 'new-root\n' > "$CROSS_ROOT/version"
  printf 'new-bin\n' > "$CROSS_BIN/version"
  printf 'new-etc\n' > "$CROSS_ETC/version"
  rollback_transaction

  [[ "$(cat "$CROSS_ROOT/version")" == old-root ]]
  [[ "$(cat "$CROSS_BIN/version")" == old-bin ]]
  [[ "$(cat "$CROSS_ETC/version")" == old-etc ]]
  [[ -f "$CROSS_COMPLETE" ]]

  legacy="$CROSS_PREFIX/.rollback-legacy-test"
  sudo mkdir -m 0700 "$legacy"
  sudo cp -a "$CROSS_ROOT" "$legacy/alpine"
  sudo cp -a "$CROSS_BIN" "$legacy/bin"
  sudo cp -a "$CROSS_ETC" "$legacy/etc"
  sudo cp -a "$CROSS_COMPLETE" "$legacy/complete"
  printf 'broken-root\n' > "$CROSS_ROOT/version"
  printf 'broken-bin\n' > "$CROSS_BIN/version"
  printf 'broken-etc\n' > "$CROSS_ETC/version"
  recover_legacy_rollback
  [[ "$(cat "$CROSS_ROOT/version")" == old-root ]]
  [[ "$(cat "$CROSS_BIN/version")" == old-bin ]]
  [[ "$(cat "$CROSS_ETC/version")" == old-etc ]]
)

printf 'rollback transaction test: OK\n'
