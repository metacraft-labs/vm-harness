## e2e_vm_harness_smoke (M0 verification).
##
## Drives the harness through one full lifecycle using NoopBackend (the
## one allowed mock per design doc §9.1). Asserts:
##
## 1. ``provisionBaseline → revertToBaseline → execInGuest →
##    copyToGuest → installArgvTraceShim → copyFromGuest →
##    stopAndCleanup`` all run in order.
## 2. The host-side output envelope contains every mandatory file
##    (``00-provision.log``, ``02-<cmd>-run.txt``, ``RESULT.txt``, ``DONE``).
## 3. The ``DONE`` sentinel is written last and contains the verdict.
## 4. Re-running against the same output dir overwrites the stale
##    sentinel — the second run's DONE matches the second verdict.

import std/[os, strutils, tables, tempfiles, unittest]
import vm_harness

suite "e2e_vm_harness_smoke":
  test "full lifecycle with NoopBackend produces expected file layout":
    let outDir = createTempDir("vmh-smoke-", "")
    defer: removeDir(outDir)
    let host = createTempDir("vmh-smoke-host-", "")
    defer: removeDir(host)
    writeFile(host / "payload.txt", "smoke-content")

    let b = newNoopBackend()
    b.provisionBaseline(BaselineSpec(name: "smoke-baseline",
                                     cpus: 2, memoryMB: 4096, diskGB: 50,
                                     guestOs: goLinux,
                                     guestArch: gaArm64))

    let envelope = newOutputEnvelope(outDir)
    envelope.logProvision("smoke run starting")

    let gate = GateSpec(
      name: "smoke",
      baseline: "smoke-baseline",
      env: {"SMOKE_TEST": "1"}.toTable,
      cmd: @["/bin/echo", "smoke"],
      copyTo: @[(host: host / "payload.txt", guest: "/tmp/payload.txt")],
      copyFrom: @[(guest: "/tmp/payload.txt", host: host / "out.txt")],
      shims: @[ArgvTraceShim(wrappedBinaryName: "useradd",
                             traceLogPath: "/tmp/useradd-trace.log")])

    let result = runGate(b, gate, envelope)

    # 1. Lifecycle ordering — NoopBackend records every call.
    let calls = b.calls.join(",")
    check "provisionBaseline:smoke-baseline" in calls
    check "revertToBaseline:smoke-baseline" in calls
    check "copyToGuest:" in calls
    check "installArgvTraceShim:useradd" in calls
    check "execInGuest:" in calls
    check "copyFromGuest:" in calls
    check "stopAndCleanup:" in calls
    # Provision must precede revert, revert must precede exec,
    # exec must precede cleanup.
    let revertIdx = calls.find("revertToBaseline")
    let execIdx = calls.find("execInGuest")
    let cleanupIdx = calls.find("stopAndCleanup")
    check revertIdx < execIdx
    check execIdx < cleanupIdx

    # 2. Mandatory envelope files exist.
    check fileExists(outDir / "00-provision.log")
    check fileExists(outDir / "RESULT.txt")
    check fileExists(outDir / "DONE")
    var hasRunFile = false
    for kind, path in walkDir(outDir):
      if kind == pcFile and "02-echo" in extractFilename(path):
        hasRunFile = true
    check hasRunFile

    # 3. DONE was written last and matches the verdict.
    check result.verdict == vPass
    check readFile(outDir / "DONE").strip == $vPass
    let resultTxt = readFile(outDir / "RESULT.txt")
    check "verdict: PASS" in resultTxt
    # The verdict line is the last non-empty row in RESULT.txt.
    let lines = resultTxt.strip.splitLines()
    check lines[^1].startsWith("verdict: ")

    # 4. The copy-from artifact actually round-tripped through
    # NoopBackend's fake filesystem.
    check fileExists(host / "out.txt")
    check readFile(host / "out.txt") == "smoke-content"

  test "rerun against the same output dir overwrites the stale DONE":
    let outDir = createTempDir("vmh-smoke-rerun-", "")
    defer: removeDir(outDir)
    let b = newNoopBackend()
    b.provisionBaseline(BaselineSpec(name: "rerun-baseline"))

    # First run — writes DONE=PASS.
    block firstRun:
      let envelope = newOutputEnvelope(outDir)
      let gate = GateSpec(name: "first", baseline: "rerun-baseline",
                          cmd: @["/bin/true"])
      discard runGate(b, gate, envelope)
      check fileExists(outDir / "DONE")
      check readFile(outDir / "DONE").strip == "PASS"

    # Second run — newOutputEnvelope must clear the stale DONE before
    # we get to finalize again.
    block secondRun:
      # Force a failure by handing back exitCode != 0.
      b.execHandler = proc(cmd: seq[string]): ExecResult =
        ExecResult(exitCode: 2, stdout: "", stderr: "boom", elapsedMs: 1)
      let envelope = newOutputEnvelope(outDir)
      # newOutputEnvelope must have removed the prior DONE sentinel.
      check not fileExists(outDir / "DONE")
      let gate = GateSpec(name: "second", baseline: "rerun-baseline",
                          cmd: @["/bin/false"])
      let r = runGate(b, gate, envelope)
      check r.verdict == vFail
      check readFile(outDir / "DONE").strip == "FAIL"
