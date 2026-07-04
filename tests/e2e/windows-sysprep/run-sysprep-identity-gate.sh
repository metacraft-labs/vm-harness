#!/usr/bin/env bash
# run-sysprep-identity-gate.sh — the sysprep distinct-identity gate.
#
# Proves the syspreped ("/generalize") cloudbase-init golden yields a FRESH
# machine identity per clone, by booting TWO independent ephemeral CoW clones
# of the golden through the REAL `vm-harness run --ephemeral --keep` CLI (each
# with its own injected config-drive) and asserting:
#
#   (a) both clones complete Win11 mini-setup (OOBE) unattended and become
#       SSH-reachable (no OOBE hang — the baked re-arm unattend skips OOBE);
#   (b) their machine SIDs DIFFER and their hostnames DIFFER (sysprep
#       /generalize regenerated the SID; the specialize `ComputerName=*`
#       assigned a random distinct name) — captured as evidence;
#   (c) cloudbase-init on each clone AUTONOMOUSLY consumes its injected
#       config-drive on first boot and runs the userdata (marker file
#       C:\cloudbase-ran.txt, stamped with the per-clone instance name) —
#       the M3 mechanism, unchanged by sysprep.
#
# Then both clones are torn down via `vm-harness ephemeral-destroy` and the
# gate asserts NO residual domain / overlay / config-drive ISO / nvram, and
# that the golden is untouched. The production windows-runner-001 domain is
# NEVER touched (distinct names, CoW overlays off a COPY of the golden).
#
# Env (required):
#   VMH_WIN_GOLDEN      sysprepped cloudbase-init golden qcow2
#   VMH_OVMF_CODE       OVMF code firmware (edk2-x86_64-code.fd)
#   VMH_OVMF_VARS       OVMF vars template (edk2-i386-vars.fd)
#   VMH_GUEST_PASSWORD  guest admin password
# Env (optional):
#   VMH_HARNESS         path to the vm-harness binary (else built via nix/nim)
#   VMH_CLONE_A         clone A domain name   (default sysprep2-cloneA)
#   VMH_CLONE_B         clone B domain name   (default sysprep2-cloneB)
#   LIBVIRT_DEFAULT_URI libvirt URI           (default qemu:///system)
#   VMH_CLOUDBASE_WAIT  seconds to wait for the cloudbase marker (default 600)
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
CLONE_A="${VMH_CLONE_A:-sysprep2-cloneA}"
CLONE_B="${VMH_CLONE_B:-sysprep2-cloneB}"
CBWAIT="${VMH_CLOUDBASE_WAIT:-600}"
WORK="$(mktemp -d /tmp/sysprep-identity.XXXXXX)"
RESULT=0
declare -A STARTED

log()  { echo "[id-gate] $*"; }
fail() { echo "[id-gate][FAIL] $*" >&2; RESULT=1; }

POOL_DIR="$(virsh -c "$URI" 2>/dev/null pool-dumpxml default | \
  grep -oP "(?<=<path>).*(?=</path>)" | head -1)"
[[ -n "$POOL_DIR" ]] || POOL_DIR="/var/lib/libvirt/images"

teardown_clone() {
  local name="$1"
  LIBVIRT_DEFAULT_URI="$URI" "$HARNESS" ephemeral-destroy --baseline "$name" \
    >/dev/null 2>&1 || true
  virsh -c "$URI" destroy "$name"  >/dev/null 2>&1
  virsh -c "$URI" undefine "$name" --nvram >/dev/null 2>&1
  rm -f "$POOL_DIR/$name.overlay.qcow2" \
        "$POOL_DIR/$name.config-drive.iso" \
        "$POOL_DIR/${name}_VARS.fd" 2>/dev/null
}

cleanup() {
  for n in "${!STARTED[@]}"; do teardown_clone "$n"; done
  rm -rf "$WORK" 2>/dev/null
}
trap cleanup EXIT

# --- prerequisites / self-skip -------------------------------------------
for v in VMH_WIN_GOLDEN VMH_OVMF_CODE VMH_OVMF_VARS VMH_GUEST_PASSWORD; do
  if [[ -z "${!v:-}" ]]; then echo "[id-gate][skip] $v not set"; echo SKIP; exit 3; fi
done
for f in "$VMH_WIN_GOLDEN" "$VMH_OVMF_CODE" "$VMH_OVMF_VARS"; do
  [[ -f "$f" ]] || { echo "[id-gate][skip] missing file: $f"; echo SKIP; exit 3; }
done
[[ -c /dev/kvm ]] || { echo "[id-gate][skip] /dev/kvm absent"; echo SKIP; exit 3; }
for c in virsh qemu-img python3 sshpass; do
  command -v "$c" >/dev/null || { echo "[id-gate][skip] no $c"; echo SKIP; exit 3; }
