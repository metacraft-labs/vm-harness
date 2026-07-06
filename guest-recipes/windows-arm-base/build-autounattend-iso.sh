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
# Optional:
#   --openssh-arm64-zip PATH          embed the Win32-OpenSSH ARM64 zip
#   --require-openssh-arm64-zip       fail if no zip is available
#
# By default, the helper embeds ./build/OpenSSH-ARM64.zip when present.
#
# Requires: hdiutil (macOS-native) OR mkisofs/genisoimage from
# cdrtools (brought in by `brew install cdrtools` or via the nix
# `pkgs.cdrtools` dev shell).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
STAGE_DIR="${BUILD_DIR}/autounattend-stage"
ISO_PATH="${BUILD_DIR}/autounattend.iso"
OPENSSH_ZIP_SRC="${VMH_OPENSSH_ARM64_ZIP:-}"
REQUIRE_OPENSSH_ZIP=0

usage() {
  cat <<EOF
Usage: ./build-autounattend-iso.sh [--openssh-arm64-zip PATH] [--require-openssh-arm64-zip]

Builds ./build/autounattend.iso. If OpenSSH-ARM64.zip is available, it is
staged as openssh/OpenSSH-ARM64.zip on the autounattend ISO so the guest can
install sshd without Windows Update.

The zip source is resolved in this order:
  1. --openssh-arm64-zip PATH
  2. VMH_OPENSSH_ARM64_ZIP
  3. ./build/OpenSSH-ARM64.zip

Run ./fetch-openssh-arm64.sh to populate the default cache.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --openssh-arm64-zip)
      [[ $# -ge 2 ]] || { echo "build-autounattend-iso: --openssh-arm64-zip needs a path" >&2; exit 1; }
      OPENSSH_ZIP_SRC="$2"
      shift 2
      ;;
    --require-openssh-arm64-zip)
      REQUIRE_OPENSSH_ZIP=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "build-autounattend-iso: unrecognized arg '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${OPENSSH_ZIP_SRC}" && -f "${BUILD_DIR}/OpenSSH-ARM64.zip" ]]; then
  OPENSSH_ZIP_SRC="${BUILD_DIR}/OpenSSH-ARM64.zip"
fi

if [[ ! -f "${SCRIPT_DIR}/autounattend.xml" ]]; then
  echo "build-autounattend-iso: missing autounattend.xml in ${SCRIPT_DIR}" >&2
  exit 1
fi
if [[ ! -f "${SCRIPT_DIR}/repro-sysprep.xml" ]]; then
  echo "build-autounattend-iso: missing repro-sysprep.xml in ${SCRIPT_DIR}" >&2
  exit 1
fi
if [[ ! -f "${SCRIPT_DIR}/provision-openssh.ps1" ]]; then
  echo "build-autounattend-iso: missing provision-openssh.ps1 in ${SCRIPT_DIR}" >&2
  exit 1
fi
if [[ -n "${OPENSSH_ZIP_SRC}" && ! -f "${OPENSSH_ZIP_SRC}" ]]; then
  echo "build-autounattend-iso: OpenSSH ARM64 zip not found: ${OPENSSH_ZIP_SRC}" >&2
  exit 1
fi
if [[ -z "${OPENSSH_ZIP_SRC}" && "${REQUIRE_OPENSSH_ZIP}" -eq 1 ]]; then
  echo "build-autounattend-iso: OpenSSH ARM64 zip is required but was not found" >&2
  echo "  run ./fetch-openssh-arm64.sh or pass --openssh-arm64-zip PATH" >&2
  exit 1
fi

rm -rf "${STAGE_DIR}"
mkdir -p "${BUILD_DIR}" "${STAGE_DIR}"
cp "${SCRIPT_DIR}/autounattend.xml" "${STAGE_DIR}/autounattend.xml"
cp "${SCRIPT_DIR}/repro-sysprep.xml" "${STAGE_DIR}/repro-sysprep.xml"
cp "${SCRIPT_DIR}/provision-openssh.ps1" "${STAGE_DIR}/provision-openssh.ps1"
if [[ -n "${OPENSSH_ZIP_SRC}" ]]; then
  mkdir -p "${STAGE_DIR}/openssh"
  cp "${OPENSSH_ZIP_SRC}" "${STAGE_DIR}/openssh/OpenSSH-ARM64.zip"
  if [[ -f "${OPENSSH_ZIP_SRC}.sha256" ]]; then
    cp "${OPENSSH_ZIP_SRC}.sha256" "${STAGE_DIR}/openssh/OpenSSH-ARM64.zip.sha256"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${OPENSSH_ZIP_SRC}" |
      awk '{print $1 "  OpenSSH-ARM64.zip"}' > "${STAGE_DIR}/openssh/OpenSSH-ARM64.zip.sha256"
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${OPENSSH_ZIP_SRC}" |
      awk '{print $1 "  OpenSSH-ARM64.zip"}' > "${STAGE_DIR}/openssh/OpenSSH-ARM64.zip.sha256"
  fi
  echo "build-autounattend-iso: embedded OpenSSH ARM64 zip: ${OPENSSH_ZIP_SRC}"
else
  echo "build-autounattend-iso: OpenSSH ARM64 zip not embedded; offline fallback will be unavailable" >&2
fi

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
