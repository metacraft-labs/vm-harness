#!/usr/bin/env bash
# build-sysprep-golden.sh — produce a sysprepped/generalized Windows golden.
#
# The Windows analog of linux-x64-runner/build-runner-image.sh. It turns the
# cloudbase-init golden (`/storage/iso/golden-win11-cloudbase.qcow2`, whose
# clones all SHARE the base machine SID + hostname) into a
# `/generalize`d golden (`golden-win11-cloudbase-sysprepped.qcow2`) whose CoW
# clones each get a FRESH, DISTINCT machine SID + hostname on first boot —
# what production needs so fleet-scale ephemeral runners don't collide on a
# duplicate SID (AD / telemetry / WSUS).
#
# This is FU5 (WIN-SYSPREP) in reprobuild-specs/
# Production-Runners-And-Shared-Store.milestones.org. It encodes the exact
# procedure — including the component-store repair (`DISM /ResetBase`) that
# UNBLOCKS the sysprep — that the M3 recipe notes
# (cloudbase-init-golden.md §"Sysprep /generalize") documented as the required
# fix after the first attempt failed at the clone specialize pass.
#
# ────────────────────────────────────────────────────────────────────────────
# SAFETY (production Windows infra):
#   * The live golden ($SRC_GOLDEN) is NEVER mutated. The script works on a
#     FULL standalone COPY ($WORK) and writes a SIDE artifact ($OUT_GOLDEN) —
#     it never overwrites $SRC_GOLDEN and never touches windows-runner-001.
#   * The throwaway work domain has a distinct name ($WORK_DOMAIN, default
#     `fu5-sysprep-work`); it is destroyed + undefined (--nvram) on exit.
#   * Capture happens the instant the guest powers off after
#     `sysprep … /shutdown`, BEFORE any reboot: booting a generalized image
#     CONSUMES the generalize (re-specializes it), so the golden is captured
#     cold.
# ────────────────────────────────────────────────────────────────────────────
#
# WHY DISM /ResetBase (the unblock):
#   The base golden carried an orphaned incomplete CBS servicing session. On
#   the first sysprep attempt, `/generalize` deprovisioned Feature-on-Demand
#   packages (Kernel-LA57-FoD, DirectX-Database-FOD) but the pending removals
#   could not commit, so every CoW clone died at the mini-setup SPECIALIZE pass
#   with "Windows could not finish configuring the system" (setupact.log:
#   ERROR_NOT_FOUND / CbsExecuteStateFailed). `DISM /Online /Cleanup-Image
#   /StartComponentCleanup /ResetBase` finalizes the pending session AND drops
#   the superseded FoD payloads, so `/generalize` no longer creates
#   un-committable transactions. Plain StartComponentCleanup (no /ResetBase)
#   did NOT clear it — /ResetBase is the load-bearing flag.
#
# PROCEDURE (each step below):
#   1. Full standalone COPY of the golden (never touch the original).
#   2. Boot a bounded throwaway UEFI/OVMF Win11 domain off the copy.
#   3. SSH in (admin / $GUEST_PASSWORD) and, in the guest:
#        a. DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase
#           (the component-store repair — the unblock), then reboot to settle.
#        b. Clear the reserved-storage servicing scenario so /generalize
#           validation passes (ShippedWithReserves=0 alone is NOT enough).
#        c. sysprep /generalize /oobe /shutdown /quiet /unattend:<rearm> —
#           /quiet is MANDATORY (a modal validation error in Session-0 would
#           hang sysprep forever holding its mutex).
#   4. Wait for the guest to power off, then CAPTURE the work copy cold into
#      $OUT_GOLDEN (a SIDE artifact — NOT the live golden).
#   5. Destroy + undefine the throwaway domain; remove the work copy + nvram.
#
# The distinct-SID PROOF is a separate step — the gate
# tests/e2e/windows-sysprep/run-sysprep-identity-gate.sh (or the infra
# two-layer gate checks/t_windows_sysprep_golden.sh) boots TWO clones of
# $OUT_GOLDEN and asserts their machine SIDs + hostnames DIFFER. This script
# only PRODUCES the golden; run the gate against it afterwards.
#
# Usage:
#   ./build-sysprep-golden.sh                       # full run (needs KVM+root)
#   VMH_SYSPREP_DRY_RUN=1 ./build-sysprep-golden.sh # print the plan, do nothing
#   VMH_SRC_GOLDEN=/storage/iso/golden-win11-cloudbase.qcow2 \
#   VMH_OUT_GOLDEN=/storage/iso/golden-win11-cloudbase-sysprepped.qcow2 \
#     ./build-sysprep-golden.sh
#
# Env:
#   VMH_SRC_GOLDEN     source cloudbase-init golden (NEVER mutated)
#                        (default /storage/iso/golden-win11-cloudbase.qcow2)
#   VMH_OUT_GOLDEN     output sysprepped golden (SIDE artifact)
#                        (default /storage/iso/golden-win11-cloudbase-sysprepped.qcow2)
#   VMH_WORK_QCOW2     throwaway full copy worked on
#                        (default /storage/scratch/fu5-sysprep-work.qcow2)
#   VMH_WORK_DOMAIN    throwaway libvirt domain name (default fu5-sysprep-work)
#   VMH_GUEST_PASSWORD guest admin password (default repro-windows-x64)
#   VMH_OVMF_CODE      OVMF code fd (default /run/libvirt/nix-ovmf/edk2-x86_64-code.fd)
#   VMH_OVMF_VARS      OVMF vars template fd (default …/edk2-i386-vars.fd)
#   VMH_VCPUS          work-VM vcpus (default 4 — keep modest on a busy host)
#   VMH_MEMORY_MB      work-VM RAM MiB (default 6144)
#   LIBVIRT_DEFAULT_URI  libvirt URI (default qemu:///system)
#   VMH_DISM_TIMEOUT   seconds to allow the DISM /ResetBase (default 2700)
#   VMH_SYSPREP_TIMEOUT seconds to allow sysprep + shutdown (default 1800)
#   VMH_VIRSH / VMH_QEMU_IMG  command overrides (default `virsh` / `qemu-img`;
#                        on the host pass e.g. VMH_VIRSH="sudo -n virsh")
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

