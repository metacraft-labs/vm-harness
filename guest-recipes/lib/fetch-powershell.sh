#!/usr/bin/env bash
# fetch-powershell.sh -- cache + verify the pinned PowerShell 7 (`pwsh`)
# standalone ZIP for a Windows golden-image build.
#
# PowerShell 7 is what supplies `pwsh.exe`; without it every GitHub Actions
# `shell: pwsh` step on a clone of the golden fails with
# "pwsh: command not found", as does anything that shells out to `pwsh`
# directly (the `dev-exec.cmd` trampoline setup-dev-env generates, codetracer's
# `pwsh -File ...` bootstrap steps, `just` on Windows). See
# guest-recipes/lib/provision-pwsh.ps1 for the full rationale and for the
# machine-PATH mechanism.
#
# Staging the archive host-side (rather than letting the guest download it) is
# what makes the golden build work on a NAT'd or offline builder, and it keeps
# the download on the reproducible side of the fence. `provision-pwsh.ps1`
# falls back to downloading in-guest when nothing is staged, but verifies the
# same SHA-256 either way.
#
# The version + checksums are NOT duplicated here: they are parsed out of
# provision-pwsh.ps1, which is the single source of truth. Two copies of a
# checksum is one copy too many -- the day they diverge, the host stages one
# build and the guest verifies another. If that file's pin block is reshaped,
# this script fails loudly rather than fetching something unpinned.
#
# Usage:
#   ./fetch-powershell.sh --arch x64      # -> ./build/PowerShell-<ver>-win-x64.zip
#   ./fetch-powershell.sh --arch arm64    # -> ./build/PowerShell-<ver>-win-arm64.zip
#   ./fetch-powershell.sh --arch x64 --output DIR
#
# The default output directory is the `build/` dir of the CALLING recipe when
# VMH_BUILD_DIR is set, else ./build relative to the current directory.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROVISION_PS1="${SCRIPT_DIR}/provision-pwsh.ps1"

ARCH=""
OUT_DIR="${VMH_BUILD_DIR:-$(pwd)/build}"

usage() {
  cat <<EOF
Usage: ./fetch-powershell.sh --arch <x64|arm64> [--output DIR]

Downloads and SHA-256-verifies the pinned PowerShell 7 standalone ZIP. The pin
lives in guest-recipes/lib/provision-pwsh.ps1.

  --arch x64 | arm64   which PowerShell asset to fetch (required)
  --output DIR         where to write it (default: \${VMH_BUILD_DIR:-./build})
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      [[ $# -ge 2 ]] || { echo "fetch-powershell: --arch needs a value" >&2; exit 1; }
      ARCH="$2"; shift 2;;
    --output)
      [[ $# -ge 2 ]] || { echo "fetch-powershell: --output needs a path" >&2; exit 1; }
      OUT_DIR="$2"; shift 2;;
    --help|-h)
      usage; exit 0;;
    *)
      echo "fetch-powershell: unrecognized arg '$1'" >&2; usage >&2; exit 1;;
  esac
done

case "${ARCH}" in
  x64|arm64) ;;
  "") echo "fetch-powershell: --arch is required (x64 or arm64)" >&2; exit 1;;
  *)  echo "fetch-powershell: unknown --arch '${ARCH}' (want x64 or arm64)" >&2; exit 1;;
esac

if [[ ! -f "${PROVISION_PS1}" ]]; then
  echo "fetch-powershell: cannot find the pin source ${PROVISION_PS1}" >&2
  exit 1
fi

# Parse the pin block out of provision-pwsh.ps1. Each assignment must be a
# single line of the form:  $Name = 'value'
parse_pin() { # varname
  local name="$1" value
  value="$(sed -n "s/^\\\$${name}[[:space:]]*=[[:space:]]*'\\([^']*\\)'.*/\\1/p" "${PROVISION_PS1}" | head -1)"
  if [[ -z "${value}" ]]; then
    echo "fetch-powershell: could not parse \$${name} from ${PROVISION_PS1}" >&2
    echo "  the pin block must keep the shape: \$${name} = '<value>'" >&2
    exit 1
  fi
  printf '%s' "${value}"
}

PWSH_VERSION="$(parse_pin PwshVersion)"

if [[ "${ARCH}" == "arm64" ]]; then
  ASSET="PowerShell-${PWSH_VERSION}-win-arm64.zip"
  SHA256="$(parse_pin PwshSha256Arm64)"
else
  ASSET="PowerShell-${PWSH_VERSION}-win-x64.zip"
  SHA256="$(parse_pin PwshSha256X64)"
fi

URL="https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/${ASSET}"
OUT="${OUT_DIR}/${ASSET}"

mkdir -p "${OUT_DIR}"

sha_of() { # path
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "fetch-powershell: need sha256sum or shasum for checksum verification" >&2
    exit 1
  fi
}

if [[ -f "${OUT}" ]] && [[ "$(sha_of "${OUT}")" == "${SHA256}" ]]; then
  echo "fetch-powershell: ${OUT} already present and matches the pin"
  printf '%s  %s\n' "${SHA256}" "${ASSET}" > "${OUT}.sha256"
  exit 0
fi

tmp="${OUT}.tmp"
rm -f "${tmp}"
echo "fetch-powershell: downloading ${URL}"
curl -fL --retry 3 --retry-delay 2 -o "${tmp}" "${URL}"

actual="$(sha_of "${tmp}")"
if [[ "${actual}" != "${SHA256}" ]]; then
  rm -f "${tmp}"
  echo "fetch-powershell: checksum mismatch for ${URL}" >&2
  echo "  expected: ${SHA256}" >&2
  echo "  actual:   ${actual}" >&2
  exit 1
fi

mv "${tmp}" "${OUT}"
printf '%s  %s\n' "${SHA256}" "${ASSET}" > "${OUT}.sha256"
echo "fetch-powershell: wrote ${OUT} (PowerShell ${PWSH_VERSION}, ${ARCH})"
