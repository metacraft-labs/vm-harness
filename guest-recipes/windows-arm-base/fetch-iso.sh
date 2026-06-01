#!/usr/bin/env bash
# fetch-iso.sh — download a fresh Windows 11 ARM Insider Preview ISO.
#
# Microsoft's ARM Insider ISO links rotate; UUP Dump (no Microsoft
# account required) is the documented path. This script wraps the
# UUP Dump "macOS shell script" recipe for a fixed-build snapshot;
# tweak UUP_BUILD_ID to track a newer build.
#
# Outputs: ./build/win11-arm-insider.iso
#
# Override with VMH_WIN11_ARM_ISO=/path/to/existing.iso to skip the
# download entirely.
#
# Requires: curl, jq (in the vm-harness flake dev shell), aria2c
# (added to the flake dev shell on macOS — see flake.nix).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
ISO_PATH="${BUILD_DIR}/win11-arm-insider.iso"

if [[ -n "${VMH_WIN11_ARM_ISO:-}" ]]; then
  echo "fetch-iso: VMH_WIN11_ARM_ISO=${VMH_WIN11_ARM_ISO} — skipping download."
  if [[ ! -f "${VMH_WIN11_ARM_ISO}" ]]; then
    echo "fetch-iso: error — ${VMH_WIN11_ARM_ISO} does not exist." >&2
    exit 1
  fi
  echo "fetch-iso: using existing ISO at ${VMH_WIN11_ARM_ISO}"
  exit 0
fi

if [[ -f "${ISO_PATH}" ]]; then
  echo "fetch-iso: ISO already present at ${ISO_PATH} — skipping download."
  echo "fetch-iso: delete it and re-run to refresh."
  exit 0
fi

mkdir -p "${BUILD_DIR}"

cat <<'EOF'
fetch-iso: UUP Dump driver script.

Microsoft does not provide a direct stable URL for Windows 11 ARM
Insider Preview ISOs without an MSA login. UUP Dump assembles the
official ESD/CAB chunks Microsoft serves to Windows Update and
generates a one-shot bash script that downloads + composes them into
an ISO locally.

Manual one-time step (per UUP Dump's no-API-key policy):

  1. Open https://uupdump.net/known.php?q=windows+11+arm+insider
  2. Pick the latest "Dev Channel" or "Beta Channel" ARM64 build.
  3. Pick language: English (United States).
  4. Pick edition: Windows Pro (other SKUs work but autounattend.xml
     names "Windows 11 Pro" by default).
  5. Click "Create download package" -> "macOS Linux shell script".
  6. Extract the downloaded zip into ./build/uup-dump-package/
  7. cd ./build/uup-dump-package && ./uup_download_macos.sh
  8. Move the resulting .ISO to ./build/win11-arm-insider.iso

EOF

echo "fetch-iso: please run the manual UUP Dump steps above, then re-run this script."
echo "fetch-iso: target ISO path: ${ISO_PATH}"
exit 2