SRC_GOLDEN="${VMH_SRC_GOLDEN:-/storage/iso/golden-win11-cloudbase.qcow2}"
OUT_GOLDEN="${VMH_OUT_GOLDEN:-/storage/iso/golden-win11-cloudbase-sysprepped.qcow2}"
WORK="${VMH_WORK_QCOW2:-/storage/scratch/fu5-sysprep-work.qcow2}"
WORK_DOMAIN="${VMH_WORK_DOMAIN:-fu5-sysprep-work}"
GUEST_PASSWORD="${VMH_GUEST_PASSWORD:-repro-windows-x64}"
OVMF_CODE="${VMH_OVMF_CODE:-/run/libvirt/nix-ovmf/edk2-x86_64-code.fd}"
OVMF_VARS="${VMH_OVMF_VARS:-/run/libvirt/nix-ovmf/edk2-i386-vars.fd}"
VCPUS="${VMH_VCPUS:-4}"
MEMORY_MB="${VMH_MEMORY_MB:-6144}"
URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
DISM_TIMEOUT="${VMH_DISM_TIMEOUT:-2700}"
SYSPREP_TIMEOUT="${VMH_SYSPREP_TIMEOUT:-1800}"
REARM_UNATTEND="${VMH_REARM_UNATTEND:-$SCRIPT_DIR/rearm-unattend.xml}"
GIT_GATE_PS1="${VMH_GIT_GATE_PS1:-$SCRIPT_DIR/../lib/assert-git-provisioned.ps1}"
PWSH_GATE_PS1="${VMH_PWSH_GATE_PS1:-$SCRIPT_DIR/../lib/assert-pwsh-provisioned.ps1}"
DEFENDER_GATE_PS1="${VMH_DEFENDER_GATE_PS1:-$SCRIPT_DIR/../lib/assert-defender-exclusions-sane.ps1}"
DRY_RUN="${VMH_SYSPREP_DRY_RUN:-}"

# shellcheck disable=SC2206
VIRSH=(${VMH_VIRSH:-virsh} -c "$URI")
# shellcheck disable=SC2206
QEMU_IMG=(${VMH_QEMU_IMG:-qemu-img})

