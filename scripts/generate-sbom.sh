#!/bin/bash
set -Eeuo pipefail

output="${1:-cross-packages.spdx}"
cross_bin="${CROSS_PREFIX:-/usr/local/cross}/bin/cross"
[[ -x "$cross_bin" ]] || { echo 'Cross is not installed' >&2; exit 1; }
[[ ! -e "$output" ]] || { echo "refusing to overwrite $output" >&2; exit 1; }

created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  printf 'SPDXVersion: SPDX-2.3\n'
  printf 'DataLicense: CC0-1.0\n'
  printf 'SPDXID: SPDXRef-DOCUMENT\n'
  printf 'DocumentName: Cross-installed-packages\n'
  printf 'DocumentNamespace: urn:cross:packages:%s\n' "$(date -u +%Y%m%dT%H%M%SZ)"
  printf 'Creator: Tool: Cross-generate-sbom\n'
  printf 'Created: %s\n' "$created"
  "$cross_bin" /usr/bin/awk '
    function emit( id) {
      if (name == "") return
      id=name; gsub(/[^A-Za-z0-9.-]/, "-", id)
      print ""
      print "PackageName: " name
      print "SPDXID: SPDXRef-Package-" id
      print "PackageVersion: " version
      print "PackageDownloadLocation: NOASSERTION"
      print "FilesAnalyzed: false"
      print "PackageLicenseConcluded: " (license == "" ? "NOASSERTION" : license)
      print "PackageLicenseDeclared: " (license == "" ? "NOASSERTION" : license)
      print "PackageCopyrightText: NOASSERTION"
      print "Relationship: SPDXRef-DOCUMENT DESCRIBES SPDXRef-Package-" id
    }
    /^P:/ { name=substr($0, 3) }
    /^V:/ { version=substr($0, 3) }
    /^L:/ { license=substr($0, 3) }
    /^$/ { emit(); name=version=license="" }
    END { emit() }
  ' /lib/apk/db/installed
} > "$output"

printf 'SBOM written: %s\n' "$output"
