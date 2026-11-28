# Third-party components

Cross installs packages from Alpine Linux and extracts a limited runtime subset
from Debian experimental. Those files retain their upstream licenses. Package
license metadata and copyright files are installed with the packages and can be
inspected with `apk info --license` and under `/usr/share/doc`.

Primary component families are Alpine Linux, apk-tools, OpenSSH, OpenRC, GNU
toolchain utilities, Rust, Node.js, FFmpeg, and GNU libc distributed by Debian.
Before publishing a release, generate an exact package inventory with:

```sh
scripts/generate-sbom.sh cross-packages.spdx
cross apk info -vv > cross-packages.txt
cross apk info --license -a > cross-package-licenses.txt
```

Those generated inventories are release artifacts; this source-tree document
cannot accurately freeze packages that users later add or upgrade.