WORK_NVRAM="${WORK%.qcow2}_VARS.fd"
WORK_XML="$(mktemp /tmp/fu5-sysprep-XXXXXX.xml)"

log()  { echo "[sysprep-golden] $*"; }
fail() { echo "[sysprep-golden][FAIL] $*" >&2; exit 1; }

cleanup() {
  "${VIRSH[@]}" destroy   "$WORK_DOMAIN" >/dev/null 2>&1 || true
  "${VIRSH[@]}" undefine  "$WORK_DOMAIN" --nvram >/dev/null 2>&1 || true
  rm -f "$WORK" "$WORK_NVRAM" "$WORK_XML" 2>/dev/null || true
}

ssh_guest() { # ip cmd
  sshpass -p "$GUEST_PASSWORD" ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o LogLevel=ERROR \
    -o PreferredAuthentications=password "admin@$1" "$2"
}

guest_ip() { # domain -> prints ip or empty
  local ip
  ip=$("${VIRSH[@]}" domifaddr "$1" --source agent 2>/dev/null \
        | grep -oE '192\.168\.122\.[0-9]+' | head -1)
  [[ -z "$ip" ]] && ip=$("${VIRSH[@]}" domifaddr "$1" 2>/dev/null \
        | grep -oE '192\.168\.122\.[0-9]+' | head -1)
  echo "$ip"
}

# ── preflight ───────────────────────────────────────────────────────────────
[[ -f "$SRC_GOLDEN" ]] || fail "source golden not found: $SRC_GOLDEN"
[[ "$OUT_GOLDEN" != "$SRC_GOLDEN" ]] || fail "refusing: OUT_GOLDEN == SRC_GOLDEN (would overwrite the live golden)"
[[ -f "$REARM_UNATTEND" ]] || fail "re-arm unattend not found: $REARM_UNATTEND"

log "SRC (live, untouched): $SRC_GOLDEN"
log "OUT (side artifact):   $OUT_GOLDEN"
log "WORK (throwaway copy): $WORK"
log "work domain:           $WORK_DOMAIN  (${VCPUS} vcpu / ${MEMORY_MB} MiB)"
log "re-arm unattend:       $REARM_UNATTEND"

if [[ -n "$DRY_RUN" ]]; then
  log "DRY RUN — plan only, no VM booted, no golden written."
  log "  1) qemu-img convert -O qcow2 $SRC_GOLDEN $WORK   (full standalone copy)"
  log "  2) boot $WORK_DOMAIN (UEFI/OVMF, virtio, virbr0)"
  log "  2b) GATE: assert-git-provisioned.ps1 in the guest — abort unless Git for"
  log "      Windows is on the MACHINE PATH and the MSYS toolchain resolves"
  log "      through bin\\bash.exe (VMH_SKIP_GIT_GATE=1 to override, loudly)"
  log "  2c) GATE: assert-pwsh-provisioned.ps1 in the guest — abort unless"
  log "      PowerShell 7 is on the MACHINE PATH and the interpreter runs"
  log "      (VMH_SKIP_PWSH_GATE=1 to override, loudly)"
  log "  3) guest: DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase; reboot"
  log "     guest: clear ReserveManager scenario + Set-ReservedStorageState Disabled"
  log "     guest: sysprep /generalize /oobe /shutdown /quiet /unattend:<rearm>"
  log "  4) qemu-img convert -O qcow2 $WORK $OUT_GOLDEN   (capture cold)"
  log "  5) destroy+undefine $WORK_DOMAIN; rm work copy+nvram"
  log "  then: run the distinct-SID gate against $OUT_GOLDEN"
  exit 0
fi

command -v sshpass >/dev/null || fail "missing tool: sshpass (nix shell nixpkgs#sshpass)"
[[ -c /dev/kvm ]] || fail "/dev/kvm absent — this must run on the KVM host"
[[ -f "$OVMF_CODE" ]] || fail "OVMF code fd not found: $OVMF_CODE"
[[ -f "$OVMF_VARS" ]] || fail "OVMF vars template not found: $OVMF_VARS"

trap cleanup EXIT

