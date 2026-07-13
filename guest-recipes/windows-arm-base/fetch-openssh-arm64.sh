#!/usr/bin/env bash
# fetch-openssh-arm64.sh -- cache the official Win32-OpenSSH ARM64 zip.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
OUT="${VMH_OPENSSH_ARM64_ZIP_OUT:-${BUILD_DIR}/OpenSSH-ARM64.zip}"
URL="${VMH_OPENSSH_ARM64_URL:-https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-ARM64.zip}"
SHA256="${VMH_OPENSSH_ARM64_SHA256:-698c6aec31c1dd0fb996206e8741f4531a97355686b5431ef347d531b07fcd42}"

usage() {
  cat <<EOF
Usage: ./fetch-openssh-arm64.sh [--output PATH]

Downloads and verifies the official PowerShell/Win32-OpenSSH
OpenSSH-ARM64.zip asset used as the offline Windows ARM sshd fallback.

Defaults:
  URL:    ${URL}
  output: ${OUT}
  sha256: ${SHA256}

Environment overrides:
  VMH_OPENSSH_ARM64_URL
  VMH_OPENSSH_ARM64_SHA256
  VMH_OPENSSH_ARM64_ZIP_OUT
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { echo "fetch-openssh-arm64: --output needs a path" >&2; exit 1; }
      OUT="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "fetch-openssh-arm64: unrecognized arg '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

mkdir -p "$(dirname -- "${OUT}")"
tmp="${OUT}.tmp"
rm -f "${tmp}"

curl -fL --retry 3 --retry-delay 2 -o "${tmp}" "${URL}"

if command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "${tmp}" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "${tmp}" | awk '{print $1}')"
else
  rm -f "${tmp}"
  echo "fetch-openssh-arm64: need shasum or sha256sum for checksum verification" >&2
  exit 1
fi
if [[ "${actual}" != "${SHA256}" ]]; then
  rm -f "${tmp}"
  echo "fetch-openssh-arm64: checksum mismatch for ${URL}" >&2
  echo "  expected: ${SHA256}" >&2
  echo "  actual:   ${actual}" >&2
  exit 1
fi

mv "${tmp}" "${OUT}"
printf '%s  %s\n' "${SHA256}" "$(basename -- "${OUT}")" > "${OUT}.sha256"
echo "fetch-openssh-arm64: wrote ${OUT}"
