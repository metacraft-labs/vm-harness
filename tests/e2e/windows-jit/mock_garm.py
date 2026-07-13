#!/usr/bin/env python3
"""Mock GARM metadata + actions-runner endpoint for the M3 gate.

Serves, on http://0.0.0.0:<port>:

GARM metadata routes (the Windows install template pulls these, each
authorized by the per-instance JWT in `Authorization: Bearer <token>`):

  GET  /system/cert-bundle                 -> {"root_certificates": {}}
  GET  /credentials/runner                 -> .runner   (JIT)
  GET  /credentials/credentials            -> .credentials
  GET  /credentials/credentials_rsaparams  -> .credentials_rsaparams
  GET  /system/service-name                -> "actions.runner...."
  POST /status                             -> 200  (progress callback)
  POST /system-info/                       -> 200  (system-info callback)

Actions-runner endpoints (so Runner.Listener, started from the injected
JIT config, reaches the "Listening for Jobs" state):

  POST /actions/oauth/token                -> OAuth bearer token
  *    /actions/...                         -> minimal Azure-DevOps-style
                                              session/message endpoints

The JWT is validated with a shared secret (per-instance token). A wrong /
missing token yields 401 -> proves JWT-authorized secret delivery.

The server records which routes were hit (and with valid auth) to a JSON
audit file so the gate can assert the guest genuinely pulled the JIT
material under the JWT.
"""
import base64
import datetime
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import jwt  # PyJWT

JIT_DIR = os.environ.get("M3_JIT_DIR", "/tmp/m3/jit")
JWT_SECRET = os.environ.get("M3_JWT_SECRET", "m3-mock-garm-instance-secret")
AUDIT_PATH = os.environ.get("M3_AUDIT", "/tmp/m3/mock-audit.json")
SERVICE_NAME = "actions.runner.metacraft-labs.ephemeral-windows-jit"

AUDIT = {"hits": [], "authorized": [], "unauthorized": []}
AUDIT_LOCK = threading.Lock()

# API resource-location GUIDs the actions runner resolves (stable, from the
# GitHub Actions runner source: DistributedTask location IDs).
SESSION_GUID = "134e239e-2df3-4794-a6f6-24f1f19ec8dc"
MESSAGE_GUID = "c3a054a6-7d8d-4eb5-b6d4-234c5d774bbe"
ACCESS_POINT = os.environ.get("M3_ACCESS_POINT", "http://192.168.122.1:8099")

# Minimal Azure-DevOps-style connection-data document. The runner's
# MessageListener resolves service endpoints against this. We advertise no
# location entries; the runner falls back to the base serverUrl for the
# agent-session + message-queue calls, which we answer generically below.
CONNECTION_DATA = {
    "authenticatedUser": {"id": "00000000-0000-0000-0000-000000000001",
                          "providerDisplayName": "ephemeral-windows-jit"},
    "authorizedUser": {"id": "00000000-0000-0000-0000-000000000001"},
    "instanceId": "00000000-0000-0000-0000-000000000002",
    "deploymentId": "00000000-0000-0000-0000-000000000003",
    "deploymentType": "hosted",
    "locationServiceData": {
        "serviceOwner": "00000000-0000-0000-0000-000000000000",
        "defaultAccessMappingMoniker": "PublicAccessMapping",
        "accessMappings": [],
        # The runner has these location GUIDs compiled in; re-registering
        # them triggers VssApiResourceDuplicateIdException. Keep this empty
        # and answer the session/message routes generically (the runner
        # builds the URL from the accessMapping accessPoint below).
        "serviceDefinitions": [],
    },
}


