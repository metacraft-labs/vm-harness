#!/usr/bin/env bash
# fetch-portable-git.sh -- cache + verify the pinned Git for Windows
# (PortableGit) self-extractor for a Windows golden-image build.
#
# Git for Windows is what supplies `bash.exe`; without it every GitHub Actions
# `shell: bash` step fails with "bash: command not found" and `actions/checkout`
# falls back to the REST-API tarball. See guest-recipes/lib/provision-git.ps1
# for the full rationale and for the machine-PATH mechanism.
#
# Staging the archive host-side (rather than letting the guest download it) is
# what makes the golden build work on a NAT'd or offline builder, and it keeps
# the download on the reproducible side of the fence. `provision-git.ps1` falls
# back to downloading in-guest when nothing is staged, but verifies the same
# SHA-256 either way.
#
# The version + checksums are NOT duplicated here: they are parsed out of
# provision-git.ps1, which is the single source of truth. If that file's pin
# block is reshaped, this script fails loudly rather than fetching something
# unpinned.
#
# Usage:
#   ./fetch-portable-git.sh --arch x64      # -> ./build/PortableGit-<ver>-64-bit.7z.exe
#   ./fetch-portable-git.sh --arch arm64    # -> ./build/PortableGit-<ver>-arm64.7z.exe
#   ./fetch-portable-git.sh --arch x64 --output DIR
#
# The default output directory is the `build/` dir of the CALLING recipe when
# VMH_BUILD_DIR is set, else ./build relative to the current directory.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROVISION_PS1="${SCRIPT_DIR}/provision-git.ps1"

ARCH=""
OUT_DIR="${VMH_BUILD_DIR:-$(pwd)/build}"

usage() {
  cat <<EOF
Usage: ./fetch-portable-git.sh --arch <x64|arm64> [--output DIR]

Downloads and SHA-256-verifies the pinned Git for Windows PortableGit
self-extractor. The pin lives in guest-recipes/lib/provision-git.ps1.

  --arch x64 | arm64   which PortableGit asset to fetch (required)
  --output DIR         where to write it (default: \${VMH_BUILD_DIR:-./build})
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      [[ $# -ge 2 ]] || { echo "fetch-portable-git: --arch needs a value" >&2; exit 1; }
      ARCH="$2"; shift 2;;
    --output)
      [[ $# -ge 2 ]] || { echo "fetch-portable-git: --output needs a path" >&2; exit 1; }
      OUT_DIR="$2"; shift 2;;
    --help|-h)
      usage; exit 0;;
    *)
      echo "fetch-portable-git: unrecognized arg '$1'" >&2; usage >&2; exit 1;;
  esac
done

case "${ARCH}" in
  x64|arm64) ;;
  "") echo "fetch-portable-git: --arch is required (x64 or arm64)" >&2; exit 1;;
  *)  echo "fetch-portable-git: unknown --arch '${ARCH}' (want x64 or arm64)" >&2; exit 1;;
esac

if [[ ! -f "${PROVISION_PS1}" ]]; then
  echo "fetch-portable-git: cannot find the pin source ${PROVISION_PS1}" >&2
  exit 1
fi

# Parse the pin block out of provision-git.ps1. Each assignment must be a
# single line of the form:  $Name = 'value'
parse_pin() { # varname
  local name="$1" value
  value="$(sed -n "s/^\\\$${name}[[:space:]]*=[[:space:]]*'\\([^']*\\)'.*/\\1/p" "${PROVISION_PS1}" | head -1)"
  if [[ -z "${value}" ]]; then
    echo "fetch-portable-git: could not parse \$${name} from ${PROVISION_PS1}" >&2
    echo "  the pin block must keep the shape: \$${name} = '<value>'" >&2
    exit 1
  fi
  printf '%s' "${value}"
}

GIT_VERSION="$(parse_pin GitVersion)"
GIT_TAG="$(parse_pin GitTag)"

if [[ "${ARCH}" == "arm64" ]]; then
  ASSET="PortableGit-${GIT_VERSION}-arm64.7z.exe"
  SHA256="$(parse_pin GitSha256Arm64)"
else
  ASSET="PortableGit-${GIT_VERSION}-64-bit.7z.exe"
  SHA256="$(parse_pin GitSha256X64)"
fi

URL="https://github.com/git-for-windows/git/releases/download/${GIT_TAG}/${ASSET}"
OUT="${OUT_DIR}/${ASSET}"

mkdir -p "${OUT_DIR}"

sha_of() { # path
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "fetch-portable-git: need sha256sum or shasum for checksum verification" >&2
    exit 1
  fi
}

if [[ -f "${OUT}" ]] && [[ "$(sha_of "${OUT}")" == "${SHA256}" ]]; then
  echo "fetch-portable-git: ${OUT} already present and matches the pin"
  printf '%s  %s\n' "${SHA256}" "${ASSET}" > "${OUT}.sha256"
  exit 0
fi

tmp="${OUT}.tmp"
rm -f "${tmp}"
echo "fetch-portable-git: downloading ${URL}"
curl -fL --retry 3 --retry-delay 2 -o "${tmp}" "${URL}"

actual="$(sha_of "${tmp}")"
if [[ "${actual}" != "${SHA256}" ]]; then
  rm -f "${tmp}"
  echo "fetch-portable-git: checksum mismatch for ${URL}" >&2
  echo "  expected: ${SHA256}" >&2
  echo "  actual:   ${actual}" >&2
  exit 1
fi

mv "${tmp}" "${OUT}"
printf '%s  %s\n' "${SHA256}" "${ASSET}" > "${OUT}.sha256"
echo "fetch-portable-git: wrote ${OUT} (Git for Windows ${GIT_VERSION}, ${ARCH})"
