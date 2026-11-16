#!/bin/bash
# cross.sh - Alpine-packages-only development environment for ChromeOS Developer Mode.
#
# No third-party source builds, containers, VMs, or mount namespaces. Alpine executes in a
# chroot and is reached over a VT-2-started, localhost-only OpenSSH service.
# The ChromeOS HOME is bind-mounted at the same path. The *bind mount only* is
# remounted with exec, so HOME-resident ELF programs (e.g. cargo run output or
# VS Code CLI helpers) can execute without tool-specific cache/target overrides.
# A ChromeOS HOME symlink policy exception is attempted only if a symlink
# execution probe fails after mount flags have been corrected.
#
# Run from VT-2 as chronos: bash ~/Downloads/cross.sh
# After setup the service starts immediately and, when supported, at every
# ChromeOS boot. On a stock verified image, setup disables rootfs verification;
# a post-reboot rerun installs the Upstart job under /etc/init. If unavailable,
# setup completes with manual startup after reboot.
# Then: source ~/.bashrc; cross; cargo run; code serve-web (if installed).

set -Eeuo pipefail
umask 022

SCRIPT_VERSION="2026-11-16.52-open-command"
ALPINE_VERSION="3.24.1"
ALPINE_BRANCH="v3.24"
APK_COMPAT_BRANCH="v3.22"
INITIAL_DOWNLOAD_JOBS=6
CROSS_PREFIX="${CROSS_PREFIX:-/usr/local/cross}"
CROSS_ROOT="$CROSS_PREFIX/alpine"
CROSS_BIN="$CROSS_PREFIX/bin"
CROSS_CACHE="$CROSS_PREFIX/cache"
CROSS_ETC="$CROSS_PREFIX/etc"
CROSS_RUN="$CROSS_PREFIX/run"
CROSS_LOG="$CROSS_PREFIX/log"
CROSS_WORK="$CROSS_PREFIX/work"
CROSS_SSH_PORT="${CROSS_SSH_PORT:-32222}"
CROSS_DESKTOP_PORT="${CROSS_DESKTOP_PORT:-32221}"
CROSS_DESKTOP_UUID=""
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
BOOT_AUTOSTART_AVAILABLE=0

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

show_ascii_banner() {
  cat <<'CROSS_ASCII'
 ▄▀▀▀▀▀▄  █▀▀▀▀▀▀▄   ▄▀▀▀▀▀▄   ▄▀▀▀▀▀▄   ▄▀▀▀▀▀▄
▓ ▄▀▀▀▄ ▒ ▓ ░▀▀▀▄ ▓ ▓ ▄▀▀▀▄ ▓ ▓ ▄▀▀▀▄ ▓ ▓ ▄▀▀▀▄ ▓
▒ ▒   ░▄░ ▒ ▒   ░ ░ ▒ ▒   ░ ▒ ▒ ▀▄  ▀▀▀ ▒ ▀▄  ▀▀▀
▒ ▓       ░ ▓▒░░▀▄▀ ░ ▓   ▒ ░  ▀▄ ▀▀▀▄   ▀▄ ▀▀▀▄
█ ▓   ▓▀▓ ▓ ░▀▀▀▀ ▓ █ █   ▓ ▓ ▄▄▄▀▀▀▄ ▓ ▄▄▄▀▀▀▄ ▓
█ ▀▄▄▄▀ ░ ▒ ▓   ░ ░ █ ▀▄▄▄▀ ░ █ ▀▄▄▄▀ ░ █ ▀▄▄▄▀ ░
 ▀▄▄▄▄▄▀  ░▄█   ▓▄█  ▀▄▄▄▄▄▀   ▀▄▄▄▄▄▀   ▀▄▄▄▄▄▀
CROSS_ASCII
}

enable_logging() {
  if have tee; then
    exec > >(tee -a "$LOG_FILE") 2>&1
  fi
}

require_vt2_eula_context() {
  local nnp
  (( EUID != 0 )) || die "run as chronos, not as root"
  if [[ -n "${CROSS_SESSION:-}" ]]; then
    die "cross.sh is running inside Alpine; update once with: /usr/bin/curl https://cross-sh.pages.dev/cross.sh | /bin/bash"
  fi
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

6. Cross boot autostart requires an Upstart job under /etc/init. On a stock
   ChromeOS release image, setup uses ChromeOS's make_dev_ssd.sh tool to disable
   rootfs verification, then requires a reboot and a second setup run only to
   add autostart. This weakens verified boot, can affect OS updates, and may
   require recovery media to restore the device. Hardware write protection is
   not changed. Cross setup continues if autostart cannot be configured safely.

7. Cross Desktop adds a localhost-only Xpra HTTP/WebSocket service on port
   32221. Its browser client can exchange clipboard contents and files with the
   Alpine session, and dropped media files may be opened automatically in VLC.

8. Acceptance authorizes the operations above. Otherwise setup will exit.
CROSS_EULA
  while :; do
    printf '\nDo you accept the Cross EULA? [y/n]: ' >/dev/tty
    if ! IFS= read -r reply </dev/tty; then
      die "unable to read the EULA response from VT-2"
    fi
    case "$reply" in
      y|Y) info "EULA accepted"; return 0 ;;
      n|N|'') printf '\nCross EULA not accepted; setup cancelled.\n' >/dev/tty; exit 1 ;;
      *) printf 'Please answer y or n.\n' >/dev/tty ;;
    esac
  done
}

release_setup_mounts() {
  local i target
  for ((i=${#ROOTFS_MOUNTED[@]}-1; i>=0; i--)); do
    target="${ROOTFS_MOUNTED[$i]}"
    sudo umount -l "$target" >/dev/null 2>&1 || true
  done
  ROOTFS_MOUNTED=()
}

cleanup() {
  local status=$?
  release_setup_mounts
  if (( status != 0 && SETUP_STARTED != 0 )); then
    printf '\nSetup failed. Log: %s\n' "$LOG_FILE" >&2
  fi
}
trap cleanup EXIT
trap 'die "line ${LINENO}: command failed: ${BASH_COMMAND}"' ERR

sha256_file() {
  local file="$1"
  if have sha256sum; then
    sha256sum "$file" | awk '{print $1}'
  elif have openssl; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    die "sha256sum or openssl is required"
  fi
}

fetch() {
  local url="$1" out="$2" progress_file="${3:-}"
  mkdir -p "$(dirname "$out")"
  [[ -n "$progress_file" ]] && rm -f "$progress_file"
  [[ -s "$out" ]] && return 0
  if [[ -z "$progress_file" ]]; then
    printf '\033[1;34m==>\033[0m Downloading %s\n' "${out##*/}"
  fi
  rm -f "$out.part"
  case "${FETCH_TOOL##*/}" in
    curl)
      if [[ -n "$progress_file" ]]; then
        env -u LD_LIBRARY_PATH "$FETCH_TOOL" --fail --location --show-error \
          --progress-bar --retry 5 --retry-delay 2 --proto '=https' --tlsv1.2 \
          --output "$out.part" "$url" 2>"$progress_file"
      else
        env -u LD_LIBRARY_PATH "$FETCH_TOOL" --fail --location --show-error \
          --progress-bar --retry 5 --retry-delay 2 --proto '=https' --tlsv1.2 \
          --output "$out.part" "$url"
      fi
      ;;
    wget)
      if [[ -n "$progress_file" ]]; then
        env -u LD_LIBRARY_PATH "$FETCH_TOOL" --https-only --tries=5 \
          --output-document="$out.part" "$url" 2>"$progress_file"
      else
        env -u LD_LIBRARY_PATH "$FETCH_TOOL" --https-only --tries=5 \
          --output-document="$out.part" "$url"
      fi
      ;;
    *) die "no download tool selected" ;;
  esac
  [[ -s "$out.part" ]] || die "empty download: $url"
  mv "$out.part" "$out"
}

is_mounted() {
  local target="$1"
  awk -v target="$target" '$2 == target { found=1 } END { exit !found }' /proc/mounts
}

mount_bind() {
  local source="$1" target="$2" recursive="${3:-0}"
  sudo mkdir -p "$target"
  if ! is_mounted "$target"; then
    if [[ "$recursive" == 1 ]]; then
      sudo mount --rbind "$source" "$target"
      sudo mount --make-rslave "$target" 2>/dev/null || true
    else
      sudo mount --bind "$source" "$target"
    fi
    ROOTFS_MOUNTED+=("$target")
  fi
}

mount_proc() {
  local target="$1"
  sudo mkdir -p "$target"
  if ! is_mounted "$target"; then
    sudo mount -t proc proc "$target"
    ROOTFS_MOUNTED+=("$target")
  fi
}

sync_host_dns() {
  local source="" candidate="" target="" temp=""
  target="$CROSS_ROOT/etc/resolv.conf"
  for candidate in \
    /run/dns-proxy/resolv.conf \
    /run/shill/resolv.conf \
    /etc/resolv.conf \
    /run/systemd/resolve/resolv.conf; do
    [[ -f "$candidate" && -r "$candidate" && -s "$candidate" ]] || continue
    if awk '
      $1 == "nameserver" && NF >= 2 && $2 !~ /^#/ &&
      $2 != "0.0.0.0" && $2 != "::" { found=1 }
      END { exit !found }
    ' "$candidate"; then
      source="$candidate"
      break
    fi
  done
  [[ -n "$source" ]] || die "No usable ChromeOS DNS configuration found"
  sudo mkdir -p "$CROSS_ROOT/etc"
  temp="$(sudo mktemp "$CROSS_ROOT/etc/.resolv.conf.cross.XXXXXXXX")"
  if ! sudo cp -L -- "$source" "$temp"; then
    sudo rm -f "$temp"
    die "Failed to copy ChromeOS DNS configuration: $source"
  fi
  sudo chown root:root "$temp"
  sudo chmod 0644 "$temp"
  sudo mv -f -- "$temp" "$target"
  info "Alpine DNS configured from $source"
}

ensure_file_backed_package_scripts() {
  local execdir="$CROSS_ROOT/lib/apk/exec"
  local probe="$execdir/.cross-exec-probe"
  sudo mkdir -p "$execdir"
  printf '%s\n' '#!/bin/sh' 'exit 0' | sudo tee "$probe" >/dev/null
  sudo chmod 0755 "$probe"
  if ! sudo "$CHROOT_BIN" "$CROSS_ROOT" /lib/apk/exec/.cross-exec-probe >/dev/null 2>&1; then
    sudo rm -f "$probe"
    die "ChromeOS denies apk-tools v2 file-backed package scripts"
  fi
  sudo rm -f "$probe"
}

bootstrap_apk_v2_runner() {
  local compat_repositories="$CROSS_ROOT/etc/apk/repositories.apk2"
  local version=""
  if [[ -x "$CROSS_ROOT/sbin/apk.static" ]]; then
    version="$(sudo "$CHROOT_BIN" "$CROSS_ROOT" /sbin/apk.static --version 2>&1 | sed -n '1p')"
  fi
  if [[ "$version" != apk-tools\ 2.* ]]; then
    info "Installing Alpine apk-tools v2 compatibility runner"
    cat <<REPOS | sudo tee "$compat_repositories" >/dev/null
https://dl-cdn.alpinelinux.org/alpine/${APK_COMPAT_BRANCH}/main
REPOS
    sudo "$CHROOT_BIN" "$CROSS_ROOT" /sbin/apk \
      --progress \
      --repositories-file /etc/apk/repositories.apk2 \
      --scripts=no --commit-hooks=no add --no-cache apk-tools-static
    [[ -x "$CROSS_ROOT/sbin/apk.static" ]] || die "Alpine apk-tools v2 binary not installed"
    version="$(sudo "$CHROOT_BIN" "$CROSS_ROOT" /sbin/apk.static --version 2>&1 | sed -n '1p')"
  else
    info "Using existing Alpine apk-tools v2 compatibility runner"
  fi
  [[ "$version" == apk-tools\ 2.* ]] || die "unexpected compatibility apk version: $version"
  printf 'Compatibility apk: %s\n' "$version"
  sudo mkdir -p "$CROSS_ROOT/usr/local/sbin"
  sudo ln -sfn /sbin/apk.static "$CROSS_ROOT/usr/local/sbin/apk"
}

ensure_chroot_exec() {
  local security_mnt="/sys/kernel/security"
  local policy_file="$security_mnt/chromiumos/inode_security_policies/allow_symlink"
  local mounted_here=0 remounted_rw=0 security_opts=""
  [[ -x "$CROSS_ROOT/bin/busybox" ]] || die "Alpine /bin/busybox missing"
  if sudo "$CHROOT_BIN" "$CROSS_ROOT" /bin/busybox true >/dev/null 2>&1; then
    return 0
  fi
  warn "ChromeOS denied chroot exec; trying Developer Mode symlink exception"
  sudo mkdir -p "$security_mnt"
  if ! is_mounted "$security_mnt"; then
    sudo mount -t securityfs -o nodev,noexec,nosuid securityfs "$security_mnt" \
      || die "cannot mount ChromeOS securityfs"
    mounted_here=1
  fi
  security_opts="$(awk -v t="$security_mnt" '$2 == t {print $4; exit}' /proc/mounts)"
  if [[ ",$security_opts," == *,ro,* ]]; then
    sudo mount -o remount,rw "$security_mnt" || die "cannot remount securityfs read-write"
    remounted_rw=1
  fi
  [[ -e "$policy_file" ]] || die "ChromeOS allow_symlink policy unavailable: $policy_file"
  printf '%s' '/mnt/stateful_partition/dev_image' | sudo tee "$policy_file" >/dev/null
  if ! sudo "$CHROOT_BIN" "$CROSS_ROOT" /bin/busybox true >/dev/null 2>&1; then
    warn "Narrow dev_image rule insufficient; allowing stateful symlinks until reboot"
    printf '%s' '/mnt/stateful_partition' | sudo tee "$policy_file" >/dev/null
  fi
  if (( remounted_rw )); then
    sudo mount -o remount,ro "$security_mnt" >/dev/null 2>&1 || true
  fi
  if (( mounted_here )); then
    sudo umount "$security_mnt" >/dev/null 2>&1 || true
  fi
  sudo "$CHROOT_BIN" "$CROSS_ROOT" /bin/busybox true >/dev/null 2>&1 \
    || die "ChromeOS still denies execution inside Alpine rootfs"
}