done
command -v genisoimage >/dev/null || command -v xorriso >/dev/null || \
  { echo "[id-gate][skip] no genisoimage/xorriso"; echo SKIP; exit 3; }

# --- resolve the harness binary ------------------------------------------
HARNESS="${VMH_HARNESS:-}"
if [[ -z "$HARNESS" ]]; then
  if [[ -x "$SCRIPT_DIR/../../../result/bin/vm-harness" ]]; then
    HARNESS="$SCRIPT_DIR/../../../result/bin/vm-harness"
  elif command -v vm-harness >/dev/null; then
    HARNESS="$(command -v vm-harness)"
  else
    HARNESS="$WORK/vm-harness"
    ( cd "$SCRIPT_DIR/../../.." && \
      nim c --hints:off --opt:speed --path:src -o:"$HARNESS" \
        src/vm_harness/cli.nim ) >/dev/null 2>&1 \
      || { fail "could not build vm-harness"; echo "SYSPREP_IDENTITY_GATE_FAIL"; exit 1; }
  fi
fi
[[ -x "$HARNESS" ]] || { fail "vm-harness not executable: $HARNESS"; echo "SYSPREP_IDENTITY_GATE_FAIL"; exit 1; }
log "using vm-harness: $HARNESS"

ssh_guest() { # ip, remote-cmd
  sshpass -p "$VMH_GUEST_PASSWORD" ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o LogLevel=ERROR \
    -o PreferredAuthentications=password "admin@$1" "$2"
}
scp_guest() { # local, ip, remote
  sshpass -p "$VMH_GUEST_PASSWORD" scp -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o PreferredAuthentications=password "$1" "admin@$2:$3"
}

