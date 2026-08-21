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
#   --portable-git PATH               embed the pinned PortableGit arm64 archive
#   --require-portable-git            fail if no PortableGit archive is available
#
# By default, the helper embeds ./build/OpenSSH-ARM64.zip when present.
# It also embeds ./build/virtio/NetKVM/w11/ARM64 when present, and
# ./build/PortableGit-*-arm64.7z.exe when present.
#
# ../lib/provision-git.ps1 is ALWAYS staged: it installs Git for Windows
# and puts C:\PortableGit\bin on the MACHINE PATH, which is what makes
# `bash.exe` reachable by a GitHub Actions runner SERVICE on clones of
# this golden. Without it every `shell: bash` step fails with
# "bash: command not found" and actions/checkout cannot use git.
#
# Requires: hdiutil (macOS-native) OR mkisofs/genisoimage from
# cdrtools (brought in by `brew install cdrtools` or via the nix
# `pkgs.cdrtools` dev shell).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB_DIR="$(cd -- "${SCRIPT_DIR}/../lib" &>/dev/null && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
STAGE_DIR="${BUILD_DIR}/autounattend-stage"
ISO_PATH="${BUILD_DIR}/autounattend.iso"
OPENSSH_ZIP_SRC="${VMH_OPENSSH_ARM64_ZIP:-}"
REQUIRE_OPENSSH_ZIP=0
VIRTIO_NETKVM_SRC="${VMH_VIRTIO_NETKVM_ARM64_DIR:-}"
REQUIRE_VIRTIO_NETKVM=0
PORTABLE_GIT_SRC="${VMH_PORTABLE_GIT_ARCHIVE:-}"
REQUIRE_PORTABLE_GIT=0