preflight() {
  info "cross.sh $SCRIPT_VERSION"
  info "Preflight checks"
  (( EUID != 0 )) || die "run as chronos, not as root"
  [[ -f /etc/lsb-release ]] || die "this does not look like ChromeOS"
  have sudo || die "sudo is required"
  have tar || die "tar is required"
  if have chroot; then
    CHROOT_BIN="$(command -v chroot)"
  elif [[ -x /usr/sbin/chroot ]]; then
    CHROOT_BIN="/usr/sbin/chroot"
  else
    die "chroot is required"
  fi
  local candidate
  for candidate in /usr/bin/ssh /bin/ssh /usr/local/bin/ssh; do
    if [[ -x "$candidate" && "$candidate" != "$CROSS_BIN/ssh" ]]; then
      HOST_SSH_BIN="$candidate"
      break
    fi
  done
  if [[ -z "$HOST_SSH_BIN" ]]; then
    candidate="$(PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin command -v ssh 2>/dev/null || true)"
    if [[ -n "$candidate" && -x "$candidate" && "$candidate" != "$CROSS_BIN/ssh" ]]; then
      HOST_SSH_BIN="$candidate"
    fi
  fi
  [[ -n "$HOST_SSH_BIN" ]] || die "host OpenSSH client required"
  "$HOST_SSH_BIN" -V >/dev/null 2>&1 || die "host SSH unusable: $HOST_SSH_BIN"
  local nnp opts free_kib
  nnp="$(awk '/^NoNewPrivs:/ {print $2}' /proc/self/status 2>/dev/null || true)"
  [[ "$nnp" != 1 ]] || die "NoNewPrivs active; use VT-2"
  sudo true
  # Always use a ChromeOS binary. Older Cross releases put curl and wget
  # wrappers at the front of PATH; those wrappers become unusable as soon as
  # the existing Cross service is stopped for maintenance.
  for candidate in /usr/bin/curl /bin/curl /usr/local/bin/curl; do
    if [[ -x "$candidate" && "$candidate" != "$CROSS_BIN/curl" ]]; then
      FETCH_TOOL="$candidate"
      break
    fi
  done
  if [[ -z "$FETCH_TOOL" ]]; then
    for candidate in /usr/bin/wget /bin/wget /usr/local/bin/wget; do
      if [[ -x "$candidate" && "$candidate" != "$CROSS_BIN/wget" ]]; then
        FETCH_TOOL="$candidate"
        break
      fi
    done
  fi
  [[ -n "$FETCH_TOOL" ]] || die "host curl or wget required"
  HOST_ARCH="$(uname -m)"
  case "$HOST_ARCH" in
    aarch64|arm64) ALPINE_ARCH="aarch64" ;;
    x86_64|amd64) ALPINE_ARCH="x86_64" ;;
    *) die "unsupported architecture: $HOST_ARCH" ;;
  esac
  [[ "$CROSS_PREFIX" == /* && "$CROSS_PREFIX" != *[[:space:]]* ]] \
    || die "CROSS_PREFIX must be an absolute path without whitespace"
  [[ "$CROSS_SSH_PORT" =~ ^[0-9]+$ ]] &&
    (( CROSS_SSH_PORT >= 1024 && CROSS_SSH_PORT <= 65535 )) \
    || die "CROSS_SSH_PORT must be 1024..65535"
  [[ "$CROSS_DESKTOP_PORT" =~ ^[0-9]+$ ]] &&
    (( CROSS_DESKTOP_PORT >= 1024 && CROSS_DESKTOP_PORT <= 65535 )) \
    || die "CROSS_DESKTOP_PORT must be 1024..65535"
  [[ "$CROSS_DESKTOP_PORT" != "$CROSS_SSH_PORT" ]] \
    || die "CROSS_DESKTOP_PORT and CROSS_SSH_PORT must be different"
  opts="$(awk '$2 == "/usr/local" {print $4}' /proc/mounts | tail -n1)"
  [[ ",$opts," != *,noexec,* ]] || die "/usr/local is noexec"
  [[ ",$opts," != *,nosuid,* ]] || die "/usr/local nosuid; Alpine sudo needs setuid"
  free_kib="$(df -Pk /usr/local | awk 'NR==2 {print $4}')"
  [[ "$free_kib" =~ ^[0-9]+$ ]] || free_kib=0
  (( free_kib >= 1200000 )) || die "at least 1.2 GiB free space under /usr/local required"
  printf 'Architecture: %s\nAlpine: %s\nPrefix: %s\nHost SSH: %s\nSSH port: %s\n' \
    "$ALPINE_ARCH" "$ALPINE_VERSION" "$CROSS_PREFIX" "$HOST_SSH_BIN" "$CROSS_SSH_PORT"
}

reset_or_prepare_prefix() {
  info "Preparing Alpine-only prefix"
  [[ ! -L "$CROSS_PREFIX" ]] || die "refusing symlinked Cross prefix: $CROSS_PREFIX"
  if [[ -d "$CROSS_PREFIX" && ! -f "$CROSS_MARKER" ]]; then
    if [[ -d "$CROSS_PREFIX/var/db/cross" || -d "$CROSS_PREFIX/opt/zig-0.16.0" ]] \
      || compgen -G "$CROSS_PREFIX/opt/alpine-make-*" >/dev/null; then
      local backup="${CROSS_PREFIX}.source-build-backup-$(date +%Y%m%d-%H%M%S)"
      warn "Moving previous source-built environment to $backup"
      sudo mv "$CROSS_PREFIX" "$backup"
    elif [[ -n "$(find "$CROSS_PREFIX" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
      die "$CROSS_PREFIX exists but is not cross.sh-managed"
    fi
  fi
  [[ ! -L "$CROSS_ETC" ]] || die "refusing symlinked Cross etc directory: $CROSS_ETC"
  [[ ! -L "$CROSS_LOG" ]] || die "refusing symlinked Cross log directory: $CROSS_LOG"
  [[ ! -L "$CROSS_MARKER" ]] || die "refusing symlinked Cross marker: $CROSS_MARKER"
  [[ ! -L "$CROSS_COMPLETE" ]] || die "refusing symlinked completion marker: $CROSS_COMPLETE"
  sudo mkdir -p "$CROSS_PREFIX" "$CROSS_ROOT" "$CROSS_BIN" "$CROSS_CACHE" \
    "$CROSS_ETC" "$CROSS_RUN" "$CROSS_LOG" "$CROSS_WORK"
  # Keep the prefix and etc directory root-owned because the boot job follows
  # paths through them as root. User-writable working directories remain below.
  sudo chown root:root "$CROSS_PREFIX" "$CROSS_ETC" "$CROSS_LOG"
  sudo chmod 0755 "$CROSS_PREFIX" "$CROSS_ETC" "$CROSS_LOG"
  sudo chown "$(id -u):$(id -g)" "$CROSS_BIN" "$CROSS_CACHE" \
    "$CROSS_RUN" "$CROSS_WORK"
  printf '%s\n' "$SCRIPT_VERSION" | sudo tee "$CROSS_MARKER" >/dev/null
  sudo chown root:root "$CROSS_MARKER"
  sudo chmod 0644 "$CROSS_MARKER"
}

quiesce_existing_service() {
  if [[ -x "$CROSS_BIN/cross-service" && -r "$CROSS_ETC/cross.conf" ]]; then
    info "Stopping existing cross service for maintenance"
    "$CROSS_BIN/cross-service" stop
  fi
}

rootfs_is_resumable() {
  [[ -f "$CROSS_ROOT/lib/apk/db/installed" ]] \
    && [[ -x "$CROSS_ROOT/bin/busybox" ]] \
    && [[ -x "$CROSS_ROOT/sbin/apk.static" ]] \
    && [[ -x "$CROSS_ROOT/usr/bin/git" ]] \
    && [[ -x "$CROSS_ROOT/usr/bin/gcc" ]] \
    && [[ -x "$CROSS_ROOT/usr/bin/make" ]] \
    && [[ -x "$CROSS_ROOT/usr/bin/rustc" ]] \
    && [[ -x "$CROSS_ROOT/usr/bin/cargo" ]] \
    && [[ -x "$CROSS_ROOT/usr/bin/node" ]] \
    && [[ -x "$CROSS_ROOT/usr/bin/npm" ]] \
    && [[ -x "$CROSS_ROOT/sbin/su-exec" ]]
}

# Never recursively delete a rootfs with lingering bind mounts (especially HOME).
assert_rootfs_unmounted_before_removal() {
  local mounted=""
  mounted="$(awk -v p="$CROSS_ROOT" '$2 == p || index($2, p "/") == 1 {print $2}' /proc/mounts)"
  [[ -z "$mounted" ]] || die "Refusing to remove mounted rootfs; unmount first:\n$mounted"
}

download_and_extract_rootfs() {
  local base archive sumfile expected actual version_file
  base="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}"
  archive="$CROSS_CACHE/alpine-minirootfs-${ALPINE_VERSION}-${ALPINE_ARCH}.tar.gz"
  sumfile="$archive.sha256"
  version_file="$CROSS_ROOT/etc/alpine-release"
  if [[ -f "$version_file" && "$(cat "$version_file")" == "$ALPINE_VERSION" ]]; then
    if rootfs_is_resumable; then
      if [[ -f "$CROSS_COMPLETE" ]]; then
        info "Alpine minirootfs $ALPINE_VERSION already installed"
      else
        warn "Resuming populated but unvalidated Alpine setup"
      fi
      return 0
    fi
    if [[ -f "$CROSS_COMPLETE" ]]; then
      warn "Completion marker found, but required Alpine commands are missing"
    else
      warn "Incomplete Alpine rootfs found"
    fi
    warn "Rebuilding incomplete Alpine rootfs"
  fi
  fetch "$base/${archive##*/}.sha256" "$sumfile"
  fetch "$base/${archive##*/}" "$archive"
  expected="$(awk 'NF {print $1; exit}' "$sumfile")"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "invalid Alpine SHA-256 file"
  actual="$(sha256_file "$archive")"
  [[ "${actual,,}" == "${expected,,}" ]] || { rm -f "$archive"; die "SHA-256 mismatch"; }
  assert_rootfs_unmounted_before_removal
  info "Extracting Alpine minirootfs $ALPINE_VERSION"
  sudo rm -f "$CROSS_COMPLETE"
  sudo rm -rf "$CROSS_ROOT"
  sudo mkdir -p "$CROSS_ROOT"
  sudo tar -xzf "$archive" -C "$CROSS_ROOT"
  sudo chown root:root "$CROSS_ROOT"
}

configure_rootfs() {
  info "Configuring Alpine repositories"
  sudo mkdir -p "$CROSS_ROOT/etc/apk" "$CROSS_ROOT/etc/ssl/certs"
  cat <<REPOS | sudo tee "$CROSS_ROOT/etc/apk/repositories" >/dev/null
https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/main
https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/community
REPOS
  sync_host_dns
  if [[ -f /etc/hosts ]]; then sudo cp -L -f /etc/hosts "$CROSS_ROOT/etc/hosts"; fi
  mount_bind /dev "$CROSS_ROOT/dev" 1
  mount_proc "$CROSS_ROOT/proc"
  mount_bind /sys "$CROSS_ROOT/sys" 1
  [[ -d /run ]] && mount_bind /run "$CROSS_ROOT/run" 1 || true
  ensure_chroot_exec
  ensure_file_backed_package_scripts
  bootstrap_apk_v2_runner
}

apk_chroot() { sudo "$CHROOT_BIN" "$CROSS_ROOT" /sbin/apk.static --progress "$@"; }

format_download_size() {
  local bytes="$1"
  if (( bytes >= 1073741824 )); then
    printf '%d.%d GiB' "$((bytes / 1073741824))" "$(((bytes % 1073741824) * 10 / 1073741824))"
  elif (( bytes >= 1048576 )); then
    printf '%d.%d MiB' "$((bytes / 1048576))" "$(((bytes % 1048576) * 10 / 1048576))"
  elif (( bytes >= 1024 )); then
    printf '%d.%d KiB' "$((bytes / 1024))" "$(((bytes % 1024) * 10 / 1024))"
  else
    printf '%d B' "$bytes"
  fi
}

