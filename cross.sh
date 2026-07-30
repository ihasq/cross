#!/bin/bash
# cross.sh - Minimal containerless development prefix for ChromeOS Developer Mode.
#
# No package manager, scripting-language bootstrap, chroot, container, or rootfs modification.
# Everything is installed below CROSS_PREFIX (default: /usr/local/cross), except
# small shell profile blocks added to the invoking user's ~/.bashrc/.bash_profile.
#
# Design:
#   * Zig supplies a self-contained Clang/LLD + musl target.
#   * C/C++ tools and the libraries built here are statically linked to musl.
#   * Git uses a static curl built with Mbed TLS (no OpenSSL/Perl bootstrap).
#   * rustup/Cargo and nvm/Node live below the same executable prefix because
#     ChromeOS user-data mounts may be noexec.
#
# Run from VT-2 as chronos (do not use sudo for the whole script):
#   bash ~/Downloads/cross.sh
#
# Optional settings:
#   CROSS_PREFIX=/usr/local/cross
#   CROSS_RUST_TOOLCHAIN=stable
#   CROSS_INSTALL_NODE=1       # 0 installs nvm but not Node
#   CROSS_NODE_VERSION=lts/*   # any selector accepted by nvm
#   CROSS_JOBS=4

set -Eeuo pipefail
umask 022

SCRIPT_VERSION="2026-07-30.9-mbedtls-direct-install"

CROSS_PREFIX="${CROSS_PREFIX:-/usr/local/cross}"
CROSS_RUST_TOOLCHAIN="${CROSS_RUST_TOOLCHAIN:-stable}"
CROSS_INSTALL_NODE="${CROSS_INSTALL_NODE:-1}"
CROSS_NODE_VERSION="${CROSS_NODE_VERSION:-lts/*}"
CROSS_JOBS="${CROSS_JOBS:-}"

ZIG_VERSION="0.16.0"
MAKE_VERSION="4.4.1"
BZIP2_VERSION="1.0.8"
PKGCONF_VERSION="2.4.3"
ZLIB_VERSION="1.3.2"
MBEDTLS_VERSION="3.6.7"
CURL_VERSION="8.21.0"
GIT_VERSION="2.55.0"
NVM_VERSION="v0.40.6"

# Published checksums for immutable upstream release archives.
MAKE_SHA256="dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3"
BZIP2_SHA256="ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269"
PKGCONF_SHA256="51203d99ed573fa7344bf07ca626f10c7cc094e0846ac4aa0023bd0c83c25a41"
ZLIB_SHA256="bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"
MBEDTLS_SHA256="a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6"
CURL_SHA256="d9b327997999045a24cda50f3983e69e51c516bd8be6ef9842fc7f99135e33bb"

BIN="$CROSS_PREFIX/bin"
LIB="$CROSS_PREFIX/lib"
INCLUDE="$CROSS_PREFIX/include"
OPT="$CROSS_PREFIX/opt"
ETC="$CROSS_PREFIX/etc"
STATE="$CROSS_PREFIX/var/db/cross"
CACHE="$CROSS_PREFIX/var/cache/cross"
BUILD_ROOT="$CROSS_PREFIX/var/tmp/cross-build.$$"
LOG_FILE="${HOME:-/home/chronos/user}/cross-setup-$(date +%Y%m%d-%H%M%S).log"

HOST_ARCH=""
ZIG_ARCH=""
ZIG_TARGET=""
RUST_HOST=""
ZIG_SHA256=""
CA_BUNDLE=""
BOOTSTRAP_FETCH=""

if command -v tee >/dev/null 2>&1; then
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  local status=$?
  rm -rf "$BUILD_ROOT" 2>/dev/null || true
  if (( status != 0 )); then
    printf '\nSetup failed. Log: %s\n' "$LOG_FILE" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'die "line ${LINENO}: command failed: ${BASH_COMMAND}"' ERR

have() { command -v "$1" >/dev/null 2>&1; }

sha256_file() {
  local file="$1"
  if have sha256sum; then
    sha256sum "$file" | awk '{print $1}'
  elif have openssl; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    die "sha256sum or openssl is required to verify downloads"
  fi
}

verify_sha256() {
  local file="$1" expected="$2" actual
  [[ -n "$expected" ]] || return 0
  actual="$(sha256_file "$file")"
  [[ "$actual" == "$expected" ]] || {
    rm -f "$file"
    die "SHA-256 mismatch for ${file##*/}: expected $expected, got $actual"
  }
}

