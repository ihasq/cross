# Changelog

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