# Each entry is pid|sequence|filename|progress-file|partial-file. curl and wget
# write their own meter into separate files, and this function combines those
# meters into stable terminal rows so parallel downloads never interleave.
wait_for_apk_download_batch() {
  local total="$1"
  shift
  local entry pid sequence name meter partial raw percent percent_value
  local bytes size line progress_bar filled empty
  local active tick=0 rendered=0 tty_columns=80 batch_status=0 result
  local -a entries=("$@") results=()

  if [[ -w /dev/tty ]]; then
    tty_columns="$(stty size </dev/tty 2>/dev/null | awk '{print $2}')"
    [[ "$tty_columns" =~ ^[0-9]+$ ]] && (( tty_columns > 0 )) || tty_columns=80
  fi

  while :; do
    active=0
    for entry in "${entries[@]}"; do
      IFS='|' read -r pid sequence name meter partial <<<"$entry"
      if kill -0 "$pid" 2>/dev/null; then
        active=1
        break
      fi
    done

    [[ -w /dev/tty ]] || { (( active )) && sleep 0.25; (( active )) && continue; break; }
    if (( rendered )); then
      printf '\033[%dA' "${#entries[@]}" >/dev/tty
    fi
    for entry in "${entries[@]}"; do
      IFS='|' read -r pid sequence name meter partial <<<"$entry"
      raw=""
      [[ -f "$meter" ]] && raw="$(awk 'BEGIN { RS="[\\r\\n]" } NF { line=$0 } END { print line }' "$meter")"
      percent=""
      if [[ "$raw" =~ ([0-9]{1,3}([.][0-9]+)?)% ]]; then
        percent="${BASH_REMATCH[1]}%"
        percent_value="${BASH_REMATCH[1]%%.*}"
        percent_value=$((10#$percent_value))
      fi
      bytes=0
      if [[ -f "$partial" ]]; then
        bytes="$(wc -c <"$partial")"
      elif [[ -f "${partial%.part}" ]]; then
        bytes="$(wc -c <"${partial%.part}")"
      fi
      bytes="${bytes//[[:space:]]/}"
      [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
      size="$(format_download_size "$bytes")"
      if ! kill -0 "$pid" 2>/dev/null; then
        line="[$sequence/$total] [ finished ] $name ($size)"
      elif [[ -n "$percent" ]]; then
        (( percent_value > 100 )) && percent_value=100
        filled=$((percent_value / 10))
        empty=$((10 - filled))
        printf -v progress_bar '%*s' "$filled" ''
        progress_bar="${progress_bar// /#}"
        printf -v result '%*s' "$empty" ''
        result="${result// /-}"
        printf -v line '[%s/%s] [%s%s] %5s %s (%s)' \
          "$sequence" "$total" "$progress_bar" "$result" "$percent" "$name" "$size"
      else
        case $((tick % 4)) in
          0) result='|' ;; 1) result='/' ;; 2) result='-' ;; *) result='\' ;;
        esac
        line="[$sequence/$total] [    $result    ] $name ($size)"
      fi
      printf '\r\033[2K%.*s\n' "$tty_columns" "$line" >/dev/tty
    done
    rendered=1
    (( active )) || break
    ((tick += 1))
    sleep 0.25
  done

  for entry in "${entries[@]}"; do
    IFS='|' read -r pid sequence name meter partial <<<"$entry"
    if wait "$pid"; then
      results+=(0)
    else
      results+=(1)
      batch_status=1
    fi
  done

  if [[ -w /dev/tty ]]; then
    (( rendered )) && printf '\033[%dA' "${#entries[@]}" >/dev/tty
    local index=0
    for entry in "${entries[@]}"; do
      IFS='|' read -r pid sequence name meter partial <<<"$entry"
      bytes=0
      if [[ -f "${partial%.part}" ]]; then
        bytes="$(wc -c <"${partial%.part}")"
      elif [[ -f "$partial" ]]; then
        bytes="$(wc -c <"$partial")"
      fi
      bytes="${bytes//[[:space:]]/}"
      [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
      size="$(format_download_size "$bytes")"
      if (( results[index] == 0 )); then
        line="[$sequence/$total] [  100%   ] $name ($size)"
      else
        line="[$sequence/$total] [ FAILED  ] $name"
      fi
      printf '\r\033[2K%.*s\n' "$tty_columns" "$line" >/dev/tty
      ((index += 1))
    done
  fi

  if (( batch_status != 0 )); then
    index=0
    for entry in "${entries[@]}"; do
      IFS='|' read -r pid sequence name meter partial <<<"$entry"
      if (( results[index] == 0 )); then
        ((index += 1))
        continue
      fi
      if [[ -s "$meter" ]]; then
        printf 'Download output for %s:\n' "$name" >&2
        tr '\r' '\n' <"$meter" | tail -n 4 >&2
      fi
      ((index += 1))
    done
  fi
  return "$batch_status"
}

