## vm-harness serve — ENROLLMENT + signed IDENTITY (RA6).
##
## Each serve host presents a **signed identity** carrying its capability
## manifest; a controller VERIFIES the signature and REJECTS an unenrolled,
## expired, or revoked identity. This closes the loop the campaign asks for:
## capabilities become first-class + auto-detected + cryptographically bound to
## a host identity, instead of being encoded in a hand-maintained class name.
##
## ── Threat model / why symmetric (documented, deliberate) ────────────────────
## The serve endpoint is ALREADY authenticated + confidential: a bearer token
## over a NetBird (WireGuard) overlay, never exposed publicly (campaign
## non-negotiable pattern (a)). This identity signature is therefore NOT a
## second transport-auth; it is capability/identity ADVERTISEMENT — its job is
## tamper-evidence, host-identity binding, expiry, and revocation on top of a
## transport that already provides confidentiality + endpoint auth.
##
## Given that, and that vm-harness is deliberately dependency-light (Nim stdlib
## ships no asymmetric primitive and we will not link OpenSSL / vendor a curve
## for this), the signature is a detached **HMAC-SHA256** keyed by a per-host
## **enrollment secret** minted at enrollment time and recorded in the
## controller's trust store. The wire format carries an ``alg`` field
## (``"hmac-sha256"``) so a later upgrade to an asymmetric scheme (Ed25519 —
## controller holds only public keys) is a versioned, non-breaking change; that
## upgrade is the documented follow-up (``docs/serve-enrollment.md``).
##
## ── Model ───────────────────────────────────────────────────────────────────
##   * ``keyId``  — a STABLE, non-secret host identifier = ``"vmh1-" &
##     sha256(secret)[0..15]``. Safe to log and to name in the trust store; it
##     does not reveal the secret. Enrolling a host = recording its keyId's
##     secret in the controller's trust store.
##   * The daemon issues SHORT-LIVED signed identities (``issuedAt`` / ``notAfter``
##     from a configurable TTL). The controller caches one and re-fetches after
##     expiry; a stale cached identity fails verification — that is what
##     "expired identity is rejected" means operationally.
##   * Revocation = adding a keyId to the trust store's revoked set (or dropping
##     its secret). A revoked/unknown keyId is rejected before the MAC is even
##     checked.

import std/[json, os, sysrand, algorithm, sets, tables, strutils]
import ./hmac
import ./capability

const
  SigAlg* = "hmac-sha256"
  KeyIdPrefix* = "vmh1-"
  DefaultIdentityTtlSec* = 3600     ## 1h short-lived signed identity by default.

type
  Identity* = object
    ## The signed payload. ``manifest`` is the capability manifest JSON.
    keyId*: string
    host*: string
    issuedAt*: int64                ## unix seconds
    notAfter*: int64                ## unix seconds (0 ⇒ never expires — testing)
    alg*: string                    ## signature algorithm (``SigAlg``)
    manifest*: JsonNode

  SignedIdentity* = object
    identity*: Identity
    sig*: string                    ## hex HMAC over ``canonicalBytes(identity)``

  VerifyStatus* = enum
    vsOk = "ok"
    vsUnenrolled = "unenrolled"     ## keyId not in the trust store
    vsRevoked = "revoked"           ## keyId explicitly revoked
    vsExpired = "expired"           ## now > notAfter
    vsBadSignature = "bad-signature"
    vsBadPayload = "bad-payload"    ## malformed / version-mismatched manifest

  VerifyResult* = object
    ok*: bool
    status*: VerifyStatus
    reason*: string

  TrustStore* = object
    ## Controller side. Maps enrolled ``keyId → secret`` and holds a revoked
    ## set. In-memory; a real controller loads it from agenix-provisioned
    ## material (documented as the infra follow-up).
    secrets: Table[string, string]
    revoked: HashSet[string]

# ── keys + trust store ───────────────────────────────────────────────────────

proc keyIdFor*(secret: string): string =
  ## Derive the stable, non-secret keyId from an enrollment secret.
  KeyIdPrefix & sha256Hex(secret)[0 ..< 16]

proc newEnrollmentSecret*(): string =
  ## Mint a fresh 256-bit enrollment secret (hex), from the OS CSPRNG.
  var buf: array[32, byte]
  discard urandom(buf)
  toHex(buf)

proc newTrustStore*(): TrustStore =
  TrustStore(secrets: initTable[string, string](), revoked: initHashSet[string]())

proc enroll*(store: var TrustStore, secret: string): string {.discardable.} =
  ## Enroll a host by its secret; returns the keyId now trusted.
  let kid = keyIdFor(secret)
  store.secrets[kid] = secret
  kid

proc revoke*(store: var TrustStore, keyId: string) =
  store.revoked.incl(keyId)

proc isEnrolled*(store: TrustStore, keyId: string): bool =
  store.secrets.hasKey(keyId)

proc isRevoked*(store: TrustStore, keyId: string): bool =
  keyId in store.revoked

# ── canonical serialization (language-neutral, deterministic) ────────────────

proc canonicalJson*(node: JsonNode): string =
  ## Deterministic, compact JSON with object keys sorted recursively. This is
  ## the exact byte string that gets signed, so a Go controller (RB) can
  ## reproduce it. Arrays keep their order (semantically meaningful); only
  ## object keys are sorted.
  case node.kind
  of JObject:
    var keys: seq[string]
    for k in node.keys: keys.add(k)
    keys.sort()
    result = "{"
    for i, k in keys:
      if i > 0: result.add(",")
      result.add(escapeJson(k))
      result.add(":")
      result.add(canonicalJson(node[k]))
    result.add("}")
  of JArray:
    result = "["
    for i, item in node.elems:
      if i > 0: result.add(",")
      result.add(canonicalJson(item))
    result.add("]")
  else:
    result = $node

