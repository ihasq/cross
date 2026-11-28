# Cross

Cross is a privileged Alpine Linux CLI development environment for ChromeOS
Developer Mode. It uses a chroot reached through a localhost-only OpenSSH
service. It is not a container, virtual machine, mount namespace, or security
boundary.

The ChromeOS home directory appears at the same path inside Alpine, so projects
can be edited on ChromeOS and built with Alpine tools without copying them.

## Security model

Cross shares the ChromeOS kernel, PID namespace, network namespace and selected
host kernel interfaces. The `chronos` account has passwordless root inside the
chroot. Root inside Cross can therefore have host-root-equivalent impact. Do not
run untrusted privileged code.

Cross does not disable ChromeOS rootfs verification. On a stock verified image,
the service must usually be started from VT-2 after each reboot. An Upstart job
is installed only when `/etc/init` is already writable.

Read [SECURITY.md](SECURITY.md) and [COMPATIBILITY.md](COMPATIBILITY.md) before
installation.

## Requirements

- ChromeOS Developer Mode and VT-2 access as `chronos`
- `x86_64` or `aarch64`
- Host `sudo`, `tar`, OpenSSH, and curl or wget
- At least 2.4 GiB free on the filesystem containing `/usr/local/cross`
- Network access to the Alpine and Debian repositories

Cross currently supports one `chronos` environment per installation. It does
not support other ChromeOS users or multiple simultaneous rootfs versions.

## Verified installation

Download the installer and its release checksum as separate files. Do not pipe
an unverified network response into a shell.

```bash
cd ~/Downloads
curl --fail --location --proto '=https' --tlsv1.2 \
  -o cross.sh https://cross-sh.pages.dev/cross.sh
curl --fail --location --proto '=https' --tlsv1.2 \
  -o SHA256SUMS https://cross-sh.pages.dev/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
bash cross.sh
```

The checksum must also be published through a trusted release channel. A hash
downloaded only from the same potentially compromised origin is not an
independent authenticity proof. Tagged repository releases attach GitHub OIDC
build provenance; when GitHub CLI is available, verify the downloaded installer
with `gh attestation verify cross.sh --repo <owner>/<repository>`.

The installer displays an EULA and must run interactively from VT-2, not as
root, from browser Crosh, or from inside Cross.

After setup, reload the shell integration:

```bash
source ~/.bashrc
cross
```

If autostart is unavailable after reboot, start Cross from VT-2:

```bash
/usr/local/cross/bin/cross start
```

## Installed environment

Cross installs Alpine 3.24 packages with apk signature verification, including:

- Bash, Git, curl, OpenSSH, Nano, Vim, FFmpeg and GNU CLI utilities
- Alpine SDK, GCC, binutils, CMake, Meson, Samurai and Autotools
- Rust, Cargo, rustup, rustfmt and Clippy
- Node.js, npm and npx
- OpenRC scripts, timezone data and log rotation tools
- Common development headers and libraries
- A limited Debian experimental glibc runtime aid
- An `xdg-open` bridge to the ChromeOS URL handler

The Alpine minirootfs SHA-256 digest is pinned in the reviewed installer.
Debian `Packages.xz` is checked against a cryptographically verified
`InRelease`, using the Debian archive keyring delivered as a signed Alpine
package. Debian package payload hashes are then verified before extraction.

The side-loaded glibc runtime is not a claim that every glibc-linked binary is
compatible. See [COMPATIBILITY.md](COMPATIBILITY.md).

## Usage

Start a login shell or run one command:

```bash
cross
cross git --version
cross cargo build
cross npm test
```

The shell profile also exposes wrappers for Git and SSH tools, GCC/binutils,
Make, CMake, Meson, Autotools, Rust, Node.js, Python and `xdg-open`. Host `bash`,
`sh`, `curl` and `wget` are not replaced. To bypass a service-command name, use
`cross -- <command>`.

The wrapper layer can be bypassed with an explicit host path such as
`/usr/bin/git`. Remove the marked `cross-alpine` block from `.bashrc` to disable
all wrappers without uninstalling the environment.

### Package management

```bash
cross sudo apk update
cross sudo apk add <package>
cross sudo apk upgrade
```

Cross uses an apk-tools v2 static compatibility runner because affected
ChromeOS kernels reject apk-tools v3 package-script execution. This cross-
branch compatibility mechanism is covered by the release support matrix; it is
not an upstream Alpine guarantee.

### OpenRC services

OpenRC is installed, although it is not PID 1. Compatible services can be
managed explicitly:

```bash
cross sudo rc-service <name> start
cross sudo rc-service <name> stop
```

Stopping Cross terminates every process whose root is the chroot. Services must
not assume systemd, a private PID namespace, or graceful machine shutdown.