download_initial_packages() {
  local package_dir="$CROSS_ROOT/tmp/cross-initial-apks"
  local url_file="$package_dir/urls"
  local world_backup="$CROSS_ROOT/etc/apk/world.cross-before-initial-download"
  local url out meter sequence=0 status=0
  local -a urls=() batch=() packages=()

  info "Downloading initial Alpine packages (${INITIAL_DOWNLOAD_JOBS} parallel jobs)"
  sudo mkdir -p "$package_dir"
  sudo chown "$(id -u):$(id -g)" "$package_dir"

  # apk resolves the exact signed package set; the host downloader then fetches
  # that set concurrently. apk.static verifies every local package while adding
  # it below, so parallelism does not weaken Alpine's signature checks.
  apk_chroot fetch --recursive --simulate --url "$@" > "$url_file"
  mapfile -t urls < <(awk '/^https:\/\// && !seen[$0]++' "$url_file")
  ((${#urls[@]} > 0)) || die "apk returned no initial package URLs"

  for url in "${urls[@]}"; do
    ((sequence += 1))
    out="$package_dir/${url%%\?*}"
    out="$package_dir/${out##*/}"
    meter="$package_dir/.progress-$sequence"
    fetch "$url" "$out" "$meter" &
    batch+=("$!|$sequence|${out##*/}|$meter|$out.part")
    if ((${#batch[@]} == INITIAL_DOWNLOAD_JOBS)); then
      wait_for_apk_download_batch "${#urls[@]}" "${batch[@]}" || status=1
      batch=()
    fi
  done
  if ((${#batch[@]} > 0)); then
    wait_for_apk_download_batch "${#urls[@]}" "${batch[@]}" || status=1
  fi
  ((status == 0)) || die "one or more initial package downloads failed"

  for out in "$package_dir"/*.apk; do
    [[ -s "$out" ]] || die "initial package download set is incomplete"
    packages+=("/tmp/cross-initial-apks/${out##*/}")
  done

  # Adding local files would otherwise put every transitive dependency in
  # /etc/apk/world. Restore the pre-install world, then record only the packages
  # requested by Cross; the second add is offline because everything is present.
  sudo cp -f "$CROSS_ROOT/etc/apk/world" "$world_backup"
  if ! apk_chroot add --no-cache "${packages[@]}"; then
    sudo cp -f "$world_backup" "$CROSS_ROOT/etc/apk/world"
    sudo rm -rf "$package_dir"
    return 1
  fi
  sudo cp -f "$world_backup" "$CROSS_ROOT/etc/apk/world"
  apk_chroot --no-network add --no-cache "$@"
  sudo rm -f "$world_backup"
  sudo rm -rf "$package_dir"
}

install_alpine_packages() {
  info "Installing signed Alpine development packages"
  apk_chroot update
  local required=(
    bash ca-certificates coreutils findutils diffutils grep sed gawk
    tar gzip bzip2 xz file patch nano vim ffmpeg
    git git-init-template curl openssh-client openssh-server
    build-base linux-headers pkgconf cmake samurai meson autoconf automake libtool
    openssl-dev zlib-dev bzip2-dev xz-dev libffi-dev ncurses-dev readline-dev
    sqlite-dev libxml2-dev libxslt-dev libarchive-dev libssh2-dev libuv-dev
    rust cargo rustfmt rust-clippy rustup nodejs npm sudo su-exec gcompat
    xpra xpra-webclient py3-gst gstreamer gst-plugins-base gst-plugins-good
    pulseaudio pulseaudio-utils dbus xdg-utils shared-mime-info
    vlc vlc-qt xterm pcmanfm gvfs mousepad ristretto mupdf-x11 font-dejavu
  )
  if [[ -f "$CROSS_COMPLETE" ]]; then
    apk_chroot add --no-cache "${required[@]}"
  else
    download_initial_packages "${required[@]}"
  fi
  sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/sbin/update-ca-certificates || true
  sudo mkdir -p "$CROSS_ROOT/usr/local/bin"
  sudo ln -sfn /usr/bin/rustup-init "$CROSS_ROOT/usr/local/bin/rustup"
}

# npm's prebuilt workerd binaries use the glibc ELF interpreter. Alpine's
# gcompat supplies that interpreter, but gcompat 1.1.0-r4 lacks __res_init,
# which current workerd binaries reference. Supply only that missing alias;
# this remains dynamically linked to Alpine musl and avoids vendoring glibc.
configure_glibc_compat() {
  local shim="/usr/local/lib/cross-gcompat-resolver.so"
  info "Configuring glibc compatibility for prebuilt workerd"
  sudo mkdir -p "$CROSS_ROOT/usr/local/lib"
  printf '%s\n' \
    '#include <resolv.h>' \
    'int __res_init(void) { return res_init(); }' \
    | sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/bin/cc \
        -shared -fPIC -O2 -Wl,-soname,cross-gcompat-resolver.so \
        -x c - -o "$shim"
  sudo chown root:root "$CROSS_ROOT$shim"
  sudo chmod 0755 "$CROSS_ROOT$shim"
  sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/bin/nm -D "$shim" \
    | grep -Eq '[[:space:]]__res_init$' \
    || die "workerd compatibility shim does not export __res_init"
}

configure_chronos_user() {
  info "Configuring chronos identity inside Alpine"
  local uid gid group host_home shadow_tmp
  uid="$(id -u)"; gid="$(id -g)"; host_home="${HOME:-/home/chronos/user}"
  sudo mkdir -p "$CROSS_ROOT$host_home"
  if ! sudo grep -q '^chronos:' "$CROSS_ROOT/etc/passwd"; then
    group="$(sudo awk -F: -v gid="$gid" '$3 == gid {print $1; exit}' "$CROSS_ROOT/etc/group")"
    if [[ -z "$group" ]]; then
      sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/sbin/addgroup -g "$gid" chronos
      group="chronos"
    fi
    sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/sbin/adduser \
      -D -u "$uid" -G "$group" -h "$host_home" -s /bin/bash chronos
  fi
  shadow_tmp="$(mktemp)"
  sudo awk -F: 'BEGIN {OFS=FS} $1 == "chronos" {$2="x"} {print}' \
    "$CROSS_ROOT/etc/shadow" > "$shadow_tmp"
  sudo install -o root -g root -m 0600 "$shadow_tmp" "$CROSS_ROOT/etc/shadow"
  rm -f "$shadow_tmp"
}

configure_cross_sudo() {
  info "Configuring passwordless sudo inside Alpine"
  if ! sudo grep -q '^wheel:' "$CROSS_ROOT/etc/group"; then
    sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/sbin/addgroup -S wheel
  fi
  if ! sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/bin/id -nG chronos \
      | tr ' ' '\n' | grep -qx wheel; then
    sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/sbin/addgroup chronos wheel
  fi
  sudo mkdir -p "$CROSS_ROOT/etc/sudoers.d"
  cat <<'SUDOERS' | sudo tee "$CROSS_ROOT/etc/sudoers.d/cross-chronos" >/dev/null
Defaults:chronos secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Defaults:chronos env_keep += "TERM LANG LC_ALL LC_CTYPE CROSS_WORK SSL_CERT_FILE GIT_SSL_CAINFO"
chronos ALL=(ALL:ALL) NOPASSWD: ALL
SUDOERS
  sudo chown root:root "$CROSS_ROOT/etc/sudoers.d/cross-chronos"
  sudo chmod 0440 "$CROSS_ROOT/etc/sudoers.d/cross-chronos"
  [[ -u "$CROSS_ROOT/usr/bin/sudo" ]] || die "Alpine sudo not setuid root"
  sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/sbin/visudo -cf /etc/sudoers >/dev/null
}

configure_cross_desktop() {
  info "Configuring Cross Desktop canvas service"
  local uid host_home uuid_file www index_tmp
  uid="$(id -u)"; host_home="${HOME:-/home/chronos/user}"
  uuid_file="$CROSS_ETC/desktop.uuid"
  www="$CROSS_ROOT/usr/local/share/cross-desktop/www"

  if [[ -r "$uuid_file" ]]; then
    CROSS_DESKTOP_UUID="$(tr -d '\r\n' < "$uuid_file")"
  fi
  if [[ ! "$CROSS_DESKTOP_UUID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
    CROSS_DESKTOP_UUID="$(tr 'A-F' 'a-f' < /proc/sys/kernel/random/uuid)"
    [[ "$CROSS_DESKTOP_UUID" =~ ^[0-9a-f-]{36}$ ]] \
      || die "could not generate the Cross Desktop UUID"
    printf '%s\n' "$CROSS_DESKTOP_UUID" | sudo tee "$uuid_file" >/dev/null
  fi
  sudo chown root:root "$uuid_file"
  sudo chmod 0644 "$uuid_file"

  [[ -f "$CROSS_ROOT/usr/share/xpra/www/index.html" ]] \
    || die "xpra-webclient did not install its HTML5 client"
  sudo rm -rf "$CROSS_ROOT/usr/local/share/cross-desktop"
  sudo mkdir -p "$www" "$CROSS_ROOT/usr/local/bin" "$CROSS_ROOT/usr/local/libexec"
  sudo cp -a "$CROSS_ROOT/usr/share/xpra/www/." "$www/"
  # The package ships pre-compressed copies. They must not shadow the branded
  # index and PWA files below.
  sudo find "$www" -type f -name '*.gz' -delete
  cat <<MANIFEST | sudo tee "$www/manifest.webmanifest" >/dev/null
{
  "id": "/",
  "name": "Cross Desktop",
  "short_name": "Cross",
  "description": "Alpine GUI applications on ChromeOS",
  "start_url": "/?sound=true&video=true&clipboard=true&file_transfer=true",
  "scope": "/",
  "display": "fullscreen",
  "prefer_related_applications": false,
  "background_color": "#101826",
  "theme_color": "#2563eb",
  "icons": [
    {"src": "/cross-icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any maskable"},
    {"src": "/cross-icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable"},
    {"src": "/cross-desktop.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "any"}
  ]
}
MANIFEST
  cat <<'ICON' | sudo tee "$www/cross-desktop.svg" >/dev/null
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect width="512" height="512" rx="104" fill="#101826"/>
  <path d="M128 128 384 384M384 128 128 384" stroke="#60a5fa" stroke-width="72" stroke-linecap="round"/>
  <circle cx="256" cy="256" r="52" fill="#f8fafc"/>
</svg>
ICON
  # Chromium's installability checks require explicit 192px and 512px raster
  # icons. Generate two tiny, opaque PNGs without adding an image-tool package.
  sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/bin/python3 - \
    /usr/local/share/cross-desktop/www <<'PYTHON_ICON'
import binascii
import pathlib
import struct
import sys
import zlib

output = pathlib.Path(sys.argv[1])

def chunk(kind, data):
    checksum = binascii.crc32(kind + data) & 0xffffffff
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", checksum)

def make_icon(size):
    background = (16, 24, 38)
    blue = (96, 165, 250)
    white = (248, 250, 252)
    inset = size * 28 // 100
    width = size * 14 // 100
    radius = size * 10 // 100
    pixels = []
    for y in range(size):
        row = bytearray((0,))
        for x in range(size):
            diagonal = min(abs(x - y), abs((size - 1 - x) - y))
            inside_x = inset - width <= x <= size - inset + width
            inside_y = inset - width <= y <= size - inset + width
            color = blue if inside_x and inside_y and diagonal <= width // 2 else background
            if (x - size // 2) ** 2 + (y - size // 2) ** 2 <= radius ** 2:
                color = white
            row.extend(color)
        pixels.append(bytes(row))
    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) +
            chunk(b"IDAT", zlib.compress(b"".join(pixels), 9)) + chunk(b"IEND", b""))

for icon_size in (192, 512):
    (output / f"cross-icon-{icon_size}.png").write_bytes(make_icon(icon_size))
PYTHON_ICON
  cat <<PWA | sudo tee "$www/cross-pwa.js" >/dev/null
(() => {
  const expected = "cross-${CROSS_DESKTOP_UUID}.localhost";
  if (location.hostname !== expected &&
      (location.hostname === "localhost" || location.hostname === "127.0.0.1")) {
    const port = location.port ? ":" + location.port : "";
    location.replace(location.protocol + "//" + expected + port + location.pathname + location.search + location.hash);
    return;
  }
  if ("serviceWorker" in navigator) {
    addEventListener("load", () => navigator.serviceWorker.register("/sw.js", {scope: "/"})
      .catch((error) => console.warn("Cross Desktop service worker:", error)));
  }
})();
PWA
  # Add PWA metadata without depending on the exact formatting of the packaged
  # Xpra index. Keep the original Xpra client code intact.
  index_tmp="$(mktemp)"
  sudo awk '
    /<\/head>/ && !done {
      print "    <meta name=\"theme-color\" content=\"#2563eb\" />"
      print "    <link rel=\"manifest\" href=\"/manifest.webmanifest\" />"
      print "    <link rel=\"icon\" href=\"/cross-desktop.svg\" type=\"image/svg+xml\" />"
      print "    <script defer src=\"/cross-pwa.js\"></script>"
      done=1
    }
    {print}
  ' "$www/index.html" > "$index_tmp"
  sudo install -o root -g root -m 0644 "$index_tmp" "$www/index.html"
  rm -f "$index_tmp"
  sudo sed -i \
    -e 's#<title>[^<]*</title>#<title>Cross Desktop</title>#' \
    -e 's#content="xpra websockets client"#content="Cross Desktop"#' \
    "$www/index.html"
  # Alpine packages this path as an absolute symlink into /etc/xpra. Since the
  # web root is being assembled from outside the chroot, replace the copied
  # link itself before writing or tee would follow it on the ChromeOS host.
  sudo rm -f "$www/default-settings.txt"
  cat <<'SETTINGS' | sudo tee "$www/default-settings.txt" >/dev/null
# Cross Desktop HTML5 defaults
clipboard = true
file_transfer = true
sound = true
video = true
offscreen = true
reconnect = true
floating_menu = true
min-quality = 20
min-speed = 50
SETTINGS
  sudo chown -R root:root "$CROSS_ROOT/usr/local/share/cross-desktop"
  sudo find "$CROSS_ROOT/usr/local/share/cross-desktop" -type d -exec chmod 0755 {} +
  sudo find "$CROSS_ROOT/usr/local/share/cross-desktop" -type f -exec chmod 0644 {} +

  cat <<'OPEN_FILE' | sudo tee "$CROSS_ROOT/usr/local/libexec/cross-open-file" >/dev/null
#!/bin/sh
set -eu
unset LD_PRELOAD
for pathname do
  [ -f "$pathname" ] || continue
  lower=$(printf '%s' "$pathname" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *.3g2|*.3gp|*.aac|*.avi|*.flac|*.flv|*.m2ts|*.m4a|*.m4v|*.mkv|*.mov|*.mp3|*.mp4|*.mpeg|*.mpg|*.ogg|*.ogv|*.opus|*.ts|*.wav|*.webm|*.wmv)
      exec /usr/bin/vlc --started-from-file "$pathname"
      ;;
  esac
done
OPEN_FILE

  cat <<'OPEN_TARGET' | sudo tee "$CROSS_ROOT/usr/local/libexec/cross-open-target" >/dev/null
#!/bin/sh
set -eu
target=${1:?missing target}
unset LD_PRELOAD

case "$target" in
  rtsp://*|rtsps://*|rtmp://*|rtmps://*|mms://*|mmsh://*|udp://*)
    exec /usr/bin/vlc "$target"
    ;;
esac

if [ -d "$target" ]; then
  exec /usr/bin/pcmanfm "$target"
fi
[ -e "$target" ] || {
  printf 'open: target not found: %s\n' "$target" >&2
  exit 1
}

mime=$(/usr/bin/file --brief --mime-type -- "$target" 2>/dev/null || true)
case "$mime" in
  audio/*|video/*|application/ogg|application/x-ogg|application/x-matroska)
    exec /usr/bin/vlc --started-from-file "$target"
    ;;
  image/*)
    exec /usr/bin/ristretto "$target"
    ;;
  text/*|application/json|application/toml|application/xml|application/x-shellscript|application/yaml)
    exec /usr/bin/mousepad "$target"
    ;;
  application/pdf|application/epub+zip|application/oxps|application/vnd.comicbook+zip|application/x-cbz|application/x-xps)
    exec /usr/bin/mupdf-x11 "$target"
    ;;
  *)
    exec /usr/bin/xdg-open "$target"
    ;;
esac
OPEN_TARGET

  cat <<'RUN_APP' | sudo tee "$CROSS_ROOT/usr/local/libexec/cross-run-app" >/dev/null
#!/bin/sh
set -eu
cwd=${1:?missing working directory}
shift
[ "$#" -gt 0 ] || { echo 'cross-run-app: missing application' >&2; exit 2; }
cd -- "$cwd" 2>/dev/null || cd -- "$HOME"
exec "$@"
RUN_APP

  cat <<DESKTOP | sudo tee "$CROSS_ROOT/usr/local/libexec/cross-desktop" >/dev/null
#!/bin/bash
set -Eeuo pipefail

DISPLAY_NUMBER=:100
PORT=$CROSS_DESKTOP_PORT
UUID=$CROSS_DESKTOP_UUID
URL=http://cross-${CROSS_DESKTOP_UUID}.localhost:${CROSS_DESKTOP_PORT}
HOME=$(printf '%q' "$host_home")
export HOME DISPLAY="\$DISPLAY_NUMBER" USER=chronos LOGNAME=chronos
export XDG_RUNTIME_DIR=/run/user/$uid
export XDG_CONFIG_HOME="\${XDG_CONFIG_HOME:-\$HOME/.config}"
export XDG_CACHE_HOME="\${XDG_CACHE_HOME:-\$HOME/.cache}"
export XDG_DATA_HOME="\${XDG_DATA_HOME:-\$HOME/.local/share}"
export QT_QPA_PLATFORM=xcb GDK_BACKEND=x11 SDL_VIDEODRIVER=x11
export QT_X11_NO_MITSHM=1 LIBGL_ALWAYS_SOFTWARE=1
unset LD_PRELOAD

STATE_DIR="\$HOME/.local/state/cross-desktop"
SOCKET_DIR="\$XDG_RUNTIME_DIR/xpra"
PID_FILE="\$XDG_RUNTIME_DIR/cross-desktop.pid"
LOG_FILE="\$STATE_DIR/xpra.log"

die() { printf 'cross_desktop: ERROR: %s\n' "\$*" >&2; exit 1; }
running_pid() {
  local pid
  [[ -r "\$PID_FILE" ]] || return 1
  read -r pid < "\$PID_FILE" || return 1
  [[ "\$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "\$pid" 2>/dev/null || return 1
  tr '\0' ' ' < "/proc/\$pid/cmdline" 2>/dev/null | grep -q '[x]pra' || return 1
  printf '%s\n' "\$pid"
}
prepare() {
  mkdir -p "\$STATE_DIR" "\$SOCKET_DIR" "\$HOME/Downloads" \
    "\$XDG_CONFIG_HOME" "\$XDG_CACHE_HOME" "\$XDG_DATA_HOME"
  chmod 0700 "\$XDG_RUNTIME_DIR" "\$SOCKET_DIR"
}
start_server() {
  local pid attempt
  prepare
  if pid="\$(running_pid 2>/dev/null)"; then
    printf 'Cross Desktop is running (pid %s).\n%s\n' "\$pid" "\$URL"
    return 0
  fi
  rm -f "\$PID_FILE"
  /usr/bin/xpra start "\$DISPLAY_NUMBER" \
    --daemon=yes \
    --bind-tcp="127.0.0.1:\$PORT,auth=http-header,property=Host,value=cross-\$UUID.localhost:\$PORT" \
    --html=/usr/local/share/cross-desktop/www \
    --socket-dir="\$SOCKET_DIR" \
    --pidfile="\$PID_FILE" \
    --log-dir="\$STATE_DIR" \
    --log-file=xpra.log \
    --session-name="Cross Desktop" \
    --mdns=no \
    --systemd-run=no \
    --dbus=no \
    --clipboard=yes \
    --file-transfer=yes \
    --file-size-limit=2048 \
    --open-files=yes \
    --open-url=no \
    --open-command=/usr/local/libexec/cross-open-file \
    --printing=no \
    --webcam=no \
    --audio=yes \
    --pulseaudio=yes \
    --speaker=on \
    --microphone=disabled \
    --start-new-commands=yes \
    --resize-display=yes \
    --sharing=no \
    --exit-with-client=no \
    --exit-with-children=no \
    --terminate-children=yes \
    --notifications=yes
  for ((attempt=1; attempt<=80; attempt++)); do
    if pid="\$(running_pid 2>/dev/null)" &&
       /usr/bin/curl --silent --fail --max-time 1 "http://127.0.0.1:\$PORT/" >/dev/null; then
      printf 'Cross Desktop started (pid %s).\n%s\n' "\$pid" "\$URL"
      return 0
    fi
    sleep 0.1
  done
  [[ ! -r "\$LOG_FILE" ]] || tail -n 80 "\$LOG_FILE" >&2
  die "Xpra did not become ready on 127.0.0.1:\$PORT"
}
stop_server() {
  local pid
  if ! pid="\$(running_pid 2>/dev/null)"; then
    echo 'Cross Desktop is stopped.'
    return 0
  fi
  /usr/bin/xpra stop "\$DISPLAY_NUMBER" --socket-dir="\$SOCKET_DIR" >/dev/null 2>&1 || kill -TERM "\$pid" 2>/dev/null || true
  for _ in {1..40}; do
    kill -0 "\$pid" 2>/dev/null || break
    sleep 0.1
  done
  rm -f "\$PID_FILE"
  echo 'Cross Desktop stopped.'
}
run_app() {
  (( \$# > 0 )) || die 'no application command supplied'
  if [[ "\$1" == */* ]]; then
    [[ -x "\$1" ]] || die "application is not executable: \$1"
  else
    command -v "\$1" >/dev/null 2>&1 || die "application not found: \$1"
  fi
  start_server >/dev/null
  prepare
  /usr/bin/xpra control --socket-dir="\$SOCKET_DIR" "\$DISPLAY_NUMBER" \
    start-child /usr/local/libexec/cross-run-app "\$PWD" "\$@" >/dev/null
  printf 'Started %q in Cross Desktop.\n%s\n' "\$1" "\$URL"
}
open_targets() {
  (( \$# > 0 )) || die 'no target supplied'
  start_server >/dev/null
  prepare
  local target
  for target in "\$@"; do
    /usr/bin/xpra control --socket-dir="\$SOCKET_DIR" "\$DISPLAY_NUMBER" \
      start-child /usr/local/libexec/cross-run-app "\$PWD" \
      /usr/local/libexec/cross-open-target "\$target" >/dev/null
    printf 'Opened %q in Cross Desktop.\n' "\$target"
  done
  printf '%s\n' "\$URL"
}

case "\${1:-start}" in
  start) shift || true; start_server ;;
  stop) shift; stop_server ;;
  restart) shift; stop_server; start_server ;;
  status)
    if pid="\$(running_pid 2>/dev/null)"; then
      printf 'Cross Desktop is running (pid %s, 127.0.0.1:%s).\n%s\n' "\$pid" "\$PORT" "\$URL"
    else
      echo 'Cross Desktop is stopped.'
      exit 3
    fi
    ;;
  url) printf '%s\n' "\$URL" ;;
  log) tail -n "\${2:-80}" "\$LOG_FILE" ;;
  run) shift; run_app "\$@" ;;
  open) shift; open_targets "\$@" ;;
  vlc) shift; run_app /usr/bin/vlc "\$@" ;;
  *) run_app "\$@" ;;
esac
DESKTOP
  sudo chown root:root "$CROSS_ROOT/usr/local/libexec/cross-desktop" \
    "$CROSS_ROOT/usr/local/libexec/cross-open-file" \
    "$CROSS_ROOT/usr/local/libexec/cross-open-target" \
    "$CROSS_ROOT/usr/local/libexec/cross-run-app"
  sudo chmod 0755 "$CROSS_ROOT/usr/local/libexec/cross-desktop" \
    "$CROSS_ROOT/usr/local/libexec/cross-open-file" \
    "$CROSS_ROOT/usr/local/libexec/cross-open-target" \
    "$CROSS_ROOT/usr/local/libexec/cross-run-app"
  sudo ln -sfn /usr/local/libexec/cross-desktop \
    "$CROSS_ROOT/usr/local/bin/cross_desktop"
}