# ── step 1: full standalone COPY of the golden (never touch the original) ────
log "step 1/5: copying the golden to a throwaway work image (standalone qcow2)"
mkdir -p "$(dirname "$WORK")"
rm -f "$WORK" "$WORK_NVRAM"
"${QEMU_IMG[@]}" convert -O qcow2 "$SRC_GOLDEN" "$WORK" \
  || fail "qemu-img convert (copy) failed"
cp "$OVMF_VARS" "$WORK_NVRAM" || fail "could not seed nvram vars from $OVMF_VARS"

# ── step 2: boot a bounded throwaway UEFI Win11 domain off the copy ──────────
log "step 2/5: defining + booting the throwaway work domain $WORK_DOMAIN"
cat > "$WORK_XML" <<XML
<domain type='kvm'>
  <name>${WORK_DOMAIN}</name>
  <memory unit='MiB'>${MEMORY_MB}</memory>
  <vcpu>${VCPUS}</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash' format='raw'>${OVMF_CODE}</loader>
    <nvram template='${OVMF_VARS}' templateFormat='raw' format='raw'>${WORK_NVRAM}</nvram>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/><apic/>
    <hyperv mode='custom'>
      <relaxed state='on'/><vapic state='on'/>
      <spinlocks state='on' retries='8191'/>
    </hyperv>
    <smm state='on'/>
  </features>
  <cpu mode='host-passthrough'/>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='hpet' present='no'/>
    <timer name='hypervclock' present='yes'/>
  </clock>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${WORK}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <graphics type='vnc' port='-1' listen='127.0.0.1'/>
    <video><model type='qxl'/></video>
  </devices>
</domain>
XML
"${VIRSH[@]}" define "$WORK_XML" >/dev/null || fail "virsh define failed"
"${VIRSH[@]}" start  "$WORK_DOMAIN" >/dev/null || fail "virsh start failed"

log "waiting for the work guest to obtain an IP + SSH (up to 15 min)…"
IP=""
for _ in $(seq 1 90); do IP="$(guest_ip "$WORK_DOMAIN")"; [[ -n "$IP" ]] && break; sleep 10; done
[[ -n "$IP" ]] || fail "work guest never got an IP (OOBE hang? check the VNC console)"
log "work guest IP=$IP"
SSH_OK=0
for _ in $(seq 1 60); do
  if ssh_guest "$IP" 'hostname' >/dev/null 2>&1; then SSH_OK=1; break; fi
  sleep 10
done
[[ "$SSH_OK" == 1 ]] || fail "work guest SSH never came up"
log "work guest SSH reachable; base hostname: $(ssh_guest "$IP" 'hostname' 2>/dev/null | tr -d '\r')"

# ── gate: refuse to build a golden whose clones have no usable Git ───────────
#
# guest-recipes/lib/provision-git.ps1 runs from FirstLogonCommands and exits 0
# even when it fails, because a non-zero exit there can wedge the rest of the
# chain (the install-done sentinel and the shutdown that signals
# install-complete to virt-install). That is a reasonable trade-off ONLY
# because of this gate.
#
# Without it, a Git-less image sails straight through: nothing in the
# autounattend, in finalize-golden.sh, or here would notice, and the first
# symptom would be every Windows CI job dying at `bash: command not found` --
# the exact defect the Git provisioning was added to fix. A README section
# telling the operator to check a marker file is documentation, not
# enforcement, so the check lives here, in the script that actually mints the
# golden the fleet is cloned from.
#
# Placed BEFORE the ~45-minute DISM /ResetBase so a bad image fails in seconds
# rather than after the long leg. Nothing in steps 3a/3b touches C:\PortableGit
# or the machine PATH -- /ResetBase drops superseded component-store payloads,
# which Git is not -- so asserting here is equivalent to asserting immediately
# before sysprep.
#
# Set VMH_SKIP_GIT_GATE=1 only to build a deliberately Git-less image (e.g.
# bisecting an unrelated sysprep failure). It is loud on purpose.
if [[ -n "${VMH_SKIP_GIT_GATE:-}" ]]; then
  log "WARNING: VMH_SKIP_GIT_GATE set — NOT verifying Git for Windows."
  log "WARNING: clones of the resulting golden may have no bash.exe and will"
  log "WARNING: fail every GitHub Actions 'shell: bash' step. Do not ship this."
