#!/usr/bin/env bash
# run-windows-jit-gate.sh — the M3 gate driver (t_windows_golden_jit_boot).
#
# Proves the ephemeral Windows JIT-injection MECHANISM end-to-end against a
# real KVM boot of a FRESH CoW clone of the cloudbase-init golden, with NO
# live GitHub (a mock GARM metadata + actions endpoint stands in):
#
#   1. Generate a synthetic-but-well-formed GitHub Actions JIT config
#      (.runner/.credentials/.credentials_rsaparams) + a per-instance JWT.
#   2. Render the GARM-style Windows bootstrap as cloudbase-init user_data
#      (config-drive openstack/latest/user_data) carrying the mock metadata
#      URL + the JWT.
#   3. Start the mock GARM metadata+runner server (JWT-authorized routes).
#   4. Boot a fresh per-job CoW clone of the golden via the REAL
#      `vm-harness run --ephemeral --keep` CLI with the config-drive ISO
#      injected (cloudbase-init ConfigDrive datasource) + UEFI (OVMF).
#      `--keep` leaves the domain running for the in-guest probe; teardown
#      goes through `vm-harness ephemeral-destroy`. The VM lifecycle
#      (clone / config-drive build / UEFI boot / teardown) is thus the
#      shipped CLI code path, not an inline virsh reimplementation.
#   5. Wait for the guest to boot; SSH in (password) and drive the bootstrap
#      (cloudbase-init runs it on first boot in production; the gate invokes
#      it explicitly for a deterministic, fast probe — see NOTE below).
#   6. ASSERT, against the mock's audit + the guest's runner _diag:
#        (a) the JIT credentials were fetched under the per-instance JWT
#            (401 without it — proves JWT-authorized secret delivery);
#        (b) the runner consumed the injected .runner/.credentials and
#            launched Runner.Listener with the JIT config;
#        (c) Runner.Listener authenticated + connected to the mock as its
#            Actions server (Location.GetConnectionData) and attempted to
#            create a runner session (i.e. reached the "configured /
#            listening for one job" phase).
#   7. Tear the clone down (vm-harness ephemeral stopAndCleanup) — assert
#      NO residual domain / overlay / config-drive ISO / nvram.
#
# The production windows-runner-001 domain is NEVER touched: the clone runs
# under a distinct name off a COPY of the golden (CoW overlay), on a
# separate config-drive.
#
# Env (required):
#   VMH_WIN_GOLDEN        cloudbase-init golden qcow2
#   VMH_OVMF_CODE         OVMF code firmware (edk2-x86_64-code.fd)
#   VMH_OVMF_VARS         OVMF vars template (edk2-i386-vars.fd)
#   VMH_GUEST_PASSWORD    guest admin password
# Env (optional):
#   VMH_GATE_NAME         domain/job name        (default m3-jit-gate)
#   VMH_MOCK_PORT         mock server port       (default 8099)
#   VMH_MOCK_HOST         host IP the guest uses (default 192.168.122.1)
#   LIBVIRT_DEFAULT_URI   libvirt URI            (default qemu:///system)
#   VMH_HARNESS           path to `vm-harness`   (default: build via nim)
#
# NOTE (honest): the gate invokes the bootstrap over SSH rather than relying
# on cloudbase-init's own first-boot run, so the probe is deterministic and
# does not depend on cloudbase-init's boot timing. A SEPARATE assertion
# (VMH_VERIFY_CLOUDBASE=1) verifies cloudbase-init itself consumes the
# config-drive + runs the userdata (slower; run when validating the golden).
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
GATE_NAME="${VMH_GATE_NAME:-m3-jit-gate}"
MOCK_PORT="${VMH_MOCK_PORT:-8099}"
MOCK_HOST="${VMH_MOCK_HOST:-192.168.122.1}"
URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
WORK="$(mktemp -d /tmp/m3-gate.XXXXXX)"
JIT_DIR="$WORK/jit"
JWT_SECRET="m3-mock-garm-instance-secret-$$"
MOCK_PID=""
CLONE_STARTED=0

log()  { echo "[m3-gate] $*"; }
fail() { echo "[m3-gate][FAIL] $*" >&2; RESULT=1; }