write_ssh_service() {
  info "Writing localhost OpenSSH service and crosh client"
  local uid gid host_home ssh_dir client_key client_pub server_pub
  uid="$(id -u)"; gid="$(id -g)"; host_home="${HOME:-/home/chronos/user}"
  ssh_dir="$CROSS_ETC/ssh"
  client_key="$ssh_dir/cross_client_ed25519"
  client_pub="$client_key.pub"
  sudo mkdir -p "$ssh_dir" "$CROSS_ROOT/etc/ssh" "$CROSS_ROOT/usr/local/libexec" \
    "$CROSS_ROOT/usr/local/bin" "$CROSS_ROOT/run" "$CROSS_ROOT/var/log" \
    "$CROSS_WORK/chronos"
  sudo chown "$uid:$gid" "$ssh_dir" "$CROSS_WORK/chronos"
  sudo chmod 0700 "$ssh_dir"

  if [[ ! -s "$CROSS_ROOT/etc/ssh/ssh_host_ed25519_key" ]]; then
    sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/bin/ssh-keygen \
      -q -t ed25519 -N '' -C cross-local-host \
      -f /etc/ssh/ssh_host_ed25519_key
  fi
  sudo chmod 0600 "$CROSS_ROOT/etc/ssh/ssh_host_ed25519_key"
  sudo chmod 0644 "$CROSS_ROOT/etc/ssh/ssh_host_ed25519_key.pub"

  if [[ ! -s "$client_key" || ! -s "$client_pub" ]]; then
    sudo rm -f "$CROSS_ROOT/etc/ssh/.cross-client-key" \
      "$CROSS_ROOT/etc/ssh/.cross-client-key.pub"
    sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/bin/ssh-keygen \
      -q -t ed25519 -N '' -C cross-local-client \
      -f /etc/ssh/.cross-client-key
    sudo cp -f "$CROSS_ROOT/etc/ssh/.cross-client-key" "$client_key"
    sudo cp -f "$CROSS_ROOT/etc/ssh/.cross-client-key.pub" "$client_pub"
    sudo rm -f "$CROSS_ROOT/etc/ssh/.cross-client-key" \
      "$CROSS_ROOT/etc/ssh/.cross-client-key.pub"
  fi
  sudo chown "$uid:$gid" "$client_key" "$client_pub"
  sudo chmod 0600 "$client_key"
  sudo chmod 0644 "$client_pub"

  awk '{print $1, $2}' "$client_pub" | sudo tee \
    "$CROSS_ROOT/etc/ssh/cross_authorized_keys" >/dev/null
  sudo chown root:root "$CROSS_ROOT/etc/ssh/cross_authorized_keys"
  sudo chmod 0644 "$CROSS_ROOT/etc/ssh/cross_authorized_keys"

  # No per-tool HOME restrictions or forced cache relocation. The executable
  # HOME bind mount applies to Cargo targets, VS Code CLI, npm/npx and others.
  cat <<SESSION | sudo tee "$CROSS_ROOT/usr/local/libexec/cross-session" >/dev/null
#!/bin/bash
set -Eeuo pipefail

export HOME=$(printf '%q' "$host_home")
export USER=chronos
export LOGNAME=chronos
export SHELL=/bin/bash
export CROSS_WORK=$(printf '%q' "$CROSS_WORK/chronos")
export PATH="\$HOME/.local/bin:\$HOME/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt
# gcompat provides the glibc loader used by npm's workerd binary. This tiny
# musl DSO supplies __res_init, which Alpine gcompat 1.1.0-r4 does not export.
export LD_PRELOAD=/usr/local/lib/cross-gcompat-resolver.so
export CROSS_SESSION=1
export LANG=C.UTF-8
export LC_ALL=
: "\${TERM:=dumb}"
export TERM
umask 022

resolve_cross_tool() {
  case "\$1" in
    apk)              printf '%s\n' /sbin/apk.static ;;
    bash)             printf '%s\n' /bin/bash ;;
    sh)               printf '%s\n' /bin/sh ;;
    git)              printf '%s\n' /usr/bin/git ;;
    git-upload-pack)  printf '%s\n' /usr/bin/git-upload-pack ;;
    git-receive-pack) printf '%s\n' /usr/bin/git-receive-pack ;;
    curl)             printf '%s\n' /usr/bin/curl ;;
    wget)             printf '%s\n' /usr/bin/wget ;;
    ssh)              printf '%s\n' /usr/bin/ssh ;;
    scp)              printf '%s\n' /usr/bin/scp ;;
    cc)               printf '%s\n' /usr/bin/cc ;;
    c++)              printf '%s\n' /usr/bin/c++ ;;
    gcc)              printf '%s\n' /usr/bin/gcc ;;
    g++)              printf '%s\n' /usr/bin/g++ ;;
    cpp)              printf '%s\n' /usr/bin/cpp ;;
    ar)               printf '%s\n' /usr/bin/ar ;;
    as)               printf '%s\n' /usr/bin/as ;;
    ld)               printf '%s\n' /usr/bin/ld ;;
    nm)               printf '%s\n' /usr/bin/nm ;;
    objdump)          printf '%s\n' /usr/bin/objdump ;;
    ranlib)           printf '%s\n' /usr/bin/ranlib ;;
    strip)            printf '%s\n' /usr/bin/strip ;;
    make)             printf '%s\n' /usr/bin/make ;;
    cmake)            printf '%s\n' /usr/bin/cmake ;;
    ninja)            printf '%s\n' /usr/bin/ninja ;;
    meson)            printf '%s\n' /usr/bin/meson ;;
    pkg-config)       printf '%s\n' /usr/bin/pkg-config ;;
    autoconf)         printf '%s\n' /usr/bin/autoconf ;;
    autoheader)       printf '%s\n' /usr/bin/autoheader ;;
    automake)         printf '%s\n' /usr/bin/automake ;;
    aclocal)          printf '%s\n' /usr/bin/aclocal ;;
    libtoolize)       printf '%s\n' /usr/bin/libtoolize ;;
    m4)               printf '%s\n' /usr/bin/m4 ;;
    rustup)           printf '%s\n' /usr/local/bin/rustup ;;
    rustc)            printf '%s\n' /usr/bin/rustc ;;
    cargo)            printf '%s\n' /usr/bin/cargo ;;
    rustfmt)          printf '%s\n' /usr/bin/rustfmt ;;
    clippy-driver)    printf '%s\n' /usr/bin/clippy-driver ;;
    node)             printf '%s\n' /usr/bin/node ;;
    npm)              printf '%s\n' /usr/bin/npm ;;
    npx)              printf '%s\n' /usr/bin/npx ;;
    corepack)         printf '%s\n' /usr/bin/corepack ;;
    python3)          printf '%s\n' /usr/bin/python3 ;;
    sudo)             printf '%s\n' /usr/bin/sudo ;;
    *) return 1 ;;
  esac
}

safe_cd() {
  local requested="\$1"
  case "\$requested" in
    "\$HOME"|"\$HOME"/*|"\$CROSS_WORK"|"\$CROSS_WORK"/*)
      cd -- "\$requested" 2>/dev/null || cd -- "\$HOME"
      ;;
    *) cd -- "\$HOME" ;;
  esac
}

if [[ -z "\${SSH_ORIGINAL_COMMAND:-}" ]]; then
  cd -- "\$HOME"
  exec /bin/bash -l
fi

eval "set -- \$SSH_ORIGINAL_COMMAND"
[[ "\${1:-}" == cross-session-v1 ]] || {
  echo "cross-session: invalid client protocol" >&2
  exit 126
}
shift
(( \$# >= 2 )) || {
  echo "cross-session: incomplete client protocol" >&2
  exit 126
}
requested_cwd="\$1"
mode="\$2"
shift 2
safe_cd "\$requested_cwd"
case "\$mode" in
  shell)
    (( \$# == 0 )) || exit 126
    exec /bin/bash -l
    ;;
  exec)
    (( \$# > 0 )) || exit 126
    command_name="\$1"
    shift
    case "\$command_name" in
      */*) exec "\$command_name" "\$@" ;;
      *)
        resolved="\$(resolve_cross_tool "\$command_name" 2>/dev/null || true)"
        if [[ -n "\$resolved" ]]; then exec "\$resolved" "\$@"; fi
        exec "\$command_name" "\$@"
        ;;
    esac
    ;;
  *) echo "cross-session: unknown mode" >&2; exit 126 ;;
esac
SESSION
  sudo chown root:root "$CROSS_ROOT/usr/local/libexec/cross-session"
  sudo chmod 0755 "$CROSS_ROOT/usr/local/libexec/cross-session"

  cat <<SSHD | sudo tee "$CROSS_ROOT/etc/ssh/sshd_config_cross" >/dev/null
Port $CROSS_SSH_PORT
ListenAddress 127.0.0.1
AddressFamily inet
PidFile /run/cross-sshd.pid
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin no
AllowUsers chronos
PubkeyAuthentication yes
AuthenticationMethods publickey
AuthorizedKeysFile /etc/ssh/cross_authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
UsePAM no
StrictModes yes
ForceCommand /usr/local/libexec/cross-session
DisableForwarding yes
X11Forwarding no
PermitTunnel no
PermitUserRC no
GatewayPorts no
PermitTTY yes
UseDNS no
PrintMotd no
PrintLastLog no
LoginGraceTime 15
MaxAuthTries 3
MaxSessions 16
ClientAliveInterval 60
ClientAliveCountMax 3
LogLevel VERBOSE
SSHD
  sudo chown root:root "$CROSS_ROOT/etc/ssh/sshd_config_cross"
  sudo chmod 0600 "$CROSS_ROOT/etc/ssh/sshd_config_cross"

  server_pub="$(sudo awk '{print $1, $2}' "$CROSS_ROOT/etc/ssh/ssh_host_ed25519_key.pub")"
  printf 'cross-local %s\n' "$server_pub" > "$ssh_dir/known_hosts"
  chmod 0600 "$ssh_dir/known_hosts"
  cat > "$ssh_dir/config" <<SSHCFG
Host cross-local
  HostName 127.0.0.1
  Port $CROSS_SSH_PORT
  User chronos
  IdentityFile $client_key
  IdentitiesOnly yes
  HostKeyAlias cross-local
  UserKnownHostsFile $ssh_dir/known_hosts
  GlobalKnownHostsFile /dev/null
  StrictHostKeyChecking yes
  UpdateHostKeys no
  BatchMode yes
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  PreferredAuthentications publickey
  ClearAllForwardings yes
  ConnectTimeout 5
  ConnectionAttempts 1
  LogLevel ERROR
SSHCFG
  chmod 0600 "$ssh_dir/config"

  {
    printf 'CROSS_ROOT=%q\n' "$CROSS_ROOT"
    printf 'CROSS_WORK=%q\n' "$CROSS_WORK"
    printf 'HOST_HOME=%q\n' "$host_home"
    printf 'HOST_UID=%q\n' "$uid"
    printf 'HOST_GID=%q\n' "$gid"
    printf 'CHROOT_BIN=%q\n' "$CHROOT_BIN"
    printf 'HOST_SSH_BIN=%q\n' "$HOST_SSH_BIN"
    printf 'CROSS_SSH_PORT=%q\n' "$CROSS_SSH_PORT"
    printf 'CROSS_DESKTOP_PORT=%q\n' "$CROSS_DESKTOP_PORT"
    printf 'CROSS_DESKTOP_UUID=%q\n' "$CROSS_DESKTOP_UUID"
    printf 'CROSS_DESKTOP_URL=%q\n' \
      "http://cross-${CROSS_DESKTOP_UUID}.localhost:${CROSS_DESKTOP_PORT}"
  } | sudo tee "$CROSS_ETC/cross.conf" >/dev/null
  sudo chown root:root "$CROSS_ETC/cross.conf"
  sudo chmod 0644 "$CROSS_ETC/cross.conf"

  cat > "$CROSS_BIN/cross-service" <<'SERVICE'
#!/bin/bash
set -Eeuo pipefail

SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PREFIX="$(dirname -- "$SELF_DIR")"
CONFIG="$PREFIX/etc/cross.conf"
[[ -r "$CONFIG" ]] || { echo "cross-service: missing $CONFIG" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG"

PID_FILE="$CROSS_ROOT/run/cross-sshd.pid"
LOG_FILE="$CROSS_ROOT/var/log/cross-sshd.log"
COMMAND_NAME="${CROSS_COMMAND_NAME:-cross-service}"
info() { printf '%s: %s\n' "$COMMAND_NAME" "$*"; }
warn() { printf '%s: WARN: %s\n' "$COMMAND_NAME" "$*" >&2; }
die()  { printf '%s: ERROR: %s\n' "$COMMAND_NAME" "$*" >&2; exit 1; }

is_mounted() {
  awk -v target="$1" '$2 == target {found=1} END {exit !found}' /proc/mounts
}

mount_options() {
  awk -v target="$1" '$2 == target {opts=$4} END {print opts}' /proc/mounts
}

mount_bind() {
  local source="$1" target="$2" recursive="${3:-0}"
  sudo mkdir -p "$target"
  if ! is_mounted "$target"; then
    if [[ "$recursive" == 1 ]]; then
      sudo mount --rbind "$source" "$target"
      sudo mount --make-rslave "$target" 2>/dev/null || true
    else
      sudo mount --bind "$source" "$target"
    fi
  fi
}

mount_proc() {
  local target="$1"
  sudo mkdir -p "$target"
  if ! is_mounted "$target"; then sudo mount -t proc proc "$target"; fi
}

ensure_vt2_context() {
  local nnp
  nnp="$(awk '/^NoNewPrivs:/ {print $2}' /proc/self/status 2>/dev/null || true)"
  if (( EUID != 0 )); then
    [[ "$nnp" != 1 ]] || die "start/stop must run from VT-2, not browser crosh"
  fi
  command -v sudo >/dev/null 2>&1 || die "sudo is required"
  sudo true
}

ensure_chroot_exec() {
  local security_mnt="/sys/kernel/security"
  local policy_file="$security_mnt/chromiumos/inode_security_policies/allow_symlink"
  local mounted_here=0 remounted_rw=0 security_opts=""
  if sudo "$CHROOT_BIN" "$CROSS_ROOT" /bin/busybox true >/dev/null 2>&1; then
    return 0
  fi
  sudo mkdir -p "$security_mnt"
  if ! is_mounted "$security_mnt"; then
    sudo mount -t securityfs -o nodev,noexec,nosuid securityfs "$security_mnt" \
      || die "cannot mount ChromeOS securityfs"
    mounted_here=1
  fi
  security_opts="$(mount_options "$security_mnt")"
  if [[ ",$security_opts," == *,ro,* ]]; then
    sudo mount -o remount,rw "$security_mnt" || die "cannot remount securityfs read-write"
    remounted_rw=1
  fi
  [[ -e "$policy_file" ]] || die "ChromeOS allow_symlink policy interface unavailable"
  printf '%s' '/mnt/stateful_partition/dev_image' | sudo tee "$policy_file" >/dev/null
  if ! sudo "$CHROOT_BIN" "$CROSS_ROOT" /bin/busybox true >/dev/null 2>&1; then
    warn "Narrow dev_image policy insufficient; enabling stateful symlinks until reboot"
    printf '%s' '/mnt/stateful_partition' | sudo tee "$policy_file" >/dev/null
  fi
  (( remounted_rw == 0 )) || sudo mount -o remount,ro "$security_mnt" >/dev/null 2>&1 || true
  (( mounted_here == 0 )) || sudo umount "$security_mnt" >/dev/null 2>&1 || true
  sudo "$CHROOT_BIN" "$CROSS_ROOT" /bin/busybox true >/dev/null 2>&1 \
    || die "ChromeOS still denies execution inside Alpine rootfs"
}

# NEW: change only the VFS flags on the *Alpine-facing* HOME bind mount.
# Do not change the original ChromeOS HOME mount. Keep nosuid,nodev.
# All names resolve inside the same mount namespace, so this also creates a
# host-accessible executable alias under CROSS_ROOT; see EULA.
mount_home_executable() {
  local target="$CROSS_ROOT$HOST_HOME" opts
  mount_bind "$HOST_HOME" "$target" 0
  opts="$(mount_options "$target")"
  [[ -n "$opts" ]] || die "missing Alpine HOME bind mount: $target"

  if [[ ",$opts," == *,nosymfollow,* ]]; then
    sudo mount -o remount,bind,exec,symfollow,nosuid,nodev \
      "$HOST_HOME" "$target" \
      || die "unable to enable exec/symfollow on Alpine HOME bind mount"
  else
    sudo mount -o remount,bind,exec,nosuid,nodev \
      "$HOST_HOME" "$target" \
      || die "unable to enable exec on Alpine HOME bind mount"
  fi

  opts="$(mount_options "$target")"
  [[ -n "$opts" ]] || die "HOME bind mount disappeared"
  case ",$opts," in
    *,noexec,*|*,nosymfollow,*)
      die "HOME bind remains execution/symlink restricted: $opts" ;;
  esac
  [[ ",$opts," == *,nosuid,* && ",$opts," == *,nodev,* ]] \
    || die "HOME bind unexpectedly lacks nosuid or nodev: $opts"
  info "HOME bind executable (exec,nosuid,nodev): $target"
}

