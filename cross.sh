#!/bin/bash
# cross.sh - Alpine-packages-only development environment for ChromeOS Developer Mode.
#
# This version performs NO source builds. It installs an official Alpine Linux
# minirootfs and signed Alpine packages below /usr/local/cross/alpine, then
# exposes convenient host-side wrappers such as `git`, `cc`, `make`, `rustup`,
# `node`, and `npm` through a localhost-only OpenSSH service hosted by a VT-2
# process. The crosh-side `cross` command is an actual SSH client.
#
# Runtime characteristics:
#   * same ChromeOS kernel; no VM, no LXC/Docker, no namespaces
#   * a chroot is used only to give Alpine binaries their expected /lib and /usr
#   * the ChromeOS home directory is bind-mounted at the identical path
#   * a VT-2-started sshd listens only on 127.0.0.1 and uses a dedicated key
#   * build outputs intended for execution belong under /usr/local/cross/work
#   * all compiler/runtime/library files are obtained from Alpine repositories
#   * apk-tools v2 static from Alpine v3.22 is retained only as the package-
#     transaction runner because ChromeOS rejects apk-tools v3 executable memfd
#     package scripts; Alpine v3.24 still publishes v2 indexes/packages
#
# Run once from VT-2 as chronos:
#   bash ~/Downloads/cross.sh
#
# After setup:
#   source ~/.bashrc
#   git --version
#   cross                 # open an interactive Alpine-backed shell
#   cross apk info        # inspect installed Alpine packages
#
# Important: nvm is not packaged by Alpine stable or Alpine edge/testing.
# To keep this script strictly Alpine-only, Node.js and npm are installed from
# Alpine packages instead. rustup itself is an Alpine package; toolchains later
# installed by rustup are downloaded by rustup from the Rust distribution site.

set -Eeuo pipefail
umask 022

SCRIPT_VERSION="2026-07-31.31-vt2-eula"
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

Cross is a successor project to Chromebrew. By accepting this agreement, you
acknowledge and agree to all of the following:

1. Cross is intended for ChromeOS Developer Mode and performs privileged system
   operations. The installer uses sudo, writes below /usr/local/cross, creates
   bind mounts and a chroot, may adjust the ChromeOS symlink security policy
   until reboot, and starts a localhost-only OpenSSH service from VT-2.

2. You are responsible for backing up important data, reviewing this script,
   and deciding whether these changes are appropriate for your device. Developer
   Mode and privileged modifications can reduce system security or cause data
   loss if misused or interrupted.

3. Cross is provided "AS IS", without warranties or guarantees of availability,
   fitness, compatibility, security, or freedom from defects. You assume all
   risk arising from installation and use, to the extent permitted by law.

4. Alpine Linux and all other third-party packages remain governed by their own
   licenses. This EULA does not replace or override those licenses.

5. Acceptance authorizes this installer to perform the operations described
   above. If you do not accept, the installer will exit without beginning setup.
CROSS_EULA

  while :; do
    printf '\nDo you accept the Cross EULA? [y/n]: ' >/dev/tty
    if ! IFS= read -r reply </dev/tty; then
      die "unable to read the EULA response from VT-2"
    fi
    case "$reply" in
      y|Y)
        info "EULA accepted"
        return 0
        ;;
      n|N|'')
        printf '\nCross EULA not accepted; setup cancelled.\n' >/dev/tty
        exit 1
        ;;
      *)
        printf 'Please answer y or n.\n' >/dev/tty
        ;;
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
  local url="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  [[ -s "$out" ]] && return 0
  info "Downloading ${out##*/}"
  rm -f "$out.part"
  case "$FETCH_TOOL" in
    curl)
      env -u LD_LIBRARY_PATH curl --fail --location --show-error --silent \
        --retry 5 --retry-delay 2 --proto '=https' --tlsv1.2 \
        --output "$out.part" "$url"
      ;;
    wget)
      env -u LD_LIBRARY_PATH wget --https-only --tries=5 \
        --output-document="$out.part" "$url"
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

