#!/bin/bash
# cross.sh - Alpine-packages-only development environment for ChromeOS Developer Mode.
#
# This version performs NO source builds. It installs an official Alpine Linux
# minirootfs and signed Alpine packages below /usr/local/cross/alpine, then
# exposes convenient host-side wrappers such as `git`, `cc`, `make`, `rustup`,
# `node`, and `npm` through a plain chroot launcher.
#
# Runtime characteristics:
#   * same ChromeOS kernel; no VM, no LXC/Docker, no namespaces
#   * a chroot is used only to give Alpine binaries their expected /lib and /usr
#   * the ChromeOS home directory is bind-mounted at the identical path
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

SCRIPT_VERSION="2026-07-31.25-resume-safe-validation"
ALPINE_VERSION="3.24.1"
ALPINE_BRANCH="v3.24"
APK_COMPAT_BRANCH="v3.22"
CROSS_PREFIX="${CROSS_PREFIX:-/usr/local/cross}"
CROSS_ROOT="$CROSS_PREFIX/alpine"
CROSS_BIN="$CROSS_PREFIX/bin"
CROSS_CACHE="$CROSS_PREFIX/cache"
CROSS_MARKER="$CROSS_PREFIX/.alpine-cross-managed"
CROSS_COMPLETE="$CROSS_PREFIX/.alpine-cross-complete"
LOG_FILE="${HOME:-/home/chronos/user}/cross-setup-$(date +%Y%m%d-%H%M%S).log"

HOST_ARCH=""
ALPINE_ARCH=""
FETCH_TOOL=""
CHROOT_BIN=""
ROOTFS_MOUNTED=()

