# Security

## Trust boundary

Cross is a privileged chroot, not a sandbox, container, or virtual machine. It
shares the ChromeOS kernel and PID namespace. The Cross user has passwordless
root inside the chroot, while host `/proc`, `/sys`, selected mounts, and a system
D-Bus socket are visible. Root inside Cross can therefore have host-root-
equivalent impact. Do not use Cross to run untrusted code with elevated rights.

The localhost SSH key is an access credential to this privileged environment.
Backups contain that key and must remain mode 0600 and confidential.

Cross never disables verified boot. Older Cross versions did; uninstalling a
current release cannot re-enable it. Use the official ChromeOS recovery process
to restore a verified system image if an older release changed that state.

## Supply chain

Release `SHA256SUMS` authenticates the downloaded installer when obtained from
an independent trusted release channel. Alpine minirootfs digests are pinned in
the reviewed installer and Alpine packages retain apk signature verification.
Debian experimental metadata is accepted only after `InRelease` verification
with Alpine's signed `debian-archive-keyring` package.

Tag-triggered releases use GitHub OIDC build-provenance attestations for
`cross.sh`. Verify them with `gh attestation verify` against the canonical
repository in addition to checking `SHA256SUMS`.

## Reporting

Do not publish an exploitable issue before a fix is available. Report it through
the repository's private security-advisory facility. No unattended security
support period is promised; users must apply both ChromeOS and Alpine updates.