fetch() {
  local url="$1" out="$2" expected="${3:-}"
  mkdir -p "$(dirname "$out")"
  if [[ -s "$out" ]]; then
    if [[ -z "$expected" ]] || [[ "$(sha256_file "$out")" == "$expected" ]]; then
      return 0
    fi
    rm -f "$out"
  fi

  info "Downloading ${out##*/}"
  if [[ -x "$BIN/curl" ]]; then
    env -u LD_LIBRARY_PATH "$BIN/curl" \
      --fail --location --show-error --silent --retry 5 --retry-delay 2 \
      --proto '=https' --tlsv1.2 --output "$out.part" "$url"
  elif [[ "$BOOTSTRAP_FETCH" == curl ]]; then
    env -u LD_LIBRARY_PATH curl \
      --fail --location --show-error --silent --retry 5 --retry-delay 2 \
      --proto '=https' --tlsv1.2 --output "$out.part" "$url"
  elif [[ "$BOOTSTRAP_FETCH" == wget ]]; then
    env -u LD_LIBRARY_PATH wget --https-only --tries=5 --output-document="$out.part" "$url"
  else
    die "curl or wget is required for the initial bootstrap"
  fi
  [[ -s "$out.part" ]] || die "empty download: $url"
  mv "$out.part" "$out"
  verify_sha256 "$out" "$expected"
}

extract_archive() {
  local archive="$1" dest="$2"
  rm -rf "$dest"
  mkdir -p "$dest"
  case "$archive" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$dest" ;;
    *.tar.xz)
      if tar -xJf "$archive" -C "$dest" 2>/dev/null; then :
      elif have xz; then xz -dc "$archive" | tar -xf - -C "$dest"
      else die "tar cannot unpack xz and no xz command is available"
      fi
      ;;
    *.tar.bz2)
      if [[ -x "$BIN/bzip2" ]]; then "$BIN/bzip2" -dc "$archive" | tar -xf - -C "$dest"
      else tar -xjf "$archive" -C "$dest"
      fi
      ;;
    *) die "unsupported archive format: $archive" ;;
  esac
}

first_source_dir() {
  find "$1" -mindepth 1 -maxdepth 1 -type d -print -quit
}

marker_file() { printf '%s/%s.version' "$STATE" "$1"; }
component_ready() {
  local name="$1" version="$2" proof="$3" marker
  marker="$(marker_file "$name")"
  [[ -e "$proof" && -f "$marker" && "$(cat "$marker")" == "$version" ]]
}
mark_done() { printf '%s\n' "$2" > "$(marker_file "$1")"; }

run_make() { "$BIN/make" -j"$CROSS_JOBS" "$@"; }

find_ca_bundle() {
  local f
  for f in \
    /etc/ssl/certs/ca-certificates.crt \
    /etc/ssl/cert.pem \
    /usr/share/chromeos-ca-certificates/roots.pem \
    /usr/share/chromeos-ca-certificates/ca-certificates.crt; do
    if [[ -s "$f" ]]; then
      CA_BUNDLE="$f"
      return 0
    fi
  done
  f="$(find /usr/share/chromeos-ca-certificates /etc/ssl -type f \( -name '*.pem' -o -name '*.crt' \) -size +20k -print -quit 2>/dev/null || true)"
  [[ -n "$f" ]] || die "could not find a ChromeOS CA certificate bundle"
  CA_BUNDLE="$f"
}

mount_options_for_usr_local() {
  if have findmnt; then
    findmnt -n -o OPTIONS /usr/local 2>/dev/null || true
  else
    awk '$2 == "/usr/local" { options=$4 } END { print options }' /proc/mounts 2>/dev/null
  fi
}

