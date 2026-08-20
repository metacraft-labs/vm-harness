#!/usr/bin/env bash
# fetch-iso.sh — fetch the two ISOs the libvirt Windows-x64 baseline
# needs:
#
#   1. virtio-win.iso  — pinned URL (fedorapeople stable channel; the
#      file is content-addressed in the sense that the same URL gives
#      you the same release until Red Hat publishes a newer one).
#   2. Win11_24H2_x64.iso — operator-supplied (Microsoft does not
#      provide a stable no-login direct URL; the user downloads from
#      microsoft.com and either drops the file at the canonical path
#      below or sets VMH_WIN11_X64_ISO).
#
# This script is intentionally split: it always fetches virtio-win.iso
# (it's tiny — ~700 MB and Red Hat redistributes it freely under
# OASIS terms), but it ONLY validates the presence of the Windows
# ISO. The Windows fetch is documented and left to the operator.
#
# Outputs:
#   ./build/virtio-win.iso              (always — downloaded)
#   ./build/Win11_24H2_x64.iso          (symlink to operator's ISO)
#
# Override the Windows ISO path with:
#   VMH_WIN11_X64_ISO=/path/to/Win11_24H2_EnglishInternational_x64.iso
#
# Required tools: curl, sha256sum. Uses xorriso (via the vm-harness dev
# shell) to validate the Windows ISO has a UEFI El Torito boot record.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB_DIR="$(cd -- "${SCRIPT_DIR}/../lib" &>/dev/null && pwd)"
# shellcheck source=../lib/validate-uefi-iso.sh
. "${LIB_DIR}/validate-uefi-iso.sh"
BUILD_DIR="${SCRIPT_DIR}/build"
VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
VIRTIO_OUT="${BUILD_DIR}/virtio-win.iso"

# Default path the operator is expected to place the Win11 ISO at.
# `high-mem-server` already uses this exact convention per
# infra/machines/server/_windows-runner-001/README.md.
DEFAULT_WIN11_ISO_PATH="/storage/iso/Win11_24H2_EnglishInternational_x64.iso"
WIN11_ISO_PATH="${VMH_WIN11_X64_ISO:-${DEFAULT_WIN11_ISO_PATH}}"
WIN11_SYMLINK="${BUILD_DIR}/Win11_24H2_x64.iso"

mkdir -p "${BUILD_DIR}"

# 1. virtio-win.iso — fetch (or skip when present).
if [[ -f "${VIRTIO_OUT}" ]]; then
  echo "fetch-iso: virtio-win.iso already present at ${VIRTIO_OUT}"
else
  echo "fetch-iso: downloading virtio-win.iso from ${VIRTIO_URL}"
  if command -v aria2c >/dev/null 2>&1; then
    aria2c --dir="${BUILD_DIR}" --out="virtio-win.iso" \
           --max-connection-per-server=4 --split=4 "${VIRTIO_URL}"
  else
    curl -L --fail --progress-bar -o "${VIRTIO_OUT}" "${VIRTIO_URL}"
  fi
  echo "fetch-iso: virtio-win.iso fetched. SHA256:"
  sha256sum "${VIRTIO_OUT}" | head -1
fi

# 2. Windows ISO — fetch it when absent, falling back to the manual path.
#
# This used to refuse outright ("bring your own"), which left a hand-carried
# artifact in the middle of an otherwise declarative pipeline. ../lib/
# fetch-windows-iso.sh drives Microsoft's own download API (via Fido) and is
# safe to call unconditionally: it no-ops when the file is already there.
#
# It is best-effort ON PURPOSE. Microsoft rate-limits link generation hard,
# so a failure here is often transient and must not be mistaken for a broken
# recipe — we fall through to the manual instructions rather than exiting on
# its behalf.
if [[ ! -f "${WIN11_ISO_PATH}" ]]; then
  if [[ -x "${LIB_DIR}/fetch-windows-iso.sh" ]]; then
    echo "fetch-iso: ${WIN11_ISO_PATH} absent — attempting automated download"
    "${LIB_DIR}/fetch-windows-iso.sh" \
      --win 11 --arch x64 --edition Pro --lang English \
      --output "${WIN11_ISO_PATH}" || true
  fi
fi

if [[ ! -f "${WIN11_ISO_PATH}" ]]; then
  cat >&2 <<EOF
fetch-iso: Windows 11 x64 ISO not found at ${WIN11_ISO_PATH}.

The automated download (../lib/fetch-windows-iso.sh) did not produce it.
That is most often Microsoft's rate limiter rather than a defect — it
clears on its own — so re-running later is worth trying before doing this
by hand.

Microsoft does not provide a stable no-login direct URL for the
Win11 x64 install media. The operator must download it manually:

  1. Open https://www.microsoft.com/en-us/software-download/windows11
  2. Pick "Windows 11 (multi-edition ISO for x64 devices)" and the
     installer's "Download Now" path.
  3. Save as: ${DEFAULT_WIN11_ISO_PATH}
     (or set VMH_WIN11_X64_ISO to wherever you saved it).
  4. Re-run this script.

The autounattend.xml in this directory expects "Windows 11 Pro"
to be present in the ISO's install.wim image list; the multi-
edition Win11 ISOs ship Pro, Home, Education, and Enterprise, so
the default selection works for any standard download.
EOF
  exit 1
fi

# 3. Validate the Windows ISO is UEFI-bootable BEFORE we commit to it.
# The libvirt Win11 domain is UEFI-only (q35 + OVMF); a BIOS-only ISO
# boots to nothing and virt-install stalls ~90 min on --wait. Fail fast
# with a clear cause instead.
validate_uefi_iso "${WIN11_ISO_PATH}" "the Windows 11 x64 ISO (${WIN11_ISO_PATH})"

# 4. Create a symlink under build/ so downstream recipes have a
# stable path regardless of where the operator stashed the ISO.
ln -sf "${WIN11_ISO_PATH}" "${WIN11_SYMLINK}"
echo "fetch-iso: Win11 ISO available at ${WIN11_SYMLINK} -> ${WIN11_ISO_PATH}"
echo "fetch-iso: SHA256:"
sha256sum "${WIN11_ISO_PATH}" | head -1

echo
echo "fetch-iso: done. Next step:"
echo "  ./build-autounattend-iso.sh [--first-boot-script PATH]"