else
  [[ -f "$GIT_GATE_PS1" ]] || fail "Git gate script not found: $GIT_GATE_PS1"
  log "gate: verifying Git for Windows is on the guest's MACHINE PATH and its toolchain resolves"
  sshpass -p "$GUEST_PASSWORD" scp -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o PreferredAuthentications=password "$GIT_GATE_PS1" \
    "admin@$IP:C:/Windows/Temp/assert-git-provisioned.ps1" \
    || fail "could not scp the Git gate script into the guest"
  if ! ssh_guest "$IP" 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\assert-git-provisioned.ps1' 2>&1 | sed 's/^/  [git-gate] /'; then
    fail "Git for Windows gate FAILED — refusing to build a golden whose clones cannot run 'shell: bash' steps (see [git-gate] output above; re-run guest-recipes/lib/provision-git.ps1 in the guest, then retry)"
  fi
  log "gate passed: Git for Windows is usable by services on clones of this golden"
fi

# ── gate: refuse to build a golden whose clones have no usable pwsh ──────────
#
# The layer directly under the Git gate, and it was found the same way. Once
# `shell: bash` steps started working, every Windows CI job died one step later
# with "##[error]pwsh: command not found": these goldens ship only Windows
# PowerShell 5.1, GitHub's hosted images bundle PowerShell 7, and nothing in
# this recipe ever installed it.
#
# guest-recipes/lib/provision-pwsh.ps1 exits 0 even when it fails, for the same
# FirstLogonCommands reason as the Git helper, so the same argument applies:
# that trade-off is only defensible because of this gate. Without it a
# pwsh-less image sails through and the first symptom is CI failing again.
#
# Placed next to the Git gate and BEFORE the ~45-minute DISM /ResetBase so a
# bad image fails in seconds rather than after the long leg. Nothing in steps
# 3a/3b touches C:\pwsh or the machine PATH -- /ResetBase drops superseded
# component-store payloads, which this is not -- so asserting here is
# equivalent to asserting immediately before sysprep.
#
# Set VMH_SKIP_PWSH_GATE=1 only to build a deliberately pwsh-less image. It is
# loud on purpose.
if [[ -n "${VMH_SKIP_PWSH_GATE:-}" ]]; then
  log "WARNING: VMH_SKIP_PWSH_GATE set — NOT verifying PowerShell 7."
  log "WARNING: clones of the resulting golden may have no pwsh.exe and will"
  log "WARNING: fail every GitHub Actions 'shell: pwsh' step. Do not ship this."
else
  [[ -f "$PWSH_GATE_PS1" ]] || fail "pwsh gate script not found: $PWSH_GATE_PS1"
  log "gate: verifying PowerShell 7 is on the guest's MACHINE PATH and the interpreter runs"
  sshpass -p "$GUEST_PASSWORD" scp -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o PreferredAuthentications=password "$PWSH_GATE_PS1" \
    "admin@$IP:C:/Windows/Temp/assert-pwsh-provisioned.ps1" \
    || fail "could not scp the pwsh gate script into the guest"
  if ! ssh_guest "$IP" 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\assert-pwsh-provisioned.ps1' 2>&1 | sed 's/^/  [pwsh-gate] /'; then
    fail "PowerShell 7 gate FAILED — refusing to build a golden whose clones cannot run 'shell: pwsh' steps (see [pwsh-gate] output above; re-run guest-recipes/lib/provision-pwsh.ps1 in the guest, then retry)"
  fi
  log "gate passed: PowerShell 7 is usable by services on clones of this golden"
fi

