#!/usr/bin/env bash
# create-utm-bundle.sh — assemble the UTM bundle skeleton and open UTM
# so the Windows install can proceed.
#
# Why not fully automated? UTM doesn't expose a CLI primitive to import
# a config.plist + qcow2 directly; bundles are GUI-imported via
# double-click in Finder or by dragging onto the UTM app. We assemble
# the bundle skeleton and let the user double-click it.
#
# Inputs (must exist before running):
#
#   ./build/win11-arm-insider.iso     — produced by fetch-iso.sh (or
#                                       VMH_WIN11_ARM_ISO override)
#   ./build/autounattend.iso          — produced by build-autounattend-iso.sh
#
# Outputs:
#
#   ./build/repro-windows-arm-base.utm/     — UTM bundle directory
#       Data/
#         disk.qcow2                        — empty 64 GB qcow2
#       config.plist                        — UTM v4 config
#
# Then opens UTM via `open -a UTM ./build/repro-windows-arm-base.utm`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
BUNDLE_NAME="${VMH_GOLDEN_BUNDLE_NAME:-repro-windows-arm-base}"
BUNDLE_PATH="${BUILD_DIR}/${BUNDLE_NAME}.utm"
DATA_DIR="${BUNDLE_PATH}/Data"
DISK_PATH="${DATA_DIR}/disk.qcow2"
CONFIG_PATH="${BUNDLE_PATH}/config.plist"
DISK_SIZE="${VMH_GOLDEN_DISK_SIZE:-64G}"

WIN_ISO="${VMH_WIN11_ARM_ISO:-${BUILD_DIR}/win11-arm-insider.iso}"
UNATTEND_ISO="${BUILD_DIR}/autounattend.iso"

if [[ ! -f "${WIN_ISO}" ]]; then
  echo "create-utm-bundle: Windows ISO not found at ${WIN_ISO}" >&2
  echo "  run fetch-iso.sh first, or set VMH_WIN11_ARM_ISO to an existing ISO" >&2
  exit 1
fi
if [[ ! -f "${UNATTEND_ISO}" ]]; then
  echo "create-utm-bundle: autounattend.iso not found at ${UNATTEND_ISO}" >&2
  echo "  run build-autounattend-iso.sh first" >&2
  exit 1
fi

if ! command -v qemu-img >/dev/null 2>&1; then
  echo "create-utm-bundle: qemu-img not on PATH (brew install qemu, or use the flake dev shell)" >&2
  exit 1
fi

if [[ -d "${BUNDLE_PATH}" ]]; then
  echo "create-utm-bundle: ${BUNDLE_PATH} already exists. Remove it (or pass" \
       "VMH_GOLDEN_BUNDLE_NAME=<other-name>) and re-run." >&2
  exit 1
fi

mkdir -p "${DATA_DIR}"

# 1. Allocate the empty disk.
qemu-img create -f qcow2 "${DISK_PATH}" "${DISK_SIZE}"

# 2. Write the config.plist. The schema below is UTM 4.5+ (newer
# `ConfigurationVersion: 5`); UTM also accepts the same bundle layout
# for earlier 4.x releases as long as the config can be parsed.
UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')

cat > "${CONFIG_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>ConfigurationVersion</key><integer>5</integer>
  <key>Backend</key><string>QEMU</string>
  <key>Information</key>
  <dict>
    <key>Name</key><string>${BUNDLE_NAME}</string>
    <key>Notes</key><string>vm-harness Windows-on-ARM golden bundle. Built via vm-harness/guest-recipes/windows-arm-base/.</string>
    <key>UUID</key><string>${UUID}</string>
    <key>IconCustom</key><false/>
  </dict>
  <key>System</key>
  <dict>
    <key>Architecture</key><string>aarch64</string>
    <key>Target</key><string>virt</string>
    <key>CPU</key><string>default</string>
    <key>CPUCount</key><integer>4</integer>
    <key>ForceMulticore</key><true/>
    <key>MemorySize</key><integer>8192</integer>
    <key>JITCacheSize</key><integer>0</integer>
    <key>BootUEFI</key><true/>
    <key>RTCLocalTime</key><false/>
  </dict>
  <key>QEMU</key>
  <dict>
    <key>HypervisorEnabled</key><true/>
    <key>UEFIBoot</key><true/>
    <key>RNGEnabled</key><true/>
    <key>BalloonEnabled</key><true/>
    <key>TPMEnabled</key><true/>
    <key>PS2ControllerEnabled</key><false/>
  </dict>
  <key>Drives</key>
  <array>
    <!-- Drive 0: the empty Windows disk. -->
    <dict>
      <key>Identifier</key><string>drive0</string>
      <key>ImagePath</key><string>disk.qcow2</string>
      <key>ImageType</key><string>Disk</string>
      <key>Interface</key><string>VirtIO</string>
      <key>ReadOnly</key><false/>
      <key>External</key><false/>
    </dict>
    <!-- Drive 1: the Windows 11 ARM Setup ISO. -->
    <dict>
      <key>Identifier</key><string>drive1</string>
      <key>ImagePath</key><string>${WIN_ISO}</string>
      <key>ImageType</key><string>CD</string>
      <key>Interface</key><string>USB</string>
      <key>ReadOnly</key><true/>
      <key>External</key><true/>
    </dict>
    <!-- Drive 2: the autounattend.iso. Setup looks at every attached
         removable medium for autounattend.xml at the root. -->
    <dict>
      <key>Identifier</key><string>drive2</string>
      <key>ImagePath</key><string>${UNATTEND_ISO}</string>
      <key>ImageType</key><string>CD</string>
      <key>Interface</key><string>USB</string>
      <key>ReadOnly</key><true/>
      <key>External</key><true/>
    </dict>
  </array>
  <key>Networks</key>
  <array>
    <dict>
      <key>Mode</key><string>Shared</string>
      <key>HardwareModel</key><string>virtio-net-pci</string>
      <key>IsolateFromHost</key><false/>
    </dict>
  </array>
  <key>Serial</key>
  <array/>
  <key>Sound</key>
  <array/>
  <key>Displays</key>
  <array>
    <dict>
      <key>HardwareModel</key><string>virtio-ramfb-gl</string>
      <key>WidthPixels</key><integer>1280</integer>
      <key>HeightPixels</key><integer>800</integer>
      <key>PixelDensity</key><integer>72</integer>
      <key>NativeResolution</key><true/>
      <key>DownscalingFilter</key><string>Linear</string>
      <key>UpscalingFilter</key><string>Linear</string>
    </dict>
  </array>
  <key>Input</key>
  <dict>
    <key>USB3Support</key><true/>
    <key>MaximumUSBShare</key><integer>3</integer>
  </dict>
  <key>SharedDirectories</key>
  <array/>
</dict>
</plist>
EOF

echo "create-utm-bundle: wrote ${BUNDLE_PATH}"
echo "create-utm-bundle: now opening it in UTM..."
echo
echo "Follow-up manual steps:"
echo "  1. UTM will show the bundle in its sidebar. Click the play"
echo "     icon to start the install."
echo "  2. Windows Setup will run unattended via autounattend.xml."
echo "     Wait until the desktop appears and C:\\Windows\\Temp\\"
echo "     repro-install-done exists (5-30 minutes)."
echo "  3. Then run the manual SysPrep step from README §5."
echo "  4. Finally, run ./finalize-golden.sh."
echo

open -a UTM "${BUNDLE_PATH}"
