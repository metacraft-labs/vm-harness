## unit_serve_enrollment — pure RA6 logic: SHA-256/HMAC test vectors, the
## capability deciders against FIXTURE inputs, and the enrollment/identity
## sign+verify state machine.
##
## Mock policy (design doc §9.1 / workspace CLAUDE.md — mocks must be justified
## in the test header): the ONLY mocks here are FIXTURE STRINGS standing in for
## the host-gathered inputs the capability deciders consume — a mock
## ``/proc/cpuinfo``, a mock ``/proc/meminfo``, mock ``lspci`` output, mock
## ``/sys/module/kvm_*`` contents, and mock probe exit results. This is
## sanctioned and necessary: the whole point of RA6 is that every capability is
## a PURE function over an injected input, so it can be asserted against KNOWN
## hardware fixtures without needing that hardware present. No sockets, no
## processes, no real crypto library — the SHA-256/HMAC is the vendored pure
## implementation checked against the published NIST/RFC vectors below.

import std/[json, strutils, unittest]
import vm_harness

suite "unit_serve_enrollment":

  test "SHA-256 matches NIST vectors":
    check sha256Hex("") ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check sha256Hex("abc") ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"

  test "HMAC-SHA256 matches RFC 4231 test case 2":
    check hmacSha256Hex("Jefe", "what do ya want for nothing?") ==
      "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"

  test "constantTimeHexEq":
    check constantTimeHexEq("deadbeef", "deadbeef")
    check not constantTimeHexEq("deadbeef", "deadbee0")
    check not constantTimeHexEq("deadbeef", "dead")

  # ── capability deciders against fixtures ──────────────────────────────────

  const v3Cpuinfo = """
processor	: 0
vendor_id	: GenuineIntel
flags		: fpu vme de pse tsc msr pae cx8 sse sse2 pni ssse3 sse4_1 sse4_2 popcnt cx16 lahf_lm movbe avx avx2 bmi1 bmi2 f16c fma
processor	: 1
flags		: fpu vme de pse tsc msr pae cx8 sse sse2 pni ssse3 sse4_1 sse4_2 popcnt cx16 lahf_lm movbe avx avx2 bmi1 bmi2 f16c fma
"""
  const v2Cpuinfo = """
processor	: 0
flags		: fpu cx8 sse sse2 pni ssse3 sse4_1 sse4_2 popcnt cx16 lahf_lm
"""
  const v4Cpuinfo = """
processor	: 0
flags		: sse sse2 pni ssse3 sse4_1 sse4_2 popcnt cx16 lahf_lm movbe avx avx2 bmi1 bmi2 f16c fma avx512f avx512bw avx512cd avx512dq avx512vl
"""
  const armCpuinfo = """
processor	: 0
Features	: fp asimd evtstrm aes pmull sha1 sha2 crc32
"""

  test "archLevelFromFlags derives x86-64-vN from cpuinfo flags":
    check archLevelFromFlags(parseCpuFlags(v2Cpuinfo), "x86_64") == "x86-64-v2"
    check archLevelFromFlags(parseCpuFlags(v3Cpuinfo), "x86_64") == "x86-64-v3"
    check archLevelFromFlags(parseCpuFlags(v4Cpuinfo), "x86_64") == "x86-64-v4"
    # A bare 64-bit baseline (no v2 group) is v1.
    check archLevelFromFlags(@["fpu", "sse", "sse2"], "amd64") == "x86-64-v1"
    # arm64 has no psABI level.
    check archLevelFromFlags(parseCpuFlags(armCpuinfo), "arm64") == ""

  test "cpuCount + memTotalMb parse /proc":
    check cpuCount(v3Cpuinfo) == 2
    check cpuCount(v2Cpuinfo) == 1
    check memTotalMb("MemTotal:       65805380 kB\nMemFree: 100 kB\n") == 64263

  test "gpuPresent from nvidia-smi OR lspci":
    check gpuPresent(true, "")                    # nvidia-smi succeeded
    check gpuPresent(false,
      "01:00.0 VGA compatible controller: NVIDIA Corporation GA102 [RTX 3090]")
    check gpuPresent(false,
      "07:00.0 3D controller: Advanced Micro Devices, Inc. [AMD/ATI] ...")
    check not gpuPresent(false,
      "00:1f.3 Audio device: Intel Corporation ...")   # not a display class
    check not gpuPresent(false, "")

  test "nestedVirt from /sys/module/kvm_*/parameters/nested":
    check nestedVirt("Y\n", "N\n")
    check nestedVirt("N\n", "1\n")
    check not nestedVirt("N\n", "N\n")
    check not nestedVirt("", "")

  test "rrHwCounters needs x86-64 + perf_event_paranoid <= 1":
    check rrHwCounters("1\n", "x86_64")
    check rrHwCounters("0", "amd64")
    check not rrHwCounters("2", "x86_64")     # PMU locked down
    check not rrHwCounters("1", "arm64")      # rr hw counters are x86-only here
    check not rrHwCounters("", "x86_64")      # unreadable ⇒ not proven

  # ── enrollment / identity sign + verify ───────────────────────────────────

  proc sampleManifest(): JsonNode =
    %*{"manifestVersion": "1", "os": "linux", "arch": "x86_64",
       "archLevel": "x86-64-v3", "cpuCount": 16, "memTotalMb": 64000,
       "gpu": true, "nestedVirt": true, "docker": true, "podman": false,
       "rrHwCounters": true, "hypervisors": [{"id": "incus", "available": true}]}

  test "keyId is stable + derived from the secret, never the secret itself":
    let secret = "enrollment-secret-abc"
    check keyIdFor(secret) == keyIdFor(secret)
    check keyIdFor(secret).startsWith("vmh1-")
    check secret notin keyIdFor(secret)
    check keyIdFor("other") != keyIdFor(secret)

  test "a signed identity from an ENROLLED host verifies":
    let secret = newEnrollmentSecret()
    var store = newTrustStore()
    let kid = store.enroll(secret)
    let id = buildIdentity(secret, "hms", sampleManifest(), now = 1000, ttlSec = 3600)
    check id.keyId == kid
    let signed = sign(secret, id)
    let r = store.verify(signed, now = 1500)
    check r.ok
    check r.status == vsOk

  test "an UNENROLLED identity is rejected":
    let secret = newEnrollmentSecret()
    let store = newTrustStore()          # nothing enrolled
    let signed = sign(secret, buildIdentity(secret, "h", sampleManifest(), 1000, 3600))
    let r = store.verify(signed, 1500)
    check not r.ok
    check r.status == vsUnenrolled

  test "an EXPIRED identity is rejected":
    let secret = newEnrollmentSecret()
    var store = newTrustStore()
    store.enroll(secret)
    let signed = sign(secret, buildIdentity(secret, "h", sampleManifest(),
                                            now = 1000, ttlSec = 100))
    let r = store.verify(signed, now = 2000)    # past notAfter=1100
    check not r.ok
    check r.status == vsExpired

  test "a REVOKED identity is rejected even with a valid signature":
    let secret = newEnrollmentSecret()
    var store = newTrustStore()
    let kid = store.enroll(secret)
    store.revoke(kid)
    let signed = sign(secret, buildIdentity(secret, "h", sampleManifest(), 1000, 3600))
    let r = store.verify(signed, 1500)
    check not r.ok
    check r.status == vsRevoked

  test "a TAMPERED manifest breaks the signature":
    let secret = newEnrollmentSecret()
    var store = newTrustStore()
    store.enroll(secret)
    var signed = sign(secret, buildIdentity(secret, "h", sampleManifest(), 1000, 3600))
    # Forge a capability the host did not sign for (claim a GPU it lacks).
    signed.identity.manifest["gpu"] = %false
    signed.identity.manifest["archLevel"] = %"x86-64-v4"
    let r = store.verify(signed, 1500)
    check not r.ok
    check r.status == vsBadSignature

  test "a wrong-secret signature is rejected (impersonation)":
    let real = newEnrollmentSecret()
    let attacker = newEnrollmentSecret()
    var store = newTrustStore()
    let kid = store.enroll(real)
    # Attacker signs an identity claiming the enrolled keyId but with its own
    # secret — the MAC will not match the enrolled secret.
    var id = buildIdentity(attacker, "h", sampleManifest(), 1000, 3600)
    id.keyId = kid
    let r = store.verify(sign(attacker, id), 1500)
    check not r.ok
    check r.status == vsBadSignature

  test "the signed envelope round-trips through JSON (the wire form)":
    let secret = newEnrollmentSecret()
    var store = newTrustStore()
    store.enroll(secret)
    let signed = sign(secret, buildIdentity(secret, "hms", sampleManifest(), 1000, 3600))
    let wire = $toJson(signed)
    let parsed = parseSignedIdentity(wire)
    check parsed.identity.keyId == signed.identity.keyId
    check store.verify(parsed, 1500).ok

  test "canonicalJson sorts object keys but preserves array order":
    let n = %*{"b": 1, "a": [3, 1, 2], "c": {"z": 1, "y": 2}}
    check canonicalJson(n) == """{"a":[3,1,2],"b":1,"c":{"y":2,"z":1}}"""