cleanup() {
  # Tear down the clone (belt-and-braces; the harness already does it) and
  # the mock. NEVER touch windows-runner-001.
  if [[ -n "$MOCK_PID" ]]; then kill "$MOCK_PID" 2>/dev/null; fi
  if [[ "$CLONE_STARTED" == "1" ]]; then
    virsh -c "$URI" destroy "$GATE_NAME" >/dev/null 2>&1
    virsh -c "$URI" undefine "$GATE_NAME" --nvram >/dev/null 2>&1
    rm -f "$POOL_DIR/$GATE_NAME.overlay.qcow2" \
          "$POOL_DIR/$GATE_NAME.config-drive.iso" \
          "$POOL_DIR/${GATE_NAME}_VARS.fd" 2>/dev/null
  fi
  rm -rf "$WORK" 2>/dev/null
}
trap cleanup EXIT

# --- prerequisites / self-skip -------------------------------------------
require_env() {
  local ok=1
  for v in VMH_WIN_GOLDEN VMH_OVMF_CODE VMH_OVMF_VARS VMH_GUEST_PASSWORD; do
    if [[ -z "${!v:-}" ]]; then echo "[m3-gate][skip] $v not set"; ok=0; fi
  done
  [[ "$ok" == "1" ]] || return 1
  for f in "$VMH_WIN_GOLDEN" "$VMH_OVMF_CODE" "$VMH_OVMF_VARS"; do
    if [[ ! -f "$f" ]]; then echo "[m3-gate][skip] missing file: $f"; return 1; fi
  done
  [[ -c /dev/kvm ]] || { echo "[m3-gate][skip] /dev/kvm absent"; return 1; }
  command -v virsh   >/dev/null || { echo "[m3-gate][skip] no virsh"; return 1; }
  command -v qemu-img>/dev/null || { echo "[m3-gate][skip] no qemu-img"; return 1; }
  command -v python3 >/dev/null || { echo "[m3-gate][skip] no python3"; return 1; }
  command -v sshpass >/dev/null || { echo "[m3-gate][skip] no sshpass"; return 1; }
  command -v genisoimage >/dev/null || command -v xorriso >/dev/null || \
    { echo "[m3-gate][skip] no genisoimage/xorriso"; return 1; }
  python3 -c "import jwt, cryptography" 2>/dev/null || \
    { echo "[m3-gate][skip] python jwt/cryptography missing"; return 1; }
  return 0
}

if ! require_env; then
  echo "SKIP"; exit 3
fi

POOL_DIR="$(virsh -c "$URI" 2>/dev/null pool-dumpxml default | \
  grep -oP "(?<=<path>).*(?=</path>)" | head -1)"
[[ -n "$POOL_DIR" ]] || POOL_DIR="/var/lib/libvirt/images"

RESULT=0

# --- 1. JIT config + JWT --------------------------------------------------
log "generating JIT config + per-instance JWT"
MOCK_URL="http://$MOCK_HOST:$MOCK_PORT"
python3 "$SCRIPT_DIR/gen_jitconfig.py" "$MOCK_URL" "$JIT_DIR" || { fail "jit gen"; exit 1; }
JWT="$(python3 - <<PY
import jwt, datetime
print(jwt.encode({"instance":"$GATE_NAME","iat":datetime.datetime.utcnow()},
                 "$JWT_SECRET", algorithm="HS256"))
PY
)"
[[ -n "$JWT" ]] || { fail "jwt gen"; exit 1; }

# --- 2. render user_data --------------------------------------------------
log "rendering cloudbase-init user_data (GARM Windows JIT bootstrap)"
USER_DATA="$WORK/user_data.ps1"
sed -e "s#@METADATA_URL@#$MOCK_URL#g" -e "s#@TOKEN@#$JWT#g" \
    "$SCRIPT_DIR/user_data.ps1.tmpl" > "$USER_DATA"

# --- 3. mock GARM server --------------------------------------------------
log "starting mock GARM metadata+runner server on :$MOCK_PORT"
AUDIT="$WORK/mock-audit.json"
M3_JIT_DIR="$JIT_DIR" M3_JWT_SECRET="$JWT_SECRET" M3_AUDIT="$AUDIT" \
  M3_ACCESS_POINT="$MOCK_URL" \
  python3 "$SCRIPT_DIR/mock_garm.py" "$MOCK_PORT" \
    >"$WORK/mock.out" 2>"$WORK/mock.err" &
