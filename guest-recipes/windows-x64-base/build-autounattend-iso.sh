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
# Which hypervisor the resulting ISO is for. Only affects whether the
# virtio driver-injection component survives into the staged
# autounattend.xml — see the VMH:VIRTIO-DRIVERS markers in that file.
TARGET="libvirt"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="$2"; shift 2;;
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

case "${TARGET}" in
  libvirt|hyperv) ;;
  *)
    echo "build-autounattend-iso: --target must be 'libvirt' or 'hyperv' (got '${TARGET}')" >&2
    exit 1;;
esac

rm -rf "${STAGE_DIR}"
mkdir -p "${BUILD_DIR}" "${STAGE_DIR}"

if [[ "${TARGET}" == "hyperv" ]]; then
  # Drop the virtio driver-injection component: Hyper-V's storage and
  # network adapters are VMBus devices whose drivers ship in-box, so
  # there is nothing to inject and the D:/E: paths name a CD that isn't
  # attached.
  awk '
    /VMH:VIRTIO-DRIVERS:BEGIN/ { skipping = 1 }
    !skipping                  { print }
    /VMH:VIRTIO-DRIVERS:END/   { skipping = 0 }
  ' "${SCRIPT_DIR}/autounattend.xml" > "${STAGE_DIR}/autounattend.xml"

  # Fail loudly rather than shipping an unmodified file: if the markers
  # are ever renamed, awk silently copies the input through and the
  # virtio block reaches a Hyper-V install. Both markers must be gone
  # AND the file must have actually shrunk.
  if grep -q "VMH:VIRTIO-DRIVERS" "${STAGE_DIR}/autounattend.xml"; then
    echo "build-autounattend-iso: virtio strip failed — markers still present" >&2
    exit 1
  fi
  if grep -q "PnpCustomizationsWinPE" "${STAGE_DIR}/autounattend.xml"; then
    echo "build-autounattend-iso: virtio strip failed — driver component survived" >&2
    exit 1
  fi
  echo "build-autounattend-iso: target=hyperv (stripped virtio driver injection)"
else
  cp "${SCRIPT_DIR}/autounattend.xml" "${STAGE_DIR}/autounattend.xml"
  echo "build-autounattend-iso: target=libvirt (virtio driver injection kept)"
fi

# Parse the staged unattend before wrapping it in an ISO.
#
# Worth the ~10 lines because the failure mode is asymmetric and slow:
# Windows Setup does not report a malformed autounattend.xml, it just
# ignores it and drops to the interactive installer, which from the
# harness side looks like a hang until the boot timeout fires an hour
# later. And a mistake inside the virtio comment block breaks ONLY the
# libvirt target — the hyperv target strips that block, so a green
# hyperv build proves nothing about the other one. (Observed: an XML
# comment containing a double hyphen, which XML forbids.)
xml_ok=""
if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "${STAGE_DIR}/autounattend.xml" || exit 1
  xml_ok="xmllint"
elif command -v python3 >/dev/null 2>&1; then
  python3 -c 'import sys,xml.dom.minidom as m; m.parse(sys.argv[1])' \
    "${STAGE_DIR}/autounattend.xml" || exit 1
  xml_ok="python3"
elif command -v powershell.exe >/dev/null 2>&1 || command -v pwsh >/dev/null 2>&1; then
  _ps="$(command -v pwsh || command -v powershell.exe)"
  if command -v cygpath >/dev/null 2>&1; then
    _xml="$(cygpath -w "${STAGE_DIR}/autounattend.xml")"
  else
    _xml="${STAGE_DIR}/autounattend.xml"
  fi
  "${_ps}" -NoProfile -NonInteractive -Command \
    "try { [void][xml](Get-Content -Raw -LiteralPath '${_xml}'); exit 0 } catch { Write-Error \$_.Exception.Message; exit 1 }" || exit 1
  xml_ok="powershell"
fi
if [[ -n "${xml_ok}" ]]; then
  echo "build-autounattend-iso: autounattend.xml parses (${xml_ok})"
else
  echo "build-autounattend-iso: WARNING — no XML parser available; shipping unvalidated" >&2
fi

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
elif command -v powershell.exe >/dev/null 2>&1 || command -v pwsh >/dev/null 2>&1; then
  # Windows host (Git Bash / MSYS). None of the Linux ISO tools exist
  # here and the Microsoft one (oscdimg) ships only in the ADK, so hand
  # off to make-iso.ps1, which prefers oscdimg when present and
  # otherwise uses in-box IMAPI2. Staging, arg parsing and the pubkey
  # sanity check above stay shared — only the final write differs.
  PS_EXE="$(command -v pwsh || command -v powershell.exe)"
  # The PowerShell side needs Windows paths, not MSYS ones.
  if command -v cygpath >/dev/null 2>&1; then
    WIN_STAGE="$(cygpath -w "${STAGE_DIR}")"
    WIN_ISO="$(cygpath -w "${ISO_PATH}")"
    WIN_SCRIPT="$(cygpath -w "${SCRIPT_DIR}/make-iso.ps1")"
  else
    WIN_STAGE="${STAGE_DIR}"; WIN_ISO="${ISO_PATH}"
    WIN_SCRIPT="${SCRIPT_DIR}/make-iso.ps1"
  fi
  "${PS_EXE}" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "${WIN_SCRIPT}" \
    -SourceDir "${WIN_STAGE}" -OutputPath "${WIN_ISO}" -VolumeName AUTOUNATTEND
else
  echo "build-autounattend-iso: need genisoimage, mkisofs, or xorriso on Linux/macOS," >&2
  echo "  or powershell/pwsh on Windows (try: nix shell nixpkgs#xorriso)" >&2
  exit 1
fi

echo "build-autounattend-iso: wrote ${ISO_PATH}"
ls -lh "${ISO_PATH}"