# apk-tools v3 stores package scripts in executable memfd objects and invokes
# those objects directly. The ChromeOS kernel on this device rejects that
# execve path with EACCES, even though normal executable files under /usr/local
# work. apk-tools v2 uses a file-backed script under /lib/apk/exec instead.
# Verify that exact path before using the compatibility transaction runner.
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

    # Use the minirootfs' apk v3 only for this script-free bootstrap transaction.
    # The repository file contains only Alpine v3.22, whose apk-tools-static is
    # the final apk-tools v2 release line. No package hook is executed here.
    sudo "$CHROOT_BIN" "$CROSS_ROOT" /sbin/apk \
      --repositories-file /etc/apk/repositories.apk2 \
      --scripts=no --commit-hooks=no add --no-cache apk-tools-static

    [[ -x "$CROSS_ROOT/sbin/apk.static" ]] \
      || die "Alpine apk-tools v2 static binary was not installed"
    version="$(sudo "$CHROOT_BIN" "$CROSS_ROOT" /sbin/apk.static --version 2>&1 | sed -n '1p')"
  else
    info "Using existing Alpine apk-tools v2 compatibility runner"
  fi

  [[ "$version" == apk-tools\ 2.* ]] \
    || die "unexpected compatibility apk version: $version"
  printf 'Compatibility apk: %s\n' "$version"

  # Put the compatibility runner first in the chroot PATH. The packaged apk v3
  # remains available as /sbin/apk for inspection, but package transactions use
  # /sbin/apk.static so their hooks follow the file-backed execution path.
  sudo mkdir -p "$CROSS_ROOT/usr/local/sbin"
  sudo ln -sfn /sbin/apk.static "$CROSS_ROOT/usr/local/sbin/apk"
}
# ChromeOS blocks symlink traversal on the stateful partition by default.
# Alpine root filesystems contain essential symlinks (for example /bin/sh and
# the musl loader), so a chroot may otherwise fail with execve(EACCES).
# Developer Mode already treats /mnt/stateful_partition/dev_image as the
# executable /usr/local tree; this adds the matching runtime exception when the
# current ChromeOS build did not retain it for nested chroot resolution.
ensure_chroot_exec() {
  local security_mnt="/sys/kernel/security"
  local policy_dir="$security_mnt/chromiumos/inode_security_policies"
  local policy_file="$policy_dir/allow_symlink"
  local mounted_here=0 remounted_rw=0 security_opts=""

  [[ -x "$CROSS_ROOT/bin/busybox" ]] \
    || die "Alpine /bin/busybox is missing or not executable"

  if sudo "$CHROOT_BIN" "$CROSS_ROOT" /bin/busybox true >/dev/null 2>&1; then
    return 0
  fi

  warn "ChromeOS denied chroot exec; enabling the Developer Mode symlink exception for /usr/local"

  sudo mkdir -p "$security_mnt"
  if ! awk -v target="$security_mnt" '$2 == target { found=1 } END { exit !found }' /proc/mounts; then
    sudo mount -t securityfs -o nodev,noexec,nosuid securityfs "$security_mnt" \
      || die "cannot mount ChromeOS securityfs to configure symlink policy"
    mounted_here=1
  fi

  security_opts="$(awk -v target="$security_mnt" '$2 == target { print $4; exit }' /proc/mounts)"
  if [[ ",${security_opts}," == *,ro,* ]]; then
    sudo mount -o remount,rw "$security_mnt" \
      || die "cannot temporarily remount $security_mnt read-write"
    remounted_rw=1
  fi

  [[ -e "$policy_file" ]] \
    || die "ChromeOS allow_symlink policy interface is unavailable: $policy_file"

  # First grant the narrow Developer Mode subtree used by /usr/local.
  printf '%s' '/mnt/stateful_partition/dev_image' | sudo tee "$policy_file" >/dev/null

  # Some ChromeOS releases resolve the chroot path against the parent stateful
  # mount. Only broaden the temporary exception if the narrow rule is not enough.
  if ! sudo "$CHROOT_BIN" "$CROSS_ROOT" /bin/busybox true >/dev/null 2>&1; then
    warn "The narrow dev_image rule was insufficient; allowing stateful symlinks until reboot"
    printf '%s' '/mnt/stateful_partition' | sudo tee "$policy_file" >/dev/null
  fi

  if (( remounted_rw )); then
    sudo mount -o remount,ro "$security_mnt" >/dev/null 2>&1 || true
  fi
  if (( mounted_here )); then
    sudo umount "$security_mnt" >/dev/null 2>&1 || true
  fi

  if ! sudo "$CHROOT_BIN" "$CROSS_ROOT" /bin/busybox true >/dev/null 2>&1; then
    sudo ls -l "$CROSS_ROOT/bin/busybox" "$CROSS_ROOT/sbin/apk" \
      "$CROSS_ROOT/lib/ld-musl-${ALPINE_ARCH}.so.1" 2>/dev/null || true
    awk '$2 == "/usr/local" || $2 == "/mnt/stateful_partition" {print}' /proc/mounts >&2 || true
    die "ChromeOS still denies execution inside the Alpine rootfs"
  fi
}

