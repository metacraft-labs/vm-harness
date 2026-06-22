#!/usr/bin/env bash
# finalize-golden.sh — confirm the libvirt domain is defined, in the
# shut-off state, and (optionally) detach the install media so per-
# boot startups don't re-mount the autounattend / Windows ISOs.
#
# Run this AFTER:
#   1. `vm-harness provision --backend libvirt --recipe windows-x64-base
#      --name <name> --first-boot-script ./bootstrap.ps1` finished
#      successfully (or the operator ran virt-install directly).
#   2. The Win11 autounattend installation completed (the marker file
#      C:\Windows\Temp\repro-install-done exists in the guest).
#   3. The guest is shut off (the autounattend's last step does NOT
#      shut down; we ACPI-shutdown via `virsh shutdown <name>`).
#
# What this does:
#   1. Asserts `virsh list --all --name` shows the domain.
#   2. Asserts `virsh domstate <name>` returns "shut off".
#   3. Asserts the qcow2 disk exists under the libvirt image pool.
#   4. Detaches the Windows install ISO and the autounattend ISO from
#      the domain so subsequent boots come straight off the qcow2.
#   5. Marks the domain `virsh autostart <name>` so a host reboot
#      brings the runner back online automatically.
#
# Optional:
#   --keep-isos       Do NOT detach the install ISOs (useful when
#                     debugging a half-completed install).
#   --no-autostart    Do NOT mark the domain autostart.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DOMAIN="${VMH_LIBVIRT_DOMAIN:-windows-runner-001}"
LIBVIRT_URI="${VMH_LIBVIRT_URI:-qemu:///system}"
IMAGE_POOL_DIR="${VMH_LIBVIRT_POOL_DIR:-/var/lib/libvirt/images}"
KEEP_ISOS=0
SET_AUTOSTART=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2;;
    --keep-isos) KEEP_ISOS=1; shift;;
    --no-autostart) SET_AUTOSTART=0; shift;;
    --help|-h) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "finalize-golden: unrecognized arg '$1'" >&2; exit 1;;
  esac
done

if ! command -v virsh >/dev/null 2>&1; then
  echo "finalize-golden: virsh not on PATH (install libvirt-clients)" >&2
  exit 1
fi

VIRSH=(virsh --connect "${LIBVIRT_URI}")

# 1. Domain exists.
if ! "${VIRSH[@]}" dominfo "${DOMAIN}" >/dev/null 2>&1; then
  echo "finalize-golden: libvirt domain '${DOMAIN}' is not defined on ${LIBVIRT_URI}" >&2
  exit 1
fi

# 2. Domain is shut off.
STATE=$("${VIRSH[@]}" domstate "${DOMAIN}" | tr -d '[:space:]')
if [[ "${STATE}" != "shutoff" ]]; then
  echo "finalize-golden: domain ${DOMAIN} state is '${STATE}', expected 'shut off'." >&2
  echo "  Run: virsh --connect ${LIBVIRT_URI} shutdown ${DOMAIN}" >&2
  exit 1
fi

# 3. Disk exists.
DISK_PATH="${IMAGE_POOL_DIR}/${DOMAIN}.qcow2"
if [[ ! -f "${DISK_PATH}" ]]; then
  echo "finalize-golden: qcow2 not found at ${DISK_PATH}" >&2
  echo "  Override the search path with VMH_LIBVIRT_POOL_DIR=..." >&2
  exit 1
fi
echo "finalize-golden: disk found at ${DISK_PATH}"
qemu-img info "${DISK_PATH}" | head -5 || true

# 4. Detach install ISOs (unless --keep-isos).
if [[ ${KEEP_ISOS} -eq 0 ]]; then
  # Enumerate the CD-ROM targets attached to the domain. virsh dumpxml
  # produces the source-file paths in <disk device='cdrom'>; we use a
  # python one-liner to keep this script portable (awk-on-multi-line-
  # XML is fragile).
  CDROMS=$("${VIRSH[@]}" dumpxml "${DOMAIN}" \
           | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
for d in root.iter('disk'):
    if d.get('device') != 'cdrom':
        continue
    src = d.find('source')
    tgt = d.find('target')
    if tgt is None: continue
    bus = tgt.get('bus','sata')
    dev = tgt.get('dev','')
    print(dev)
")
  for dev in ${CDROMS}; do
    echo "finalize-golden: detaching CD-ROM ${dev}"
    "${VIRSH[@]}" change-media "${DOMAIN}" "${dev}" --eject --config || true
  done
else
  echo "finalize-golden: --keep-isos set; not detaching install media"
fi

# 5. Autostart.
if [[ ${SET_AUTOSTART} -eq 1 ]]; then
  "${VIRSH[@]}" autostart "${DOMAIN}" >/dev/null
  echo "finalize-golden: domain ${DOMAIN} marked autostart"
fi

echo
echo "Done. The harness can now manage this domain via:"
echo "  vm-harness run --backend libvirt --baseline ${DOMAIN} -- powershell -Command hostname"