usage() {
  cat <<EOF
Usage: ./build-autounattend-iso.sh [--openssh-arm64-zip PATH] [--require-openssh-arm64-zip] [--virtio-netkvm-arm64-dir PATH] [--require-virtio-netkvm-arm64] [--portable-git PATH] [--require-portable-git]

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

The PortableGit source is resolved in this order:
  1. --portable-git PATH
  2. VMH_PORTABLE_GIT_ARCHIVE
  3. ./build/PortableGit-*-arm64.7z.exe

Run ./fetch-openssh-arm64.sh to populate the default cache.
Run ./fetch-virtio-netkvm-arm64.sh to populate the default NetKVM cache.
Run ../lib/fetch-portable-git.sh --arch arm64 --output ./build to populate
the default PortableGit cache.
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
    --portable-git)
      [[ $# -ge 2 ]] || { echo "build-autounattend-iso: --portable-git needs a path" >&2; exit 1; }
      PORTABLE_GIT_SRC="$2"
      shift 2
      ;;
    --require-portable-git)
      REQUIRE_PORTABLE_GIT=1
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
# Resolved by glob so the recipe does not have to repeat the pinned version;
# ../lib/provision-git.ps1 owns it.
if [[ -z "${PORTABLE_GIT_SRC}" ]]; then
  for candidate in "${BUILD_DIR}"/PortableGit-*-arm64.7z.exe; do
    [[ -f "${candidate}" ]] && PORTABLE_GIT_SRC="${candidate}" && break
  done
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
if [[ ! -f "${LIB_DIR}/provision-git.ps1" ]]; then
  echo "build-autounattend-iso: missing provision-git.ps1 in ${LIB_DIR}" >&2
  exit 1
fi
if [[ ! -f "${LIB_DIR}/assert-git-provisioned.ps1" ]]; then
  echo "build-autounattend-iso: missing assert-git-provisioned.ps1 in ${LIB_DIR}" >&2
  exit 1
fi
if [[ ! -f "${LIB_DIR}/provision-pwsh.ps1" ]]; then
  echo "build-autounattend-iso: missing provision-pwsh.ps1 in ${LIB_DIR}" >&2
  exit 1
fi
if [[ ! -f "${LIB_DIR}/assert-pwsh-provisioned.ps1" ]]; then
  echo "build-autounattend-iso: missing assert-pwsh-provisioned.ps1 in ${LIB_DIR}" >&2
  exit 1
fi
# Default the PowerShell 7 ZIP to whatever ../lib/fetch-powershell.sh left in
# ./build. Resolved by glob so the recipe does not have to repeat the pinned
# version (provision-pwsh.ps1 owns it).
PWSH_ZIP_SRC="${VMH_PWSH_ZIP:-}"
if [[ -z "${PWSH_ZIP_SRC}" ]]; then
  for candidate in "${BUILD_DIR}"/PowerShell-*-win-arm64.zip; do
    [[ -f "${candidate}" ]] && PWSH_ZIP_SRC="${candidate}" && break
  done
fi
if [[ -n "${PWSH_ZIP_SRC}" && ! -f "${PWSH_ZIP_SRC}" ]]; then
  echo "build-autounattend-iso: PowerShell ZIP not found: ${PWSH_ZIP_SRC}" >&2
  exit 1
fi

if [[ -n "${PORTABLE_GIT_SRC}" && ! -f "${PORTABLE_GIT_SRC}" ]]; then
  echo "build-autounattend-iso: PortableGit archive not found: ${PORTABLE_GIT_SRC}" >&2
  exit 1
fi
if [[ -z "${PORTABLE_GIT_SRC}" && "${REQUIRE_PORTABLE_GIT}" -eq 1 ]]; then
  echo "build-autounattend-iso: PortableGit archive is required but was not found" >&2
  echo "  run ../lib/fetch-portable-git.sh --arch arm64 --output ${BUILD_DIR}" >&2
  echo "  or pass --portable-git PATH" >&2
  exit 1
fi

rm -rf "${STAGE_DIR}"
mkdir -p "${BUILD_DIR}" "${STAGE_DIR}"
cp "${SCRIPT_DIR}/autounattend.xml" "${STAGE_DIR}/autounattend.xml"
cp "${SCRIPT_DIR}/repro-sysprep.xml" "${STAGE_DIR}/repro-sysprep.xml"
cp "${SCRIPT_DIR}/provision-openssh.ps1" "${STAGE_DIR}/provision-openssh.ps1"
cp "${LIB_DIR}/provision-git.ps1" "${STAGE_DIR}/provision-git.ps1"
# The gate that makes provision-git.ps1's exit-0-on-failure safe. This golden
# is captured by a MANUAL SysPrep, so the gate must ride along in the image.
cp "${LIB_DIR}/assert-git-provisioned.ps1" "${STAGE_DIR}/assert-git-provisioned.ps1"
cp "${LIB_DIR}/provision-pwsh.ps1" "${STAGE_DIR}/provision-pwsh.ps1"
# The gate that makes provision-pwsh.ps1's exit-0-on-failure safe, carried for
# the same reason as the Git one above.
cp "${LIB_DIR}/assert-pwsh-provisioned.ps1" "${STAGE_DIR}/assert-pwsh-provisioned.ps1"
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

if [[ -n "${PWSH_ZIP_SRC}" ]]; then
  mkdir -p "${STAGE_DIR}/pwsh"
  cp "${PWSH_ZIP_SRC}" "${STAGE_DIR}/pwsh/$(basename -- "${PWSH_ZIP_SRC}")"
  if [[ -f "${PWSH_ZIP_SRC}.sha256" ]]; then
    cp "${PWSH_ZIP_SRC}.sha256" "${STAGE_DIR}/pwsh/$(basename -- "${PWSH_ZIP_SRC}").sha256"
  fi
  echo "build-autounattend-iso: embedded PowerShell 7 ZIP: ${PWSH_ZIP_SRC}"
else
  echo "build-autounattend-iso: PowerShell 7 ZIP not embedded; the guest will download it from the pinned URL (still checksum-verified)" >&2
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