# ── gate: refuse to capture a golden carrying a stale Defender exclusion ─────
#
# The third defect found the same way, and the one that proves a recipe fix
# alone is not enough. provision-pwsh.ps1 added its PID-named extraction
# staging directory as a PERMANENT Defender exclusion and never removed it, so
# the promoted golden shipped
#
#   Get-MpPreference -> ExclusionPath: C:\Windows\Temp\vmh-pwsh-extract-6752
#
# naming a directory that stopped existing during the very run that added it.
# Windows reuses PIDs, so any later process drawing 6752 recreates that path
# and gets an UNSCANNED directory -- on machines whose whole job is running
# pull-request code from forks.
#
# provision-pwsh.ps1 is fixed. That fix reaches the fleet only when a golden is
# next built or retrofitted, and NOTHING refused to ship the image that already
# had the rule -- which is exactly why it survived promotion. This gate is that
# missing refusal.
#
# It asserts an INVARIANT ("every path exclusion names a path that exists"),
# not a hard-coded name, so it also catches the next golden's different PID and
# staging paths from recipes that do not exist yet. It deliberately does not
# demand an EMPTY list: C:\pwsh is a load-bearing exclusion (MsMpEng flags
# pwsh.exe as PUA:Win32/PowerShellCore) and clearing it would trade this defect
# for a worse one.
#
# Placed with the other gates, BEFORE the ~45-minute DISM /ResetBase, so a bad
# image fails in seconds. /ResetBase drops superseded component-store payloads
# and does not touch Defender preferences, so asserting here is equivalent to
# asserting immediately before sysprep.
#
# Set VMH_SKIP_DEFENDER_GATE=1 only to build an image deliberately carrying a
# stale exclusion. It is loud on purpose.
if [[ -n "${VMH_SKIP_DEFENDER_GATE:-}" ]]; then
  log "WARNING: VMH_SKIP_DEFENDER_GATE set — NOT verifying Defender exclusions."
  log "WARNING: clones of the resulting golden may carry an exclusion naming a"
  log "WARNING: directory that does not exist, which any process reusing that"
  log "WARNING: PID silently inherits as an unscanned path. Do not ship this."
else
  [[ -f "$DEFENDER_GATE_PS1" ]] || fail "Defender gate script not found: $DEFENDER_GATE_PS1"
  log "gate: verifying no Defender exclusion outlived the directory it excluded"
  sshpass -p "$GUEST_PASSWORD" scp -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o PreferredAuthentications=password "$DEFENDER_GATE_PS1" \
    "admin@$IP:C:/Windows/Temp/assert-defender-exclusions-sane.ps1" \
    || fail "could not scp the Defender gate script into the guest"
  if ! ssh_guest "$IP" 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\assert-defender-exclusions-sane.ps1' 2>&1 | sed 's/^/  [defender-gate] /'; then
    fail "Defender exclusion gate FAILED — refusing to build a golden that ships an antivirus exemption for a directory that does not exist (see [defender-gate] output above; remove the stale rules with Remove-MpPreference -ExclusionPath '<path>' in the guest, then retry)"
  fi
  log "gate passed: every Defender exclusion on this image names a path that exists"
fi

# ── step 3a: component-store repair — DISM /ResetBase (THE UNBLOCK) ──────────
log "step 3a/5: DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase (component-store repair — the unblock)"
ssh_guest "$IP" 'dism /online /Cleanup-Image /AnalyzeComponentStore' 2>&1 | sed 's/^/  [analyze] /' || true
if ! timeout "$DISM_TIMEOUT" bash -c "$(declare -f ssh_guest); GUEST_PASSWORD='$GUEST_PASSWORD' ssh_guest '$IP' 'dism /online /Cleanup-Image /StartComponentCleanup /ResetBase'" 2>&1 | sed 's/^/  [resetbase] /'; then
  fail "DISM /StartComponentCleanup /ResetBase failed or timed out"
fi
log "DISM /ResetBase done; rebooting the work guest to settle pending CBS"
ssh_guest "$IP" 'shutdown /r /t 3 /f' 2>&1 | sed 's/^/  /' || true
sleep 45
IP=""
for _ in $(seq 1 60); do IP="$(guest_ip "$WORK_DOMAIN")"; [[ -n "$IP" ]] && ssh_guest "$IP" 'hostname' >/dev/null 2>&1 && break; sleep 10; done
[[ -n "$IP" ]] || fail "work guest did not come back after the post-DISM reboot"
log "work guest back up after reboot; IP=$IP"

# ── step 3b: clear the reserved-storage servicing scenario ───────────────────
log "step 3b/5: clearing the ReserveManager scenario + disabling reserved storage"
ssh_guest "$IP" 'dism /online /Cleanup-Image /StartComponentCleanup' 2>&1 | sed 's/^/  /' || true
ssh_guest "$IP" 'reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" /v ActiveScenario /t REG_DWORD /d 0 /f' 2>&1 | sed 's/^/  /' || true
ssh_guest "$IP" 'reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" /v DisableDeletes /t REG_DWORD /d 0 /f' 2>&1 | sed 's/^/  /' || true
ssh_guest "$IP" 'dism /online /Set-ReservedStorageState /State:Disabled' 2>&1 | sed 's/^/  /' || true

