# Cross

Cross provides an Alpine Linux development environment on a ChromeOS device in
Developer Mode. It uses a chroot and a localhost-only OpenSSH service instead
of a container, virtual machine, or mount namespace.

The ChromeOS home directory is available at the same path inside Alpine, so
projects can be edited from ChromeOS and built with Alpine tools without being
copied between environments.

## Quickstart

After enabling ChromeOS Developer Mode, open VT-2, sign in as `chronos`, and
run the installer:

```bash
curl https://cross-sh.pages.dev/cross.sh | bash
```

Open Crosh again (or run `source ~/.bashrc`), then enter the Alpine environment:

```bash
cross
```

See [Requirements](#requirements) and [Installation](#installation) before
installing for the security implications and complete setup instructions.

## What Cross installs

Cross bootstraps an Alpine minirootfs with SHA-256 verification and installs
signed development packages from the official Alpine repositories. The default
environment includes:

- Bash, Git, curl, OpenSSH, Nano, Vim, FFmpeg, and standard GNU command-line
  utilities
- GCC, binutils, musl headers, CMake, Meson, Samurai, Autoconf, Automake, and
  Libtool
- Rust, Cargo, rustup, rustfmt, and Clippy
- Node.js, npm, and npx
- Common development libraries such as OpenSSL, zlib, SQLite, libffi, libxml2,
  libxslt, libarchive, libssh2, and libuv
- Cross Desktop, an Xpra-backed X11-to-canvas layer with VLC, browser audio,
  clipboard synchronization, file drag-and-drop, and PWA metadata

Cross does not build third-party tools from source. It builds only a small
musl compatibility DSO needed by glibc-linked `workerd` binaries used by some
npm packages.

## Requirements

- A ChromeOS device in Developer Mode
- An `x86_64` or `aarch64` processor
- Access to VT-2 as the `chronos` user
- `sudo`, `tar`, OpenSSH, and either curl or wget on the ChromeOS host
- At least 1.2 GiB free under `/usr/local`
- An internet connection to the Alpine package repositories

Disabling hardware write protection is not necessary. Boot autostart does,
however, require a writable `/etc/init`. On stock ChromeOS release images the
installer uses the official ChromeOS developer tool to disable rootfs
verification, then asks you to reboot and run the installer a second time to
add autostart. The initial Cross setup still completes before that reboot.
Disabling rootfs verification weakens verified boot, can affect OS updates, and
may require recovery media to restore the device. If autostart cannot be safely
configured, the installer warns and completes the remaining setup normally.

## Installation

### 1. Enable ChromeOS Developer Mode

Developer Mode reduces ChromeOS security and may erase local data when it is
enabled or disabled. Back up important files first and follow the instructions
for your device.

### 2. Run the installer from VT-2

Enter VT-2, sign in as `chronos`, and run:

```bash
curl https://cross-sh.pages.dev/cross.sh | bash
```

Review and accept the displayed EULA to continue. Run the installer as
`chronos`, not as root and not inside Crosh. The installer uses `sudo` only for
the operations that require it.

If `/etc/init` is read-only, the first run disables rootfs verification but
continues installing Cross without autostart. Reboot when convenient, return to
VT-2, and run the same command again to install and verify the boot job. If the
required ChromeOS facilities are absent or reject the change, setup likewise
continues without autostart instead of failing.

The setup run downloads Alpine packages with up to six concurrent downloads
and shows a per-package progress indicator, installs the toolchains, creates
SSH keys, starts the local service, and runs a smoke test. A setup log is
written to:

```text
~/cross-setup-YYYYMMDD-HHMMSS.log
```

### 3. Reload the shell environment

Open Crosh again, or reload the existing shell profile:

```bash
source ~/.bashrc
```

Then enter the Alpine shell:

```bash
cross
```

The prompt changes to `cross@localhost` while the interactive Alpine shell is
active. Use `exit` to return to the ChromeOS host shell.

## Usage

Start an interactive shell:

```bash
cross
```

Run one Alpine command without entering a shell:

```bash
cross git --version
cross cargo build
cross npm test
```

Cross also installs host-side wrappers for commonly used development commands.
After reloading `~/.bashrc`, these commands are forwarded to Alpine:

```bash
git status
cc hello.c -o hello
cargo run
npm install
```

The wrappers include Git and SSH tools, the GCC/binutils toolchain, Make,
CMake, Meson, Autotools, Rust tools, and Node.js tools. `bash`, `sh`, `curl`,
and `wget` intentionally remain the ChromeOS host commands so the installer can
be updated even when the Cross service is stopped.

### Open URLs and files

The Crosh-side `open` command uses ChromeOS's system D-Bus URL handler for web
URLs and Cross Desktop for local files and directories:

```bash
open https://example.com
open ~/Downloads/movie.mp4
open ~/Downloads/photo.jpg
open .
open -a mousepad README.md
```

HTTP, HTTPS, and `mailto:` targets open in ChromeOS Chrome. Audio, video,
images, text, documents, and directories open respectively in VLC, Ristretto,
Mousepad, MuPDF, or PCManFM on the browser canvas. `open -a APPLICATION`
selects an Alpine GUI command explicitly. Running `open` without arguments
starts Cross Desktop and opens its canvas.

Inside Cross, `xdg-open` sends its single link directly to ChromeOS's system
D-Bus URL handler:

```bash
xdg-open https://example.com
xdg-open 'my-app://open/item/42'
```

The bridge does not restrict URL schemes, so ChromeOS can dispatch custom
application links as well as web links. The same command is also installed as
a Crosh-side wrapper after reloading `~/.bashrc`.

### GUI applications

Run GUI applications directly from Crosh. The command starts the application
in its browser canvas and opens the corresponding Chrome page:

```bash
vlc ~/Downloads/movie.mp4
gimp ~/Downloads/image.png
```

The `cross_desktop` command is also available for explicit application launches
and session management:

```bash
cross_desktop
cross_desktop vlc ~/Downloads/movie.mp4
cross_desktop gimp ~/Downloads/image.png
```

Each application keeps its own stable random UUID and dedicated Xpra session.
All sessions are routed through the loopback-only port:

```text
http://cross-{uuid}.localhost:32221
```

The command prints the application's concrete URL and asks ChromeOS to open it
through the `org.chromium.UrlHandlerService` system D-Bus service. Crosh-side
launches send the request from the host, while the Cross Desktop launcher can
use the exposed bus socket for launches made from an interactive Cross shell:

```bash
cross
cross_desktop mousepad README.md
```

Set `CROSS_DESKTOP_OPEN=0` to print the URL without opening a browser. The canvas
fills the whole page with one application's main window; dialogs remain layered
over that window. Each origin exposes a separate webmanifest using the
application's name and icon, so VLC, Mousepad, XTerm and other applications can
be installed as distinct Chrome PWAs. UUID assignments persist across restarts.
Cross also restores each registered application's most recent launch command
when its service restarts, keeping installed PWA origins usable after reboot.

Run VLC with or without a file from the shared ChromeOS home directory:

```bash
vlc
vlc ~/Downloads/movie.mp4
```

Run GIMP 3 in its own application-branded PWA. GIMP uses its default
single-window interface and Cross suppresses the startup splash and first-run
welcome dialog so the editor becomes the page window directly:

```bash
gimp
gimp ~/Downloads/image.png
open -a gimp ~/Downloads/image.png
```

GIMP receives the shared ChromeOS path directly. Its UUID, configuration,
recent launch and PWA icon persist like the other Cross applications.

Other Alpine GUI applications can be started through `open` or the namespaced
desktop control:

```bash
open -a xterm
cross desktop run my-gui-program --flag
cross_desktop -- my-gui-program --flag
```

Desktop session controls are:

```bash
cross desktop status
cross desktop stop
cross desktop restart
cross desktop log
cross desktop url
```

The equivalent `cross_desktop status|stop|restart|log|url` forms are supported.

Dragging files from ChromeOS onto an application page uploads them to that
application's Alpine session and passes the files to the application. Clipboard
exchange is enabled in both directions, subject to Chrome's clipboard
permission and user-gesture rules.

When a canvas first opens, click it or press a key once. Cross uses that browser
gesture to focus the application's X11 window, enable keyboard capture, and
unlock Chrome audio playback. The hint disappears after activation. Cross also
backports Xpra's legacy HTML5 keymap initialization needed by Alpine 3.24's
Xpra 6.4 server. The Xpra and ChromeOS software keyboards remain closed unless
the user explicitly requests one.

### Working directories

When a command is launched from the ChromeOS home directory, Cross uses the
same path inside Alpine. This allows commands such as `cargo run` and `npm test`
to operate directly on the current project.

Commands launched outside the home directory or Cross work directory start in
the home directory instead. An additional writable work area is available at:

```text
/usr/local/cross/work/chronos
```

### Package management

Use Alpine's package manager through `sudo` inside Cross:

```bash
cross sudo apk update
cross sudo apk add <package>
cross sudo apk upgrade
```

Cross uses the Alpine `apk-tools` v2 static compatibility runner because some
ChromeOS kernels reject the file-descriptor execution mechanism used by
`apk-tools` v3 package scripts.

## How it works

The command path is:

```text
Crosh command
  -> ChromeOS host SSH client
  -> 127.0.0.1:32222
  -> VT-2-started sshd
  -> forced Cross session
  -> Alpine chroot
```

The optional GUI path is:

```text
Chrome/PWA at cross-{uuid}.localhost:32221
  -> localhost-only UUID router
  -> per-application Xpra HTTP/WebSocket backend
  -> dedicated virtual X11 display
  -> one Alpine GUI application (for example VLC)
```

Xpra sends window updates to browser canvases and negotiates native browser
video decoding where available. A private PulseAudio null sink and an explicit
GStreamer PulseAudio capture source provide speaker audio to the browser; the
VLC launcher is pinned to its PulseAudio output. Cross restarts a
browser-blocked stream on the next canvas gesture. Cross forces common
Wayland-capable toolkits onto their X11 backend for this virtual display
(`QT_QPA_PLATFORM=xcb`, `GDK_BACKEND=x11`), so the layer does not depend on the
ChromeOS display server.

At runtime Cross bind-mounts only ChromeOS's
`/run/dbus/system_bus_socket` into Alpine's otherwise private `/run`. An
explicit GUI launch or `xdg-open URL` uses it to call
`org.chromium.UrlHandlerService.OpenUrl`; background session restoration does
not open browser pages.

The SSH daemon listens only on `127.0.0.1` and accepts the dedicated key created
by the installer. Arbitrary SSH forwarding is disabled. The forced session
selects the requested Alpine tool and preserves only supported working
directories.

Cross is a chroot, not a security boundary. Processes inside the environment
run with the ChromeOS user's access to the exposed system D-Bus socket, and
processes with root access can affect the mounted host home directory and the
Cross installation.

## Service management

Run service-management commands from VT-2:

```bash
cross status
cross start
cross stop
cross restart
cross doctor
cross log
```

These are built into the `cross` command. To run an Alpine command whose name
matches a service subcommand, put `--` before it, for example `cross -- start`.
The former `cross-service` command remains available for compatibility.

`doctor` checks the HOME bind mount, executable and symlink behavior, SSH key
permissions, effective sshd settings, and public-key authentication.

The installer starts the service immediately. When supported, it also installs
a ChromeOS Upstart job at `/etc/init/cross-service.conf`. At each boot, the job
waits until the encrypted user home is available (normally after login), then
runs the service controller used by `cross start`. Startup attempts and errors
are recorded in `/usr/local/cross/log/boot.log`. If the job cannot be installed,
setup completes and reports that the service must be started manually after
reboot.

Starting or stopping the service from browser Crosh is intentionally rejected
because Crosh normally runs with restrictions that prevent the required mount
and chroot operations.

## Updating Cross

Rerun the installer from VT-2. Updates are performed in place and preserve the
existing Alpine installation where possible:

```bash
curl https://cross-sh.pages.dev/cross.sh | bash
```

If Cross was installed by an older release that added `bash` or `curl` wrappers,
use the host binaries explicitly for the first update:

```bash
/usr/bin/curl https://cross-sh.pages.dev/cross.sh | /bin/bash
```

To update Alpine packages independently of Cross itself:

```bash
cross sudo apk update
cross sudo apk upgrade
```

## Security considerations

Read the EULA shown by the installer before accepting it. Important aspects of
the design include:

- Developer Mode and privileged chroot operations reduce ChromeOS security.
- Boot autostart disables rootfs verification so it can install the required
  Upstart job. This step is skipped when it cannot be performed safely.
  ChromeOS updates may replace that job; rerun the installer if Cross no longer
  starts after an update.
- The Alpine-visible bind mount of HOME is remounted with
  `exec,nosuid,nodev`; the original ChromeOS HOME mount is not remounted.
- Because Cross does not use a mount namespace, host processes can also reach
  this executable view through `/usr/local/cross/alpine`.
- If ChromeOS blocks HOME symlinks, Cross may request a temporary symlink-policy
  exception for the stateful partition. The exception lasts until reboot.
- The local SSH service is restricted to loopback and key authentication, but
  it still exposes a privileged development environment to local host
  processes that can access its private key.
- Cross Desktop listens only on `127.0.0.1:32221` and routes only registered
  application UUIDs from the HTTP/WebSocket `Host` header. Each UUID isolates
  the application's browser origin and PWA state; it
  is not a security boundary against other local processes, which can read or
  forge localhost traffic.
- Enabling clipboard and file transfer exposes copied or dropped data to the
  Alpine session. Dropped media is opened automatically in VLC; other uploaded
  files are saved without automatic execution.

Review `cross.sh` before running it and keep backups of important data.

## Troubleshooting

### `cross: VT-2 service unreachable`

Open VT-2 and run:

```bash
/usr/local/cross/bin/cross start
```

If it still fails, inspect the service:

```bash
/usr/local/cross/bin/cross doctor
/usr/local/cross/bin/cross log 120
```

### Public-key authentication fails

Run `cross doctor` from VT-2. If the key or permission checks fail,
rerun the installer to repair the generated configuration.

### `cross` is not found

Reload the shell profile or open a new Crosh window:

```bash
source ~/.bashrc
```

### Downloads or DNS resolution fail

Verify that ChromeOS itself has network access, then rerun the installer. Cross
copies a usable host DNS configuration into Alpine during setup and validates
resolution before completing.

### Cross Desktop has no audio or keyboard input

Check the canvas service and its Xpra/PulseAudio log:

```bash
cross desktop status
cross desktop log 120
```

If the main Cross service is stopped, start it from VT-2 first. Click the canvas
or press a key once when the activation hint appears; this focuses the X11
window and satisfies Chrome's audio user-gesture requirement. If input or audio
still fails, `cross desktop restart` recreates the virtual display and its
private PulseAudio server.

### Boot autostart requires a reboot and rerun

This is expected on a stock ChromeOS release image. The first run completes
Cross setup while disabling rootfs verification so `/etc/init` can become
writable after reboot. Reboot, return to VT-2, and rerun the installer to add
autostart. If `make_dev_ssd.sh` refuses the change, follow its printed safety
guidance to enable autostart later. Cross setup itself continues without
autostart when the change is unavailable.

### Boot autostart is unavailable

The installer treats autostart as optional. Cross is still installed and
started at the end of setup. After a reboot, start it from VT-2 with:

```bash
/usr/local/cross/bin/cross start
```

### Cross stopped autostarting after a ChromeOS update

An OS update can replace the root filesystem and remove the Upstart job while
leaving `/usr/local/cross` intact. Rerun the installer from VT-2; it repairs the
job and preserves the existing Alpine environment where possible.

### `nvm` is unavailable

`nvm` is not packaged by Alpine and is not installed by Cross. Use the Alpine
`nodejs` and `npm` packages instead.

## Installation layout

| Path | Purpose |
| --- | --- |
| `/usr/local/cross/alpine` | Alpine root filesystem |
| `/usr/local/cross/bin` | `cross`, its compatibility helpers, and host wrappers |
| `/usr/local/cross/cache` | Download cache |
| `/usr/local/cross/etc` | Cross, default application UUID, and SSH client configuration |
| `/usr/local/cross/log` | Cross service and boot-start logs |
| `/usr/local/cross/run` | Runtime client state |
| `/usr/local/cross/work/chronos` | Additional writable development area |

## License

Cross is released under CC0.
