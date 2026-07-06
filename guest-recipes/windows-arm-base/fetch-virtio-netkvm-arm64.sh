#!/usr/bin/env bash
# fetch-virtio-netkvm-arm64.sh -- cache ARM64 VirtIO NetKVM drivers.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
ARCHIVE_OUT="${VMH_VIRTIO_NETKVM_ARM64_ARCHIVE_OUT:-${BUILD_DIR}/virtio-win-0.1.285.tar.xz}"
DRIVER_OUT="${VMH_VIRTIO_NETKVM_ARM64_DIR_OUT:-${BUILD_DIR}/virtio/NetKVM/w11/ARM64}"
URL="${VMH_VIRTIO_NETKVM_ARM64_URL:-https://github.com/qemus/virtiso-arm/releases/download/v0.1.285-1/virtio-win-0.1.285.tar.xz}"
SHA256="${VMH_VIRTIO_NETKVM_ARM64_SHA256:-c6712f8d5730c09c1212be9fc3baa18b78534f3c8c136cf02b2cca46515ca310}"
MEMBER_ROOT="NetKVM/w11/ARM64"

usage() {
  cat <<EOF
Usage: ./fetch-virtio-netkvm-arm64.sh [--archive PATH] [--driver-dir PATH]

Downloads and verifies the slim ARM64 virtio-win tarball from qemus/virtiso-arm,
then extracts NetKVM/w11/ARM64 for offline installation in Windows ARM guests.

Defaults:
  URL:        ${URL}
  archive:    ${ARCHIVE_OUT}
  driver-dir: ${DRIVER_OUT}
  sha256:     ${SHA256}

Environment overrides:
  VMH_VIRTIO_NETKVM_ARM64_URL
  VMH_VIRTIO_NETKVM_ARM64_SHA256
  VMH_VIRTIO_NETKVM_ARM64_ARCHIVE_OUT
  VMH_VIRTIO_NETKVM_ARM64_DIR_OUT
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)
      [[ $# -ge 2 ]] || { echo "fetch-virtio-netkvm-arm64: --archive needs a path" >&2; exit 1; }
      ARCHIVE_OUT="$2"
      shift 2
      ;;
    --driver-dir)
      [[ $# -ge 2 ]] || { echo "fetch-virtio-netkvm-arm64: --driver-dir needs a path" >&2; exit 1; }
      DRIVER_OUT="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "fetch-virtio-netkvm-arm64: unrecognized arg '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

mkdir -p "${BUILD_DIR}" "$(dirname -- "${ARCHIVE_OUT}")" "$(dirname -- "${DRIVER_OUT}")"
tmp="${ARCHIVE_OUT}.tmp"
rm -f "${tmp}"

curl -fL --retry 3 --retry-delay 2 -o "${tmp}" "${URL}"

if command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "${tmp}" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "${tmp}" | awk '{print $1}')"
else
  rm -f "${tmp}"
  echo "fetch-virtio-netkvm-arm64: need shasum or sha256sum for checksum verification" >&2
  exit 1
fi
if [[ "${actual}" != "${SHA256}" ]]; then
  rm -f "${tmp}"
  echo "fetch-virtio-netkvm-arm64: checksum mismatch for ${URL}" >&2
  echo "  expected: ${SHA256}" >&2
  echo "  actual:   ${actual}" >&2
  exit 1
fi

member_list="${tmp}.members"
rm -f "${member_list}"
tar -tf "${tmp}" > "${member_list}"
if ! grep -qx "${MEMBER_ROOT}/netkvm.inf" "${member_list}"; then
  rm -f "${member_list}"
  rm -f "${tmp}"
  echo "fetch-virtio-netkvm-arm64: archive does not contain ${MEMBER_ROOT}/netkvm.inf" >&2
  exit 1
fi
rm -f "${member_list}"

mv "${tmp}" "${ARCHIVE_OUT}"
printf '%s  %s\n' "${SHA256}" "$(basename -- "${ARCHIVE_OUT}")" > "${ARCHIVE_OUT}.sha256"

extract_tmp="$(mktemp -d "${BUILD_DIR}/virtio-extract.XXXXXX")"
cleanup() {
  chmod -R u+w "${extract_tmp}" 2>/dev/null || true
  rm -rf "${extract_tmp}"
}
trap cleanup EXIT

tar -xf "${ARCHIVE_OUT}" -C "${extract_tmp}" "NetKVM"
chmod -R u+w "${extract_tmp}/NetKVM" 2>/dev/null || true
driver_parent="$(dirname -- "${DRIVER_OUT}")"
if [[ -e "${DRIVER_OUT}" ]]; then
  chmod -R u+w "${DRIVER_OUT}" 2>/dev/null || true
fi
if [[ -d "${driver_parent}" ]]; then
  chmod u+w "${driver_parent}" 2>/dev/null || true
fi
rm -rf "${DRIVER_OUT}"
mkdir -p "${driver_parent}"
chmod u+w "${driver_parent}" 2>/dev/null || true
mv "${extract_tmp}/${MEMBER_ROOT}" "${DRIVER_OUT}"
chmod -R u+w "${DRIVER_OUT}" 2>/dev/null || true

if [[ ! -f "${DRIVER_OUT}/netkvm.inf" ]]; then
  echo "fetch-virtio-netkvm-arm64: extracted driver missing ${DRIVER_OUT}/netkvm.inf" >&2
  exit 1
fi

echo "fetch-virtio-netkvm-arm64: wrote ${ARCHIVE_OUT}"
echo "fetch-virtio-netkvm-arm64: extracted ${DRIVER_OUT}"
