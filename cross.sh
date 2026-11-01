#!/bin/bash
# cross.sh - Alpine-packages-only development environment for ChromeOS Developer Mode.
#
# No source builds, containers, VMs, or mount namespaces. Alpine executes in a
# chroot and is reached over a VT-2-started, localhost-only OpenSSH service.
# The ChromeOS HOME is bind-mounted at the same path. The *bind mount only* is
# remounted with exec, so HOME-resident ELF programs (e.g. cargo run output or
# VS Code CLI helpers) can execute without tool-specific cache/target overrides.
# A ChromeOS HOME symlink policy exception is attempted only if a symlink
# execution probe fails after mount flags have been corrected.
#
# Run from VT-2 as chronos: bash ~/Downloads/cross.sh
# After setup: source ~/.bashrc; cross; cargo run; code serve-web (if installed).

set -Eeuo pipefail
umask 022

SCRIPT_VERSION="2026-11-01.32-home-bind-exec"
ALPINE_VERSION="3.24.1"
ALPINE_BRANCH="v3.24"
APK_COMPAT_BRANCH="v3.22"
CROSS_PREFIX="${CROSS_PREFIX:-/usr/local/cross}"
CROSS_ROOT="$CROSS_PREFIX/alpine"
CROSS_BIN="$CROSS_PREFIX/bin"
CROSS_CACHE="$CROSS_PREFIX/cache"
CROSS_ETC="$CROSS_PREFIX/etc"
CROSS_RUN="$CROSS_PREFIX/run"
CROSS_LOG="$CROSS_PREFIX/log"
CROSS_WORK="$CROSS_PREFIX/work"
CROSS_SSH_PORT="${CROSS_SSH_PORT:-32222}"
CROSS_MARKER="$CROSS_PREFIX/.alpine-cross-managed"
CROSS_COMPLETE="$CROSS_PREFIX/.alpine-cross-complete"
LOG_FILE="${HOME:-/home/chronos/user}/cross-setup-$(date +%Y%m%d-%H%M%S).log"

HOST_ARCH=""
ALPINE_ARCH=""
FETCH_TOOL=""
CHROOT_BIN=""
HOST_SSH_BIN=""
ROOTFS_MOUNTED=()
SETUP_STARTED=0

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

enable_logging() {
  if have tee; then
    exec > >(tee -a "$LOG_FILE") 2>&1
  fi
}

require_vt2_eula_context() {
  local nnp
  (( EUID != 0 )) || die "run as chronos, not as root"
  [[ -f /etc/lsb-release ]] || die "this does not look like the ChromeOS host"
  have sudo || die "sudo is required; run from VT-2 in Developer Mode"
  nnp="$(awk '/^NoNewPrivs:/ {print $2}' /proc/self/status 2>/dev/null || true)"
  [[ "$nnp" != 1 ]] || die "run from VT-2, not browser crosh"
  [[ -c /dev/tty ]] || die "an interactive VT-2 terminal is required to accept the EULA"
}

show_eula_and_require_acceptance() {
  local reply
  cat <<'CROSS_EULA'

Cross End User License Agreement (EULA)
=======================================

Cross is a successor project to Chromebrew. By accepting, you agree:

1. Cross performs privileged operations in ChromeOS Developer Mode: sudo,
   chroot, bind mounts, an OpenSSH daemon bound to 127.0.0.1, and possible
   changes to ChromeOS symlink security policy until reboot.

2. Cross deliberately remounts the Alpine-visible bind mount of your HOME with
   exec while retaining nosuid,nodev and without modifying the original HOME
   mount flags. Because Cross uses no mount namespace, this executable alias
   can also be reached by host processes through /usr/local/cross/alpine.
   This reduces the effective protection supplied by HOME's noexec setting.

3. If ChromeOS blocks symlinks in HOME, Cross may request a symlink-policy
   exception for this HOME subtree until reboot. It does not promise that
   every ChromeOS kernel or security configuration will permit this change.

4. Developer Mode, executable mounts, and privileged modifications reduce
   security and may cause data loss. Back up data and review this script.

5. Cross is provided "AS IS" without warranties, to the extent permitted by
   law. Alpine and other third-party software retain their own licenses.

6. Acceptance authorizes the operations above. Otherwise setup will exit.
CROSS_EULA
  while :; do
    printf '\nDo you accept the Cross EULA? [y/n]: ' >/dev/tty