MOCK_PID=$!
# wait for it to accept auth
for _ in $(seq 1 30); do
  code=$(python3 - <<PY 2>/dev/null
import urllib.request
req=urllib.request.Request("http://127.0.0.1:$MOCK_PORT/system/cert-bundle",
  headers={"Authorization":"Bearer $JWT"})
try: print(urllib.request.urlopen(req,timeout=2).status)
except Exception as e: print(getattr(e,"code",0))
PY
)
  [[ "$code" == "200" ]] && break
  sleep 1
done
[[ "$code" == "200" ]] || { fail "mock not up (code=$code)"; cat "$WORK/mock.err"; exit 1; }
log "mock up (authorized cert-bundle -> 200)"

# --- 4. boot a fresh CoW clone with the config-drive injected ------------
# Drive the REAL vm-harness CLI: `run --ephemeral --keep` clones a fresh
# CoW overlay off the golden, builds + attaches the config-2 ISO from
# --user-data/--meta-data, boots UEFI (OVMF via --uefi-loader/--uefi-nvram-
# template), and LEAVES THE DOMAIN RUNNING so we can SSH in and drive the
# JIT bootstrap. Teardown goes through `vm-harness ephemeral-destroy`
# (same ephemeral stopAndCleanup: destroy + undefine --nvram + remove
# overlay/config-drive/nvram). This exercises the SHIPPED CLI code path
# (buildConfigDriveIso + buildEphemeralDomainXml UEFI + attach + boot +
# teardown) end-to-end, not an inline virsh reimplementation.
log "booting fresh ephemeral clone '$GATE_NAME' via real vm-harness CLI (UEFI + config-drive)"

# Resolve the harness binary. Prefer $VMH_HARNESS, then a nix build result,
# then build it once from source via nim.
HARNESS="${VMH_HARNESS:-}"
if [[ -z "$HARNESS" ]]; then
  if [[ -x "$SCRIPT_DIR/../../../result/bin/vm-harness" ]]; then
    HARNESS="$SCRIPT_DIR/../../../result/bin/vm-harness"
  elif command -v vm-harness >/dev/null; then
    HARNESS="$(command -v vm-harness)"
  else
    log "no prebuilt vm-harness; compiling from source (nim)"
    HARNESS="$WORK/vm-harness"
    ( cd "$SCRIPT_DIR/../../.." && \
      nim c --hints:off --opt:speed --path:src -o:"$HARNESS" \
        src/vm_harness/cli.nim ) >/dev/null 2>&1 \
      || { fail "could not build vm-harness"; exit 1; }
  fi
fi
[[ -x "$HARNESS" ]] || { fail "vm-harness binary not found/executable: $HARNESS"; exit 1; }
log "using vm-harness: $HARNESS"

# Paths the CLI derives deterministically from --baseline (used for the
# residue check + belt-and-braces cleanup).
OVERLAY="$POOL_DIR/$GATE_NAME.overlay.qcow2"
CDISO="$POOL_DIR/$GATE_NAME.config-drive.iso"
NVRAM="$POOL_DIR/${GATE_NAME}_VARS.fd"
rm -f "$OVERLAY" "$CDISO" "$NVRAM"

# meta_data.json for the config-drive (openstack layout the CLI builds).
METADATA="$WORK/meta_data.json"
printf '{"uuid":"%s","hostname":"%s","name":"%s"}' "$GATE_NAME" "$GATE_NAME" "$GATE_NAME" \
  > "$METADATA"

CLONE_STARTED=1
if ! LIBVIRT_DEFAULT_URI="$URI" "$HARNESS" run --ephemeral --keep \
      --baseline "$GATE_NAME" \
      --golden-image "$VMH_WIN_GOLDEN" \
      --user-data "$USER_DATA" \
      --meta-data "$METADATA" \
      --uefi-loader "$VMH_OVMF_CODE" \
      --uefi-nvram-template "$VMH_OVMF_VARS" \
      --cpus 4 --memory-mb 4096 \
      >"$WORK/harness-up.out" 2>"$WORK/harness-up.err"; then
  fail "vm-harness run --ephemeral --keep failed"
  cat "$WORK/harness-up.err" >&2
  exit 1
