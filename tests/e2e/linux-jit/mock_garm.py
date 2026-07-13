#!/usr/bin/env python3
"""Mock GARM metadata + actions-runner endpoint for the IM2 Linux gate.

The Linux/container analog of ``windows-jit/mock_garm.py`` (the M3 Windows
mock). It is deliberately **Python-stdlib-only** (no PyJWT, no cryptography)
so it can run INSIDE a plain Debian cloud Incus container that has nothing
but the base ``python3`` — the JWT is verified with ``hmac``/``hashlib`` and
all RSA/JIT material is pre-generated on the host (by ``gen_jitconfig.py``,
which does have ``cryptography``) and merely SERVED here as static bytes.

Why a container and not the host: on this host the firewall (``nixos-fw``)
does not trust ``incusbr0``, so a container cannot reach a service bound on
the host. Two containers on the same bridge talk L2, so the mock runs in a
sibling container (``im2-mock``) and the runner container reaches it at the
mock's ``incusbr0`` address.

Serves, on http://0.0.0.0:<port>:

GARM metadata routes (each authorized by the per-instance JWT in
``Authorization: Bearer <token>`` — a wrong/missing token yields 401):

  GET  /system/cert-bundle                 -> {"root_certificates": {}}
  GET  /credentials/jitconfig              -> combined base64 --jitconfig blob
  GET  /credentials/runner                 -> .runner   (JIT, GARM parity)
  GET  /credentials/credentials            -> .credentials
  GET  /credentials/credentials_rsaparams  -> .credentials_rsaparams
  GET  /system/service-name                -> "actions.runner...."
  POST /status                             -> 200  (progress callback)
  POST /system-info/                       -> 200  (system-info callback)

Actions-runner endpoints (so Runner.Listener, launched from the injected
``run.sh --jitconfig`` config, reaches the session-create / "Listening for
Jobs" state):

  POST /actions/oauth/token                -> OAuth bearer token
  *    /actions/...                         -> minimal Azure-DevOps-style
                                              session/message endpoints

The server records which routes were hit (and with valid auth) to a JSON
audit file so the gate can assert the guest genuinely pulled the JIT
material under the JWT and that Runner.Listener reached session creation.
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

JIT_DIR = os.environ.get("IM2_JIT_DIR", "/tmp/im2/jit")
JWT_SECRET = os.environ.get("IM2_JWT_SECRET", "im2-mock-garm-instance-secret")
AUDIT_PATH = os.environ.get("IM2_AUDIT", "/tmp/im2/mock-audit.json")
SERVICE_NAME = "actions.runner.metacraft-labs.ephemeral-linux-jit"
ACCESS_POINT = os.environ.get("IM2_ACCESS_POINT", "http://127.0.0.1:8299")

AUDIT = {"hits": [], "authorized": [], "unauthorized": []}
AUDIT_LOCK = threading.Lock()

# Azure-DevOps-style connection-data document. The runner's VSS client
# resolves each API resource by its location GUID against
# ``locationServiceData``; if a GUID it needs (e.g. the TaskAgentSession
# location) is not registered here, it raises "API resource location ... is
# not registered" and never POSTs the session. So we advertise the
# DistributedTask location GUIDs the runner uses to create a session and
# long-poll for messages, resolved (relativeToSetting=Context) against an
# access mapping whose accessPoint is our /actions base. The runner then
# builds the request URL from the access point + its compiled route template
# and POSTs to us, which we answer generically below.
SESSION_LOC = "134e239e-2df3-4794-a6f6-24f1f19ec8dc"   # TaskAgentSession
MESSAGE_LOC = "c3a054f6-7a8a-49c0-944e-3a8e5d7adfd7"   # TaskAgentMessage queue


def _service_def(identifier, rel_path):
    return {
        "serviceType": "TaskAgent",
        "identifier": identifier,
        "displayName": identifier,
        "relativeToSetting": "context",
        "relativePath": rel_path,
        "description": "",
        "serviceOwner": "00000000-0000-0000-0000-000000000000",
        "resourceVersion": 1,
        "minVersion": "1.0",
        "maxVersion": "12.0",
        "releasedVersion": "0.0",
        "status": "active",
        "locationMappings": [],
        "properties": {},
    }


CONNECTION_DATA = {
    "authenticatedUser": {"id": "00000000-0000-0000-0000-000000000001",
                          "providerDisplayName": "ephemeral-linux-jit"},
    "authorizedUser": {"id": "00000000-0000-0000-0000-000000000001"},
    "instanceId": "00000000-0000-0000-0000-000000000002",
    "deploymentId": "00000000-0000-0000-0000-000000000003",
    "deploymentType": "hosted",
    "locationServiceData": {
        "serviceOwner": "00000000-0000-0000-0000-000000000000",
        "defaultAccessMappingMoniker": "PublicAccessMapping",
        "accessMappings": [{
            "displayName": "Public",
            "moniker": "PublicAccessMapping",
            "accessPoint": "@ACCESS_POINT@/actions/",
            "virtualDirectory": "",
        }],
        "serviceDefinitions": [
            _service_def(SESSION_LOC,
                         "_apis/distributedtask/pools/{poolId}/sessions"),
            _service_def(MESSAGE_LOC,
                         "_apis/distributedtask/pools/{poolId}/messages"),
        ],
    },
}


# --- stdlib HS256 JWT (verify + mint) --------------------------------------
def _b64url_decode(s):
    if isinstance(s, str):
        s = s.encode()
    return base64.urlsafe_b64decode(s + b"=" * (-len(s) % 4))


def _b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def verify_jwt(token, secret):
    """Verify an HS256 JWT with only stdlib. Ignores exp (test tokens)."""
    try:
        header_b64, payload_b64, sig_b64 = token.split(".")
        signing_input = (header_b64 + "." + payload_b64).encode()
        expected = hmac.new(secret.encode(), signing_input,
                            hashlib.sha256).digest()
        got = _b64url_decode(sig_b64)
        return hmac.compare_digest(expected, got)
    except Exception:
        return False


def mint_jwt(payload, secret):
    header = _b64url(json.dumps({"alg": "HS256", "typ": "JWT"},
                                separators=(",", ":")).encode())
    body = _b64url(json.dumps(payload, separators=(",", ":")).encode())
    signing_input = (header + "." + body).encode()
    sig = _b64url(hmac.new(secret.encode(), signing_input,
                           hashlib.sha256).digest())
    return header + "." + body + "." + sig


def _connection_data():
    return json.loads(json.dumps(CONNECTION_DATA).replace(
        "@ACCESS_POINT@", ACCESS_POINT))


def load(name):
    with open(os.path.join(JIT_DIR, name), "rb") as f:
        return f.read()


def record(path, ok):
    with AUDIT_LOCK:
        AUDIT["hits"].append(path)
        (AUDIT["authorized"] if ok else AUDIT["unauthorized"]).append(path)
        with open(AUDIT_PATH, "w") as f:
            json.dump(AUDIT, f, indent=2)


def check_jwt(handler):
    hdr = handler.headers.get("Authorization", "")
    if not hdr.startswith("Bearer "):
        return False
    return verify_jwt(hdr[len("Bearer "):].strip(), JWT_SECRET)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("[mock-garm] " + (fmt % args) + "\n")

    def _send(self, code, body=b"", ctype="application/json"):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        p = self.path.split("?")[0].rstrip("/")
        record("OPTIONS " + p, True)
        return self._send(200, json.dumps({"count": 0, "value": []}))

    # --- GARM metadata routes (JWT-authorized) + actions routes ---
    def do_GET(self):
        p = self.path.split("?")[0].rstrip("/")
        if p.startswith("/actions"):
            return self._actions_get(p)

        authorized = check_jwt(self)
        if p in ("/system/cert-bundle", "/credentials/jitconfig",
                 "/credentials/runner", "/credentials/credentials",
                 "/credentials/credentials_rsaparams", "/system/service-name"):
            if not authorized:
                record(p, False)
                return self._send(401, '{"error":"unauthorized"}')
            record(p, True)
            if p == "/system/cert-bundle":
                return self._send(200, json.dumps({"root_certificates": {}}))
            if p == "/credentials/jitconfig":
                return self._send(200, load("jitconfig.b64"),
                                  ctype="text/plain")
            if p == "/credentials/runner":
                return self._send(200, load(".runner"))
            if p == "/credentials/credentials":
                return self._send(200, load(".credentials"))
            if p == "/credentials/credentials_rsaparams":
                return self._send(200, load(".credentials_rsaparams"))
            if p == "/system/service-name":
                return self._send(200, SERVICE_NAME, ctype="text/plain")
        return self._send(404, '{"error":"not found"}')

    def do_POST(self):
        p = self.path.split("?")[0].rstrip("/")
        if p.startswith("/actions"):
            return self._actions_post(p)
        if p in ("/status", "/system-info"):
            ok = check_jwt(self)
            record(p, ok)
            return self._send(200 if ok else 401, "{}")
        return self._send(404, '{"error":"not found"}')

    # --- Actions-runner (Azure DevOps-style) minimal endpoints ---
    def _read_body(self):
        n = int(self.headers.get("Content-Length", "0") or "0")
        return self.rfile.read(n) if n else b""

    def _actions_get(self, p):
        record("GET " + p, True)
        if "connectiondata" in p.lower() or p.endswith("/_apis"):
            return self._send(200, json.dumps(_connection_data()))
        if "/messages" in p:
            record("LISTENING", True)
            time.sleep(2)
            return self._send(200, json.dumps({}))
        return self._send(200, json.dumps({"count": 0, "value": []}))

    def _actions_post(self, p):
        self._read_body()
        record("POST " + p, True)
        if p == "/actions/oauth/token":
            tok = mint_jwt({"sub": "ephemeral-linux-jit",
                            "iat": int(time.time())}, JWT_SECRET)
            return self._send(200, json.dumps({
                "token_type": "bearer",
                "access_token": tok,
                "expires_in": 3600,
            }))
        if "agentsessions" in p or "session" in p:
            record("SESSION-CREATED", True)
            return self._send(200, json.dumps({
                "sessionId": "00000000-0000-0000-0000-000000000009",
                "ownerName": "ephemeral-linux-jit",
                "agent": {"id": 1, "name": "ephemeral-linux-jit"},
                "useFipsEncryption": False,
                "encryptionKey": {"encrypted": False, "value": ""},
            }))
        return self._send(200, json.dumps({
            "sessionId": "00000000-0000-0000-0000-000000000009",
            "encryptionKey": {"encrypted": False, "value": ""},
            "ownerName": "ephemeral-linux-jit",
        }))


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8299
    os.makedirs(os.path.dirname(AUDIT_PATH) or ".", exist_ok=True)
    with open(AUDIT_PATH, "w") as f:
        json.dump(AUDIT, f)
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    sys.stderr.write("[mock-garm] listening on :%d, JIT_DIR=%s\n"
                     % (port, JIT_DIR))
    srv.serve_forever()


if __name__ == "__main__":
    main()