# Generic OS-level probe. Runs with chronos UID *inside Alpine* and attempts
# to execute an actual ELF copied into HOME, with or without a symlink.
probe_home_exec() {
  local mode="$1"
  sudo "$CHROOT_BIN" "$CROSS_ROOT" /sbin/su-exec chronos /bin/sh -c '
    set -eu
    h="$1"; mode="$2"
    d="$(mktemp -d "$h/.cross-home-exec.XXXXXXXX")"
    trap '\''rm -rf -- "$d"'\'' EXIT
    # BusyBox dispatches by argv[0]; retain the basename "busybox".
    cp /bin/busybox "$d/busybox"
    chmod 0700 "$d/busybox"
    "$d/busybox" true
    if [ "$mode" = symlink ]; then
      mkdir "$d/link"
      ln -s ../busybox "$d/link/busybox"
      "$d/link/busybox" true
    fi
  ' cross-home-probe "$HOST_HOME" "$mode"
}

# ChromeOS LSM's inode policy differs from a Linux nosymfollow mount option.
# Only touch it if an executable symlink probe actually fails. The scope is
# HOME, not the full stateful partition. Failure is a hard error, not success.
allow_home_symlinks_if_needed() {
  local security_mnt="/sys/kernel/security"
  local policy_file="$security_mnt/chromiumos/inode_security_policies/allow_symlink"
  local mounted_here=0 remounted_rw=0 opts=""
  if probe_home_exec symlink >/dev/null 2>&1; then
    info "HOME ELF and symlink execution verified"
    return 0
  fi
  warn "HOME ELF works, but symlink execution failed; trying narrow ChromeOS LSM exception"
  sudo mkdir -p "$security_mnt"
  if ! is_mounted "$security_mnt"; then
    sudo mount -t securityfs -o nodev,noexec,nosuid securityfs "$security_mnt" \
      || die "cannot mount securityfs for HOME symlink policy"
    mounted_here=1
  fi
  opts="$(mount_options "$security_mnt")"
  if [[ ",$opts," == *,ro,* ]]; then
    sudo mount -o remount,rw "$security_mnt" || die "cannot remount securityfs rw"
    remounted_rw=1
  fi
  if [[ ! -e "$policy_file" ]]; then
    (( remounted_rw == 0 )) || sudo mount -o remount,ro "$security_mnt" >/dev/null 2>&1 || true
    (( mounted_here == 0 )) || sudo umount "$security_mnt" >/dev/null 2>&1 || true
    die "ChromeOS HOME symlink policy interface unavailable"
  fi
  # This may be rejected on some ChromeOS builds; never silently broaden to
  # the entire stateful filesystem to fix HOME symlinks.
  local wrote=0
  if printf '%s' "$HOST_HOME" | sudo tee "$policy_file" >/dev/null; then
    wrote=1
  fi
  (( remounted_rw == 0 )) || sudo mount -o remount,ro "$security_mnt" >/dev/null 2>&1 || true
  (( mounted_here == 0 )) || sudo umount "$security_mnt" >/dev/null 2>&1 || true
  (( wrote )) || die "ChromeOS rejected the narrow HOME symlink exception"
  probe_home_exec symlink >/dev/null 2>&1 \
    || die "HOME symlink execution still denied after narrow LSM exception"
  info "HOME symlink execution verified with narrow ChromeOS LSM exception"
}

sync_runtime_dns() {
  local source="" candidate="" target="" temp=""
  target="$CROSS_ROOT/etc/resolv.conf"
  for candidate in \
    /run/dns-proxy/resolv.conf \
    /run/shill/resolv.conf \
    /etc/resolv.conf \
    /run/systemd/resolve/resolv.conf; do
    [[ -f "$candidate" && -r "$candidate" && -s "$candidate" ]] || continue
    if awk '
      $1 == "nameserver" && NF >= 2 && $2 !~ /^#/ &&
      $2 != "0.0.0.0" && $2 != "::" {found=1}
      END {exit !found}
    ' "$candidate"; then source="$candidate"; break; fi
  done
  [[ -n "$source" ]] || die "ChromeOS DNS unavailable"
  sudo mkdir -p "$CROSS_ROOT/etc"
  temp="$(sudo mktemp "$CROSS_ROOT/etc/.resolv.conf.cross.XXXXXXXX")"
  if ! sudo cp -L -- "$source" "$temp"; then
    sudo rm -f "$temp"
    die "cannot copy DNS from $source"
  fi
  sudo chown root:root "$temp"
  sudo chmod 0644 "$temp"
  sudo mv -f -- "$temp" "$target"
  info "DNS synchronized from $source"
}

prepare_mounts() {
  sync_runtime_dns
  if [[ -f /etc/hosts ]]; then sudo cp -L -f /etc/hosts "$CROSS_ROOT/etc/hosts"; fi
  mount_bind /dev "$CROSS_ROOT/dev" 1
  mount_proc "$CROSS_ROOT/proc"
  mount_bind /sys "$CROSS_ROOT/sys" 1
  mount_home_executable
  mount_bind "$CROSS_WORK" "$CROSS_ROOT$CROSS_WORK" 0
  # /run was temporarily bind-mounted from ChromeOS while packages were being
  # installed, but runtime services use Alpine's own /run. Recreate the
  # per-user directory on every service start, after all setup binds are gone.
  sudo mkdir -p "$CROSS_ROOT/run/user/$HOST_UID" "$CROSS_ROOT/var/log" \
    "$CROSS_ROOT/run/sshd"
  sudo chown root:root "$CROSS_ROOT/run" "$CROSS_ROOT/run/user"
  sudo chmod 0755 "$CROSS_ROOT/run" "$CROSS_ROOT/run/user"
  sudo chown "$HOST_UID:$HOST_GID" "$CROSS_ROOT/run/user/$HOST_UID"
  sudo chmod 0700 "$CROSS_ROOT/run/user/$HOST_UID"
  ensure_chroot_exec
  if ! probe_home_exec direct >/dev/null 2>&1; then
    die "HOME ELF execution failed despite exec bind mount. Check ChromeOS LSM, filesystem and mount flags"
  fi
  allow_home_symlinks_if_needed
}

master_pid() {
  [[ -r "$PID_FILE" ]] || return 1
  local pid
  read -r pid < "$PID_FILE" || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  sudo kill -0 "$pid" >/dev/null 2>&1 || return 1
  printf '%s\n' "$pid"
}

chroot_pids() {
  local proc pid root
  for proc in /proc/[0-9]*; do
    pid="${proc##*/}"
    root="$(sudo readlink "$proc/root" 2>/dev/null || true)"
    [[ "$root" == "$CROSS_ROOT" ]] && printf '%s\n' "$pid"
  done
}

unmount_runtime() {
  local target
  for target in \
    "$CROSS_ROOT$CROSS_WORK" \
    "$CROSS_ROOT$HOST_HOME" \
    "$CROSS_ROOT/run" \
    "$CROSS_ROOT/sys" \
    "$CROSS_ROOT/proc" \
    "$CROSS_ROOT/dev"; do
    is_mounted "$target" && sudo umount -l "$target" >/dev/null 2>&1 || true
  done
}

auth_probe_error_file() {
  if (( EUID == 0 )); then
    printf '%s\n' "$PREFIX/etc/cross-auth-probe.log"
  else
    printf '%s\n' "$PREFIX/run/cross-auth-probe.log"
  fi
}

auth_probe() {
  local remote quoted err_file status
  err_file="$(auth_probe_error_file)"
  [[ ! -L "$err_file" ]] || die "refusing symlinked authentication log: $err_file"
  printf -v quoted '%q' "$HOST_HOME"
  remote="cross-session-v1 $quoted exec /bin/true"
  : > "$err_file"
  set +e
  "$HOST_SSH_BIN" -F "$PREFIX/etc/ssh/config" -T cross-local "$remote" \
    </dev/null >/dev/null 2>"$err_file"
  status=$?
  set -e
  return "$status"
}

show_auth_failure() {
  local err_file
  err_file="$(auth_probe_error_file)"
  printf '%s: localhost SSH authentication probe failed\n' "$COMMAND_NAME" >&2
  [[ ! -s "$err_file" ]] || sed 's/^/client: /' "$err_file" >&2
  [[ ! -r "$LOG_FILE" ]] \
    || sudo tail -n 80 "$LOG_FILE" | sed 's/^/sshd: /' >&2 || true
}

start_desktop_service() {
  if ! sudo "$CHROOT_BIN" "$CROSS_ROOT" /sbin/su-exec chronos \
      /usr/local/libexec/cross-desktop start; then
    warn "Cross Desktop did not start; inspect it with: cross_desktop log 120"
    return 1
  fi
}

start_service() {
  ensure_vt2_context
  local pid i
  if pid="$(master_pid 2>/dev/null)"; then
    if auth_probe; then
      start_desktop_service || true
      info "running and authenticated (pid $pid, 127.0.0.1:$CROSS_SSH_PORT)"
      return 0
    fi
    show_auth_failure
    die "sshd running but public-key authentication failed; rerun cross.sh"
  fi
  sudo rm -f "$PID_FILE"
  prepare_mounts
  sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/sbin/sshd -t -f /etc/ssh/sshd_config_cross
  sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/sbin/sshd \
    -f /etc/ssh/sshd_config_cross -E /var/log/cross-sshd.log
  for ((i=1; i<=30; i++)); do
    if pid="$(master_pid 2>/dev/null)" && auth_probe; then
      start_desktop_service || true
      info "started and authenticated (pid $pid, 127.0.0.1:$CROSS_SSH_PORT)"
      return 0
    fi
    sleep 0.1
  done
  show_auth_failure
  stop_service >/dev/null 2>&1 || true
  die "sshd did not pass public-key authentication probe"
}

stop_service() {
  ensure_vt2_context
  local pid pids
  if pid="$(master_pid 2>/dev/null)"; then
    sudo kill -TERM "$pid" >/dev/null 2>&1 || true
  fi
  pids="$(chroot_pids || true)"
  if [[ -n "$pids" ]]; then
    # shellcheck disable=SC2086
    sudo kill -TERM $pids >/dev/null 2>&1 || true
    sleep 0.5
    pids="$(chroot_pids || true)"
    if [[ -n "$pids" ]]; then
      # shellcheck disable=SC2086
      sudo kill -KILL $pids >/dev/null 2>&1 || true
    fi
  fi
  sudo rm -f "$PID_FILE"
  unmount_runtime
  info "stopped"
}

status_service() {
  local pid
  if pid="$(master_pid 2>/dev/null)"; then
    info "running (pid $pid, 127.0.0.1:$CROSS_SSH_PORT)"
  else
    info "stopped"
    return 3
  fi
}

doctor_service() {
  ensure_vt2_context
  local client_blob auth_blob mode owner opts
  printf 'Service: '; status_service || true
  opts="$(mount_options "$CROSS_ROOT$HOST_HOME")"
  printf 'HOME bind options: %s\n' "${opts:-not mounted}"
  if [[ -n "$opts" ]]; then
    if probe_home_exec direct; then
      echo 'HOME ELF execution: yes'
    else
      echo 'HOME ELF execution: no'
    fi
    if probe_home_exec symlink; then
      echo 'HOME symlink execution: yes'
    else
      echo 'HOME symlink execution: no'
    fi
  fi
  client_blob="$(awk 'NF >= 2 {print $2; exit}' "$PREFIX/etc/ssh/cross_client_ed25519.pub" 2>/dev/null || true)"
  auth_blob="$(sudo awk 'NF >= 2 {print $2; exit}' "$CROSS_ROOT/etc/ssh/cross_authorized_keys" 2>/dev/null || true)"
  mode="$(sudo stat -c '%a' "$CROSS_ROOT/etc/ssh/cross_authorized_keys" 2>/dev/null || true)"
  owner="$(sudo stat -c '%U:%G' "$CROSS_ROOT/etc/ssh/cross_authorized_keys" 2>/dev/null || true)"
  printf 'AuthorizedKeys: owner=%s mode=%s readable-as-chronos=' "${owner:-missing}" "${mode:-missing}"
  if sudo -u "#$HOST_UID" test -r "$CROSS_ROOT/etc/ssh/cross_authorized_keys" 2>/dev/null; then
    echo yes
  else
    echo no
  fi
  [[ -n "$client_blob" && "$client_blob" == "$auth_blob" ]] && echo 'Key match: yes' || echo 'Key match: no'
  echo 'Effective SSH settings:'
  sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/sbin/sshd -T \
    -f /etc/ssh/sshd_config_cross \
    -C user=chronos,host=localhost,addr=127.0.0.1 2>/dev/null \
    | grep -E '^(port|listenaddress|allowusers|pubkeyauthentication|authenticationmethods|authorizedkeysfile|strictmodes|forcecommand) ' \
    || true
  if master_pid >/dev/null 2>&1; then
    if auth_probe; then
      echo 'Authentication: success'
    else
      echo 'Authentication: failed'
      show_auth_failure
      return 1
    fi
  else
    echo 'Authentication: not tested (service stopped)'
  fi
}