# boot_clone NAME -> populates HOST_$NAME / SID_$NAME / CB_$NAME via globals
boot_and_probe() {
  local name="$1"
  local key="${name//[^A-Za-z0-9]/_}"   # bash var names: no hyphens
  local overlay="$POOL_DIR/$name.overlay.qcow2"
  local cdiso="$POOL_DIR/$name.config-drive.iso"
  local nvram="$POOL_DIR/${name}_VARS.fd"
  rm -f "$overlay" "$cdiso" "$nvram"

  local udata="$WORK/$name.user_data.ps1"
  sed -e "s#@INSTANCE@#$name#g" "$SCRIPT_DIR/user_data.ps1.tmpl" > "$udata"
  local metadata="$WORK/$name.meta_data.json"
  printf '{"uuid":"%s","hostname":"%s","name":"%s"}' "$name" "$name" "$name" > "$metadata"

  log "[$name] booting fresh ephemeral clone via real vm-harness CLI (UEFI + config-drive)"
  STARTED["$name"]=1
  if ! LIBVIRT_DEFAULT_URI="$URI" "$HARNESS" run --ephemeral --keep \
        --baseline "$name" \
        --golden-image "$VMH_WIN_GOLDEN" \
        --user-data "$udata" \
        --meta-data "$metadata" \
        --uefi-loader "$VMH_OVMF_CODE" \
        --uefi-nvram-template "$VMH_OVMF_VARS" \
        --cpus 4 --memory-mb 4096 \
        >"$WORK/$name.up.out" 2>"$WORK/$name.up.err"; then
    fail "[$name] vm-harness run --ephemeral --keep failed"
    cat "$WORK/$name.up.err" >&2
    return 1
  fi
  [[ -f "$overlay" ]] || { fail "[$name] CLI did not create overlay"; return 1; }
  [[ -f "$cdiso" ]]   || { fail "[$name] CLI did not create config-drive ISO"; return 1; }

  local ip=""
  for _ in $(seq 1 90); do
    ip=$(virsh -c "$URI" domifaddr "$name" --source agent 2>/dev/null \
      | grep -oE '192\.168\.122\.[0-9]+' | head -1)
    [[ -z "$ip" ]] && ip=$(virsh -c "$URI" domifaddr "$name" 2>/dev/null \
      | grep -oE '192\.168\.122\.[0-9]+' | head -1)
    [[ -n "$ip" ]] && break
    sleep 10
  done
  [[ -n "$ip" ]] || { fail "[$name] guest IP not obtained (OOBE hang?)"; return 1; }
  log "[$name] guest IP=$ip"
  eval "IP_$key=$ip"

  local ssh_ok=0
  for _ in $(seq 1 60); do
    if ssh_guest "$ip" 'hostname' 2>/dev/null | grep -qiE '[a-z0-9]'; then ssh_ok=1; break; fi
    sleep 10
  done
  [[ "$ssh_ok" == "1" ]] || { fail "[$name] guest SSH never came up (OOBE hang?)"; return 1; }
  log "[$name] (a) OOBE complete + SSH reachable"

  # (c) wait for cloudbase-init to autonomously run the injected userdata.
  local cb=""
  local deadline=$(( $(date +%s) + CBWAIT ))
  while [[ $(date +%s) -lt $deadline ]]; do
    cb=$(ssh_guest "$ip" 'powershell -NoProfile -Command "if (Test-Path C:\cloudbase-ran.txt) { (Get-Content -Raw C:\cloudbase-ran.txt).Trim() }"' 2>/dev/null)
    [[ "$cb" == *"CLOUDBASE-INIT-USERDATA-RAN"* ]] && break
    sleep 15
  done
  if [[ "$cb" == *"CLOUDBASE-INIT-USERDATA-RAN instance=$name"* ]]; then
    log "[$name] (c) cloudbase-init consumed the config-drive: $cb"
    eval "CB_$key=ok"
  else
    fail "[$name] (c) cloudbase-init did NOT run the injected userdata (marker: '${cb:-none}')"
    eval "CB_$key=no"
  fi

  # (b) capture hostname + machine SID.
  scp_guest "$SCRIPT_DIR/probe-identity.ps1" "$ip" 'C:/probe-identity.ps1' 2>/dev/null \
    || { fail "[$name] scp probe"; return 1; }
  local probe
  probe=$(ssh_guest "$ip" 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\probe-identity.ps1' 2>/dev/null)
  echo "$probe" > "$WORK/$name.identity.txt"
  local host sid
  host=$(echo "$probe" | grep -oE 'HOSTNAME=.*' | head -1 | cut -d= -f2- | tr -d '\r')
  sid=$(echo "$probe" | grep -oE 'MACHINE_SID=.*' | head -1 | cut -d= -f2- | tr -d '\r')
  [[ -n "$host" ]] || { fail "[$name] no hostname captured"; return 1; }
  [[ -n "$sid" ]]  || { fail "[$name] no machine SID captured"; return 1; }
  log "[$name] hostname=$host machine_sid=$sid"
  eval "HOST_$key=\"$host\""
  eval "SID_$key=\"$sid\""
  return 0
}

boot_and_probe "$CLONE_A" || true
boot_and_probe "$CLONE_B" || true

# Indirect expansion of the per-clone globals (names are configurable; the
# globals are keyed by the sanitized name — hyphens -> underscores).
KEY_A="${CLONE_A//[^A-Za-z0-9]/_}"; KEY_B="${CLONE_B//[^A-Za-z0-9]/_}"
hA="$(eval echo \"\${HOST_$KEY_A:-}\")"; hB="$(eval echo \"\${HOST_$KEY_B:-}\")"
sA="$(eval echo \"\${SID_$KEY_A:-}\")";  sB="$(eval echo \"\${SID_$KEY_B:-}\")"

echo "=== distinct-identity evidence ==="
echo "clone A ($CLONE_A): hostname=$hA machine_sid=$sA"
echo "clone B ($CLONE_B): hostname=$hB machine_sid=$sB"

if [[ -n "$hA" && -n "$hB" && "$hA" != "$hB" ]]; then
  log "PASS (b1): hostnames DIFFER ($hA != $hB)"
else
  fail "(b1) hostnames not distinct: A='$hA' B='$hB'"
fi
if [[ -n "$sA" && -n "$sB" && "$sA" != "$sB" ]]; then
  log "PASS (b2): machine SIDs DIFFER"
else
  fail "(b2) machine SIDs not distinct: A='$sA' B='$sB'"
fi

# --- teardown + residue check --------------------------------------------
for n in "$CLONE_A" "$CLONE_B"; do teardown_clone "$n"; unset 'STARTED[$n]'; done
sleep 2
for n in "$CLONE_A" "$CLONE_B"; do
  if virsh -c "$URI" list --all --name 2>/dev/null | grep -qx "$n"; then
    fail "residual domain '$n' remains"; fi
  for f in "$POOL_DIR/$n.overlay.qcow2" "$POOL_DIR/$n.config-drive.iso" "$POOL_DIR/${n}_VARS.fd"; do
    [[ -e "$f" ]] && fail "residual artifact remains: $f"
  done
done
[[ -f "$VMH_WIN_GOLDEN" ]] || fail "golden vanished (must be untouched!)"
[[ "$RESULT" == "0" ]] && log "PASS (d): no residue; golden intact"

if [[ "$RESULT" == "0" ]]; then echo "SYSPREP_IDENTITY_GATE_PASS"; else echo "SYSPREP_IDENTITY_GATE_FAIL"; fi
exit "$RESULT"