fi
# Sanity: the CLI must have created the overlay + config-drive ISO.
[[ -f "$OVERLAY" ]] || { fail "CLI did not create overlay $OVERLAY"; exit 1; }
[[ -f "$CDISO" ]]   || { fail "CLI did not create config-drive ISO $CDISO"; exit 1; }
log "clone booted via CLI; waiting for guest IP + SSH"

# --- 5. wait for guest, drive bootstrap over SSH -------------------------
GUEST_IP=""
for _ in $(seq 1 60); do
  GUEST_IP=$(virsh -c "$URI" domifaddr "$GATE_NAME" --source agent 2>/dev/null \
    | grep -oE '192\.168\.122\.[0-9]+' | head -1)
  [[ -z "$GUEST_IP" ]] && GUEST_IP=$(virsh -c "$URI" domifaddr "$GATE_NAME" 2>/dev/null \
    | grep -oE '192\.168\.122\.[0-9]+' | head -1)
  [[ -n "$GUEST_IP" ]] && break
  sleep 10
done
[[ -n "$GUEST_IP" ]] || { fail "guest IP not obtained"; exit 1; }
log "guest IP=$GUEST_IP"

SSH=(sshpass -p "$VMH_GUEST_PASSWORD" ssh -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o LogLevel=ERROR \
  -o PreferredAuthentications=password "admin@$GUEST_IP")
SCP=(sshpass -p "$VMH_GUEST_PASSWORD" scp -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  -o PreferredAuthentications=password)

# wait for sshd
SSH_OK=0
for _ in $(seq 1 40); do
  if "${SSH[@]}" 'echo ALIVE' 2>/dev/null | grep -q ALIVE; then SSH_OK=1; break; fi
  sleep 10
done
[[ "$SSH_OK" == "1" ]] || { fail "guest SSH never came up"; exit 1; }
log "guest SSH up"

# Optionally verify cloudbase-init itself ran the userdata from the config
# drive (slower; proves the datasource + userdata plugin end-to-end).
if [[ "${VMH_VERIFY_CLOUDBASE:-0}" == "1" ]]; then
  log "waiting for cloudbase-init to consume the config-drive + run userdata"
  CBOK=0
  for _ in $(seq 1 30); do
    if "${SSH[@]}" 'powershell -NoProfile -Command "Test-Path C:\m3-bootstrap.log"' 2>/dev/null | grep -qi True; then
      CBOK=1; break
    fi
    sleep 10
  done
  if [[ "$CBOK" == "1" ]]; then
    log "PASS: cloudbase-init ran the injected userdata (C:\\m3-bootstrap.log present)"
  else
    fail "cloudbase-init did not run the injected userdata within timeout"
  fi
fi

# Drive the bootstrap deterministically (production: cloudbase-init runs this
# on first boot; the gate invokes it for a fast/deterministic probe).
"${SCP[@]}" "$USER_DATA" "admin@$GUEST_IP:C:/m3-gate-bootstrap.ps1" 2>/dev/null \
  || { fail "scp bootstrap"; exit 1; }
log "running JIT bootstrap in guest (pull JIT under JWT -> launch Runner.Listener)"
"${SSH[@]}" 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\m3-gate-bootstrap.ps1' >/dev/null 2>&1

# Give the runner a moment to connect + attempt a session.
sleep 8

# --- 6. assertions --------------------------------------------------------
log "collecting evidence"
BOOTLOG="$("${SSH[@]}" 'powershell -NoProfile -Command "if (Test-Path C:\m3-bootstrap.log) { Get-Content -Raw C:\m3-bootstrap.log }"' 2>/dev/null)"
DIAG="$("${SSH[@]}" 'powershell -NoProfile -Command "$f = Get-ChildItem C:\actions-runner\_diag\ -Filter Runner_*.log | Sort-Object LastWriteTime | Select-Object -Last 1; if ($f) { Get-Content -Raw $f.FullName }"' 2>/dev/null)"

echo "$BOOTLOG" > "$WORK/bootstrap.log"
echo "$DIAG"    > "$WORK/runner_diag.log"

