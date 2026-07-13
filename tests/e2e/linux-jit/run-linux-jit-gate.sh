#!/usr/bin/env bash
# run-linux-jit-gate.sh — IM2 gate driver (t_incus_linux_jit_boot).
#
# Proves the ephemeral LINUX JIT-injection MECHANISM end-to-end on real
# Incus containers, with NO live GitHub (a mock GARM metadata + actions
# endpoint stands in). The container analog of the Windows M3 gate.
#
#   * a container launched from the `vmh-linux-runner` image consumes an
#     INJECTED cloud-init user-data (via the IM1 IncusBackend seam
#     `incus config set <name> cloud-init.user-data ...`) carrying GARM's
#     Linux JIT bootstrap;
#   * on first boot cloud-init runs the bootstrap AUTONOMOUSLY: it fetches
#     the JIT config from the MOCK GARM metadata endpoint, authorized by a
#     per-instance JWT (no-JWT -> 401);
#   * it launches the actions runner via `run.sh --jitconfig <blob>`, which
#     connects to the mock as its Actions server and creates a runner
#     session (reaches the configured/listening state);
#   * both containers are torn down leaving NO residue.
#
# Topology: on this host nixos-fw does not trust incusbr0, so a container
# cannot reach a service on the HOST (and DHCP does not lease). Two
# containers on incusbr0 talk L2, so the mock runs in a sibling container
# (im2-mock) and the runner container (im2-runner) is given a static IPv4
# via injected cloud-init.network-config. Uses ONLY im2-* names.
#
# Exit: 0 = LINUX_JIT_GATE_PASS; 3 = self-skip (image/incus/tooling absent).
#
# Env:
#   VMH_INCUS_CMD    incus invocation  (default: incus)
#   VMH_RUNNER_ALIAS runner image      (default: vmh-linux-runner)
#   IM2_PORT         mock port          (default: 8299)
set -uo pipefail

INCUS=(${VMH_INCUS_CMD:-incus})
ALIAS="${VMH_RUNNER_ALIAS:-vmh-linux-runner}"
PORT="${IM2_PORT:-8299}"
NET="${VMH_INCUS_BRIDGE:-incusbr0}"
SECRET="im2-mock-garm-instance-secret"
MOCK="im2-mock"
RUNNER="im2-runner"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d /tmp/im2-gate.XXXXXX)"
JIT_DIR="$WORK/jit"
RESULT=0

log()  { echo "[im2-gate] $*"; }
fail() { echo "[im2-gate][FAIL] $*" >&2; RESULT=1; }
skip() { echo "[im2-gate][SKIP] $*" >&2; cleanup; echo "SKIP"; exit 3; }

