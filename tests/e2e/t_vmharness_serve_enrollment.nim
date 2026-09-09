## t_vmharness_serve_enrollment — RA6 gate.
##
## A remote client reads a ``vm-harness serve`` daemon's SIGNED IDENTITY + its
## CAPABILITY MANIFEST over the authenticated ``GET /v1/manifest`` endpoint and
## VERIFIES it against a controller trust store, and:
##
##   (a) an ENROLLED, unexpired identity verifies (``vsOk``);
##   (b) an UNENROLLED identity is rejected (``vsUnenrolled``);
##   (c) an EXPIRED cached identity is rejected (``vsExpired``);
##   (d) a REVOKED identity is rejected (``vsRevoked``);
##   (e) a TAMPERED manifest is rejected (``vsBadSignature``);
##   (f) the manifest's capability detection (arch-level / gpu / nested-virt /
##       rr-hw-counters / …) is asserted against KNOWN FIXTURES.
##
## Mock policy (design doc §9.1 / workspace CLAUDE.md): the ONLY mocks are the
## sanctioned ``noop`` backend (so the daemon is hermetic — no real hypervisor)
## and, for (f), FIXTURE STRINGS fed to the pure capability deciders (a mock
## ``/proc/cpuinfo`` + mock probe outputs). The daemon, the TCP transport, the
## HTTP framing, the bearer-token auth, the HMAC signature, and the trust-store
## verification are all REAL. Hermetic on Linux via ``--backend noop`` and the
## same no-threads self-exec topology as the RA1 roundtrip gate.
##
## Test topology (no threads): the compiled test binary re-execs ITSELF as the
## daemon so a genuine cross-process signed-manifest fetch runs with no external
## binary dependency:
##   * ``<binary> __serve <host> <port> <tokenFile> <portFile> <secretFile>``
##     runs the daemon with a fixed enrollment secret (so the test controls the
##     keyId + can enroll it).

import std/[json, os, osproc, strutils, tempfiles, times, unittest]
import vm_harness

const TestSecret = "ra6-enrollment-secret-2f7c91ab"
const TestToken = "unit-test-bearer-ra6-8d1e"

when isMainModule:
  let params = commandLineParams()
  if params.len >= 6 and params[0] == "__serve":
    let cfg = ServeConfig(
      listenHost: params[1],
      listenPort: parseInt(params[2]),
      token: readFile(params[3]).strip(),
      enrollSecretFile: params[5],
      identityTtlSec: 3600,
      hostId: "test-host",
      workerExe: getAppFilename(),
      workerArgPrefix: @["__vmh_cli"],
      portFile: params[4],
      quiet: true)
    runServe(cfg)
    quit(0)
  elif params.len >= 1 and params[0] == "__vmh_cli":
    # not used by this gate, but keep the worker role consistent with RA1
    quit(0)

proc waitForPort(portFile: string, timeoutSec = 10.0): int =
  let deadline = epochTime() + timeoutSec
  while epochTime() < deadline:
    if fileExists(portFile):
      let raw = readFile(portFile).strip()
      if raw.len > 0:
        try: return parseInt(raw)
        except ValueError: discard
    sleep(50)
  raise newException(IOError, "daemon did not report a port within timeout")

