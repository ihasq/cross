# Cross

## Setup

### 0. Enable ChromeOS Developer Mode
Disabling WPS is not neccesary.

### 1. Enter VT-2 and do this
```shell
curl https://cross-sh.pages.dev/cross.sh | bash
/usr/local/cross/bin/cross-service start
```

If Cross was installed by a version that wrapped `bash` and `curl`, use the
host binaries for the first update:

```shell
/usr/bin/curl https://cross-sh.pages.dev/cross.sh | /bin/bash
```

That update removes the old host-command wrappers. Later updates can use the
normal `curl ... | bash` command again.

### 2. Open Crosh and do this
```shell
cross
```

## License
Cross is CC0