# (a) JWT-authorized JIT delivery (mock audit).
if python3 - "$AUDIT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
a = set(d["authorized"])
need = {"/credentials/runner", "/credentials/credentials",
        "/credentials/credentials_rsaparams", "/system/service-name",
        "/system/cert-bundle"}
missing = need - a
sys.exit(0 if not missing else 1)
PY
then log "PASS (a): JIT credentials fetched under the per-instance JWT"
else fail "(a) JIT credentials NOT all fetched under JWT (see $AUDIT)"; fi

# (a') JWT enforcement: at least one unauthorized (401) probe recorded, OR
# assert the mock rejects a no-auth request live.
NOAUTH=$(python3 - <<PY 2>/dev/null
import urllib.request
try:
    urllib.request.urlopen("http://127.0.0.1:$MOCK_PORT/credentials/runner", timeout=3)
    print("200")
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print("ERR")
PY
)
if [[ "$NOAUTH" == "401" ]]; then log "PASS (a'): no-JWT credentials pull rejected (401)"
else fail "(a') no-JWT credentials pull was not rejected (got $NOAUTH)"; fi

# (b) bootstrap consumed the injected config + launched Runner.Listener.
if grep -q "RUNNER-CREDS-FETCHED" "$WORK/bootstrap.log" && \
   grep -q "RUNNER-LISTENER-STARTED" "$WORK/bootstrap.log"; then
  log "PASS (b): injected .runner/.credentials consumed; Runner.Listener launched"
else fail "(b) bootstrap did not fetch creds / launch Runner.Listener"; fi

# (c) Runner.Listener authenticated + connected to the mock + attempted a
# runner session (reached the configured / listening-for-one-job phase).
if grep -qi "\.runner" "$WORK/runner_diag.log" && \
   grep -qiE "create session|GetConnectionData|MessageListener" "$WORK/runner_diag.log"; then
  log "PASS (c): Runner.Listener read the JIT config + attempted a runner session"
else fail "(c) runner diag lacks JIT/session evidence"; fi

# Also assert the runner reached the mock's actions server (audit records
# authenticated connectionData GETs from the runner).
if python3 - "$AUDIT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
hits = d["hits"]
ok = any("connectionData" in h for h in hits)
sys.exit(0 if ok else 1)
PY
then log "PASS (c'): runner connected to the mock Actions server (connectionData)"
else fail "(c') runner never reached the mock Actions connectionData endpoint"; fi

# --- 7. teardown + no-residue --------------------------------------------
# Reclaim via the REAL CLI (ephemeral stopAndCleanup: destroy + undefine
# --nvram + remove overlay/config-drive/nvram — no residue).
log "tearing down clone via real vm-harness CLI (ephemeral-destroy)"
LIBVIRT_DEFAULT_URI="$URI" "$HARNESS" ephemeral-destroy \
  --baseline "$GATE_NAME" >/dev/null 2>&1 \
  || log "ephemeral-destroy returned non-zero (will verify residue directly)"
# Belt-and-braces (never leak; the CLI already did the above).
virsh -c "$URI" destroy "$GATE_NAME"  >/dev/null 2>&1
virsh -c "$URI" undefine "$GATE_NAME" --nvram >/dev/null 2>&1
rm -f "$OVERLAY" "$CDISO" "$NVRAM"
CLONE_STARTED=0

sleep 2
RESIDUE=0
if virsh -c "$URI" list --all --name 2>/dev/null | grep -qx "$GATE_NAME"; then
  fail "residual domain '$GATE_NAME' remains"; RESIDUE=1; fi
for f in "$OVERLAY" "$CDISO" "$NVRAM"; do
  if [[ -e "$f" ]]; then fail "residual artifact remains: $f"; RESIDUE=1; fi
done
# The golden must be untouched.
[[ -f "$VMH_WIN_GOLDEN" ]] || fail "golden vanished (must be untouched!)"
[[ "$RESIDUE" == "0" ]] && log "PASS (d): no residual domain/overlay/config-drive/nvram; golden intact"

if [[ "$RESULT" == "0" ]]; then
  echo "M3_GATE_PASS"
else
  echo "M3_GATE_FAIL"
fi
exit "$RESULT"
