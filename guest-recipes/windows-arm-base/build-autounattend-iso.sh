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
#   --virtio-netkvm-arm64-dir PATH    embed NetKVM\w11\ARM64 driver dir
#   --require-virtio-netkvm-arm64     fail if no NetKVM driver dir is available
#
# By default, the helper embeds ./build/OpenSSH-ARM64.zip when present.
# It also embeds ./build/virtio/NetKVM/w11/ARM64 when present.
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
VIRTIO_NETKVM_SRC="${VMH_VIRTIO_NETKVM_ARM64_DIR:-}"
REQUIRE_VIRTIO_NETKVM=0

usage() {
  cat <<EOF
Usage: ./build-autounattend-iso.sh [--openssh-arm64-zip PATH] [--require-openssh-arm64-zip] [--virtio-netkvm-arm64-dir PATH] [--require-virtio-netkvm-arm64]

Builds ./build/autounattend.iso. If OpenSSH-ARM64.zip is available, it is
staged as openssh/OpenSSH-ARM64.zip on the autounattend ISO so the guest can
install sshd without Windows Update.

If the ARM64 VirtIO NetKVM driver is available, NetKVM/w11/ARM64 is staged as
virtio/NetKVM/w11/ARM64 so the guest can install the QEMU virtio-net driver
offline before OpenSSH readiness is checked.

The zip source is resolved in this order:
  1. --openssh-arm64-zip PATH
  2. VMH_OPENSSH_ARM64_ZIP
  3. ./build/OpenSSH-ARM64.zip

The NetKVM source is resolved in this order:
  1. --virtio-netkvm-arm64-dir PATH
  2. VMH_VIRTIO_NETKVM_ARM64_DIR
  3. ./build/virtio/NetKVM/w11/ARM64

Run ./fetch-openssh-arm64.sh to populate the default cache.
Run ./fetch-virtio-netkvm-arm64.sh to populate the default NetKVM cache.
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
    --virtio-netkvm-arm64-dir)
      [[ $# -ge 2 ]] || { echo "build-autounattend-iso: --virtio-netkvm-arm64-dir needs a path" >&2; exit 1; }
      VIRTIO_NETKVM_SRC="$2"
      shift 2
      ;;
    --require-virtio-netkvm-arm64)
      REQUIRE_VIRTIO_NETKVM=1
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
if [[ -z "${VIRTIO_NETKVM_SRC}" && -f "${BUILD_DIR}/virtio/NetKVM/w11/ARM64/netkvm.inf" ]]; then
  VIRTIO_NETKVM_SRC="${BUILD_DIR}/virtio/NetKVM/w11/ARM64"
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
if [[ -n "${VIRTIO_NETKVM_SRC}" && ! -f "${VIRTIO_NETKVM_SRC}/netkvm.inf" ]]; then
  echo "build-autounattend-iso: NetKVM ARM64 driver dir must contain netkvm.inf: ${VIRTIO_NETKVM_SRC}" >&2
  exit 1
fi
if [[ -z "${VIRTIO_NETKVM_SRC}" && "${REQUIRE_VIRTIO_NETKVM}" -eq 1 ]]; then
  echo "build-autounattend-iso: NetKVM ARM64 driver dir is required but was not found" >&2
  echo "  run ./fetch-virtio-netkvm-arm64.sh or pass --virtio-netkvm-arm64-dir PATH" >&2
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
if [[ -n "${VIRTIO_NETKVM_SRC}" ]]; then
  mkdir -p "${STAGE_DIR}/virtio/NetKVM/w11/ARM64"
  cp -R "${VIRTIO_NETKVM_SRC}/." "${STAGE_DIR}/virtio/NetKVM/w11/ARM64/"
  echo "build-autounattend-iso: embedded NetKVM ARM64 driver dir: ${VIRTIO_NETKVM_SRC}"
else
  echo "build-autounattend-iso: NetKVM ARM64 driver dir not embedded; virtio networking offline install will be unavailable" >&2
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