suite "t_vmharness_serve_enrollment":
  let work = createTempDir("vmh-enroll-", "")
  let tokenFile = work / "token"
  let portFile = work / "port"
  let secretFile = work / "enroll-secret"
  writeFile(tokenFile, TestToken)
  writeFile(secretFile, TestSecret)

  let daemon = startProcess(
    getAppFilename(),
    args = @["__serve", "127.0.0.1", "0", tokenFile, portFile, secretFile],
    options = {poParentStreams})
  var port = 0
  try:
    port = waitForPort(portFile)
  except CatchableError:
    daemon.terminate()
    raise

  let addr0 = "127.0.0.1:" & $port
  let client = newServeClient(addr0, TestToken)

  test "unauthenticated / wrong-credential client cannot read the manifest":
    let bad = newServeClient(addr0, "wrong-token")
    expect ServeAuthError:
      discard bad.manifest()

  test "an ENROLLED host's signed identity + manifest verifies":
    let wire = client.manifest()
    let signed = parseSignedIdentity($wire)
    # The daemon derived its keyId from the enrollment secret the controller
    # ALSO holds — so the controller enrolls that keyId into its trust store.
    check signed.identity.keyId == keyIdFor(TestSecret)
    check signed.identity.host == "test-host"
    check signed.identity.alg == SigAlg

    var store = newTrustStore()
    store.enroll(TestSecret)
    let r = store.verify(signed, getTime().toUnix())
    check r.ok
    check r.status == vsOk

    # The signed payload carries a real, machine-checkable capability manifest.
    let m = signed.identity.manifest
    check m["manifestVersion"].getStr == ManifestVersion
    check m["os"].getStr == "linux"
    check m.hasKey("archLevel")
    check m.hasKey("gpu")
    check m.hasKey("nestedVirt")
    check m.hasKey("rrHwCounters")
    # The hypervisor backends this daemon can drive include the noop fixture.
    var sawNoop = false
    for h in m["hypervisors"]:
      if h["id"].getStr == "noop": sawNoop = true
    check sawNoop

  test "an UNENROLLED identity is rejected by the controller":
    let signed = parseSignedIdentity($client.manifest())
    let empty = newTrustStore()          # controller has enrolled nothing
    let r = empty.verify(signed, getTime().toUnix())
    check not r.ok
    check r.status == vsUnenrolled

  test "an EXPIRED cached identity is rejected":
    # The controller caches a signed identity and re-checks it later; once the
    # daemon-set notAfter passes, the cached copy fails verification.
    let signed = parseSignedIdentity($client.manifest())
    var store = newTrustStore()
    store.enroll(TestSecret)
    let future = signed.identity.notAfter + 10
    let r = store.verify(signed, future)
    check not r.ok
    check r.status == vsExpired

  test "a REVOKED identity is rejected even though the signature is valid":
    let signed = parseSignedIdentity($client.manifest())
    var store = newTrustStore()
    let kid = store.enroll(TestSecret)
    store.revoke(kid)
    let r = store.verify(signed, getTime().toUnix())
    check not r.ok
    check r.status == vsRevoked

  test "a TAMPERED manifest fails the signature (forged capability)":
    var signed = parseSignedIdentity($client.manifest())
    var store = newTrustStore()
    store.enroll(TestSecret)
    # Forge a GPU + a higher arch-level the host never signed for.
    signed.identity.manifest["gpu"] = %true
    signed.identity.manifest["archLevel"] = %"x86-64-v4"
    let r = store.verify(signed, getTime().toUnix())
    check not r.ok
    check r.status == vsBadSignature

  test "capability detection matches KNOWN hardware fixtures":
    # (f): the arch-level / gpu / nested-virt / rr-hw-counter deciders the
    # manifest is built from, asserted against mock inputs.
    const v3 = "processor\t: 0\nflags\t: sse sse2 pni ssse3 sse4_1 sse4_2 " &
      "popcnt cx16 lahf_lm movbe avx avx2 bmi1 bmi2 f16c fma\n"
    check archLevelFromFlags(parseCpuFlags(v3), "x86_64") == "x86-64-v3"
    check gpuPresent(false,
      "01:00.0 VGA compatible controller: NVIDIA Corporation GA102")
    check not gpuPresent(false, "00:1f.3 Audio device: Intel Corporation")
    check nestedVirt("Y\n", "N\n")
    check rrHwCounters("1", "x86_64")
    check not rrHwCounters("3", "x86_64")

  # Fixture teardown.
  if daemon.running:
    daemon.terminate()
    discard daemon.waitForExit(timeout = 3000)
  daemon.close()
  removeDir(work)