case "${1:-status}" in
  start) start_service ;;
  stop) stop_service ;;
  restart) stop_service; start_service ;;
  status) status_service ;;
  doctor) doctor_service ;;
  log) sudo tail -n "${2:-80}" "$LOG_FILE" ;;
  *) die "usage: $COMMAND_NAME {start|stop|restart|status|doctor|log [lines]}" ;;
esac
SERVICE
  chmod 0755 "$CROSS_BIN/cross-service"

  cat > "$CROSS_BIN/cross" <<'CLIENT'
#!/bin/bash
set -Eeuo pipefail

SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PREFIX="$(dirname -- "$SELF_DIR")"
CONFIG="$PREFIX/etc/cross.conf"
SSH_CONFIG="$PREFIX/etc/ssh/config"
[[ -r "$CONFIG" ]] || { echo "cross: missing $CONFIG; rerun cross.sh" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG"

# Service management is part of the cross CLI. Prefixing a command with `--`
# bypasses this dispatch, so an Alpine command with the same name remains
# reachable (for example, `cross -- start`).
case "${1:-}" in
  start|stop|restart|status|doctor|log)
    service_command="$1"
    shift
    export CROSS_COMMAND_NAME=cross
    exec "$SELF_DIR/cross-service" "$service_command" "$@"
    ;;
esac

[[ -x "$HOST_SSH_BIN" ]] || { echo "cross: host ssh unavailable: $HOST_SSH_BIN" >&2; exit 1; }
[[ -r "$SSH_CONFIG" ]] || { echo "cross: missing SSH client configuration" >&2; exit 1; }

pty=auto
case "${1:-}" in
  -t) pty=yes; shift ;;
  -T) pty=no; shift ;;
  --) shift ;;