proc identityJson*(id: Identity): JsonNode =
  ## The identity as JSON (the object that gets signed + wired).
  %*{
    "keyId": id.keyId,
    "host": id.host,
    "issuedAt": id.issuedAt,
    "notAfter": id.notAfter,
    "alg": id.alg,
    "manifest": id.manifest}

proc canonicalBytes*(id: Identity): string =
  canonicalJson(identityJson(id))

# ── sign + serialize ─────────────────────────────────────────────────────────

proc buildIdentity*(secret, host: string, manifest: JsonNode,
                    now: int64, ttlSec: int): Identity =
  Identity(
    keyId: keyIdFor(secret),
    host: host,
    issuedAt: now,
    notAfter: (if ttlSec > 0: now + ttlSec.int64 else: 0),
    alg: SigAlg,
    manifest: manifest)

proc sign*(secret: string, id: Identity): SignedIdentity =
  SignedIdentity(identity: id,
                 sig: hmacSha256Hex(secret, canonicalBytes(id)))

proc toJson*(s: SignedIdentity): JsonNode =
  %*{"identity": identityJson(s.identity), "sig": s.sig}

proc parseIdentity(node: JsonNode): Identity =
  Identity(
    keyId: node{"keyId"}.getStr(""),
    host: node{"host"}.getStr(""),
    issuedAt: node{"issuedAt"}.getBiggestInt(0),
    notAfter: node{"notAfter"}.getBiggestInt(0),
    alg: node{"alg"}.getStr(""),
    manifest: (if node.hasKey("manifest"): node["manifest"] else: newJNull()))

proc parseSignedIdentity*(body: string): SignedIdentity =
  ## Parse a ``GET /v1/manifest`` response body. Raises ``ValueError`` on a
  ## malformed envelope.
  let node =
    try: parseJson(body)
    except CatchableError as e:
      raise newException(ValueError, "manifest: invalid JSON: " & e.msg)
  if node.kind != JObject or not node.hasKey("identity") or not node.hasKey("sig"):
    raise newException(ValueError, "manifest: expected {identity, sig}")
  SignedIdentity(identity: parseIdentity(node["identity"]),
                 sig: node{"sig"}.getStr(""))

# ── verify ───────────────────────────────────────────────────────────────────

proc verify*(store: TrustStore, s: SignedIdentity, now: int64): VerifyResult =
  ## The controller-side check. Order matters: identity/enrollment status is
  ## decided BEFORE (and independently of) the cryptographic MAC, so an
  ## unknown/revoked keyId is rejected without a secret even existing.
  let id = s.identity
  if id.keyId.len == 0:
    return VerifyResult(ok: false, status: vsBadPayload, reason: "empty keyId")
  if store.isRevoked(id.keyId):
    return VerifyResult(ok: false, status: vsRevoked,
                        reason: "keyId " & id.keyId & " is revoked")
  if not store.isEnrolled(id.keyId):
    return VerifyResult(ok: false, status: vsUnenrolled,
                        reason: "keyId " & id.keyId & " is not enrolled")
  if id.alg != SigAlg:
    return VerifyResult(ok: false, status: vsBadPayload,
                        reason: "unsupported alg '" & id.alg & "'")
  if id.manifest.isNil or id.manifest.kind != JObject or
     id.manifest{"manifestVersion"}.getStr("") != ManifestVersion:
    return VerifyResult(ok: false, status: vsBadPayload,
                        reason: "manifest missing/has wrong manifestVersion")
  # Signature (constant-time hex compare over the canonical payload).
  let secret = store.secrets[id.keyId]
  let expect = hmacSha256Hex(secret, canonicalBytes(id))
  if not constantTimeHexEq(expect, s.sig):
    return VerifyResult(ok: false, status: vsBadSignature,
                        reason: "signature mismatch")
  # Expiry LAST (only a signature-valid identity's clock is trustworthy).
  if id.notAfter != 0 and now > id.notAfter:
    return VerifyResult(ok: false, status: vsExpired,
                        reason: "identity expired at " & $id.notAfter &
                                " (now " & $now & ")")
  VerifyResult(ok: true, status: vsOk, reason: "")

# ── daemon-side secret resolution ────────────────────────────────────────────

proc resolveEnrollmentSecret*(secret, secretFile, stateDir: string): string =
  ## Precedence, mirroring the bearer-token resolver:
  ##   ``--enroll-secret`` > ``--enroll-secret-file`` > ``$VMH_ENROLL_SECRET``
  ##   > a persisted secret under ``stateDir`` (generated on first run).
  ## The persisted path lets a daemon come up with a STABLE identity across
  ## restarts without operator-provisioned material (dev / self-bootstrap); in
  ## production the operator provisions the secret via agenix / LoadCredential
  ## and enrolls its keyId centrally.
  if secret.len > 0: return secret.strip()
  if secretFile.len > 0:
    if not fileExists(secretFile):
      raise newException(ValueError,
        "--enroll-secret-file '" & secretFile & "': file not found")
    return readFile(secretFile).strip()
  let env = getEnv("VMH_ENROLL_SECRET").strip()
  if env.len > 0: return env
  if stateDir.len > 0:
    let p = stateDir / "enrollment-secret"
    if fileExists(p):
      let existing = readFile(p).strip()
      if existing.len > 0: return existing
    let fresh = newEnrollmentSecret()
    createDir(stateDir)
    writeFile(p, fresh)
    try: setFilePermissions(p, {fpUserRead, fpUserWrite})
    except CatchableError: discard
    return fresh
  ""
