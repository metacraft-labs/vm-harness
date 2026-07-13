#!/usr/bin/env python3
"""Generate a synthetic-but-well-formed GitHub Actions JIT runner config.

Produces the three files the actions runner consumes, in the exact schema
GitHub's generate-jitconfig API emits:

  .runner                 -> JSON runner config (agentId, serverUrl, ...)
  .credentials            -> JSON OAuth credentials (clientId, authorizationUrl)
  .credentials_rsaparams  -> RSA private key params (used to decrypt the
                             session OAuth token)

The base64-of-{filename: base64(contents)} map is what `run.cmd --jitconfig`
accepts. We also emit the individual files so the GARM Windows template's
per-file metadata pull can serve them.

serverUrl / authorizationUrl point at the MOCK GARM metadata/runner endpoint
so Runner.Listener connects there (no live GitHub needed).
"""
import base64
import json
import sys

from cryptography.hazmat.primitives.asymmetric import rsa


def b64u_to_b64std_int(n: int) -> str:
    # GitHub .credentials_rsaparams encodes each RSA parameter as standard
    # base64 of the big-endian unsigned byte representation.
    length = (n.bit_length() + 7) // 8
    return base64.b64encode(n.to_bytes(length, "big")).decode()


def main():
    mock_url = sys.argv[1] if len(sys.argv) > 1 else "http://192.168.122.1:8099"
    outdir = sys.argv[2] if len(sys.argv) > 2 else "/tmp/m3/jit"
    import os
    os.makedirs(outdir, exist_ok=True)

    # Generate an RSA-2048 key (the runner uses it to decrypt the OAuth token
    # the token-service returns during session creation).
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    priv = key.private_numbers()
    pub = priv.public_numbers

    rsaparams = {
        "d": b64u_to_b64std_int(priv.d),
        "dp": b64u_to_b64std_int(priv.dmp1),
        "dq": b64u_to_b64std_int(priv.dmq1),
        "exponent": b64u_to_b64std_int(pub.e),
        "inverseQ": b64u_to_b64std_int(priv.iqmp),
        "modulus": b64u_to_b64std_int(pub.n),
        "p": b64u_to_b64std_int(priv.p),
        "q": b64u_to_b64std_int(priv.q),
    }

    runner_cfg = {
        "agentId": 1,
        "agentName": "ephemeral-windows-jit",
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
        p = os.path.join(outdir, name)
        with open(p, "w") as f:
            json.dump(obj, f)
        return p

    w(".runner", runner_cfg)
    w(".credentials", credentials)
    w(".credentials_rsaparams", rsaparams)

    # The combined --jitconfig payload: base64( { name: base64(contents) } )
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

    # Export the RSA private key PEM so the mock server can encrypt the
    # session OAuth token to it (matching .credentials_rsaparams).
    from cryptography.hazmat.primitives import serialization
    pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption(),
    )
    with open(os.path.join(outdir, "rsa_private.pem"), "wb") as f:
        f.write(pem)

    print("JIT config written to", outdir)


if __name__ == "__main__":
    main()