if command -v tee >/dev/null 2>&1; then
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  local status=$? i target
  for ((i=${#ROOTFS_MOUNTED[@]}-1; i>=0; i--)); do
    target="${ROOTFS_MOUNTED[$i]}"
    sudo umount -l "$target" >/dev/null 2>&1 || true
  done
  if (( status != 0 )); then
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

  opts="$(awk '$2 == "/usr/local" {print $4}' /proc/mounts | tail -n1)"
  [[ ",${opts}," != *,noexec,* ]] || die "/usr/local is mounted noexec"

  free_kib="$(df -Pk /usr/local | awk 'NR==2 {print $4}')"
  [[ "$free_kib" =~ ^[0-9]+$ ]] || free_kib=0
  (( free_kib >= 1200000 )) || die "at least 1.2 GiB free space under /usr/local is required"

  printf 'Architecture: %s\n' "$ALPINE_ARCH"
  printf 'Alpine:       %s\n' "$ALPINE_VERSION"
  printf 'Prefix:       %s\n' "$CROSS_PREFIX"
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

  sudo mkdir -p "$CROSS_PREFIX" "$CROSS_ROOT" "$CROSS_BIN" "$CROSS_CACHE"
  sudo chown "$(id -u):$(id -g)" "$CROSS_PREFIX" "$CROSS_BIN" "$CROSS_CACHE"
  printf '%s\n' "$SCRIPT_VERSION" > "$CROSS_MARKER"
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
    tar gzip bzip2 xz file patch git git-init-template curl openssh-client
    build-base linux-headers pkgconf cmake samurai meson autoconf automake libtool
    openssl-dev zlib-dev bzip2-dev xz-dev libffi-dev ncurses-dev readline-dev
    sqlite-dev libxml2-dev libxslt-dev libarchive-dev libssh2-dev libuv-dev
    rust cargo rustfmt rust-clippy rustup nodejs npm su-exec
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

  local uid gid group host_home
  uid="$(id -u)"
  gid="$(id -g)"
  host_home="${HOME:-/home/chronos/user}"

  # adduser expects the parent path to exist even though the real ChromeOS home
  # is bind-mounted over this directory by the launcher.
  sudo mkdir -p "$CROSS_ROOT$host_home"

  if sudo grep -q '^chronos:' "$CROSS_ROOT/etc/passwd"; then
    return 0
  fi

  group="$(sudo awk -F: -v gid="$gid" '$3 == gid {print $1; exit}' "$CROSS_ROOT/etc/group")"
  if [[ -z "$group" ]]; then
    sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/sbin/addgroup -g "$gid" chronos
    group="chronos"
  fi

  sudo "$CHROOT_BIN" "$CROSS_ROOT" /usr/sbin/adduser \
    -D -u "$uid" -G "$group" -h "$host_home" \
    -s /bin/bash chronos
}

write_launcher() {
  info "Writing cross launcher and command wrappers"

  cat > "$CROSS_BIN/cross" <<'LAUNCHER'
#!/bin/bash
set -Eeuo pipefail

ROOT="/usr/local/cross/alpine"
HOST_HOME="${HOME:-/home/chronos/user}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
if command -v chroot >/dev/null 2>&1; then
  CHROOT_BIN="$(command -v chroot)"
elif [[ -x /usr/sbin/chroot ]]; then
  CHROOT_BIN="/usr/sbin/chroot"
else
  echo "cross: chroot command is unavailable" >&2
  exit 1
fi

[[ -x "$ROOT/sbin/su-exec" ]] || {
  echo "cross: Alpine environment is incomplete; rerun cross.sh" >&2
  exit 1
}

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

ensure_apk_compat() {
  local execdir="$ROOT/lib/apk/exec"
  local probe="$execdir/.cross-exec-probe"
  local version

  [[ -x "$ROOT/sbin/apk.static" ]] || {
    echo "cross: Alpine apk-tools v2 compatibility runner is missing; rerun cross.sh" >&2
    exit 1
  }
  version="$(sudo "$CHROOT_BIN" "$ROOT" /sbin/apk.static --version 2>&1 | sed -n '1p')"
  case "$version" in
    apk-tools\ 2.*) ;;
    *) echo "cross: unexpected compatibility apk version: $version" >&2; exit 1 ;;
  esac

  sudo mkdir -p "$execdir"
  printf '%s\n' '#!/bin/sh' 'exit 0' | sudo tee "$probe" >/dev/null
  sudo chmod 0755 "$probe"
  if ! sudo "$CHROOT_BIN" "$ROOT" /lib/apk/exec/.cross-exec-probe >/dev/null 2>&1; then
    sudo rm -f "$probe"
    echo "cross: ChromeOS denies apk file-backed package scripts" >&2
    exit 1
  fi
  sudo rm -f "$probe"
}
ensure_chroot_exec() {
  local security_mnt="/sys/kernel/security"
  local policy_file="$security_mnt/chromiumos/inode_security_policies/allow_symlink"
  local mounted_here=0 remounted_rw=0 security_opts=""

  if sudo "$CHROOT_BIN" "$ROOT" /bin/busybox true >/dev/null 2>&1; then
    return 0
  fi

  sudo mkdir -p "$security_mnt"
  if ! awk -v target="$security_mnt" '$2 == target { found=1 } END { exit !found }' /proc/mounts; then
    sudo mount -t securityfs -o nodev,noexec,nosuid securityfs "$security_mnt" || {
      echo "cross: cannot mount ChromeOS securityfs" >&2
      exit 1
    }
    mounted_here=1
  fi

  security_opts="$(awk -v target="$security_mnt" '$2 == target { print $4; exit }' /proc/mounts)"
  if [[ ",${security_opts}," == *,ro,* ]]; then
    sudo mount -o remount,rw "$security_mnt" || {
      echo "cross: cannot remount ChromeOS securityfs read-write" >&2
      exit 1
    }
    remounted_rw=1
  fi

  [[ -e "$policy_file" ]] || {
    echo "cross: ChromeOS allow_symlink policy interface is unavailable" >&2
    exit 1
  }

  printf '%s' '/mnt/stateful_partition/dev_image' | sudo tee "$policy_file" >/dev/null
  if ! sudo "$CHROOT_BIN" "$ROOT" /bin/busybox true >/dev/null 2>&1; then
    printf '%s' '/mnt/stateful_partition' | sudo tee "$policy_file" >/dev/null
  fi

  if (( remounted_rw )); then
    sudo mount -o remount,ro "$security_mnt" >/dev/null 2>&1 || true
  fi
  if (( mounted_here )); then
    sudo umount "$security_mnt" >/dev/null 2>&1 || true
  fi

  sudo "$CHROOT_BIN" "$ROOT" /bin/busybox true >/dev/null 2>&1 || {
    echo "cross: ChromeOS still denies execution inside the Alpine rootfs" >&2
    exit 1
  }
}

sudo cp -f /etc/resolv.conf "$ROOT/etc/resolv.conf"
[[ -f /etc/hosts ]] && sudo cp -f /etc/hosts "$ROOT/etc/hosts" || true

mount_bind /dev "$ROOT/dev" 1
mount_proc "$ROOT/proc"
mount_bind /sys "$ROOT/sys" 1
[[ -d /run ]] && mount_bind /run "$ROOT/run" 1 || true
mount_bind "$HOST_HOME" "$ROOT$HOST_HOME" 0
ensure_chroot_exec
ensure_apk_compat

case "$PWD" in
  "$HOST_HOME"|"$HOST_HOME"/*) CROSS_CWD="$PWD" ;;
  *) CROSS_CWD="$HOST_HOME" ;;
esac

if (( $# == 0 )); then
  set -- /bin/bash -l
fi

exec sudo "$CHROOT_BIN" "$ROOT" /usr/bin/env -i \
  HOME="$HOST_HOME" \
  USER=chronos \
  LOGNAME=chronos \
  SHELL=/bin/bash \
  TERM="${TERM:-linux}" \
  LANG="${LANG:-C.UTF-8}" \
  LC_ALL="${LC_ALL:-}" \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
  GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt \
  RUSTUP_HOME="$HOST_HOME/.rustup" \
  CARGO_HOME="$HOST_HOME/.cargo" \
  /sbin/su-exec "$HOST_UID:$HOST_GID" \
  /bin/sh -c 'cd "$1"; shift; exec "$@"' sh "$CROSS_CWD" "$@"
LAUNCHER
  chmod 0755 "$CROSS_BIN/cross"

  local cmd
  for cmd in \
    apk bash sh git git-upload-pack git-receive-pack curl wget ssh scp \
    cc c++ gcc g++ cpp ar as ld nm objdump ranlib strip make cmake ninja meson \
    pkg-config autoconf autoheader automake aclocal libtoolize m4 \
    rustup rustc cargo rustfmt clippy-driver \
    node npm npx corepack python3; do
    cat > "$CROSS_BIN/$cmd" <<WRAPPER
#!/bin/sh
exec "$CROSS_BIN/cross" "$cmd" "\$@"
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

  touch "$bashrc" "$profile"
  if ! grep -Fq "$begin" "$bashrc"; then
    cat >> "$bashrc" <<'PROFILE'

# >>> cross-alpine >>>
export PATH="/usr/local/cross/bin:$PATH"
# <<< cross-alpine <<<
PROFILE
  fi
  if ! grep -Fq "$begin" "$profile"; then
    cat >> "$profile" <<'PROFILE'

# >>> cross-alpine >>>
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
# <<< cross-alpine <<<
PROFILE
  fi
}

validate() {
  info "Validating Alpine package environment"

  ensure_file_backed_package_scripts
  "$CROSS_BIN/cross" apk --version
  "$CROSS_BIN/cross" git --version
  # sed consumes the complete stream. Unlike head -n1, it does not close the
  # pipe early and turn a successful producer into SIGPIPE under pipefail.
  "$CROSS_BIN/cross" curl --version | sed -n '1p'
  "$CROSS_BIN/cross" gcc --version | sed -n '1p'
  "$CROSS_BIN/cross" make --version | sed -n '1p'
  "$CROSS_BIN/cross" rustup --version
  "$CROSS_BIN/cross" rustc --version
  "$CROSS_BIN/cross" cargo --version
  "$CROSS_BIN/cross" node --version
  "$CROSS_BIN/cross" npm --version

  local testdir
  testdir="${HOME:-/home/chronos/user}/.cross-smoke-test.$$"
  mkdir -p "$testdir"
  cat > "$testdir/hello.c" <<'C_SOURCE'
#include <stdio.h>
int main(void) { puts("cross-alpine-ok"); return 0; }
C_SOURCE
  "$CROSS_BIN/cross" /bin/sh -c "cd '$testdir' && cc hello.c -o hello && ./hello"
  rm -rf "$testdir"
}

main() {
  preflight
  reset_or_prepare_prefix
  download_and_extract_rootfs
  configure_rootfs
  install_alpine_packages
  configure_chronos_user
  write_launcher
  write_profile
  validate
  printf '%s\n' "$SCRIPT_VERSION" > "$CROSS_COMPLETE"

  info "Setup complete"
  cat <<SUMMARY

No source packages were built.
All installed system tools and libraries came from signed Alpine ${ALPINE_BRANCH}
main/community packages. Package transactions use Alpine apk-tools v2 static
from ${APK_COMPAT_BRANCH} because ChromeOS rejects apk-tools v3 memfd scripts.

Activate wrappers in the current shell:
  source ~/.bashrc

Examples:
  git --version
  cc --version
  node --version
  rustup --version
  cross                 # interactive Alpine-backed shell
  cross apk upgrade     # update all Alpine packages

Note: Alpine does not package nvm. Node.js and npm are supplied directly by apk.
Log: $LOG_FILE
SUMMARY
}

main "$@"