def _connection_data():
    """Return CONNECTION_DATA with @ACCESS_POINT@ placeholders resolved."""
    return json.loads(json.dumps(CONNECTION_DATA).replace("@ACCESS_POINT@", ACCESS_POINT))


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
    token = hdr[len("Bearer "):].strip()
    try:
        jwt.decode(token, JWT_SECRET, algorithms=["HS256"],
                   options={"verify_exp": False})
        return True
    except Exception:
        return False


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

    # Azure-DevOps resource-location discovery (the runner's MessageListener
    # sends OPTIONS /actions/_apis/ then GET connectiondata). Answer with a
    # minimal service-definition doc so it can create a session.
    def do_OPTIONS(self):
        p = self.path.split("?")[0].rstrip("/")
        record("OPTIONS " + p, True)
        return self._send(200, json.dumps({
            "count": 0,
            "value": [],
        }))

    # --- GARM metadata routes (JWT-authorized) ---
    def do_GET(self):
        p = self.path.split("?")[0].rstrip("/")
        # Actions-runner connection endpoints (no JWT; runner uses its own
        # OAuth token). We answer just enough to reach "Listening for Jobs".
        if p.startswith("/actions"):
            return self._actions_get(p)

        authorized = check_jwt(self)
        if p in ("/system/cert-bundle", "/credentials/runner",
                 "/credentials/credentials", "/credentials/credentials_rsaparams",
                 "/system/service-name"):
            if not authorized:
                record(p, False)
                return self._send(401, '{"error":"unauthorized"}')
            record(p, True)
            if p == "/system/cert-bundle":
                return self._send(200, json.dumps({"root_certificates": {}}))
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
        # status / system-info callbacks (JWT-authorized)
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
        if os.environ.get("M3_REQLOG"):
            with open("/tmp/m3/reqlog.txt", "a") as f:
                f.write("GET %s\n" % self.path)
        # connectiondata: tell the runner our (empty) location service +
        # deployment type so it proceeds to resolve endpoints.
        if "connectiondata" in p.lower() or p.endswith("/_apis"):
            return self._send(200, json.dumps(_connection_data()))
        # Message-queue long-poll: the runner is now "Listening for Jobs".
        # Record the milestone and hold briefly (no job to deliver).
        if "/messages" in p:
            record("LISTENING", True)
            import time
            time.sleep(2)
            return self._send(200, json.dumps({}))
        return self._send(200, json.dumps({"count": 0, "value": []}))

    def _actions_post(self, p):
        body = self._read_body()
        record("POST " + p, True)
        if os.environ.get("M3_REQLOG"):
            with open("/tmp/m3/reqlog.txt", "a") as f:
                f.write("POST %s\n%s\n---\n" % (self.path, body[:500].decode("utf-8", "replace")))
        if p == "/actions/oauth/token":
            # Hand back an OAuth bearer token so the runner can create a
            # session. (The runner would decrypt an RSA-encrypted token in
            # the real flow; here we return a plain bearer which is enough
            # for the runner to proceed to session creation against us.)
            tok = jwt.encode(
                {"sub": "ephemeral-windows-jit",
                 "iat": datetime.datetime.utcnow()},
                JWT_SECRET, algorithm="HS256")
            return self._send(200, json.dumps({
                "token_type": "bearer",
                "access_token": tok,
                "expires_in": 3600,
            }))
        # CreateAgentSession -> return a valid session so the runner proceeds
        # to the message-queue long-poll ("Listening for Jobs").
        if "agentsessions" in p or "session" in p:
            record("SESSION-CREATED", True)
            return self._send(200, json.dumps({
                "sessionId": "00000000-0000-0000-0000-000000000009",
                "ownerName": "ephemeral-windows-jit",
                "agent": {"id": 1, "name": "ephemeral-windows-jit"},
                "useFipsEncryption": False,
                "encryptionKey": {"encrypted": False, "value": ""},
            }))
        return self._send(200, json.dumps({
            "sessionId": "00000000-0000-0000-0000-000000000009",
            "encryptionKey": {"encrypted": False, "value": ""},
            "ownerName": "ephemeral-windows-jit",
        }))


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
    # Reset audit
    with open(AUDIT_PATH, "w") as f:
        json.dump(AUDIT, f)
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    sys.stderr.write("[mock-garm] listening on :%d, JIT_DIR=%s\n" % (port, JIT_DIR))
    srv.serve_forever()


if __name__ == "__main__":
    main()
