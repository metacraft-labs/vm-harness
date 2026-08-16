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
#   ./build-autounattend-iso.sh --portable-git PATH          # embeds PATH as
#                                                            # git/PortableGit-*.7z.exe
#   ./build-autounattend-iso.sh --require-portable-git       # fail if no
#                                                            # PortableGit archive
#                                                            # is available
#
# The --controller-pubkey path lets the libvirt M4 windows-runner
# bootstrap inject the controller's SSH public key into the guest in
# one shot, so no manual notepad-paste step is needed on first boot.
# Implementation: the helper stages controller.pub at the root of the
# autounattend ISO alongside autounattend.xml; the autounattend's
# FirstLogonCommands block scans removable drives for controller.pub
# and appends it to C:\Users\admin\.ssh\authorized_keys.
#
# Git for Windows: ../lib/provision-git.ps1 is ALWAYS staged at the ISO
# root; it installs PortableGit and puts C:\PortableGit\bin on the
# MACHINE PATH, which is what makes `bash.exe` reachable by the GitHub
# Actions runner SERVICE on clones of this golden. The pinned
# PortableGit archive is additionally embedded under git/ when
# available (run ../lib/fetch-portable-git.sh --arch x64 to populate
# ./build), so the golden build does not depend on the guest reaching
# github.com. Without an embedded archive the guest downloads it and
# verifies the same pinned checksum.
#
# Requires: genisoimage OR mkisofs OR xorriso. All three are in the
# vm-harness flake's Linux dev shell via `pkgs.cdrkit` /
# `pkgs.xorriso`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB_DIR="$(cd -- "${SCRIPT_DIR}/../lib" &>/dev/null && pwd)"
# VMH_BUILD_DIR lets the caller redirect outputs to a writable
# directory when the recipe lives in /nix/store (e.g. when shipped
# inside a Nix-built vm-harness package). When unset we keep the
# historical "<SCRIPT_DIR>/build" shape so in-tree developer
# workflows stay byte-identical.
BUILD_DIR="${VMH_BUILD_DIR:-${SCRIPT_DIR}/build}"
STAGE_DIR="${BUILD_DIR}/autounattend-stage"
ISO_PATH="${BUILD_DIR}/autounattend.iso"
FIRST_BOOT_SRC=""
CONTROLLER_PUBKEY_SRC=""
PORTABLE_GIT_SRC="${VMH_PORTABLE_GIT_ARCHIVE:-}"
REQUIRE_PORTABLE_GIT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --first-boot-script)
      FIRST_BOOT_SRC="$2"; shift 2;;
    --controller-pubkey)
      CONTROLLER_PUBKEY_SRC="$2"; shift 2;;
    --portable-git)
      PORTABLE_GIT_SRC="$2"; shift 2;;
    --require-portable-git)
      REQUIRE_PORTABLE_GIT=1; shift;;
    --help|-h)
      sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0;;
    *)
      echo "build-autounattend-iso: unrecognized arg '$1'" >&2; exit 1;;
  esac
done

if [[ ! -f "${SCRIPT_DIR}/autounattend.xml" ]]; then
  echo "build-autounattend-iso: missing autounattend.xml in ${SCRIPT_DIR}" >&2
  exit 1
fi
if [[ ! -f "${LIB_DIR}/provision-git.ps1" ]]; then
  echo "build-autounattend-iso: missing provision-git.ps1 in ${LIB_DIR}" >&2
  exit 1
fi
if [[ ! -f "${LIB_DIR}/assert-git-provisioned.ps1" ]]; then
  echo "build-autounattend-iso: missing assert-git-provisioned.ps1 in ${LIB_DIR}" >&2
  exit 1
fi

# Default the PortableGit archive to whatever ../lib/fetch-portable-git.sh
# left in ./build. Resolved by glob so the recipe does not have to repeat the
# pinned version (provision-git.ps1 owns it).
if [[ -z "${PORTABLE_GIT_SRC}" ]]; then
  for candidate in "${BUILD_DIR}"/PortableGit-*-64-bit.7z.exe; do
    [[ -f "${candidate}" ]] && PORTABLE_GIT_SRC="${candidate}" && break
  done
fi
if [[ -n "${PORTABLE_GIT_SRC}" && ! -f "${PORTABLE_GIT_SRC}" ]]; then
  echo "build-autounattend-iso: PortableGit archive not found: ${PORTABLE_GIT_SRC}" >&2
  exit 1
fi
if [[ -z "${PORTABLE_GIT_SRC}" && "${REQUIRE_PORTABLE_GIT}" -eq 1 ]]; then
  echo "build-autounattend-iso: PortableGit archive is required but was not found" >&2
  echo "  run ../lib/fetch-portable-git.sh --arch x64 --output ${BUILD_DIR}" >&2
  echo "  or pass --portable-git PATH" >&2
  exit 1
fi

rm -rf "${STAGE_DIR}"
mkdir -p "${BUILD_DIR}" "${STAGE_DIR}"
cp "${SCRIPT_DIR}/autounattend.xml" "${STAGE_DIR}/autounattend.xml"
cp "${LIB_DIR}/provision-git.ps1" "${STAGE_DIR}/provision-git.ps1"
# The gate that makes provision-git.ps1's exit-0-on-failure safe.
# build-sysprep-golden.sh scp's its own copy in, but carrying it on the ISO
# lets an operator run the same check by hand against a booted guest.
cp "${LIB_DIR}/assert-git-provisioned.ps1" "${STAGE_DIR}/assert-git-provisioned.ps1"

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

if [[ -n "${PORTABLE_GIT_SRC}" ]]; then
  mkdir -p "${STAGE_DIR}/git"
  cp "${PORTABLE_GIT_SRC}" "${STAGE_DIR}/git/$(basename -- "${PORTABLE_GIT_SRC}")"
  if [[ -f "${PORTABLE_GIT_SRC}.sha256" ]]; then
    cp "${PORTABLE_GIT_SRC}.sha256" "${STAGE_DIR}/git/$(basename -- "${PORTABLE_GIT_SRC}").sha256"
  fi
  echo "build-autounattend-iso: embedded PortableGit archive: ${PORTABLE_GIT_SRC}"
else
  echo "build-autounattend-iso: PortableGit archive not embedded; the guest will download it from the pinned URL (still checksum-verified)" >&2
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