esac
case "$PWD" in
  "$HOST_HOME"|"$HOST_HOME"/*|"$CROSS_WORK/chronos"|"$CROSS_WORK/chronos"/*)
    remote_cwd="$PWD" ;;
  *) remote_cwd="$HOST_HOME" ;;
esac
remote='cross-session-v1'
printf -v quoted '%q' "$remote_cwd"
remote+=" $quoted"
if (( $# == 0 )); then
  remote+=' shell'
  if [[ "$pty" == auto ]]; then
    if [[ -t 0 && -t 1 ]]; then pty=yes; else pty=no; fi
  fi
else
  remote+=' exec'
  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    remote+=" $quoted"
  done
  [[ "$pty" != auto ]] || pty=no
fi
ssh_args=(-F "$SSH_CONFIG")
case "$pty" in
  yes) ssh_args+=(-t) ;;
  no) ssh_args+=(-T) ;;
esac
err_file="$(mktemp "$PREFIX/run/cross-client.XXXXXX")"
trap 'rm -f "$err_file"' EXIT
set +e
"$HOST_SSH_BIN" "${ssh_args[@]}" cross-local "$remote" 2>"$err_file"
status=$?
set -e
[[ ! -s "$err_file" ]] || cat "$err_file" >&2
if (( status == 255 )); then
  if grep -Fq 'Permission denied (publickey)' "$err_file"; then
    cat >&2 <<MESSAGE
cross: SSH public-key authentication failed.
From VT-2: $PREFIX/bin/cross doctor
Rerun cross.sh if key permissions need repair.
MESSAGE
  else
    cat >&2 <<MESSAGE
cross: VT-2 service unreachable.
From VT-2: $PREFIX/bin/cross start
MESSAGE
  fi
fi
exit "$status"
CLIENT
  chmod 0755 "$CROSS_BIN/cross"

  cat > "$CROSS_BIN/cross-open-url" <<'OPEN_URL_CLIENT'
#!/bin/bash
set -Eeuo pipefail

if (( $# != 1 )); then
  echo 'usage: cross-open-url URL' >&2
  exit 2
fi
url=$1
case "$url" in
  http://*|https://*|mailto:*) ;;
  *) echo "cross-open-url: unsupported URL scheme: $url" >&2; exit 2 ;;
esac
[[ -x /usr/bin/dbus-send ]] || {
  echo 'cross-open-url: ChromeOS dbus-send is unavailable' >&2
  exit 1
}
if ! reply=$(/usr/bin/dbus-send --system --type=method_call --print-reply \
    --dest=org.chromium.UrlHandlerService \
    /org/chromium/UrlHandlerService \
    org.chromium.UrlHandlerServiceInterface.OpenUrl \
    "string:$url" 2>&1); then
  printf 'cross-open-url: ChromeOS rejected %s\n%s\n' "$url" "$reply" >&2
  exit 1
fi
OPEN_URL_CLIENT
  chmod 0755 "$CROSS_BIN/cross-open-url"

  cat > "$CROSS_BIN/cross_desktop" <<'DESKTOP_CLIENT'
#!/bin/bash
set -Eeuo pipefail

SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PREFIX="$(dirname -- "$SELF_DIR")"
CONFIG="$PREFIX/etc/cross.conf"
[[ -r "$CONFIG" ]] || { echo "cross_desktop: missing $CONFIG; rerun cross.sh" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG"

usage() {
  cat <<'USAGE'
usage: cross_desktop [start|stop|restart|status|url|log [lines]]
       cross_desktop vlc [file ...]
       cross_desktop open TARGET [TARGET ...]
       cross_desktop run COMMAND [ARG ...]
       cross_desktop -- COMMAND [ARG ...]

With no arguments, starts Cross Desktop and opens its ChromeOS URL.
USAGE
}

open_browser() {
  [[ "${CROSS_DESKTOP_OPEN:-1}" != 0 ]] || return 0
  "$SELF_DIR/cross-open-url" "$CROSS_DESKTOP_URL"
}

command_name="${1:-start}"
case "$command_name" in
  -h|--help|help) usage; exit 0 ;;
  start|restart)
    "$SELF_DIR/cross" /usr/local/libexec/cross-desktop "$command_name"
    open_browser
    ;;
  stop|status)
    exec "$SELF_DIR/cross" /usr/local/libexec/cross-desktop "$@"
    ;;
  url)
    printf '%s\n' "$CROSS_DESKTOP_URL"
    ;;
  log)
    exec "$SELF_DIR/cross" /usr/local/libexec/cross-desktop "$@"
    ;;
  vlc|run|open)
    "$SELF_DIR/cross" /usr/local/libexec/cross-desktop "$@"
    open_browser
    ;;
  --)
    shift
    (( $# > 0 )) || { usage >&2; exit 2; }
    "$SELF_DIR/cross" /usr/local/libexec/cross-desktop run "$@"
    open_browser
    ;;
  *)
    "$SELF_DIR/cross" /usr/local/libexec/cross-desktop run "$@"
    open_browser
    ;;
esac
DESKTOP_CLIENT
  chmod 0755 "$CROSS_BIN/cross_desktop"
  ln -sfn cross_desktop "$CROSS_BIN/cross-desktop"

  cat > "$CROSS_BIN/open" <<'OPEN_CLIENT'
#!/bin/bash
set -Eeuo pipefail

SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
usage() {
  cat <<'USAGE'
usage: open [TARGET ...]
       open -a APPLICATION [ARG ...]

HTTP(S) and mailto URLs open in ChromeOS Chrome. Files and directories open
in an appropriate Cross Desktop application. With no target, opens the canvas.
USAGE
}

if (( $# == 0 )); then
  exec "$SELF_DIR/cross_desktop"
fi
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -a|--application)
    shift
    (( $# > 0 )) || { echo 'open: -a requires an application command' >&2; exit 2; }
    application=$1
    shift
    exec "$SELF_DIR/cross_desktop" -- "$application" "$@"
    ;;
  --) shift ;;
  -*) echo "open: unknown option: $1" >&2; usage >&2; exit 2 ;;
esac
(( $# > 0 )) || exec "$SELF_DIR/cross_desktop"

status=0
declare -a desktop_targets=()
for target in "$@"; do
  case "$target" in
    http://*|https://*|mailto:*)
      "$SELF_DIR/cross-open-url" "$target" || status=$?
      ;;
    *) desktop_targets+=("$target") ;;
  esac
done
if (( ${#desktop_targets[@]} > 0 )); then
  "$SELF_DIR/cross_desktop" open "${desktop_targets[@]}" || status=$?
fi
exit "$status"
OPEN_CLIENT
  chmod 0755 "$CROSS_BIN/open"

  local spec cmd remote_path
  local wrapper_specs=(
    'apk:/sbin/apk.static'
    'git:/usr/bin/git'
    'git-upload-pack:/usr/bin/git-upload-pack'
    'git-receive-pack:/usr/bin/git-receive-pack'
    'ssh:/usr/bin/ssh'
    'scp:/usr/bin/scp'
    'cc:/usr/bin/cc'
    'c++:/usr/bin/c++'
    'gcc:/usr/bin/gcc'
    'g++:/usr/bin/g++'
    'cpp:/usr/bin/cpp'
    'ar:/usr/bin/ar'
    'as:/usr/bin/as'
    'ld:/usr/bin/ld'
    'nm:/usr/bin/nm'
    'objdump:/usr/bin/objdump'
    'ranlib:/usr/bin/ranlib'
    'strip:/usr/bin/strip'
    'make:/usr/bin/make'
    'cmake:/usr/bin/cmake'
    'ninja:/usr/bin/ninja'
    'meson:/usr/bin/meson'
    'pkg-config:/usr/bin/pkg-config'
    'autoconf:/usr/bin/autoconf'
    'autoheader:/usr/bin/autoheader'
    'automake:/usr/bin/automake'
    'aclocal:/usr/bin/aclocal'
    'libtoolize:/usr/bin/libtoolize'
    'm4:/usr/bin/m4'
    'rustup:/usr/local/bin/rustup'
    'rustc:/usr/bin/rustc'
    'cargo:/usr/bin/cargo'
    'rustfmt:/usr/bin/rustfmt'
    'clippy-driver:/usr/bin/clippy-driver'
    'node:/usr/bin/node'
    'npm:/usr/bin/npm'
    'npx:/usr/bin/npx'
    'corepack:/usr/bin/corepack'
    'python3:/usr/bin/python3'
  )

  # These commands are part of the host-side bootstrap path. Shadowing them
  # makes `curl .../cross.sh | bash` run the installer inside Alpine and makes
  # updates depend on the service that the installer must stop. Remove files
  # left by releases that generated wrappers for them.
  rm -f "$CROSS_BIN/bash" "$CROSS_BIN/sh" "$CROSS_BIN/curl" "$CROSS_BIN/wget"

  for spec in "${wrapper_specs[@]}"; do
    cmd="${spec%%:*}"
    remote_path="${spec#*:}"
    cat > "$CROSS_BIN/$cmd" <<WRAPPER
#!/bin/sh
exec "$CROSS_BIN/cross" "$remote_path" "\$@"
WRAPPER
    chmod 0755 "$CROSS_BIN/$cmd"
  done

  # A previous version installed a special npx helper and moved npm caches
  # away from HOME. They are no longer needed with the executable HOME bind.
  sudo rm -f "$CROSS_ROOT/usr/local/bin/npx"

  cat > "$CROSS_BIN/nvm" <<'NVM_NOTICE'
#!/bin/sh
echo "nvm is not packaged by Alpine. Node.js and npm are supplied by apk." >&2
echo "Inside cross: sudo apk upgrade nodejs npm" >&2
exit 2
NVM_NOTICE
  chmod 0755 "$CROSS_BIN/nvm"
}

# ChromeOS release images intentionally do not load services from the writable
# /usr/local tree. A persistent boot service therefore needs a job in /etc/init,
# which in turn requires rootfs verification to have been disabled. Autostart is
# optional: inability to configure it must not prevent the Alpine setup.
ensure_boot_autostart_prerequisites() {
  local make_dev_ssd="/usr/share/vboot/bin/make_dev_ssd.sh"
  local root_device="" root_partition="" kernel_partition=""

  info "Checking ChromeOS boot autostart prerequisites"
  BOOT_AUTOSTART_AVAILABLE=0
  if ! have initctl; then
    warn "Boot autostart unavailable: ChromeOS Upstart initctl was not found."
    warn "Continuing setup without boot autostart."
    return 0
  fi
  if sudo test -d /etc/init && sudo test -w /etc/init; then
    BOOT_AUTOSTART_AVAILABLE=1
    return 0
  fi

  # A developer/test image can have verity disabled while / is currently
  # mounted read-only. Prefer a remount over rewriting its kernel configuration.
  if sudo mount -o remount,rw / 2>/dev/null \
      && sudo test -d /etc/init && sudo test -w /etc/init; then
    info "Remounted the already-unverified ChromeOS rootfs read-write"
    BOOT_AUTOSTART_AVAILABLE=1
    return 0
  fi

  if [[ ! -x "$make_dev_ssd" ]]; then
    warn "Boot autostart unavailable: /etc/init is read-only and $make_dev_ssd was not found."
    warn "Continuing setup without boot autostart."
    return 0
  fi
  if ! have rootdev; then
    warn "Boot autostart unavailable: rootdev was not found."
    warn "Continuing setup without boot autostart."
    return 0
  fi
  root_device="$(rootdev -s 2>/dev/null || true)"
  if [[ "$root_device" =~ ([0-9]+)$ ]]; then
    root_partition="${BASH_REMATCH[1]}"
  fi
  if [[ ! "$root_partition" =~ ^[0-9]+$ ]] || (( root_partition <= 1 )); then
    warn "Boot autostart unavailable: cannot identify the active ChromeOS root partition (${root_device:-unknown})."
    warn "Continuing setup without boot autostart."
    return 0
  fi
  kernel_partition="$((root_partition - 1))"
  case "$kernel_partition" in
    2|4|6) ;;
    *)
      warn "Boot autostart unavailable: unexpected active ChromeOS kernel partition $kernel_partition."
      warn "Continuing setup without boot autostart."
      return 0
      ;;
  esac

  warn "Boot autostart requires disabling ChromeOS rootfs verification."
  warn "This weakens verified boot and can affect ChromeOS updates."
  info "Disabling rootfs verification for active kernel partition $kernel_partition"
  if ! sudo "$make_dev_ssd" --remove_rootfs_verification \
      --partitions "$kernel_partition"; then
    warn "Boot autostart unavailable: could not disable rootfs verification."
    warn "Continuing setup without boot autostart; follow make_dev_ssd.sh's guidance to enable it later."
    return 0
  fi

  cat <<'REBOOT_REQUIRED'

ChromeOS must reboot before /etc/init becomes writable, but Cross setup will
continue now without boot autostart.

After this setup completes:

  1. Reboot the Chromebook when convenient.
  2. Return to VT-2 as chronos.
  3. Run cross.sh again to install boot autostart.

Do not switch Developer Mode off; doing so may wipe local data.
REBOOT_REQUIRED
  warn "Continuing setup without boot autostart until the post-reboot rerun."
  return 0
}

# Install the ChromeOS Upstart boot job after the prerequisite check has made
# /etc/init writable. Any failure is reported to the caller so setup can fall
# back to manual service startup.
install_boot_autostart() {
  info "Configuring ChromeOS boot autostart"
  local job="/etc/init/cross-service.conf"
  local stored="$CROSS_ETC/cross-service.upstart.conf"
  local helper="$CROSS_ETC/cross-boot-start"
  local boot_service="$CROSS_ETC/cross-service-boot"
  local boot_log="$CROSS_LOG/boot.log"

  if [[ -L "$helper" || -L "$boot_service" || -L "$stored" || -L "$job" ]]; then
    warn "Boot autostart not installed: a protected autostart path is a symlink."
    return 1
  fi

  # Upstart runs this chain as root. Snapshot the generated service controller
  # below the root-owned etc directory instead of executing its user-writable
  # command in bin directly.
  if ! sudo install -o root -g root -m 0755 \
      "$CROSS_BIN/cross-service" "$boot_service"; then
    warn "Boot autostart not installed: could not secure the boot service."
    return 1
  fi
  if [[ -L "$boot_log" || ( -e "$boot_log" && ! -f "$boot_log" ) ]]; then
    warn "Boot autostart not installed: refusing unsafe boot log $boot_log."
    return 1
  fi
  if ! sudo touch "$boot_log" \
      || ! sudo chown root:root "$boot_log" \
      || ! sudo chmod 0644 "$boot_log"; then
    warn "Boot autostart not installed: could not secure $boot_log."
    return 1
  fi

  # The user's encrypted HOME might be absent until login. Upstart must not
  # block system startup; this small watchdog runs independently of the UI.
  if ! cat <<'BOOT_HELPER' | sudo tee "$helper" >/dev/null; then
#!/bin/bash
set -Eeuo pipefail
SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PREFIX="$(dirname -- "$SELF_DIR")"
[[ -r "$PREFIX/etc/cross.conf" ]] || exit 0
# shellcheck disable=SC1090
. "$PREFIX/etc/cross.conf"
[[ -f "$PREFIX/.alpine-cross-complete" ]] || exit 0
# A login may be needed to unlock ChromeOS cryptohome; do not attempt to
# bind the empty pre-login placeholder as HOME.
while :; do
  if [[ -d "$HOST_HOME" && -f "$HOST_HOME/.bashrc" ]]; then
    if "$PREFIX/etc/cross-service-boot" start; then
      exit 0
    fi
    echo "cross-boot-start: start failed; retrying after 15 seconds" >&2
    sleep 15
  else
    sleep 5
  fi
done
BOOT_HELPER
    warn "Boot autostart not installed: could not write $helper."
    return 1
  fi
  if ! sudo chown root:root "$helper" || ! sudo chmod 0755 "$helper"; then
    warn "Boot autostart not installed: could not secure $helper."
    return 1
  fi

  if ! cat <<UPSTART | sudo tee "$stored" >/dev/null; then
# Cross Alpine SSH service. Generated by cross.sh.
# Installed after setup has made /etc/init writable.
description "Cross Alpine localhost SSH autostart"
start on started system-services
stop on stopping system-services
task
script
  exec $(printf '%q' "$helper") >> $(printf '%q' "$boot_log") 2>&1
end script
UPSTART
    warn "Boot autostart not installed: could not write $stored."
    return 1
  fi
  if ! sudo chown root:root "$stored" || ! sudo chmod 0644 "$stored"; then
    warn "Boot autostart not installed: could not secure $stored."
    return 1
  fi

  if [[ -e "$job" ]] \
      && ! sudo grep -Fqx '# Cross Alpine SSH service. Generated by cross.sh.' "$job"; then
    warn "Boot autostart not installed: existing $job is not Cross-managed."
    return 1
  fi
  if ! sudo test -d /etc/init || ! sudo test -w /etc/init; then
    warn "Boot autostart not installed: /etc/init is not writable."
    return 1
  fi
  if ! sudo install -o root -g root -m 0644 "$stored" "$job" \
      || ! sudo cmp -s "$stored" "$job"; then
    warn "Boot autostart not installed: could not install or verify $job."
    return 1
  fi
  if ! sudo initctl reload-configuration; then
    warn "Boot autostart not installed: Upstart rejected $job."
    return 1
  fi
  info "Boot autostart installed: $job (starts after HOME is unlocked)"
}

write_profile() {
  info "Updating shell profile"
  local bashrc="${HOME:-/home/chronos/user}/.bashrc"
  local profile="${HOME:-/home/chronos/user}/.bash_profile"
  local begin='# >>> cross-alpine >>>'
  local end='# <<< cross-alpine <<<'
  local tmp
  touch "$bashrc" "$profile"
  tmp="$(mktemp)"
  awk -v begin="$begin" -v end="$end" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "$bashrc" > "$tmp"
  {
    printf '\n# >>> cross-alpine >>>\n'
    printf 'export CROSS_WORK=%q\n' "$CROSS_WORK/chronos"
    cat <<'PROFILE'
if [ -n "${CROSS_SESSION:-}" ]; then
  case $- in
    *i*)
      PS1='\[\e[1;32m\]cross@localhost\[\e[0m\] \[\e[1;34m\]\W\[\e[0m\] $ '
      ;;
  esac
else
  export PATH="/usr/local/cross/bin:$PATH"
fi
# <<< cross-alpine <<<
PROFILE
  } >> "$tmp"
  cat "$tmp" > "$bashrc"
  rm -f "$tmp"

  if ! grep -Fq "$begin" "$profile"; then
    cat >> "$profile" <<'PROFILE'

# >>> cross-alpine >>>
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
# <<< cross-alpine <<<
PROFILE
  fi
}

validate_dns() {
  info "Validating Alpine DNS"
  "$CROSS_BIN/cross" /bin/sh -c '
    test -s /etc/resolv.conf || exit 1
    grep -Eq "^[[:space:]]*nameserver[[:space:]]+" /etc/resolv.conf || exit 1
    getent ahosts dl-cdn.alpinelinux.org >/dev/null 2>&1
  ' || die "Alpine DNS resolution failed"
  info "Alpine DNS resolution OK"
}

# Generic validation without Cargo-specific or VS Code-specific exceptions.
validate_home_execution() {
  info "Validating ELF and symlink execution from HOME"
  # Pass one complete -c argument instead of nesting a heredoc. This stays
  # robust when cross.sh itself is delivered through a stdin pipe.
  "$CROSS_BIN/cross" /bin/sh -c '
    set -eu
    dir="$(mktemp -d "$HOME/.cross-exec-probe.XXXXXXXX")"
    trap '\''rm -rf -- "$dir"'\'' EXIT
    cp /bin/busybox "$dir/busybox"
    chmod 0700 "$dir/busybox"
    "$dir/busybox" true
    mkdir "$dir/link"
    ln -s ../busybox "$dir/link/busybox"
    "$dir/link/busybox" true
    printf "HOME ELF execution: OK\nHOME symlink execution: OK\n"
  '
}

validate() {
  info "Validating Alpine environment over localhost SSH"
  "$CROSS_BIN/cross" status
  "$CROSS_BIN/cross" /bin/sh -c '
    test -x /sbin/apk.static
    for cli in git curl nano vim ffmpeg gcc make rustup rustc cargo node npm npx xpra vlc xterm; do
      command -v "$cli" >/dev/null 2>&1 || exit 1
    done
  '
  "$CROSS_BIN/cross" /bin/sh -c 'test "$CROSS_SESSION" = 1'
  "$CROSS_BIN/cross" /bin/sh -c '
    test -r /usr/local/lib/cross-gcompat-resolver.so
    test -e /lib64/ld-linux-x86-64.so.2 -o \
         -e /lib/ld-linux-aarch64.so.1 -o \
         -e /lib64/ld-linux-aarch64.so.1
    test "$LD_PRELOAD" = /usr/local/lib/cross-gcompat-resolver.so
  '
  "$CROSS_BIN/cross" /bin/sh -c 'test "$(command -v npx)" = /usr/bin/npx'
  [[ "$("$CROSS_BIN/cross" sudo -n /usr/bin/id -u)" == 0 ]] \
    || die "Alpine sudo did not elevate chronos to uid 0"

  validate_home_execution

  local testdir
  testdir="$CROSS_WORK/chronos/.cross-smoke-test.$$"
  mkdir -p "$testdir"
  cat > "$testdir/hello.c" <<'C_SOURCE'
#include <stdio.h>
int main(void) { puts("cross-alpine-ok"); return 0; }
C_SOURCE
  "$CROSS_BIN/cross" /bin/sh -c "cd '$testdir' && cc hello.c -o hello && ./hello"
  rm -rf "$testdir"

  info "Validating Cross Desktop, browser canvas, and VLC"
  "$CROSS_BIN/cross" /usr/local/libexec/cross-desktop start
  "$CROSS_BIN/cross" /usr/local/libexec/cross-desktop status
  "$CROSS_BIN/cross" /bin/sh -c '
    test -x /usr/bin/vlc
    test -x /usr/bin/pcmanfm
    test -x /usr/bin/mousepad
    test -x /usr/bin/ristretto
    test -x /usr/bin/mupdf-x11
    test -x /usr/local/libexec/cross-open-target
    test -f /usr/local/share/cross-desktop/www/manifest.webmanifest
    test -f /usr/local/share/cross-desktop/www/sw.js
    curl --silent --fail --max-time 3 http://127.0.0.1:'"$CROSS_DESKTOP_PORT"'/ \
      | grep -q "Cross Desktop"
  '
}

main() {
  show_ascii_banner
  require_vt2_eula_context
  show_eula_and_require_acceptance
  enable_logging
  SETUP_STARTED=1
  preflight
  ensure_boot_autostart_prerequisites
  reset_or_prepare_prefix
  quiesce_existing_service
  download_and_extract_rootfs
  configure_rootfs
  install_alpine_packages
  configure_glibc_compat
  configure_chronos_user
  configure_cross_sudo
  configure_cross_desktop
  write_ssh_service
  write_profile
  if (( BOOT_AUTOSTART_AVAILABLE )); then
    if ! install_boot_autostart; then
      BOOT_AUTOSTART_AVAILABLE=0
      warn "Continuing setup without boot autostart."
    fi
  else
    warn "Boot autostart is unavailable; continuing with manual service startup."
  fi

  # Set-up binds must be released before the service installs long-lived binds.
  release_setup_mounts
  "$CROSS_BIN/cross" restart

  validate_dns
  validate
  printf '%s\n' "$SCRIPT_VERSION" | sudo tee "$CROSS_COMPLETE" >/dev/null
  sudo chown root:root "$CROSS_COMPLETE"
  sudo chmod 0644 "$CROSS_COMPLETE"

  info "Setup complete"
  cat <<SUMMARY

No third-party source packages were built; system tools and libraries came from
Alpine ${ALPINE_BRANCH} repositories. A two-line musl compatibility DSO is built
locally so npm's glibc-linked workerd binary can run with Alpine gcompat.
Transactions use Alpine apk-tools v2 static from ${APK_COMPAT_BRANCH} because
the current ChromeOS kernel rejects apk v3 memfd hooks.

Transport:
  crosh cross -> host ssh -> Cross service -> Alpine chroot

Cross Desktop:
  $CROSS_BIN/cross_desktop
  http://cross-${CROSS_DESKTOP_UUID}.localhost:${CROSS_DESKTOP_PORT}

  The X11-to-canvas session supports browser audio, clipboard synchronization,
  file drag-and-drop and PWA installation. To start VLC:
    cross_desktop vlc

Open URLs in ChromeOS Chrome and local targets in Cross Desktop:
  open https://example.com
  open ~/Downloads/movie.mp4

Activate wrappers:
  source ~/.bashrc

Boot autostart:
  When supported, an Upstart boot job starts Cross once the encrypted HOME is
  available (normally after ChromeOS login). If autostart could not be safely
  configured, setup still completed; run cross start manually after boot.

Service management from VT-2:
  cross status
  cross start
  cross stop
  cross restart
  cross doctor

Examples:
  cross
  apk info
  git --version
  cc --version
  cross sudo apk upgrade
  cross sudo -n id

ChromeOS HOME is bind-mounted at the same pathname inside Alpine. The *bind
mount* is set to exec,nosuid,nodev; ChromeOS' original HOME mount flags stay
unchanged. This is a security trade-off: because no mount namespace is used,
programs on the host can also reach the executable alias under the chroot.

ELF and symlink execution from HOME are tested independently of any tool.
You can keep Cargo build outputs, rustup toolchains, and npm/npx caches under
HOME without project-specific directory overrides. The suggested alternate
build-output directory still exists at:
  $CROSS_WORK/chronos

VS Code CLI is not an Alpine system package installed by this script. If you
installed it separately, the executable HOME bind removes one possible EACCES
cause; other runtime incompatibilities or ChromeOS policies may still apply.

Log: $LOG_FILE
SUMMARY
}

main "$@"