preflight() {
  info "cross.sh $SCRIPT_VERSION"
  info "Preflight checks"

  (( EUID != 0 )) || die "run as chronos, not as root"
  [[ -f /etc/lsb-release ]] || die "this does not look like the ChromeOS host"
  have sudo || die "sudo is required; run from VT-2 in Developer Mode"
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
  [[ -n "$HOST_SSH_BIN" ]] \
    || die "a host OpenSSH client is required for the crosh-side cross command"
  "$HOST_SSH_BIN" -V >/dev/null 2>&1 \
    || die "the detected host ssh client is not usable: $HOST_SSH_BIN"

  local nnp opts free_kib
  nnp="$(awk '/^NoNewPrivs:/ {print $2}' /proc/self/status 2>/dev/null || true)"
  [[ "$nnp" != 1 ]] || die "NoNewPrivs is active; run from VT-2, not browser crosh"

  sudo true

  if have curl; then
    FETCH_TOOL="curl"
  elif have wget; then
    FETCH_TOOL="wget"
  else
    die "curl or wget is required for the initial Alpine download"
  fi

  HOST_ARCH="$(uname -m)"
  case "$HOST_ARCH" in
    aarch64|arm64) ALPINE_ARCH="aarch64" ;;
    x86_64|amd64) ALPINE_ARCH="x86_64" ;;
    *) die "unsupported architecture: $HOST_ARCH" ;;
  esac

  [[ "$CROSS_PREFIX" != *[[:space:]]* ]] \
    || die "CROSS_PREFIX must not contain whitespace"
  [[ "$CROSS_SSH_PORT" =~ ^[0-9]+$ ]] && (( CROSS_SSH_PORT >= 1024 && CROSS_SSH_PORT <= 65535 )) \
    || die "CROSS_SSH_PORT must be an unprivileged TCP port from 1024 to 65535"

  opts="$(awk '$2 == "/usr/local" {print $4}' /proc/mounts | tail -n1)"
  [[ ",${opts}," != *,noexec,* ]] || die "/usr/local is mounted noexec"
  [[ ",${opts}," != *,nosuid,* ]] || die "/usr/local is mounted nosuid; Alpine sudo requires setuid support"

  free_kib="$(df -Pk /usr/local | awk 'NR==2 {print $4}')"
  [[ "$free_kib" =~ ^[0-9]+$ ]] || free_kib=0
  (( free_kib >= 1200000 )) || die "at least 1.2 GiB free space under /usr/local is required"

  printf 'Architecture: %s\n' "$ALPINE_ARCH"
  printf 'Alpine:       %s\n' "$ALPINE_VERSION"
  printf 'Prefix:       %s\n' "$CROSS_PREFIX"
  printf 'Host SSH:     %s\n' "$HOST_SSH_BIN"
  printf 'SSH port:     %s\n' "$CROSS_SSH_PORT"
}

