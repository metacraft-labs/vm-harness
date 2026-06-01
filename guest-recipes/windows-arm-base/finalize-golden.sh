#!/usr/bin/env bash
# finalize-golden.sh — strip the install ISOs from the golden bundle
# and confirm it's registered with UTM under the expected name.
#
# Run this AFTER:
#   1. ./create-utm-bundle.sh has opened the bundle in UTM.
#   2. The Windows install finished (C:\Windows\Temp\repro-install-done
#      sentinel exists in the guest).
#   3. You ran the manual SysPrep step from README §5 inside the guest,
#      and the VM has shut down.
#
# What this does:
#   1. Verifies the VM is registered with UTM via `utmctl list`.
#   2. Verifies the VM is stopped.
#   3. Detaches the Windows ISO and autounattend ISO from the bundle's
#      config.plist so per-gate clones boot straight off the qcow2.
#   4. Verifies `utmctl status repro-windows-arm-base` returns "stopped".

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
BUNDLE_NAME="${VMH_GOLDEN_BUNDLE_NAME:-repro-windows-arm-base}"
BUNDLE_PATH="${BUILD_DIR}/${BUNDLE_NAME}.utm"
CONFIG_PATH="${BUNDLE_PATH}/config.plist"

if ! command -v utmctl >/dev/null 2>&1; then
  echo "finalize-golden: utmctl not on PATH (brew install --cask utm)" >&2
  exit 1
fi

if [[ ! -d "${BUNDLE_PATH}" ]]; then
  echo "finalize-golden: bundle ${BUNDLE_PATH} does not exist." >&2
  echo "  run create-utm-bundle.sh first." >&2
  exit 1
fi
if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "finalize-golden: bundle is malformed — missing config.plist." >&2
  exit 1
fi

# 1. Check the VM is registered with UTM under the right name.
if ! utmctl list 2>/dev/null | awk 'NR>1 {print $NF}' | grep -qx "${BUNDLE_NAME}"; then
  echo "finalize-golden: ${BUNDLE_NAME} is not registered with UTM." >&2
  echo "  Double-click ${BUNDLE_PATH} in Finder to register it, then re-run." >&2
  exit 1
fi

# 2. Check it's stopped.
STATUS=$(utmctl status "${BUNDLE_NAME}" 2>/dev/null | tr -d '[:space:]')
if [[ "${STATUS}" != "stopped" ]]; then
  echo "finalize-golden: ${BUNDLE_NAME} status is '${STATUS}', expected 'stopped'." >&2
  echo "  Wait for the SysPrep shutdown to complete, then re-run." >&2
  exit 1
fi

# 3. Strip the External=true CD entries from config.plist so per-gate
# clones don't try to re-mount the install ISOs (which may have moved
# or been deleted by then). Uses /usr/libexec/PlistBuddy which ships
# with macOS.
PB=/usr/libexec/PlistBuddy
if [[ ! -x "${PB}" ]]; then
  echo "finalize-golden: /usr/libexec/PlistBuddy not found (this is macOS-only)" >&2
  exit 1
fi

# Walk the Drives array, identify CD/External entries, and remove them.
# Iterate from the end backwards because PlistBuddy's `Delete` shifts
# subsequent indices.
DRIVE_COUNT=$("${PB}" -c "Print :Drives" "${CONFIG_PATH}" \
              | grep -cE '^    Dict \{' || true)
for ((i=DRIVE_COUNT-1; i>=0; i--)); do
  IMAGE_TYPE=$("${PB}" -c "Print :Drives:${i}:ImageType" "${CONFIG_PATH}" 2>/dev/null || echo "")
  EXTERNAL=$("${PB}" -c "Print :Drives:${i}:External" "${CONFIG_PATH}" 2>/dev/null || echo "")
  if [[ "${IMAGE_TYPE}" == "CD" && "${EXTERNAL}" == "true" ]]; then
    echo "finalize-golden: removing Drive ${i} (${IMAGE_TYPE}, External=${EXTERNAL})"
    "${PB}" -c "Delete :Drives:${i}" "${CONFIG_PATH}"
  fi
done

# 4. Final verification.
echo "finalize-golden: bundle stripped. Final state:"
utmctl list 2>/dev/null | head -1
utmctl list 2>/dev/null | awk -v n="${BUNDLE_NAME}" 'NR>1 && $NF==n'

echo
echo "Done. The harness can now clone this bundle via:"
echo "  vm-harness run --backend utm-windows-arm --baseline ${BUNDLE_NAME} -- cmd /c hostname"
echo
echo "Or run the M3 verification tests:"
echo "  cd $(dirname "${SCRIPT_DIR}")/../.. && nimble test"
