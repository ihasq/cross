#!/bin/bash
set -Eeuo pipefail

[[ -f /etc/lsb-release ]] || { echo 'run on ChromeOS' >&2; exit 1; }
[[ "$(id -un)" == chronos ]] || { echo 'run as chronos' >&2; exit 1; }

cross_bin="${CROSS_PREFIX:-/usr/local/cross}/bin/cross"
[[ -x "$cross_bin" ]] || { echo 'Cross is not installed' >&2; exit 1; }

"$cross_bin" status
"$cross_bin" doctor
"$cross_bin" /bin/sh -eu -c '
  test "$CROSS_SESSION" = 1
  test -x /usr/local/libexec/cross-apk2
  test -f /usr/share/keyrings/debian-archive-keyring.gpg
  test -f /run/openrc/softlevel
  test -S /run/dbus/system_bus_socket
  getent ahosts dl-cdn.alpinelinux.org >/dev/null
'

probe="${CROSS_WORK:-/usr/local/cross/work/chronos}/.release-smoke-$$"
mkdir -p "$probe"
trap 'rm -rf -- "$probe"' EXIT
printf '#include <stdio.h>\nint main(void){puts("ok");}\n' > "$probe/main.c"
(cd "$probe" && "$cross_bin" cc main.c -o main && "$cross_bin" ./main) \
  | grep -qx ok

printf 'ChromeOS real-device smoke test: OK\n'
