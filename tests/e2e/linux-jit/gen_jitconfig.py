#!/usr/bin/env python3
"""Generate a synthetic-but-well-formed GitHub Actions JIT runner config.

Runs on the HOST (needs ``cryptography``); the produced files are served by
the stdlib-only ``mock_garm.py`` from inside the mock container. Produces the
three files the actions runner consumes, in the exact schema GitHub's
generate-jitconfig API emits, plus the combined base64 blob that
``run.sh --jitconfig`` accepts:

  .runner                 -> JSON runner config (agentId, serverUrl, ...)
  .credentials            -> JSON OAuth credentials (clientId, authorizationUrl)
  .credentials_rsaparams  -> RSA private key params (the runner signs its
                             OAuth client-assertion with this key)
  jitconfig.b64           -> base64( { filename: base64(contents) } ), the
                             argument to ``run.sh --jitconfig``

serverUrl / authorizationUrl point at the MOCK GARM metadata/runner endpoint
so Runner.Listener connects there (no live GitHub needed).
"""
import base64
import json
import os
import sys

from cryptography.hazmat.primitives.asymmetric import rsa


def b64_int(n: int) -> str:
    length = (n.bit_length() + 7) // 8
    return base64.b64encode(n.to_bytes(length, "big")).decode()


def main():
    mock_url = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8299"
    outdir = sys.argv[2] if len(sys.argv) > 2 else "/tmp/im2/jit"
    os.makedirs(outdir, exist_ok=True)

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    priv = key.private_numbers()
    pub = priv.public_numbers

    rsaparams = {
        "d": b64_int(priv.d),
        "dp": b64_int(priv.dmp1),
        "dq": b64_int(priv.dmq1),
        "exponent": b64_int(pub.e),
        "inverseQ": b64_int(priv.iqmp),
        "modulus": b64_int(pub.n),
        "p": b64_int(priv.p),
        "q": b64_int(priv.q),
    }

    runner_cfg = {
        "agentId": 1,
        "agentName": "ephemeral-linux-jit",
        "poolId": 1,
        "poolName": "Default",
        "ephemeral": True,
        "serverUrl": mock_url + "/actions",
        "gitHubUrl": "https://github.com/metacraft-labs/ephemeral-runners",
        "workFolder": "_work",
    }

    credentials = {
        "scheme": "OAuth",
        "data": {
            "clientId": "00000000-0000-0000-0000-000000000001",
            "authorizationUrl": mock_url + "/actions/oauth/token",
            "oauthEndpointUrl": mock_url + "/actions/oauth/token",
            "requireFipsCryptography": False,
        },
    }

    def w(name, obj):
        with open(os.path.join(outdir, name), "w") as f:
            json.dump(obj, f)

    w(".runner", runner_cfg)
    w(".credentials", credentials)
    w(".credentials_rsaparams", rsaparams)

    def enc(obj):
        return base64.b64encode(json.dumps(obj).encode()).decode()

    jit_map = {
        ".runner": enc(runner_cfg),
        ".credentials": enc(credentials),
        ".credentials_rsaparams": enc(rsaparams),
    }
    combined = base64.b64encode(json.dumps(jit_map).encode()).decode()
    with open(os.path.join(outdir, "jitconfig.b64"), "w") as f:
        f.write(combined)

    print("JIT config written to", outdir)


if __name__ == "__main__":
    main()
