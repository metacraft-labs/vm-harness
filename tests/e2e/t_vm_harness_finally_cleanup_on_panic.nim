## e2e_vm_harness_finally_cleanup_on_panic (M0 verification).
##
## Verifies that the orchestrator's ``try/finally`` block guarantees
## ``stopAndCleanup`` runs and the output envelope is finalized even
## when a gate phase raises mid-flight. Three sub-cases:
##
## 1. ``execInGuest`` raises — cleanup still runs, verdict is ERROR.
## 2. ``copyToGuest`` raises before exec — cleanup still runs, verdict
##    is ERROR, ``RESULT.txt`` shows the error step.
## 3. A baseline that was never provisioned causes ``revertToBaseline``
##    to raise — no VM handle is ever created so cleanup is skipped,
##    but the envelope is still finalized.
##
## Uses NoopBackend with a poisoned ``execHandler`` / direct
## construction to force the failure paths without touching a real VM.

import std/[os, strutils, tables, tempfiles, times, unittest]
import vm_harness

type
  BoomError = object of CatchableError

  PanicNoopBackend = ref object of NoopBackend
    explodeOn*: string   ## "exec" | "copyTo" | "" (no panic)

method execInGuest*(b: PanicNoopBackend, vm: VmHandle,
                   env: Table[string, string],
                   cmd: seq[string],
                   stdin: string = "",
                   timeoutSec: int = 600): ExecResult =
  b.calls.add("execInGuest:" & cmd.join(" "))
  if b.explodeOn == "exec":
    raise newException(BoomError, "exec exploded")
  procCall execInGuest(NoopBackend(b), vm, env, cmd, stdin, timeoutSec)

method copyToGuest*(b: PanicNoopBackend, vm: VmHandle,
                   hostPath: string, guestPath: string) =
  b.calls.add("copyToGuest:" & hostPath & "->" & guestPath)
  if b.explodeOn == "copyTo":
    raise newException(BoomError, "copyTo exploded")
  procCall copyToGuest(NoopBackend(b), vm, hostPath, guestPath)

proc newPanicNoopBackend(explodeOn: string): PanicNoopBackend =
  result = PanicNoopBackend(
    id: biNoop,
    hostPlatform: detectHostPlatform(),
    supportedGuests: {goLinux, goWindows, goMacos},
    rootDir: getTempDir() / "vmh-panic-" & $epochTime(),
    available: true,
    explodeOn: explodeOn,
    shims: initTable[string, string]())
  createDir(result.rootDir / "guest-fs")

suite "e2e_vm_harness_finally_cleanup_on_panic":
  test "exec raising still triggers cleanup; DONE shows ERROR":
    let outDir = createTempDir("vmh-panic-exec-", "")
    defer: removeDir(outDir)
    let b = newPanicNoopBackend(explodeOn = "exec")
    b.provisionBaseline(BaselineSpec(name: "boom"))
    let envelope = newOutputEnvelope(outDir)
    let gate = GateSpec(name: "exec-boom", baseline: "boom",
                        cmd: @["/bin/true"])

    let r = runGate(b, gate, envelope)
    check r.verdict == vError
    check fileExists(outDir / "DONE")
    check readFile(outDir / "DONE").strip == $vError
    # Cleanup must have run despite the exception.
    check b.activeVms.len == 0
    check b.cleanedVms.len == 1
    # RESULT.txt should reflect the error step and end with the verdict.
    let result = readFile(outDir / "RESULT.txt")
    check "error:BoomError" in result
    check "step: cleanup  status: ok" in result
    check result.strip.splitLines()[^1] == "verdict: ERROR"

  test "copyTo raising before exec still triggers cleanup":
    let outDir = createTempDir("vmh-panic-copy-", "")
    defer: removeDir(outDir)
    let b = newPanicNoopBackend(explodeOn = "copyTo")
    b.provisionBaseline(BaselineSpec(name: "boom"))
    let envelope = newOutputEnvelope(outDir)
    let host = createTempDir("vmh-panic-host-", "")
    defer: removeDir(host)
    writeFile(host / "x", "x")
    let gate = GateSpec(name: "copy-boom", baseline: "boom",
                        cmd: @["/bin/true"],
                        copyTo: @[(host: host / "x", guest: "/tmp/x")])

    let r = runGate(b, gate, envelope)
    check r.verdict == vError
    check fileExists(outDir / "DONE")
    check b.cleanedVms.len == 1
    # execInGuest was never reached.
    let calls = b.calls.join(",")
    check "copyToGuest:" in calls
    check "execInGuest:" notin calls

  test "revert raising leaks no VM handle and still finalizes the envelope":
    let outDir = createTempDir("vmh-panic-revert-", "")
    defer: removeDir(outDir)
    let b = newPanicNoopBackend(explodeOn = "")
    # NOTE: we deliberately skip provisionBaseline so revertToBaseline
    # raises ``VmHarnessError`` inside the orchestrator.
    let envelope = newOutputEnvelope(outDir)
    let gate = GateSpec(name: "revert-boom", baseline: "never-provisioned",
                        cmd: @["/bin/true"])

    let r = runGate(b, gate, envelope)
    check r.verdict == vError
    check fileExists(outDir / "DONE")
    check b.activeVms.len == 0
    check b.cleanedVms.len == 0  # nothing to clean up
    let result = readFile(outDir / "RESULT.txt")
    check "error:" in result
    check result.strip.splitLines()[^1] == "verdict: ERROR"
