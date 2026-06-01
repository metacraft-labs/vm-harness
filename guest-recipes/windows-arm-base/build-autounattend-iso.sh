#!/usr/bin/env bash
# build-autounattend-iso.sh — wrap autounattend.xml + repro-sysprep.xml
# as a CD-ROM ISO that UTM can attach to the VM.
#
# Windows Setup scans every attached removable medium at first boot
# for an autounattend.xml at the root; whichever one it finds first
# wins. We ship a tiny FAT12/UDF ISO with both XML files at the root.
#
# Outputs: ./build/autounattend.iso
#
# Requires: hdiutil (macOS-native) OR mkisofs/genisoimage from
# cdrtools (brought in by `brew install cdrtools` or via the nix
# `pkgs.cdrtools` dev shell).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
STAGE_DIR="${BUILD_DIR}/autounattend-stage"
ISO_PATH="${BUILD_DIR}/autounattend.iso"

if [[ ! -f "${SCRIPT_DIR}/autounattend.xml" ]]; then
  echo "build-autounattend-iso: missing autounattend.xml in ${SCRIPT_DIR}" >&2
  exit 1
fi
if [[ ! -f "${SCRIPT_DIR}/repro-sysprep.xml" ]]; then
  echo "build-autounattend-iso: missing repro-sysprep.xml in ${SCRIPT_DIR}" >&2
  exit 1
fi

mkdir -p "${BUILD_DIR}" "${STAGE_DIR}"
cp "${SCRIPT_DIR}/autounattend.xml" "${STAGE_DIR}/autounattend.xml"
cp "${SCRIPT_DIR}/repro-sysprep.xml" "${STAGE_DIR}/repro-sysprep.xml"

rm -f "${ISO_PATH}"

if command -v hdiutil >/dev/null 2>&1; then
  # hdiutil makecdr-style flags produce a UDF/ISO 9660 hybrid that
  # Windows reads cleanly.
  hdiutil makehybrid \
    -o "${ISO_PATH}" \
    -hfs -joliet -iso -udf \
    -default-volume-name AUTOUNATTEND \
    "${STAGE_DIR}"
elif command -v mkisofs >/dev/null 2>&1; then
  mkisofs -o "${ISO_PATH}" -V AUTOUNATTEND -J -r "${STAGE_DIR}"
elif command -v genisoimage >/dev/null 2>&1; then
  genisoimage -o "${ISO_PATH}" -V AUTOUNATTEND -J -r "${STAGE_DIR}"
else
  echo "build-autounattend-iso: need hdiutil (macOS), mkisofs, or genisoimage" >&2
  exit 1
fi

echo "build-autounattend-iso: wrote ${ISO_PATH}"
ls -lh "${ISO_PATH}"