# ── step 3c: sysprep /generalize /oobe /shutdown /quiet ──────────────────────
log "step 3c/5: staging the re-arm unattend + running sysprep /generalize /oobe /shutdown /quiet"
sshpass -p "$GUEST_PASSWORD" scp -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  -o PreferredAuthentications=password "$REARM_UNATTEND" \
  "admin@$IP:C:/sysprep2-unattend.xml" \
  || fail "could not scp the re-arm unattend into the guest"
# Keep Windows Update startable so GeneralizeForImaging does not stall.
ssh_guest "$IP" 'sc config wuauserv start= demand' 2>&1 | sed 's/^/  /' || true
# Launch sysprep. It shuts the guest down on success (/shutdown); a validation
# failure writes Panther\setuperr.log and exits (/quiet — no modal hang).
ssh_guest "$IP" 'C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /quiet /unattend:C:\sysprep2-unattend.xml' 2>&1 | sed 's/^/  /' || true

log "waiting for the work guest to power off after sysprep (up to $((SYSPREP_TIMEOUT/60)) min)…"
OFF=0
deadline=$(( $(date +%s) + SYSPREP_TIMEOUT ))
while [[ $(date +%s) -lt $deadline ]]; do
  st="$("${VIRSH[@]}" domstate "$WORK_DOMAIN" 2>/dev/null | tr -d '[:space:]')"
  if [[ "$st" == "shutoff" ]]; then OFF=1; break; fi
  sleep 15
done
if [[ "$OFF" != 1 ]]; then
  # Pull the sysprep logs for diagnosis before giving up.
  ip2="$(guest_ip "$WORK_DOMAIN")"
  if [[ -n "$ip2" ]]; then
    log "sysprep did not power off — pulling setuperr.log for diagnosis:"
    ssh_guest "$ip2" 'type C:\Windows\System32\Sysprep\Panther\setuperr.log' 2>&1 | sed 's/^/  [setuperr] /' || true
  fi
  fail "guest did not power off after sysprep (validation failure? see setuperr above / VNC console)"
fi
log "work guest powered off cleanly after sysprep /generalize"

# ── step 4: capture cold (BEFORE any boot) into the SIDE artifact ────────────
log "step 4/5: capturing the sysprepped golden cold -> $OUT_GOLDEN (side artifact)"
tmp_out="${OUT_GOLDEN}.partial.$$"
"${QEMU_IMG[@]}" convert -O qcow2 "$WORK" "$tmp_out" || fail "qemu-img convert (capture) failed"
mv -f "$tmp_out" "$OUT_GOLDEN" || fail "could not move captured golden into place"
log "captured: $(ls -la "$OUT_GOLDEN")"

# ── step 5: teardown (trap also runs, but do it explicitly + verify) ─────────
log "step 5/5: destroying the throwaway work domain + removing the work copy"
"${VIRSH[@]}" destroy  "$WORK_DOMAIN" >/dev/null 2>&1 || true
"${VIRSH[@]}" undefine "$WORK_DOMAIN" --nvram >/dev/null 2>&1 || true
rm -f "$WORK" "$WORK_NVRAM"

# Confirm the live golden is byte-untouched (never opened for write).
log "verifying the live golden is untouched: $(stat -c '%n size=%s mtime=%y' "$SRC_GOLDEN")"
log "DONE. Sysprepped golden: $OUT_GOLDEN"
log "NEXT: prove distinct SIDs — run the identity gate against \$OUT_GOLDEN, e.g.:"
log "  VMH_WIN_GOLDEN=$OUT_GOLDEN \\"
log "  VMH_OVMF_CODE=$OVMF_CODE VMH_OVMF_VARS=$OVMF_VARS \\"
log "  VMH_GUEST_PASSWORD=$GUEST_PASSWORD \\"
log "  bash $SCRIPT_DIR/../../tests/e2e/windows-sysprep/run-sysprep-identity-gate.sh"