reset_or_prepare_prefix() {
  info "Preparing Alpine-only prefix"

  if [[ -d "$CROSS_PREFIX" && ! -f "$CROSS_MARKER" ]]; then
    if [[ -d "$CROSS_PREFIX/var/db/cross" || -d "$CROSS_PREFIX/opt/zig-0.16.0" ]] \
      || compgen -G "$CROSS_PREFIX/opt/alpine-make-*" >/dev/null; then
      local backup="${CROSS_PREFIX}.source-build-backup-$(date +%Y%m%d-%H%M%S)"
      warn "Moving the previous source-built environment to $backup"
      sudo mv "$CROSS_PREFIX" "$backup"
    elif [[ -n "$(find "$CROSS_PREFIX" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
      die "$CROSS_PREFIX exists but is not recognized as a cross.sh-managed prefix"
    fi
  fi

  sudo mkdir -p "$CROSS_PREFIX" "$CROSS_ROOT" "$CROSS_BIN" "$CROSS_CACHE" \
    "$CROSS_ETC" "$CROSS_RUN" "$CROSS_LOG" "$CROSS_WORK"
  sudo chown "$(id -u):$(id -g)" "$CROSS_PREFIX" "$CROSS_BIN" "$CROSS_CACHE" \
    "$CROSS_RUN" "$CROSS_LOG" "$CROSS_WORK"
  printf '%s\n' "$SCRIPT_VERSION" > "$CROSS_MARKER"
}

quiesce_existing_service() {
  if [[ -x "$CROSS_BIN/cross-service" && -r "$CROSS_ETC/cross.conf" ]]; then
    info "Stopping existing cross service for maintenance"
    "$CROSS_BIN/cross-service" stop
  fi
}

rootfs_is_resumable() {
  [[ -f "$CROSS_ROOT/lib/apk/db/installed" ]] \
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

download_and_extract_rootfs() {
  local base archive sumfile expected actual version_file
  base="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}"
  archive="$CROSS_CACHE/alpine-minirootfs-${ALPINE_VERSION}-${ALPINE_ARCH}.tar.gz"
  sumfile="$archive.sha256"
  version_file="$CROSS_ROOT/etc/alpine-release"

  if [[ -f "$version_file" && "$(cat "$version_file")" == "$ALPINE_VERSION" ]]; then
    if [[ -f "$CROSS_COMPLETE" ]]; then
      info "Alpine minirootfs $ALPINE_VERSION already installed"
      return 0
    fi
    if rootfs_is_resumable; then
      warn "A fully populated but unvalidated Alpine setup was found; resuming without re-extraction"
      return 0
    fi
    warn "An incomplete Alpine setup was found; rebuilding the rootfs from the verified archive"
  fi

  fetch "$base/${archive##*/}.sha256" "$sumfile"
  fetch "$base/${archive##*/}" "$archive"

  expected="$(awk 'NF {print $1; exit}' "$sumfile")"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "invalid Alpine SHA-256 file"
  actual="$(sha256_file "$archive")"
  [[ "${actual,,}" == "${expected,,}" ]] || {
    rm -f "$archive"
    die "SHA-256 mismatch for ${archive##*/}"
  }

  info "Extracting Alpine minirootfs $ALPINE_VERSION"
  rm -f "$CROSS_COMPLETE"
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

  sudo cp -f /etc/resolv.conf "$CROSS_ROOT/etc/resolv.conf"
  [[ -f /etc/hosts ]] && sudo cp -f /etc/hosts "$CROSS_ROOT/etc/hosts" || true

  mount_bind /dev "$CROSS_ROOT/dev" 1
  mount_proc "$CROSS_ROOT/proc"
  mount_bind /sys "$CROSS_ROOT/sys" 1
  [[ -d /run ]] && mount_bind /run "$CROSS_ROOT/run" 1 || true

  ensure_chroot_exec
  ensure_file_backed_package_scripts
  bootstrap_apk_v2_runner
}

apk_chroot() {
  sudo "$CHROOT_BIN" "$CROSS_ROOT" /sbin/apk.static "$@"
}

install_alpine_packages() {
  info "Installing signed Alpine development packages"

  # A freshly extracted minirootfs does not need a whole-system upgrade here.
  # `apk upgrade --available` can fail on ChromeOS chroots while processing the
  # release image's initial world set, before any requested development package
  # is installed. Refresh indexes, resolve the requested package set, then add
  # that set directly. Dependencies are selected from the current signed indexes.
  apk_chroot update

  local required=(
    bash ca-certificates coreutils findutils diffutils grep sed gawk
    tar gzip bzip2 xz file patch git git-init-template curl openssh-client openssh-server
    build-base linux-headers pkgconf cmake samurai meson autoconf automake libtool
    openssl-dev zlib-dev bzip2-dev xz-dev libffi-dev ncurses-dev readline-dev
    sqlite-dev libxml2-dev libxslt-dev libarchive-dev libssh2-dev libuv-dev
    rust cargo rustfmt rust-clippy rustup nodejs npm sudo su-exec
  )

  # A real apk transaction performs dependency resolution before applying any
  # package changes. Avoid a separate --simulate gate: apk also reports existing
  # database/filesystem health errors in simulation summaries, which can reject a
  # perfectly resolvable package set without identifying a missing dependency.
  info "Resolving and installing Alpine package set"
  apk_chroot add --no-cache "${required[@]}"
  sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/sbin/update-ca-certificates || true

  # Alpine's rustup package installs the multicall binary as rustup-init.
  # Expose it as rustup without downloading any upstream toolchain.
  sudo mkdir -p "$CROSS_ROOT/usr/local/bin"
  sudo ln -sfn /usr/bin/rustup-init "$CROSS_ROOT/usr/local/bin/rustup"
}

configure_chronos_user() {
  info "Configuring chronos identity inside Alpine"

  local uid gid group host_home shadow_tmp
  uid="$(id -u)"
  gid="$(id -g)"
  host_home="${HOME:-/home/chronos/user}"

  sudo mkdir -p "$CROSS_ROOT$host_home"

  if ! sudo grep -q '^chronos:' "$CROSS_ROOT/etc/passwd"; then
    group="$(sudo awk -F: -v gid="$gid" '$3 == gid {print $1; exit}' "$CROSS_ROOT/etc/group")"
    if [[ -z "$group" ]]; then
      sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/sbin/addgroup -g "$gid" chronos
      group="chronos"
    fi

    sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/sbin/adduser \
      -D -u "$uid" -G "$group" -h "$host_home" \
      -s /bin/bash chronos
  fi

  # OpenSSH with UsePAM=no rejects accounts whose shadow password begins with
  # '!' or '*', even when only public-key authentication is enabled. Install an
  # impossible non-locking password field; password authentication remains off.
  shadow_tmp="$(mktemp)"
  sudo awk -F: 'BEGIN { OFS=FS } $1 == "chronos" { $2="x" } { print }' \
    "$CROSS_ROOT/etc/shadow" > "$shadow_tmp"
  sudo install -o root -g root -m 0600 "$shadow_tmp" "$CROSS_ROOT/etc/shadow"
  rm -f "$shadow_tmp"
}

configure_cross_sudo() {
  info "Configuring passwordless sudo inside Alpine"

  # The localhost SSH key is the sole login credential and the chronos account
  # has no usable password. Configure sudo explicitly as passwordless rather
  # than relying on an authentication path that can never succeed.
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
Defaults:chronos env_keep += "TERM LANG LC_ALL LC_CTYPE CROSS_WORK RUSTUP_HOME CARGO_HOME SSL_CERT_FILE GIT_SSL_CAINFO NPM_CONFIG_CACHE NPM_CONFIG_PREFIX COREPACK_HOME TMPDIR"
chronos ALL=(ALL:ALL) NOPASSWD: ALL
SUDOERS
  sudo chown root:root "$CROSS_ROOT/etc/sudoers.d/cross-chronos"
  sudo chmod 0440 "$CROSS_ROOT/etc/sudoers.d/cross-chronos"

  [[ -u "$CROSS_ROOT/usr/bin/sudo" ]] \
    || die "Alpine sudo is not setuid root; check /usr/local mount options"
  sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/sbin/visudo -cf /etc/sudoers >/dev/null
}

write_ssh_service() {
  info "Writing localhost OpenSSH service and crosh client"

  local uid gid host_home ssh_dir client_key client_pub server_pub
  uid="$(id -u)"
  gid="$(id -g)"
  host_home="${HOME:-/home/chronos/user}"
  ssh_dir="$CROSS_ETC/ssh"
  client_key="$ssh_dir/cross_client_ed25519"
  client_pub="$client_key.pub"

  sudo mkdir -p "$ssh_dir" "$CROSS_ROOT/etc/ssh" "$CROSS_ROOT/usr/local/libexec" \
    "$CROSS_ROOT/usr/local/bin" "$CROSS_ROOT/run" "$CROSS_ROOT/var/log" \
    "$CROSS_WORK/chronos/npm/cache" "$CROSS_WORK/chronos/npm/prefix/bin" \
    "$CROSS_WORK/chronos/corepack" "$CROSS_WORK/chronos/tmp"
  sudo chown "$uid:$gid" "$ssh_dir"
  sudo chown -R "$uid:$gid" "$CROSS_WORK/chronos"
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
  # OpenSSH opens AuthorizedKeysFile after temporarily switching to the
  # target user's uid. Keep this central file root-owned so chronos cannot
  # modify it, but make it readable by the authenticating user.
  sudo chown root:root "$CROSS_ROOT/etc/ssh/cross_authorized_keys"
  sudo chmod 0644 "$CROSS_ROOT/etc/ssh/cross_authorized_keys"

  # Do not execute Alpine's /usr/bin/npx symlink. Invoke the npm CLI through
  # node directly, and keep npx's symlink-heavy cache on the Developer Mode
  # /usr/local tree rather than ChromeOS' stateful HOME mount.
  cat <<'NPX_HELPER' | sudo tee "$CROSS_ROOT/usr/local/bin/npx" >/dev/null
#!/bin/bash
set -Eeuo pipefail

: "${CROSS_WORK:=/usr/local/cross/work/chronos}"
: "${NPM_CONFIG_CACHE:=$CROSS_WORK/npm/cache}"
: "${NPM_CONFIG_PREFIX:=$CROSS_WORK/npm/prefix}"
: "${COREPACK_HOME:=$CROSS_WORK/corepack}"
: "${TMPDIR:=$CROSS_WORK/tmp}"
export CROSS_WORK NPM_CONFIG_CACHE NPM_CONFIG_PREFIX COREPACK_HOME TMPDIR
mkdir -p "$NPM_CONFIG_CACHE" "$NPM_CONFIG_PREFIX/bin" "$COREPACK_HOME" "$TMPDIR"

# ChromeOS stateful HOME commonly has noexec/nosymfollow semantics. npx always
# exposes local node_modules/.bin entries, so a project-local dependency tree
# under HOME can still be unusable even though the remote npx cache is safe.
# Detect that case and report the real constraint instead of surfacing ELOOP.
case "$PWD" in
  "$HOME"|"$HOME"/*)
    dir="$PWD"
    while :; do
      if [[ -d "$dir/node_modules/.bin" ]] \
          && find "$dir/node_modules/.bin" -mindepth 1 -maxdepth 1 -print -quit \
             2>/dev/null | grep -q .; then
        cat >&2 <<EOF
npx: this project has local package executables under ChromeOS HOME:
  $dir/node_modules/.bin
ChromeOS may reject their symlink traversal or execution. Move the Node project
under $CROSS_WORK, then reinstall dependencies there.
EOF
        exit 126
      fi
      [[ "$dir" == "$HOME" ]] && break
      dir="${dir%/*}"
      [[ -n "$dir" ]] || break
    done
    ;;
esac

exec /usr/bin/node /usr/lib/node_modules/npm/bin/npx-cli.js "$@"
NPX_HELPER
  sudo chown root:root "$CROSS_ROOT/usr/local/bin/npx"
  sudo chmod 0755 "$CROSS_ROOT/usr/local/bin/npx"

  cat <<SESSION | sudo tee "$CROSS_ROOT/usr/local/libexec/cross-session" >/dev/null
#!/bin/bash
set -Eeuo pipefail

export HOME=$(printf '%q' "$host_home")
export USER=chronos
export LOGNAME=chronos
export SHELL=/bin/bash
export CROSS_WORK=$(printf '%q' "$CROSS_WORK/chronos")
export NPM_CONFIG_CACHE=$(printf '%q' "$CROSS_WORK/chronos/npm/cache")
export NPM_CONFIG_PREFIX=$(printf '%q' "$CROSS_WORK/chronos/npm/prefix")
export COREPACK_HOME=$(printf '%q' "$CROSS_WORK/chronos/corepack")
export TMPDIR=$(printf '%q' "$CROSS_WORK/chronos/tmp")
export PATH="\$NPM_CONFIG_PREFIX/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt
export RUSTUP_HOME=$(printf '%q' "$host_home/.rustup")
export CARGO_HOME=$(printf '%q' "$host_home/.cargo")
export CROSS_SESSION=1
export LANG=C.UTF-8
export LC_ALL=
: "\${TERM:=dumb}"
export TERM
umask 022
mkdir -p "\$NPM_CONFIG_CACHE" "\$NPM_CONFIG_PREFIX/bin" "\$COREPACK_HOME" "\$TMPDIR"

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
    npx)              printf '%s\n' /usr/local/bin/npx ;;
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
    *)
      cd -- "\$HOME"
      ;;
  esac
}

if [[ -z "\${SSH_ORIGINAL_COMMAND:-}" ]]; then
  cd -- "\$HOME"
  exec /bin/bash -l
fi

# The client emits Bash %q quoting. Authentication is limited to the dedicated
# localhost key, and this process already runs as chronos inside the chroot.
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
        if [[ -n "\$resolved" ]]; then
          exec "\$resolved" "\$@"
        fi
        exec "\$command_name" "\$@"
        ;;
    esac
    ;;
  *)
    echo "cross-session: unknown mode" >&2
    exit 126
    ;;
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

info() { printf 'cross-service: %s\n' "$*"; }
die()  { printf 'cross-service: %s\n' "$*" >&2; exit 1; }

is_mounted() {
  awk -v target="$1" '$2 == target { found=1 } END { exit !found }' /proc/mounts
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
  if ! is_mounted "$target"; then
    sudo mount -t proc proc "$target"
  fi
}

ensure_vt2_context() {
  local nnp
  nnp="$(awk '/^NoNewPrivs:/ {print $2}' /proc/self/status 2>/dev/null || true)"
  [[ "$nnp" != 1 ]] || die "start/stop must be run from VT-2, not browser crosh"
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
  if ! awk -v target="$security_mnt" '$2 == target { found=1 } END { exit !found }' /proc/mounts; then
    sudo mount -t securityfs -o nodev,noexec,nosuid securityfs "$security_mnt" \
      || die "cannot mount ChromeOS securityfs"
    mounted_here=1
  fi

  security_opts="$(awk -v target="$security_mnt" '$2 == target { print $4; exit }' /proc/mounts)"
  if [[ ",$security_opts," == *,ro,* ]]; then
    sudo mount -o remount,rw "$security_mnt" \
      || die "cannot remount ChromeOS securityfs read-write"
    remounted_rw=1
  fi

  [[ -e "$policy_file" ]] || die "ChromeOS allow_symlink policy interface is unavailable"
  printf '%s' '/mnt/stateful_partition/dev_image' | sudo tee "$policy_file" >/dev/null
  if ! sudo "$CHROOT_BIN" "$CROSS_ROOT" /bin/busybox true >/dev/null 2>&1; then
    printf '%s' '/mnt/stateful_partition' | sudo tee "$policy_file" >/dev/null
  fi

  (( remounted_rw == 0 )) || sudo mount -o remount,ro "$security_mnt" >/dev/null 2>&1 || true
  (( mounted_here == 0 )) || sudo umount "$security_mnt" >/dev/null 2>&1 || true

  sudo "$CHROOT_BIN" "$CROSS_ROOT" /bin/busybox true >/dev/null 2>&1 \
    || die "ChromeOS still denies execution inside the Alpine rootfs"
}

prepare_mounts() {
  sudo cp -f /etc/resolv.conf "$CROSS_ROOT/etc/resolv.conf"
  [[ ! -f /etc/hosts ]] || sudo cp -f /etc/hosts "$CROSS_ROOT/etc/hosts"

  mount_bind /dev "$CROSS_ROOT/dev" 1
  mount_proc "$CROSS_ROOT/proc"
  mount_bind /sys "$CROSS_ROOT/sys" 1
  mount_bind "$HOST_HOME" "$CROSS_ROOT$HOST_HOME" 0
  mount_bind "$CROSS_WORK" "$CROSS_ROOT$CROSS_WORK" 0

  sudo mkdir -p "$CROSS_ROOT/run" "$CROSS_ROOT/var/log" "$CROSS_ROOT/run/sshd"
  ensure_chroot_exec
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

auth_probe() {
  local remote quoted err_file status
  err_file="$PREFIX/run/cross-auth-probe.log"
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
  echo "cross-service: localhost SSH authentication probe failed" >&2
  [[ ! -s "$PREFIX/run/cross-auth-probe.log" ]] \
    || sed 's/^/client: /' "$PREFIX/run/cross-auth-probe.log" >&2
  [[ ! -r "$LOG_FILE" ]] \
    || sudo tail -n 80 "$LOG_FILE" | sed 's/^/sshd: /' >&2 || true
}

start_service() {
  ensure_vt2_context
  if pid="$(master_pid 2>/dev/null)"; then
    if auth_probe; then
      info "running and authenticated (pid $pid, 127.0.0.1:$CROSS_SSH_PORT)"
      return 0
    fi
    show_auth_failure
    die "sshd is running but public-key authentication is not working; rerun cross.sh"
  fi

  sudo rm -f "$PID_FILE"
  prepare_mounts
  sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/sbin/sshd \
    -t -f /etc/ssh/sshd_config_cross
  sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/sbin/sshd \
    -f /etc/ssh/sshd_config_cross -E /var/log/cross-sshd.log

  local i pid=""
  for ((i=1; i<=30; i++)); do
    if pid="$(master_pid 2>/dev/null)" && auth_probe; then
      info "started and authenticated (pid $pid, 127.0.0.1:$CROSS_SSH_PORT)"
      return 0
    fi
    sleep 0.1
  done
  show_auth_failure
  stop_service >/dev/null 2>&1 || true
  die "sshd did not pass the public-key authentication probe"
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
  local client_blob auth_blob mode owner
  printf 'Service:        '
  status_service || true
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
  if [[ -n "$client_blob" && "$client_blob" == "$auth_blob" ]]; then
    echo 'Key match:      yes'
  else
    echo 'Key match:      no'
  fi
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
  *) die "usage: cross-service {start|stop|restart|status|doctor|log [lines]}" ;;
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
[[ -x "$HOST_SSH_BIN" ]] || { echo "cross: host ssh is unavailable: $HOST_SSH_BIN" >&2; exit 1; }
[[ -r "$SSH_CONFIG" ]] || { echo "cross: missing SSH client configuration" >&2; exit 1; }

pty=auto
case "${1:-}" in
  -t) pty=yes; shift ;;
  -T) pty=no; shift ;;
  --) shift ;;
esac

case "$PWD" in
  "$HOST_HOME"|"$HOST_HOME"/*|"$CROSS_WORK/chronos"|"$CROSS_WORK/chronos"/*)
    remote_cwd="$PWD"
    ;;
  *)
    remote_cwd="$HOST_HOME"
    ;;
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
cross: the VT-2 service answered, but public-key authentication failed.
From VT-2 run:
  $PREFIX/bin/cross-service doctor
Then rerun the current cross.sh installer to repair the SSH key permissions.
MESSAGE
  else
    cat >&2 <<MESSAGE
cross: the VT-2 service is not reachable.
Switch to VT-2, log in as chronos, and run:
  $PREFIX/bin/cross-service start
MESSAGE
  fi
fi
exit "$status"
CLIENT
  chmod 0755 "$CROSS_BIN/cross"

  local spec cmd remote_path
  local wrapper_specs=(
    'apk:/sbin/apk.static'
    'bash:/bin/bash'
    'sh:/bin/sh'
    'git:/usr/bin/git'
    'git-upload-pack:/usr/bin/git-upload-pack'
    'git-receive-pack:/usr/bin/git-receive-pack'
    'curl:/usr/bin/curl'
    'wget:/usr/bin/wget'
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
    'npx:/usr/local/bin/npx'
    'corepack:/usr/bin/corepack'
    'python3:/usr/bin/python3'
  )
  for spec in "${wrapper_specs[@]}"; do
    cmd="${spec%%:*}"
    remote_path="${spec#*:}"
    cat > "$CROSS_BIN/$cmd" <<WRAPPER
#!/bin/sh
exec "$CROSS_BIN/cross" "$remote_path" "\$@"
WRAPPER
    chmod 0755 "$CROSS_BIN/$cmd"
  done

  cat > "$CROSS_BIN/nvm" <<'NVM_NOTICE'
#!/bin/sh
echo "nvm is not packaged by Alpine. This strict Alpine-only environment provides node and npm from apk." >&2
echo "Use: apk upgrade nodejs npm" >&2
exit 2
NVM_NOTICE
  chmod 0755 "$CROSS_BIN/nvm"
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
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$bashrc" > "$tmp"
  {
    printf '\n# >>> cross-alpine >>>\n'
    printf 'export CROSS_WORK=%q\n' "$CROSS_WORK/chronos"
    cat <<'PROFILE'
if [ -n "${CROSS_SESSION:-}" ]; then
  case $- in
    *i*)
      # Distinguish the Alpine SSH session from the ChromeOS host shell while
      # retaining a compact crosh-like coloured prompt. \W renders HOME as ~.
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

validate() {
  info "Validating Alpine environment over localhost SSH"

  "$CROSS_BIN/cross-service" status
  "$CROSS_BIN/cross" apk --version
  "$CROSS_BIN/cross" git --version
  "$CROSS_BIN/cross" curl --version | sed -n '1p'
  "$CROSS_BIN/cross" gcc --version | sed -n '1p'
  "$CROSS_BIN/cross" make --version | sed -n '1p'
  "$CROSS_BIN/cross" rustup --version
  "$CROSS_BIN/cross" rustc --version
  "$CROSS_BIN/cross" cargo --version
  "$CROSS_BIN/cross" node --version
  "$CROSS_BIN/cross" npm --version
  "$CROSS_BIN/cross" npx --version
  "$CROSS_BIN/cross" /bin/sh -c 'test "$CROSS_SESSION" = 1'
  "$CROSS_BIN/cross" /bin/sh -c 'test "$(command -v npx)" = /usr/local/bin/npx'
  "$CROSS_BIN/cross" /bin/sh -c 'test "$(npm config get cache)" = "$NPM_CONFIG_CACHE"'
  "$CROSS_BIN/cross" /bin/sh -c 'd="$NPM_CONFIG_CACHE/.cross-link-probe.$$"; trap '"'"'rm -rf "$d"'"'"' EXIT; mkdir -p "$d"; printf ok > "$d/target"; ln -s target "$d/link"; test "$(cat "$d/link")" = ok'
  [[ "$("$CROSS_BIN/cross" sudo -n /usr/bin/id -u)" == 0 ]] \
    || die "Alpine sudo did not elevate chronos to uid 0"

  local testdir
  testdir="$CROSS_WORK/chronos/.cross-smoke-test.$$"
  mkdir -p "$testdir"
  cat > "$testdir/hello.c" <<'C_SOURCE'
#include <stdio.h>
int main(void) { puts("cross-alpine-ok"); return 0; }
C_SOURCE
  "$CROSS_BIN/cross" /bin/sh -c "cd '$testdir' && cc hello.c -o hello && ./hello"
  rm -rf "$testdir"
}

main() {
  require_vt2_eula_context
  show_eula_and_require_acceptance
  enable_logging
  SETUP_STARTED=1
  preflight
  reset_or_prepare_prefix
  quiesce_existing_service
  download_and_extract_rootfs
  configure_rootfs
  install_alpine_packages
  configure_chronos_user
  configure_cross_sudo
  write_ssh_service
  write_profile

  # The installer-owned mounts must be released before cross-service starts;
  # otherwise the EXIT trap would detach mounts from the running SSH daemon.
  release_setup_mounts
  "$CROSS_BIN/cross-service" restart
  validate
  printf '%s\n' "$SCRIPT_VERSION" > "$CROSS_COMPLETE"

  info "Setup complete"
  cat <<SUMMARY

No source packages were built.
All installed system tools and libraries came from signed Alpine ${ALPINE_BRANCH}
main/community packages. Package transactions use Alpine apk-tools v2 static
from ${APK_COMPAT_BRANCH} because ChromeOS rejects apk-tools v3 memfd scripts.

The runtime transport is a real localhost-only OpenSSH connection:
  crosh cross -> host ssh -> VT-2-started cross-service -> Alpine chroot

Activate wrappers in the current shell:
  source ~/.bashrc

Service management from VT-2:
  cross-service status
  cross-service start
  cross-service stop
  cross-service restart
  cross-service doctor

Examples from crosh shell:
  cross                 # interactive Alpine-backed SSH session
  git --version
  cc --version
  cross apk upgrade
  cross sudo -n id       # root inside the Alpine chroot

The crosh host command sudo remains the ChromeOS sudo. Inside an interactive
cross shell, or when invoked as cross sudo ..., sudo elevates inside Alpine.

Executable build output belongs under:
  $CROSS_WORK/chronos
The ChromeOS home directory remains shared, but directly executing newly built
files from the home filesystem may be denied by ChromeOS.

Note: Alpine does not package nvm. Node.js and npm are supplied directly by apk.
Node/npx cache: $CROSS_WORK/chronos/npm/cache
Place Node projects with local node_modules under $CROSS_WORK/chronos to avoid
ChromeOS HOME noexec/nosymfollow restrictions.
Log: $LOG_FILE
SUMMARY
}

main "$@"
