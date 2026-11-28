#!/bin/bash
set -Eeuo pipefail

unset CDPATH
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
script="$repo/cross.sh"
readme="$repo/README.md"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
must_have() { grep -Fq -- "$1" "$2" || fail "$2 lacks: $1"; }
must_not_have() { ! grep -Fq -- "$1" "$2" || fail "$2 contains forbidden text: $1"; }

bash -n "$script"
(cd "$repo" && sha256sum -c SHA256SUMS)

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
for marker in SERVICE CLIENT XDG_OPEN BOOT_HELPER; do
  awk -v token="<<'$marker'" -v end="$marker" '
    index($0, token) { emit=1; next }
    emit && $0 == end { exit }
    emit { print }
  ' "$script" > "$tmp/$marker.sh"
  [[ -s "$tmp/$marker.sh" ]] || fail "could not extract generated $marker script"
  bash -n "$tmp/$marker.sh"
done

must_have 'ALPINE_MINIROOTFS_SHA256_X86_64=' "$script"
must_have 'ALPINE_MINIROOTFS_SHA256_AARCH64=' "$script"
must_have 'debian-archive-keyring' "$script"
must_have '/usr/bin/gpgv' "$script"
must_have 'APK_COMPAT_CHROOT="/usr/local/libexec/cross-apk2"' "$script"
must_have 'TRANSACTION_DIR="${CROSS_PREFIX}.rollback-' "$script"
must_have 'begin_transaction' "$script"
must_have 'rollback_transaction' "$script"
must_have 'backup_service' "$script"
must_have 'restore_service' "$script"
must_have 'uninstall_service' "$script"
must_have 'acquire_operation_lock' "$script"
must_not_have '--remove_rootfs_verification' "$script"
must_not_have 'apk_chroot() { sudo "$CHROOT_BIN" "$CROSS_ROOT" /sbin/apk.static' "$script"
must_not_have 'curl https://cross-sh.pages.dev/cross.sh | bash' "$readme"

for file in LICENSE SECURITY.md COMPATIBILITY.md THIRD_PARTY.md CHANGELOG.md; do
  [[ -s "$repo/$file" ]] || fail "missing $file"
done
[[ -x "$repo/scripts/generate-sbom.sh" ]] || fail 'SBOM generator is missing or not executable'
[[ -s "$repo/.github/workflows/release.yml" ]] || fail 'signed release workflow is missing'

printf 'static checks: OK\n'
