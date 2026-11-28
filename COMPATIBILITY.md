# Compatibility scope

Cross supports ChromeOS Developer Mode on `x86_64` and `aarch64`, using the
ChromeOS `chronos` VT-2 account. Every supported release must pass installation,
reinstallation, rollback, reboot/manual-start, backup/restore, DNS-change, and
uninstall tests on both architectures before publication.

Cross shares the ChromeOS kernel. It does not promise systemd, kernel modules,
nested containers, FUSE, eBPF, GPU, audio, camera, USB, ADB, or arbitrary device
access. OpenRC is installed for conventional service scripts, but it is not PID
1. Long-running services must tolerate the whole chroot being stopped.

Network routes and listening ports use the host network namespace. A service
bound to non-loopback addresses may be reachable from the same networks as the
Chromebook. DNS follows host changes through a watcher. ChromeOS PAC settings,
enterprise trust stores, clipboard, notifications, SSH/GPG agent sockets, and
file associations other than `xdg-open` are not automatically bridged.

The Debian experimental glibc files provide a limited runtime aid, not ABI
compatibility for every GNU/Linux binary. Programs may require other Debian
libraries, a newer kernel, a different CPU baseline, NSS configuration, or
unsupported devices. Only programs covered by release tests should be described
as compatible.

ChromeOS release channels and kernels vary. A release without an accompanying
tested-device matrix is experimental.
