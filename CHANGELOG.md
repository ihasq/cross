# Changelog

## 2026-11-28.75

- Moved the apk-tools v2 compatibility runner to the package-manager-independent
  `/usr/local/libexec/cross-apk2` path and remove the temporary static package
  before upgrades, preventing apk v3 from replacing the runner.
- Repair `pinentry` and OpenRC package scripts after upgrading an installation
  affected by the former runner replacement bug.
- Store rollback snapshots beside the Cross prefix, validate them before any
  mutation, and retain failed update trees while atomically restoring the old
  root, binaries, and configuration.
- Detect and restore complete prefix-internal rollback snapshots left by the
  failed 2026-11-28.74 updater before attempting another update.

## 2026-11-28

- Made Alpine updates in-place and added pre-update rollback snapshots.
- Added operation locks, backup, restore, recoverable uninstall, disk reporting,
  cache pruning, DNS-change monitoring, timezone setup, and OpenRC compatibility.
- Pinned Alpine 3.24.4 minirootfs hashes for x86_64 and aarch64.
- Added Debian `InRelease` signature verification before glibc extraction.
- Stopped changing ChromeOS verified-boot settings.
- Added CI policy checks and security, compatibility, licensing, and lifecycle
  documentation.
- Added tag-triggered OIDC provenance attestations, a release checksum manifest,
  a real-device test matrix, and an installed-package SPDX generator.