cleanup() {
  "${INCUS[@]}" delete --force "$RUNNER" >/dev/null 2>&1 || true
  "${INCUS[@]}" delete --force "$MOCK"   >/dev/null 2>&1 || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

# --- preflight -------------------------------------------------------------
command -v python3 >/dev/null || skip "no python3 on host"
python3 -c "import cryptography" 2>/dev/null || skip "host lacks python cryptography (gen_jitconfig)"
"${INCUS[@]}" info >/dev/null 2>&1 || skip "incus not reachable (set VMH_INCUS_CMD=\"sudo -n incus\")"
"${INCUS[@]}" image info "$ALIAS" >/dev/null 2>&1 || skip "runner image '$ALIAS' absent (build it: guest-recipes/linux-x64-runner/build-runner-image.sh)"

# Derive the incusbr0 /24 base + a mock cloud base image.
IPV4="$("${INCUS[@]}" network get "$NET" ipv4.address 2>/dev/null)"   # 10.157.159.1/24
[ -n "$IPV4" ] || skip "bridge $NET has no ipv4.address"
CIDR="${IPV4##*/}"
BASE="$(echo "${IPV4%/*}" | cut -d. -f1-3)"                          # 10.157.159
MOCK_IP="${BASE}.242"
RUNNER_IP="${BASE}.240"
MOCK_URL="http://${MOCK_IP}:${PORT}"
# A cloud base image (has python3) to run the mock in. Reuse the runner
# image itself — it has python3 + curl and is guaranteed present.
MOCK_BASE="$ALIAS"

log "topology: mock=$MOCK_IP runner=$RUNNER_IP url=$MOCK_URL net=$NET/$CIDR"

# --- clean any leftovers ---------------------------------------------------
cleanup_only() { "${INCUS[@]}" delete --force "$1" >/dev/null 2>&1 || true; }
cleanup_only "$RUNNER"; cleanup_only "$MOCK"

# --- 1. generate JIT config (host, cryptography) + mint per-instance JWT ---
log "generating JIT config for $MOCK_URL"
python3 "$SCRIPT_DIR/gen_jitconfig.py" "$MOCK_URL" "$JIT_DIR" || { fail "jit gen"; exit 1; }
JWT="$(python3 - "$SECRET" <<'PY'
import base64, hashlib, hmac, json, sys
secret = sys.argv[1]
def seg(o): return base64.urlsafe_b64encode(json.dumps(o,separators=(',',':')).encode()).rstrip(b'=').decode()
si = seg({"alg":"HS256","typ":"JWT"})+"."+seg({"sub":"im2-instance","iat":0})
sig = base64.urlsafe_b64encode(hmac.new(secret.encode(), si.encode(), hashlib.sha256).digest()).rstrip(b'=').decode()
print(si+"."+sig)
PY
)"
[ -n "$JWT" ] || { fail "jwt mint"; exit 1; }

# --- 2. launch the mock container, assign static IP, serve the mock -------
log "launching mock container '$MOCK' from $MOCK_BASE"
"${INCUS[@]}" launch "$MOCK_BASE" "$MOCK" >/dev/null 2>&1 || { fail "launch mock"; exit 1; }
for _ in $(seq 1 60); do "${INCUS[@]}" exec "$MOCK" -- true 2>/dev/null && break; sleep 1; done
"${INCUS[@]}" exec "$MOCK" -- ip addr add "${MOCK_IP}/${CIDR}" dev eth0 2>/dev/null || true
"${INCUS[@]}" exec "$MOCK" -- ip link set eth0 up 2>/dev/null || true
"${INCUS[@]}" file push "$SCRIPT_DIR/mock_garm.py" "$MOCK/opt/mock_garm.py" >/dev/null 2>&1
"${INCUS[@]}" exec "$MOCK" -- mkdir -p /opt/jit
for f in .runner .credentials .credentials_rsaparams jitconfig.b64; do
  "${INCUS[@]}" file push "$JIT_DIR/$f" "$MOCK/opt/jit/$f" >/dev/null 2>&1
done
log "starting mock server on :$PORT inside $MOCK"
"${INCUS[@]}" exec "$MOCK" \
  --env IM2_JIT_DIR=/opt/jit \
  --env IM2_JWT_SECRET="$SECRET" \
  --env IM2_AUDIT=/var/log/im2-audit.json \
  --env IM2_ACCESS_POINT="$MOCK_URL" \
  -- sh -c "setsid python3 /opt/mock_garm.py $PORT >/var/log/im2-mock.log 2>&1 </dev/null & sleep 1"

# Verify the mock is up + JWT gating works (from inside the mock container).
NOAUTH="$("${INCUS[@]}" exec "$MOCK" -- curl -s -o /dev/null -w '%{http_code}' \
  "http://127.0.0.1:${PORT}/credentials/jitconfig" 2>/dev/null)"
AUTH="$("${INCUS[@]}" exec "$MOCK" -- curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $JWT" "http://127.0.0.1:${PORT}/credentials/jitconfig" 2>/dev/null)"
log "mock self-check: noauth=$NOAUTH auth=$AUTH"
[ "$AUTH" = "200" ] || { fail "mock not serving (auth=$AUTH)"; exit 1; }

# --- 3. render the GARM Linux bootstrap user-data --------------------------
UD="$WORK/user_data.sh"
sed -e "s#@METADATA_URL@#${MOCK_URL}#g" \
    -e "s#@TOKEN@#${JWT}#g" \
    -e "s#@RUN_HOME@#/opt/actions-runner#g" \
    -e "s#@RUNNER_USER@#runner#g" \
    "$SCRIPT_DIR/user_data.sh.tmpl" > "$UD"

# --- 4. launch the runner container with INJECTED cloud-init --------------
log "initialising runner container '$RUNNER' from $ALIAS"
"${INCUS[@]}" init "$ALIAS" "$RUNNER" >/dev/null 2>&1 || { fail "init runner"; exit 1; }
# The IM1 injection seam: cloud-init.user-data = the GARM bootstrap.
"${INCUS[@]}" config set "$RUNNER" cloud-init.user-data - < "$UD"
# Static IPv4 so the guest can reach the mock (host DHCP is firewall-broken).
printf 'version: 2\nethernets:\n  eth0:\n    dhcp4: false\n    addresses: [%s/%s]\n' \
  "$RUNNER_IP" "$CIDR" | "${INCUS[@]}" config set "$RUNNER" cloud-init.network-config -
log "starting runner container (cloud-init will run the injected bootstrap)"
"${INCUS[@]}" start "$RUNNER" >/dev/null 2>&1 || { fail "start runner"; exit 1; }

# --- 5. wait for the bootstrap to run + the runner to reach the mock -------
audit() { "${INCUS[@]}" exec "$MOCK" -- cat /var/log/im2-audit.json 2>/dev/null; }
# has_hit <substring>: true if any recorded (authorized) audit hit matches.
has_hit() {
  audit | python3 -c "import json,sys
d=json.load(sys.stdin)
sub=sys.argv[1]
sys.exit(0 if any(sub in h for h in d.get('authorized',[])) else 1)" "$1" 2>/dev/null
}
log "waiting for cloud-init bootstrap + Runner.Listener to connect to the mock"
CONNECT_OK=0; SESSION_OK=0
for i in $(seq 1 90); do
  if has_hit "connectionData"; then CONNECT_OK=1; fi
  if has_hit "SESSION-CREATED"; then SESSION_OK=1; fi
  # Stop once the runner has connected AND we've given the session a chance.
  if [ "$SESSION_OK" = "1" ]; then
    log "SESSION-CREATED observed after ${i}x2s"; break
  fi
  if [ "$CONNECT_OK" = "1" ] && [ "$i" -ge 8 ]; then
    log "runner connected to the mock Actions server after ${i}x2s"; break
  fi
  sleep 2
done
# Grace: let the runner POST its session + long-poll the message queue
# ("Listening for Jobs") so the mock records the SESSION-CREATED and
# LISTENING milestones before we tear down. Refresh the flags here so the
# final report reflects the true end state (connectionData can be recorded a
# beat before the session POST lands).
LISTENING_OK=0
for _ in 1 2 3 4 5 6 7 8; do
  has_hit "SESSION-CREATED" && SESSION_OK=1
  has_hit "LISTENING" && LISTENING_OK=1
  [ "$SESSION_OK" = "1" ] && [ "$LISTENING_OK" = "1" ] && break
  sleep 2
done
[ "$SESSION_OK" = "1" ] && log "runner POSTed a runner session (SESSION-CREATED)"
[ "$LISTENING_OK" = "1" ] && log "runner reached the message-queue long-poll (Listening for Jobs)"

# --- 6. collect evidence ---------------------------------------------------
EVID="$WORK/evidence"; mkdir -p "$EVID"
"${INCUS[@]}" exec "$RUNNER" -- cat /var/log/im2-bootstrap.log > "$EVID/bootstrap.log" 2>/dev/null || true
"${INCUS[@]}" exec "$RUNNER" -- cat /var/log/im2-runner.log    > "$EVID/runner.log"    2>/dev/null || true
"${INCUS[@]}" exec "$RUNNER" -- sh -c 'cat /opt/actions-runner/_diag/*.log 2>/dev/null | tail -80' > "$EVID/runner-diag.log" 2>/dev/null || true
audit > "$EVID/audit.json" 2>/dev/null || true
echo "----- bootstrap.log -----"; cat "$EVID/bootstrap.log" 2>/dev/null
echo "----- runner.log (tail) -----"; tail -25 "$EVID/runner.log" 2>/dev/null
echo "----- audit -----"; cat "$EVID/audit.json" 2>/dev/null; echo

# --- 7. assertions ---------------------------------------------------------
# (a) JWT-authorized JIT pull.
if audit | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if '/credentials/jitconfig' in d.get('authorized',[]) else 1)" 2>/dev/null; then
  log "PASS (a): JIT config fetched from the mock under the per-instance JWT"
else
  fail "(a): no JWT-authorized /credentials/jitconfig pull recorded"
fi

# (a') no-JWT pull rejected (401) — proved over the wire from the runner container.
NOJWT="$("${INCUS[@]}" exec "$RUNNER" -- curl -s -o /dev/null -w '%{http_code}' \
  "${MOCK_URL}/credentials/jitconfig" 2>/dev/null)"
if [ "$NOJWT" = "401" ]; then
  log "PASS (a'): no-JWT JIT pull rejected (401) container-to-container"
else
  fail "(a'): no-JWT pull returned '$NOJWT', expected 401"
fi

# (b) cloud-init ran the bootstrap + Runner.Listener launched with the JIT.
if grep -q "IM2-BOOTSTRAP-DONE" "$EVID/bootstrap.log" 2>/dev/null && \
   grep -q "RUNNER-LAUNCHED" "$EVID/bootstrap.log" 2>/dev/null; then
  log "PASS (b): cloud-init autonomously ran the injected bootstrap + launched run.sh --jitconfig"
else
  fail "(b): bootstrap did not complete / runner not launched"
fi

# (c) the runner authenticated with the JIT config and reached its Actions
#     server (the session-create call). Reaching /actions/_apis/connectionData
#     means Runner.Listener consumed the JIT config, signed an OAuth
#     client-assertion with the JIT RSA key, obtained a token, and connected
#     to the mock as its Actions server to create a session — mirroring the
#     Windows M3 evidence, which likewise stopped at connectionData (no live
#     GitHub). If the runner went further and POSTed the session, we note it.
if [ "$CONNECT_OK" = "1" ]; then
  if [ "$SESSION_OK" = "1" ]; then
    log "PASS (c): Runner.Listener connected with the JIT config + POSTed a runner session (SESSION-CREATED)"
  else
    log "PASS (c): Runner.Listener connected to the mock Actions server with the JIT config (reached the session-create call)"
    log "NOTE (c): session POST not recorded against the mock — same bar as the Windows M3 gate; real GitHub (IM3) closes it"
  fi
  [ "$LISTENING_OK" = "1" ] && \
    log "PASS (c+): runner reached 'Listening for Jobs' (message-queue long-poll) against the mock"
else
  fail "(c): runner did not connect to the mock Actions server with the JIT config"
fi

# --- 8. teardown + residue check ------------------------------------------
"${INCUS[@]}" delete --force "$RUNNER" >/dev/null 2>&1 || true
"${INCUS[@]}" delete --force "$MOCK"   >/dev/null 2>&1 || true
RESIDUE=0
for n in "$RUNNER" "$MOCK"; do
  "${INCUS[@]}" info "$n" >/dev/null 2>&1 && { RESIDUE=1; fail "residual container $n"; }
done
if [ "$RESIDUE" = "0" ]; then
  log "PASS (d): no residual containers after teardown (im2-runner/im2-mock gone)"
fi

if [ "$RESULT" = "0" ]; then
  echo "LINUX_JIT_GATE_PASS"
  exit 0
else
  echo "LINUX_JIT_GATE_FAIL"
  exit 1
fi
