#!/usr/bin/env bash
# build-autounattend-iso.sh — wrap autounattend.xml (and an optional
# first-boot.ps1) as a CD-ROM ISO that libvirt's virt-install can
# attach to the VM via the libvirt backend's third sata CD slot.
#
# Windows Setup scans every attached removable medium at first boot
# for an autounattend.xml at the root; whichever one it finds first
# wins. We ship a tiny ISO9660 + Joliet ISO with autounattend.xml
# at the root (and first-boot.ps1 alongside, when provided).
#
# Outputs: ./build/autounattend.iso
#
# Usage:
#   ./build-autounattend-iso.sh                              # plain unattend
#   ./build-autounattend-iso.sh --first-boot-script PATH     # also embeds PATH
#                                                            # as first-boot.ps1
#   ./build-autounattend-iso.sh --controller-pubkey PATH     # also embeds PATH
#                                                            # as controller.pub
#                                                            # (installed into
#                                                            # the guest user's
#                                                            # authorized_keys
#                                                            # by FirstLogonCommands)
#
# The --controller-pubkey path lets the libvirt M4 windows-runner
# bootstrap inject the controller's SSH public key into the guest in
# one shot, so no manual notepad-paste step is needed on first boot.
# Implementation: the helper stages controller.pub at the root of the
# autounattend ISO alongside autounattend.xml; the autounattend's
# FirstLogonCommands block scans removable drives for controller.pub
# and appends it to C:\Users\admin\.ssh\authorized_keys.
#
# Requires: genisoimage OR mkisofs OR xorriso. All three are in the
# vm-harness flake's Linux dev shell via `pkgs.cdrkit` /
# `pkgs.xorriso`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
STAGE_DIR="${BUILD_DIR}/autounattend-stage"
ISO_PATH="${BUILD_DIR}/autounattend.iso"
FIRST_BOOT_SRC=""
CONTROLLER_PUBKEY_SRC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --first-boot-script)
      FIRST_BOOT_SRC="$2"; shift 2;;
    --controller-pubkey)
      CONTROLLER_PUBKEY_SRC="$2"; shift 2;;
    --help|-h)
      sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0;;
    *)
      echo "build-autounattend-iso: unrecognized arg '$1'" >&2; exit 1;;
  esac
done

if [[ ! -f "${SCRIPT_DIR}/autounattend.xml" ]]; then
  echo "build-autounattend-iso: missing autounattend.xml in ${SCRIPT_DIR}" >&2
  exit 1
fi

rm -rf "${STAGE_DIR}"
mkdir -p "${BUILD_DIR}" "${STAGE_DIR}"
cp "${SCRIPT_DIR}/autounattend.xml" "${STAGE_DIR}/autounattend.xml"

if [[ -n "${FIRST_BOOT_SRC}" ]]; then
  if [[ ! -f "${FIRST_BOOT_SRC}" ]]; then
    echo "build-autounattend-iso: first-boot script not found: ${FIRST_BOOT_SRC}" >&2
    exit 1
  fi
  cp "${FIRST_BOOT_SRC}" "${STAGE_DIR}/first-boot.ps1"
  echo "build-autounattend-iso: embedded first-boot script: ${FIRST_BOOT_SRC}"
fi

if [[ -n "${CONTROLLER_PUBKEY_SRC}" ]]; then
  if [[ ! -f "${CONTROLLER_PUBKEY_SRC}" ]]; then
    echo "build-autounattend-iso: controller pubkey not found: ${CONTROLLER_PUBKEY_SRC}" >&2
    exit 1
  fi
  # Quick sanity check: SSH public keys are ASCII and start with a known
  # algorithm prefix. Bail loudly rather than baking garbage into the ISO.
  first_word="$(head -c 64 "${CONTROLLER_PUBKEY_SRC}" | awk '{print $1}')"
  case "${first_word}" in
    ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
      ;;
    *)
      echo "build-autounattend-iso: ${CONTROLLER_PUBKEY_SRC} does not look like an OpenSSH public key (first token: '${first_word}')" >&2
      exit 1
      ;;
  esac
  cp "${CONTROLLER_PUBKEY_SRC}" "${STAGE_DIR}/controller.pub"
  echo "build-autounattend-iso: embedded controller pubkey: ${CONTROLLER_PUBKEY_SRC}"
fi

rm -f "${ISO_PATH}"

if command -v genisoimage >/dev/null 2>&1; then
  genisoimage -o "${ISO_PATH}" -V AUTOUNATTEND -J -r "${STAGE_DIR}"
elif command -v mkisofs >/dev/null 2>&1; then
  mkisofs -o "${ISO_PATH}" -V AUTOUNATTEND -J -r "${STAGE_DIR}"
elif command -v xorriso >/dev/null 2>&1; then
  xorriso -as mkisofs -o "${ISO_PATH}" -V AUTOUNATTEND -J -r "${STAGE_DIR}"
else
  echo "build-autounattend-iso: need genisoimage, mkisofs, or xorriso (try: nix shell nixpkgs#xorriso)" >&2
  exit 1
fi

echo "build-autounattend-iso: wrote ${ISO_PATH}"
ls -lh "${ISO_PATH}"