preflight() {
  info "Preflight checks"
  (( EUID != 0 )) || die "run as chronos, not as root; the script invokes sudo only to create the prefix"
  [[ -f /etc/lsb-release ]] || die "this does not look like the ChromeOS host"

  local user no_new_privs devsw opts free_kib
  user="$(id -un)"
  [[ "$user" == chronos ]] || warn "expected user 'chronos', got '$user'"

  no_new_privs="$(awk '/^NoNewPrivs:/ {print $2}' /proc/self/status 2>/dev/null || true)"
  [[ "$no_new_privs" != 1 ]] || die "NoNewPrivs is active; run from VT-2, not the browser crosh shell"

  if have crossystem; then
    devsw="$(crossystem devsw_boot 2>/dev/null || true)"
    [[ -z "$devsw" || "$devsw" == 1 ]] || die "Developer Mode was not detected (devsw_boot=$devsw)"
  fi

  case "$(uname -m)" in
    x86_64)
      HOST_ARCH=x86_64
      ZIG_ARCH=x86_64
      ZIG_TARGET=x86_64-linux-musl
      RUST_HOST=x86_64-unknown-linux-gnu
      ZIG_SHA256="70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00"
      ;;
    aarch64|arm64)
      HOST_ARCH=aarch64
      ZIG_ARCH=aarch64
      ZIG_TARGET=aarch64-linux-musl
      RUST_HOST=aarch64-unknown-linux-gnu
      ZIG_SHA256="ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17"
      ;;
    *) die "supported architectures are x86_64 and aarch64; got $(uname -m)" ;;
  esac

  if have curl; then BOOTSTRAP_FETCH=curl
  elif have wget; then BOOTSTRAP_FETCH=wget
  else die "ChromeOS curl or wget is required for the first download"
  fi

  have tar || die "tar is required"
  have sudo || die "sudo is required in VT-2"

  opts="$(mount_options_for_usr_local)"
  [[ -n "$opts" ]] || warn "could not inspect /usr/local mount options"
  [[ ",$opts," != *,noexec,* ]] || die "/usr/local is mounted noexec; Developer Mode dev_image mount is not active"

  case "$CROSS_PREFIX" in
    /usr/local/*) ;;
    *) die "CROSS_PREFIX must be below /usr/local so installed programs are executable on ChromeOS" ;;
  esac

  free_kib="$(df -Pk /usr/local 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ "$free_kib" =~ ^[0-9]+$ ]] && (( free_kib < 4 * 1024 * 1024 )); then
    die "at least roughly 4 GiB free under the stateful partition is required"
  fi

  find_ca_bundle
  printf 'Architecture: %s\nPrefix:       %s\nCA bundle:    %s\n' "$HOST_ARCH" "$CROSS_PREFIX" "$CA_BUNDLE"
}

prepare_prefix() {
  info "Preparing $CROSS_PREFIX"
  if [[ ! -d "$CROSS_PREFIX" ]]; then
    sudo mkdir -p "$CROSS_PREFIX"
  fi
  if [[ ! -w "$CROSS_PREFIX" ]]; then
    sudo chown -R "$(id -u):$(id -g)" "$CROSS_PREFIX"
  fi
  mkdir -p "$BIN" "$LIB" "$INCLUDE" "$OPT" "$ETC" "$STATE" "$CACHE" "$BUILD_ROOT"

  if [[ -z "$CROSS_JOBS" ]]; then
    CROSS_JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 2)"
  fi
  [[ "$CROSS_JOBS" =~ ^[1-9][0-9]*$ ]] || die "CROSS_JOBS must be a positive integer"
}

install_zig() {
  local name="zig-$ZIG_ARCH-linux-$ZIG_VERSION"
  local archive="$CACHE/$name.tar.xz"
  local install="$OPT/zig-$ZIG_VERSION"
  local work="$BUILD_ROOT/zig"
  local system_nm="" candidate

  if component_ready zig "$ZIG_VERSION-$HOST_ARCH" "$install/zig"; then
    info "Zig $ZIG_VERSION already installed"
  else
    fetch "https://ziglang.org/download/$ZIG_VERSION/$name.tar.xz" "$archive" "$ZIG_SHA256"
    extract_archive "$archive" "$work"
    rm -rf "$install"
    mv "$(first_source_dir "$work")" "$install"
    mark_done zig "$ZIG_VERSION-$HOST_ARCH"
  fi
  ln -sfn "$install/zig" "$BIN/zig"

  # Do not force -static in the compiler wrapper.  Autoconf performs many
  # feature/linker probes, and an unconditional -static changes or breaks some
  # of those probes.  Components that need a static final executable pass
  # -static through their own LDFLAGS instead.
  # Autoconf/libtool asks a GCC-compatible driver for its linker with
  # `-print-prog-name=ld`.  Zig normally reports the relative name `ld.lld`,
  # but the Zig archive does not install a standalone ld.lld executable in
  # PATH.  Return our absolute wrapper path so configure can validate it.
  cat > "$BIN/cc" <<WRAPPER
#!/bin/sh
case "\${1-}" in
  -print-prog-name=ld|--print-prog-name=ld)
    printf '%s\n' "$BIN/ld.lld"
    exit 0
    ;;
esac
exec "$BIN/zig" cc -target "$ZIG_TARGET" "\$@"
WRAPPER
  cat > "$BIN/c++" <<WRAPPER
#!/bin/sh
case "\${1-}" in
  -print-prog-name=ld|--print-prog-name=ld)
    printf '%s\n' "$BIN/ld.lld"
    exit 0
    ;;
esac
exec "$BIN/zig" c++ -target "$ZIG_TARGET" "\$@"
WRAPPER
  cat > "$BIN/ld.lld" <<WRAPPER
#!/bin/sh
exec "$BIN/zig" ld.lld "\$@"
WRAPPER
  cat > "$BIN/ar" <<WRAPPER
#!/bin/sh
exec "$BIN/zig" ar "\$@"
WRAPPER
  cat > "$BIN/ranlib" <<WRAPPER
#!/bin/sh
exec "$BIN/zig" ranlib "\$@"
WRAPPER
  cat > "$BIN/objcopy" <<WRAPPER
#!/bin/sh
exec "$BIN/zig" objcopy "\$@"
WRAPPER
  chmod 0755 \
    "$BIN/cc" "$BIN/c++" "$BIN/ld.lld" "$BIN/ar" \
    "$BIN/ranlib" "$BIN/objcopy"
  ln -sfn ld.lld "$BIN/ld"

  # Zig exposes ar/ranlib/objcopy/LLD, but Zig 0.16 does not expose an nm
  # frontend.  Some ChromeOS images also omit both nm and llvm-nm.  That is not
  # fatal for this static-only bootstrap: GNU make, bzip2, zlib, Mbed TLS, curl,
  # and Git perform their actual links with CC/AR/RANLIB.  Autoconf/Libtool may
  # still probe NM, so provide a successful no-output compatibility shim when
  # no real implementation exists.  This deliberately disables symbol-table
  # inspection rather than pretending to provide it.
  rm -f "$BIN/nm"
  for candidate in /usr/bin/llvm-nm /usr/bin/nm /bin/llvm-nm /bin/nm; do
    if [[ -x "$candidate" ]]; then
      system_nm="$candidate"
      break
    fi
  done
  if [[ -n "$system_nm" ]]; then
    ln -s "$system_nm" "$BIN/nm"
  else
    cat > "$BIN/nm" <<'WRAPPER'
#!/bin/sh
# cross.sh fallback for ChromeOS images without nm/llvm-nm.
# Static-only builds can proceed without symbol-table inspection.
case "${1-}" in
  --version|-V)
    printf '%s\n' 'cross.sh nm compatibility stub (no symbol output)'
    ;;
  --help|-h)
    printf '%s\n' 'nm unavailable on this ChromeOS image; this stub exits successfully without output.'
    ;;
esac
exit 0
WRAPPER
    chmod 0755 "$BIN/nm"
    warn "nm/llvm-nm is absent; using a no-output NM shim suitable for this static-only build"
  fi
  ln -sfn cc "$BIN/musl-cc"
  ln -sfn c++ "$BIN/musl-c++"

  export PATH="$BIN:$PATH"
  export CC="$BIN/cc" CXX="$BIN/c++" LD="$BIN/ld.lld"
  export AR="$BIN/ar" RANLIB="$BIN/ranlib" NM="$BIN/nm" OBJCOPY="$BIN/objcopy"

  # Fail here with the actual compiler output instead of later as a vague
  # Autoconf "C compiler cannot create executables" message.
  local probe_c="$BUILD_ROOT/zig-cc-probe.c" probe_bin="$BUILD_ROOT/zig-cc-probe"
  cat > "$probe_c" <<'C'
#include <stdio.h>
int main(void) { puts("zig cc probe OK"); return 0; }
C
  if ! "$CC" -O2 "$probe_c" -o "$probe_bin"; then
    "$BIN/zig" version >&2 || true
    die "Zig C compiler probe failed for target $ZIG_TARGET"
  fi
  if ! "$probe_bin" >/dev/null; then
    die "Zig produced a binary that this ChromeOS host cannot execute"
  fi

  # Verify the direct LLD frontend as well: GNU configure/libtool probes it
  # independently even though normal final links are performed by zig cc.
  if [[ "$("$CC" -print-prog-name=ld 2>/dev/null || true)" != "$LD" ]]; then
    die "Zig compiler driver did not report the expected linker: $LD"
  fi
  if ! "$LD" --version >/dev/null 2>&1; then
    die "Zig LLD frontend is unavailable through $LD"
  fi
}

install_make() {
  local archive="$CACHE/make-$MAKE_VERSION.tar.gz" work="$BUILD_ROOT/make" src
  if component_ready make "$MAKE_VERSION" "$BIN/make"; then
    info "GNU make $MAKE_VERSION already installed"
    return
  fi
  fetch "https://ftp.gnu.org/gnu/make/make-$MAKE_VERSION.tar.gz" "$archive" "$MAKE_SHA256"
  extract_archive "$archive" "$work"
  src="$(first_source_dir "$work")"
  info "Building GNU make $MAKE_VERSION"

  # Keep configure under an explicit shell and capture its diagnostics.
  # ChromeOS does not ship GNU make in this environment, so Automake cannot
  # bootstrap its dependency-tracking fragments during configure.  Dependency
  # tracking is unnecessary for this one-shot source build and is disabled.
  local cfg_out="$work/configure-output.log"
  if ! (
    cd "$src"
    CONFIG_SHELL=/bin/sh \
    CC="$CC" CXX="$CXX" LD="$LD" AR="$AR" RANLIB="$RANLIB" NM="$NM" \
    CFLAGS='-O2 -Wno-error' \
      sh ./configure \
        --prefix="$CROSS_PREFIX" \
        --disable-nls \
        --disable-dependency-tracking \
        --disable-shared \
        --enable-static
  ) >"$cfg_out" 2>&1; then
    warn "GNU make configure failed; diagnostic tail follows"
    tail -n 120 "$cfg_out" >&2 2>/dev/null || true
    if [[ -s "$src/config.log" ]]; then
      printf '\n--- config.log (last 160 lines) ---\n' >&2
      tail -n 160 "$src/config.log" >&2 || true
      cp "$src/config.log" "$STATE/make-config.log" 2>/dev/null || true
    fi
    die "GNU make configure failed (saved diagnostic: $STATE/make-config.log)"
  fi

  (
    cd "$src"
    CC="$CC" CFLAGS='-O2 -Wno-error' LDFLAGS='-static' sh ./build.sh

    # build.sh has already produced the complete standalone GNU make binary.
    # Do not run the generated top-level `make all`: that recurses into po/,
    # whose Makefile is intentionally absent when NLS is disabled in this
    # bootstrap-only environment.  Only the executable is needed downstream.
    /usr/bin/install -c -m 0755 ./make "$BIN/make"
    ln -sfn make "$BIN/gmake"

    "$BIN/make" --version >/dev/null
    probe_dir="$work/probe"
    mkdir -p "$probe_dir"
    printf 'all:\n\t@printf "make-probe-ok\\n"\n' >"$probe_dir/Makefile"
    [[ "$("$BIN/make" -s -C "$probe_dir")" == "make-probe-ok" ]]
  )
  mark_done make "$MAKE_VERSION"
}

install_bzip2() {
  local archive="$CACHE/bzip2-$BZIP2_VERSION.tar.gz" work="$BUILD_ROOT/bzip2" src
  if component_ready bzip2 "$BZIP2_VERSION" "$LIB/libbz2.a"; then
    info "bzip2 $BZIP2_VERSION already installed"
    return
  fi
  fetch "https://sourceware.org/pub/bzip2/bzip2-$BZIP2_VERSION.tar.gz" "$archive" "$BZIP2_SHA256"
  extract_archive "$archive" "$work"
  src="$(first_source_dir "$work")"
  info "Building bzip2 $BZIP2_VERSION"
  (
    cd "$src"
    # bzip2's default `all` target also runs its test suite, which requires
    # the external `cmp` utility.  Minimal ChromeOS images may not provide it.
    # Build only the artifacts required by the install target.
    run_make libbz2.a bzip2 bzip2recover \
      CC="$CC" AR="$AR" RANLIB="$RANLIB" \
      CFLAGS='-O2 -fPIC -Wall -Winline'
    "$BIN/make" PREFIX="$CROSS_PREFIX" \
      CC="$CC" AR="$AR" RANLIB="$RANLIB" \
      CFLAGS='-O2 -fPIC -Wall -Winline' install
  )
  mark_done bzip2 "$BZIP2_VERSION"
}

install_pkgconf() {
  local archive="$CACHE/pkgconf-$PKGCONF_VERSION.tar.xz" work="$BUILD_ROOT/pkgconf" src
  if component_ready pkgconf "$PKGCONF_VERSION" "$BIN/pkgconf"; then
    info "pkgconf $PKGCONF_VERSION already installed"
    return
  fi
  fetch "https://distfiles.ariadne.space/pkgconf/pkgconf-$PKGCONF_VERSION.tar.xz" "$archive" "$PKGCONF_SHA256"
  extract_archive "$archive" "$work"
  src="$(first_source_dir "$work")"
  info "Building pkgconf $PKGCONF_VERSION"
  (
    cd "$src"
    CC="$CC" CFLAGS='-O2' LDFLAGS='-static' ./configure \
      --prefix="$CROSS_PREFIX" --disable-shared --enable-static
    run_make
    "$BIN/make" install
  )
  ln -sfn pkgconf "$BIN/pkg-config"
  mark_done pkgconf "$PKGCONF_VERSION"
}

install_zlib() {
  local archive="$CACHE/zlib-$ZLIB_VERSION.tar.gz" work="$BUILD_ROOT/zlib" src
  if component_ready zlib "$ZLIB_VERSION" "$LIB/libz.a"; then
    info "zlib $ZLIB_VERSION already installed"
    return
  fi
  fetch "https://zlib.net/zlib-$ZLIB_VERSION.tar.gz" "$archive" "$ZLIB_SHA256"
  extract_archive "$archive" "$work"
  src="$(first_source_dir "$work")"
  info "Building zlib $ZLIB_VERSION"
  (
    cd "$src"
    CC="$CC" AR="$AR" RANLIB="$RANLIB" CFLAGS='-O2 -fPIC' \
      ./configure --prefix="$CROSS_PREFIX" --static
    run_make
    "$BIN/make" install
  )
  mark_done zlib "$ZLIB_VERSION"
}

install_mbedtls() {
  local base="mbedtls-$MBEDTLS_VERSION.tar.bz2"
  local archive="$CACHE/$base"
  local work="$BUILD_ROOT/mbedtls" src
  if component_ready mbedtls "$MBEDTLS_VERSION" "$LIB/libmbedtls.a"; then
    info "Mbed TLS $MBEDTLS_VERSION already installed"
    return
  fi
  # The release page publishes the archive checksum in its release notes.
  # A separate "-sha256sum.txt" asset is not guaranteed for every release.
  fetch "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$MBEDTLS_VERSION/$base"     "$archive" "$MBEDTLS_SHA256"
  extract_archive "$archive" "$work"
  src="$(first_source_dir "$work")"
  info "Building Mbed TLS $MBEDTLS_VERSION"
  (
    cd "$src"
    # The upstream top-level install target depends on no_test -> programs ->
    # mbedtls_test, which invokes Python.  Build only the three libraries and
    # install their public headers/archive files directly.
    run_make lib CC="$CC" AR="$AR" CFLAGS='-O2 -fPIC'

    mkdir -p "$LIB" "$INCLUDE" "$LIB/pkgconfig"
    rm -rf "$INCLUDE/mbedtls" "$INCLUDE/psa"
    cp -R include/mbedtls "$INCLUDE/"
    cp -R include/psa "$INCLUDE/"
    install -m 0644 \
      library/libmbedcrypto.a \
      library/libmbedx509.a \
      library/libmbedtls.a \
      "$LIB/"

    cat > "$LIB/pkgconfig/mbedcrypto.pc" <<EOF
prefix=$CROSS_PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: mbedcrypto
Description: Mbed TLS cryptography library
Version: $MBEDTLS_VERSION
Libs: -L\${libdir} -lmbedcrypto
Cflags: -I\${includedir}
EOF

    cat > "$LIB/pkgconfig/mbedx509.pc" <<EOF
prefix=$CROSS_PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: mbedx509
Description: Mbed TLS X.509 library
Version: $MBEDTLS_VERSION
Requires.private: mbedcrypto
Libs: -L\${libdir} -lmbedx509
Cflags: -I\${includedir}
EOF

    cat > "$LIB/pkgconfig/mbedtls.pc" <<EOF
prefix=$CROSS_PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: mbedtls
Description: Mbed TLS TLS library
Version: $MBEDTLS_VERSION
Requires.private: mbedx509 mbedcrypto
Libs: -L\${libdir} -lmbedtls
Cflags: -I\${includedir}
EOF
  )

  [[ -s "$LIB/libmbedtls.a" && -s "$LIB/libmbedx509.a" && -s "$LIB/libmbedcrypto.a" ]] || \
    die "Mbed TLS libraries were not installed"
  [[ -s "$INCLUDE/mbedtls/ssl.h" && -s "$INCLUDE/psa/crypto.h" ]] || \
    die "Mbed TLS public headers were not installed"
  mark_done mbedtls "$MBEDTLS_VERSION"
}

install_curl() {
  local archive="$CACHE/curl-$CURL_VERSION.tar.gz" work="$BUILD_ROOT/curl" src
  if component_ready curl "$CURL_VERSION" "$BIN/curl"; then
    info "curl $CURL_VERSION already installed"
    return
  fi
  fetch "https://curl.se/download/curl-$CURL_VERSION.tar.gz" "$archive" "$CURL_SHA256"
  extract_archive "$archive" "$work"
  src="$(first_source_dir "$work")"
  info "Building curl $CURL_VERSION"
  (
    cd "$src"
    PKG_CONFIG="$BIN/pkg-config" \
    PKG_CONFIG_PATH="$LIB/pkgconfig:$CROSS_PREFIX/share/pkgconfig" \
    CPPFLAGS="-I$INCLUDE" CFLAGS='-O2' LDFLAGS="-static -L$LIB" \
    LIBS='-lpthread' CC="$CC" \
      ./configure \
        --prefix="$CROSS_PREFIX" \
        --disable-shared --enable-static \
        --with-mbedtls="$CROSS_PREFIX" --with-zlib="$CROSS_PREFIX" \
        --with-ca-bundle="$CA_BUNDLE" \
        --without-libpsl --without-libidn2 --without-brotli --without-zstd \
        --without-libssh --without-libssh2 --without-librtmp --without-gssapi \
        --without-nghttp2 --without-ngtcp2 --without-nghttp3 --without-quiche \
        --disable-ldap --disable-ldaps --disable-rtsp --disable-dict \
        --disable-telnet --disable-tftp --disable-pop3 --disable-imap \
        --disable-smb --disable-smtp --disable-gopher --disable-mqtt \
        --disable-manual --disable-debug
    run_make
    "$BIN/make" install
  )
  mark_done curl "$CURL_VERSION"
  hash -r
}

install_git() {
  local archive="$CACHE/git-$GIT_VERSION.tar.xz" work="$BUILD_ROOT/git" src
  if component_ready git "$GIT_VERSION" "$BIN/git"; then
    info "Git $GIT_VERSION already installed"
    return
  fi
  # kernel.org publishes signed release material. This script downloads over
  # HTTPS; unlike the other fixed archives, Git's checksum is not hardcoded.
  fetch "https://www.kernel.org/pub/software/scm/git/git-$GIT_VERSION.tar.xz" "$archive"
  extract_archive "$archive" "$work"
  src="$(first_source_dir "$work")"
  info "Building Git $GIT_VERSION"
  (
    cd "$src"
    "$BIN/make" -j"$CROSS_JOBS" \
      prefix="$CROSS_PREFIX" \
      CC="$CC" AR="$AR" CURL_CONFIG="$BIN/curl-config" \
      CURL_CFLAGS="$("$BIN/curl-config" --cflags)" \
      CURL_LDFLAGS="$("$BIN/curl-config" --static-libs)" \
      CFLAGS="-O2 -I$INCLUDE" LDFLAGS="-static -L$LIB" \
      NO_OPENSSL=YesPlease NO_EXPAT=YesPlease NO_GETTEXT=YesPlease \
      NO_PERL=YesPlease NO_PYTHON=YesPlease NO_TCLTK=YesPlease \
      NO_ICONV=YesPlease NO_INSTALL_HARDLINKS=YesPlease \
      all
    "$BIN/make" \
      prefix="$CROSS_PREFIX" \
      CC="$CC" AR="$AR" CURL_CONFIG="$BIN/curl-config" \
      CURL_CFLAGS="$("$BIN/curl-config" --cflags)" \
      CURL_LDFLAGS="$("$BIN/curl-config" --static-libs)" \
      CFLAGS="-O2 -I$INCLUDE" LDFLAGS="-static -L$LIB" \
      NO_OPENSSL=YesPlease NO_EXPAT=YesPlease NO_GETTEXT=YesPlease \
      NO_PERL=YesPlease NO_PYTHON=YesPlease NO_TCLTK=YesPlease \
      NO_ICONV=YesPlease NO_INSTALL_HARDLINKS=YesPlease \
      install
  )
  mark_done git "$GIT_VERSION"
}

install_rustup() {
  local cargo_home="$OPT/cargo" rustup_home="$OPT/rustup"
  local init="$CACHE/rustup-init-$RUST_HOST" sum="$CACHE/rustup-init-$RUST_HOST.sha256"
  local expected
  if [[ -x "$cargo_home/bin/rustup" ]]; then
    info "rustup already installed"
  else
    fetch "https://static.rust-lang.org/rustup/dist/$RUST_HOST/rustup-init" "$init"
    fetch "https://static.rust-lang.org/rustup/dist/$RUST_HOST/rustup-init.sha256" "$sum"
    expected="$(awk '{print $1; exit}' "$sum")"
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "invalid rustup checksum sidecar"
    verify_sha256 "$init" "${expected,,}"
    chmod 0755 "$init"
    info "Installing rustup ($CROSS_RUST_TOOLCHAIN, minimal profile)"
    CARGO_HOME="$cargo_home" RUSTUP_HOME="$rustup_home" \
      "$init" -y --no-modify-path --profile minimal \
      --default-toolchain "$CROSS_RUST_TOOLCHAIN"
  fi

  export CARGO_HOME="$cargo_home" RUSTUP_HOME="$rustup_home"
  export PATH="$CARGO_HOME/bin:$BIN:$PATH"
  "$CARGO_HOME/bin/rustup" toolchain install "$CROSS_RUST_TOOLCHAIN" --profile minimal
  "$CARGO_HOME/bin/rustup" default "$CROSS_RUST_TOOLCHAIN"
  "$CARGO_HOME/bin/rustup" component add rustfmt clippy || warn "rustfmt/clippy are unavailable for this toolchain"
}

install_nvm() {
  local archive="$CACHE/nvm-$NVM_VERSION.tar.gz" work="$BUILD_ROOT/nvm" src nvm_dir="$OPT/nvm"
  if [[ -s "$nvm_dir/nvm.sh" && -f "$STATE/nvm.version" && "$(cat "$STATE/nvm.version")" == "$NVM_VERSION" ]]; then
    info "nvm $NVM_VERSION already installed"
  else
    fetch "https://github.com/nvm-sh/nvm/archive/refs/tags/$NVM_VERSION.tar.gz" "$archive"
    extract_archive "$archive" "$work"
    src="$(first_source_dir "$work")"
    rm -rf "$nvm_dir"
    mkdir -p "$nvm_dir"
    cp -a "$src"/. "$nvm_dir"/
    mark_done nvm "$NVM_VERSION"
  fi

  export NVM_DIR="$nvm_dir"
  set +u
  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh"
  set -u

  if [[ "$CROSS_INSTALL_NODE" == 1 ]]; then
    info "Installing Node.js via nvm: $CROSS_NODE_VERSION"
    set +u
    if [[ "$CROSS_NODE_VERSION" == 'lts/*' || "$CROSS_NODE_VERSION" == lts ]]; then
      nvm install --lts
      nvm alias default 'lts/*'
    else
      nvm install "$CROSS_NODE_VERSION"
      nvm alias default "$CROSS_NODE_VERSION"
    fi
    nvm use default
    set -u
  fi
}

write_profile() {
  local profile="$ETC/cross-env.sh" bashrc="$HOME/.bashrc" bash_profile="$HOME/.bash_profile"
  local begin='# >>> cross.sh minimal environment >>>' end='# <<< cross.sh minimal environment <<<' tmp

  cat > "$profile" <<PROFILE
# Generated by cross.sh
export CROSS_PREFIX="$CROSS_PREFIX"
export PATH="$OPT/cargo/bin:$BIN:\$PATH"
export CC="$BIN/cc"
export CXX="$BIN/c++"
export AR="$BIN/ar"
export RANLIB="$BIN/ranlib"
export NM="$BIN/nm"
export PKG_CONFIG="$BIN/pkg-config"
export PKG_CONFIG_PATH="$LIB/pkgconfig:$CROSS_PREFIX/share/pkgconfig"
export CARGO_HOME="$OPT/cargo"
export RUSTUP_HOME="$OPT/rustup"
export NVM_DIR="$OPT/nvm"
if [ -s "\$NVM_DIR/nvm.sh" ]; then
  case \$- in *u*) _cross_had_nounset=1; set +u ;; *) _cross_had_nounset=0 ;; esac
  . "\$NVM_DIR/nvm.sh"
  [ "\$_cross_had_nounset" = 1 ] && set -u
  unset _cross_had_nounset
fi
PROFILE
  chmod 0644 "$profile"

  touch "$bashrc"
  tmp="$BUILD_ROOT/bashrc"
  awk -v b="$begin" -v e="$end" '
    $0 == b {skip=1; next}
    $0 == e {skip=0; next}
    !skip {print}
  ' "$bashrc" > "$tmp"
  cat >> "$tmp" <<PROFILE

$begin
[ -r "$profile" ] && . "$profile"
$end
PROFILE
  cp -p "$bashrc" "$bashrc.cross-backup" 2>/dev/null || true
  cat "$tmp" > "$bashrc"

  touch "$bash_profile"
  if ! grep -Eq '(^|[[:space:]])(source|\.)[[:space:]]+.*\.bashrc' "$bash_profile"; then
    cat >> "$bash_profile" <<'PROFILE'

# Added by cross.sh
[ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
PROFILE
  fi
}

self_test() {
  local testdir="$BUILD_ROOT/self-test"
  mkdir -p "$testdir"
  info "Running smoke tests"

  cat > "$testdir/hello.c" <<'C'
#include <stdio.h>
#include <zlib.h>
int main(void) {
  printf("musl C toolchain OK; zlib %s\n", zlibVersion());
  return 0;
}
C
  "$CC" -static -I"$INCLUDE" "$testdir/hello.c" "$LIB/libz.a" -o "$testdir/hello"
  "$testdir/hello"

  "$BIN/curl" --version | head -n2
  "$BIN/git" --version
  "$OPT/cargo/bin/rustc" --version
  "$OPT/cargo/bin/cargo" --version

  export NVM_DIR="$OPT/nvm"
  set +u
  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh"
  nvm --version
  if [[ "$CROSS_INSTALL_NODE" == 1 ]]; then
    node --version
    npm --version
    node -e 'console.log("Node.js OK")'
  fi
  set -u
}

main() {
  info "cross.sh $SCRIPT_VERSION"
  preflight
  prepare_prefix
  install_zig
  install_make
  install_bzip2
  install_pkgconf
  install_zlib
  install_mbedtls
  install_curl
  install_git
  install_rustup
  install_nvm
  write_profile
  self_test

  info "Done"
  cat <<RESULT
Installed prefix: $CROSS_PREFIX
Log:              $LOG_FILE

Activate it in the current shell with:
  source "$ETC/cross-env.sh"

No ChromeOS rootfs files were replaced. C/C++ output from cc/c++ is static musl;
Rust and Node host tools use the ChromeOS host ABI and are kept under /usr/local
so they remain executable even when the user-data mount is noexec.
RESULT
}

main "$@"