### Host integration

`xdg-open` sends a URL or file URL to ChromeOS:

```bash
xdg-open https://example.com
xdg-open "$HOME/Documents/example.pdf"
```

The host system D-Bus socket is exposed with read-only mount flags. Those flags
do not restrict D-Bus methods; normal ChromeOS per-user bus policy remains the
authorization boundary.

`LANG`, `LC_*`, `TZ` and common HTTP proxy variables are forwarded through SSH.
Timezone files are copied during setup. SSH/GPG agent sockets, enterprise CA
stores, PAC settings, clipboard and notifications are not bridged.

DNS is copied from ChromeOS at startup and watched for changes while the service
runs. Routes, VPN interfaces and listening ports use the host network namespace.
Do not bind a development server to a non-loopback address unless LAN exposure
is intended.

## Lifecycle management

Run state-changing service commands from VT-2. They are serialized by an
operation lock.

```bash
cross status
cross start
cross stop
cross restart
cross doctor
cross log 120
cross disk
cross prune
```

`doctor` checks executable HOME mounts, symlinks, SSH keys, effective sshd
settings and authentication. `disk` reports storage consumption. `prune`
removes old downloads and caps oversized logs.

### Updating

Download and verify the new installer exactly as for first installation, then
run it from VT-2. Before mutating a complete installation, setup creates a
rollback snapshot of the rootfs and Cross configuration. Package and patch
upgrades within the supported Alpine branch are performed in place. A branch
migration requires an explicitly implemented migration and otherwise stops
without changing the rootfs. If setup or validation fails, the old
snapshot is restored and the previously running service is restarted.

The installer never deletes a usable rootfs because its patch version differs.
An incomplete rootfs is moved under `/usr/local/cross/recovery` rather than
deleted.

### Backup and restore

Backups contain the localhost SSH private key and are created mode 0600, with a
mandatory `.sha256` sidecar checked before restore.

```bash
cross backup "$HOME/Downloads/cross-backup.tar.gz"
cross restore "$HOME/Downloads/cross-backup.tar.gz"
```

Backup stops the chroot to obtain a consistent archive and restores the prior
running state. Restore rejects absolute paths and traversal entries, validates
Cross markers in a staging directory, atomically switches installations, and
retains the replaced installation beside `/usr/local/cross` for recovery.

### Uninstall

```bash
cross uninstall --yes
```

Uninstall stops the service, removes a Cross-managed Upstart job and shell
profile blocks, then moves the installation to a timestamped
`/usr/local/cross.uninstalled-*` directory. This is deliberately recoverable;
delete that directory after preserving any needed data.

Current Cross releases never disable verified boot. If an older release did,
use official ChromeOS recovery to restore a verified system image; deleting a
file from `/usr/local` cannot restore the verified root filesystem.

## Working directories and data

Commands started below the ChromeOS home retain the same working directory.
Commands started elsewhere use HOME. An additional writable area is available
at `/usr/local/cross/work/chronos`.

Data stored only under the Alpine rootfs is not part of the ChromeOS home
backup. Use `cross backup` before recovery, Powerwash, channel changes or other
operations that may erase the stateful partition.

## Architecture

```text
Crosh command
  -> ChromeOS host SSH client
  -> 127.0.0.1:32222
  -> VT-2-started sshd
  -> forced Cross session
  -> privileged Alpine chroot
```

sshd accepts only the generated key, binds IPv4 loopback, pins its host key and
disables forwarding, tunnels, user rc files and password authentication. These
restrictions protect the transport; they do not turn the chroot into a sandbox.

## Installation layout

| Path | Purpose |
| --- | --- |
| `/usr/local/cross/alpine` | Alpine root filesystem |
| `/usr/local/cross/bin` | CLI and host wrappers |
| `/usr/local/cross/cache` | Verified download cache |
| `/usr/local/cross/etc` | Root-owned Cross and SSH configuration |
| `/usr/local/cross/log` | Service, boot and DNS watcher logs |
| `/usr/local/cross/run` | Runtime locks and client state |
| `/usr/local/cross/work/chronos` | Additional writable work area |
| `/usr/local/cross/recovery` | Incomplete rootfs retained for recovery |

## Release policy

CI runs syntax, policy and ShellCheck validation. A publishable release also
requires the real-device matrix described in [COMPATIBILITY.md](COMPATIBILITY.md),
a generated `SHA256SUMS`, package inventory, license inventory and a reviewed
[CHANGELOG.md](CHANGELOG.md). Source licensing is in [LICENSE](LICENSE), with
third-party information in [THIRD_PARTY.md](THIRD_PARTY.md). An installed-package
SPDX inventory can be generated with `scripts/generate-sbom.sh`.
