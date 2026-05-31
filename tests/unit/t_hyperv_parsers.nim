## Unit tests for the HyperVBackend and shared process_helpers parsers.
##
## These cover pure-logic helpers — verdict parsing, RESULT.txt
## decoding, and PowerShell argv construction. None of them touch a
## VM, so they run on any host including macOS (where this M1 was
## authored).

import std/[os, sequtils, tempfiles, unittest]
import vm_harness

suite "parseScriptVerdict":
  test "PASS verdict":
    let v = parseScriptVerdict("VERDICT: PASS")
    check v.kind == svPass
    check v.exitCode == -1
    check v.timeoutMinutes == -1

  test "FAIL with exit code":
    let v = parseScriptVerdict("VERDICT: FAIL exit=1")
    check v.kind == svFail
    check v.exitCode == 1

  test "FAIL with multi-digit exit":
    let v = parseScriptVerdict("VERDICT: FAIL exit=42")
    check v.kind == svFail
    check v.exitCode == 42

  test "TIMEOUT verdict carries minutes":
    let v = parseScriptVerdict("VERDICT: TIMEOUT after 45 min")
    check v.kind == svTimeout
    check v.timeoutMinutes == 45

  test "ERROR verdict":
    let v = parseScriptVerdict("VERDICT: ERROR: something exploded")
    check v.kind == svError

  test "lowercase verdict prefix tolerated":
    let v = parseScriptVerdict("verdict: PASS")
    check v.kind == svPass

  test "non-verdict line is svUnknown":
    let v = parseScriptVerdict("step: foo  status: ok")
    check v.kind == svUnknown

suite "parseScriptStep":
  test "reprobuild column-aligned form":
    let s = parseScriptStep("revert                   OK")
    check s.name == "revert"
    check s.status == "OK"

  test "reprobuild step with multi-word status":
    let s = parseScriptStep("gate-run                 FAIL exit=2")
    check s.name == "gate-run"
    check s.status == "FAIL exit=2"

  test "vm-harness native step form":
    let s = parseScriptStep("step: revert  status: ok  elapsed_ms: 12345")
    check s.name == "revert"
    check s.status == "ok"
    check s.elapsedMs == 12345

  test "blank line yields empty step":
    let s = parseScriptStep("")
    check s.name == ""

  test "name-only line records the name":
    let s = parseScriptStep("just-a-token")
    check s.name == "just-a-token"
    check s.status == ""

suite "parseScriptResult":
  test "parses a hyperv-style RESULT.txt":
    let rt = """M69 Hyper-V destructive-gate run - RESULT
generated:      2026-05-31 12:00:00
host:           HYPERV-HOST  user: User
vm:             repro-m69-hyperv
gate:           feature-capability
scenario:       base-clean
wall-clock min: 4.2

revert                   OK
boot                     OK
gsi-ready                OK
prep-harness-dirs        OK
stage-binaries           OK
stage-vs-bootstrapper    SKIPPED: D:\metacraft\hyperv-m69-system-cache\vs_buildtools.exe missing
gate-run                 PASS
harvest-vm-diag          OK (D:\metacraft\hyperv-m69-system-out\feature-capability-base-clean\m69-vm-diag.zip, 12345 bytes)

VERDICT: PASS
"""
    let r = parseScriptResult(rt, donePresent = true)
    check r.done
    check r.verdict.kind == svPass
    check r.steps.len == 8
    let names = r.steps.mapIt(it.name)
    check "revert" in names
    check "gate-run" in names

  test "parses a wsl-style RESULT.txt with FAIL verdict":
    let rt = """M69 POSIX destructive-gate WSL harness - RESULT
generated:      2026-05-31 13:00:00
host:           WSL-HOST  user: User
distro:         repro-m69-posix-12345
wall-clock min: 18.6

gateE_passwd_exit                       1
gateE_passwd_status                     FAIL
gateE_passwd_log                        passwd.user-run.txt

VERDICT: FAIL exit=1
"""
    let r = parseScriptResult(rt, donePresent = true)
    check r.done
    check r.verdict.kind == svFail
    check r.verdict.exitCode == 1
    check r.steps.len == 3

  test "missing DONE marks not-done":
    let r = parseScriptResult("VERDICT: PASS\n", donePresent = false)
    check not r.done
    check r.verdict.kind == svPass

  test "empty input yields svUnknown verdict":
    let r = parseScriptResult("", donePresent = false)
    check r.verdict.kind == svUnknown
    check r.steps.len == 0

suite "readScriptResult":
  test "reads RESULT.txt and DONE sentinel from disk":
    let dir = createTempDir("vmh-parser-", "")
    defer: removeDir(dir)
    writeFile(dir / "RESULT.txt", "step: a  status: ok\nVERDICT: PASS\n")
    writeFile(dir / "DONE", "done\n")
    let r = readScriptResult(dir)
    check r.done
    check r.verdict.kind == svPass
    check r.steps.len == 1
    check r.steps[0].name == "a"

  test "missing files yield empty unknown result":
    let dir = createTempDir("vmh-parser-empty-", "")
    defer: removeDir(dir)
    let r = readScriptResult(dir)
    check not r.done
    check r.verdict.kind == svUnknown

suite "toVerdict":
  test "verdict mapping covers all kinds":
    check toVerdict(ScriptVerdict(kind: svPass)) == vPass
    check toVerdict(ScriptVerdict(kind: svFail, exitCode: 1)) == vFail
    check toVerdict(ScriptVerdict(kind: svTimeout)) == vError
    check toVerdict(ScriptVerdict(kind: svError)) == vError
    check toVerdict(ScriptVerdict(kind: svUnknown)) == vIncomplete

suite "buildPwshArgs":
  test "standard launcher flags are prepended":
    let a = buildPwshArgs(plPwsh, "C:\\scripts\\foo.ps1",
                          ["-Gate", "feature-capability"])
    check a[0] == "pwsh"
    check a[1] == "-NoLogo"
    check a[2] == "-NoProfile"
    check a[3] == "-ExecutionPolicy"
    check a[4] == "Bypass"
    check a[5] == "-File"
    check a[6] == "C:\\scripts\\foo.ps1"
    check a[7] == "-Gate"
    check a[8] == "feature-capability"

  test "Windows PowerShell launcher renders as 'powershell'":
    let a = buildPwshArgs(plPowershell, "C:\\s.ps1", [])
    check a[0] == "powershell"

suite "buildHyperVRunArgs":
  test "minimal invocation drops empty flags":
    let inv = HyperVRunInvocation(
      scriptPath: "C:\\scripts\\run.ps1",
      gate: "feature-capability")
    let a = buildHyperVRunArgs(plPwsh, inv)
    check "-Gate" in a
    check "feature-capability" in a
    check "-Scenario" notin a
    check "-OutDir" notin a
    check "-GateTimeoutMinutes" notin a
    check "-KeepVmRunning" notin a

  test "all flags propagate":
    let inv = HyperVRunInvocation(
      scriptPath: "C:\\scripts\\run.ps1",
      gate: "feature-capability",
      scenario: "base-clean",
      outDir: "D:\\out",
      gateTimeoutMinutes: 30,
      keepVmRunning: true)
    let a = buildHyperVRunArgs(plPwsh, inv)
    check "-Scenario" in a
    check "base-clean" in a
    check "-OutDir" in a
    check "D:\\out" in a
    check "-GateTimeoutMinutes" in a
    check "30" in a
    check "-KeepVmRunning" in a

suite "buildHyperVProvisionArgs":
  test "default invocation has no flags":
    let inv = HyperVProvisionInvocation(
      scriptPath: "C:\\scripts\\provision.ps1")
    let a = buildHyperVProvisionArgs(plPwsh, inv)
    check "-Force" notin a
    check "-VhdxOverridePath" notin a
    check "-SkipVsInstall" notin a

  test "all flags propagate":
    let inv = HyperVProvisionInvocation(
      scriptPath: "C:\\scripts\\provision.ps1",
      force: true,
      vhdxOverridePath: "D:\\custom.vhdx",
      skipVsInstall: true)
    let a = buildHyperVProvisionArgs(plPwsh, inv)
    check "-Force" in a
    check "-VhdxOverridePath" in a
    check "D:\\custom.vhdx" in a
    check "-SkipVsInstall" in a

suite "newHyperVBackend":
  test "construction sets the expected identity":
    let b = newHyperVBackend(vmName = "test-vm",
                             credentialCachePath = "C:\\cred.xml")
    check b.id == biHyperv
    check b.hostPlatform == hpWindows
    check goWindows in b.supportedGuests
    check goLinux in b.supportedGuests
    check b.vmName == "test-vm"
    check b.credentialCachePath == "C:\\cred.xml"

  test "M0 registry auto-registers a default instance":
    # The factory registered by hyperv.nim's bootstrap should produce a
    # backend identifiable as biHyperv. (We can't actually exec on Mac
    # but the construction is OS-independent.)
    let b = newBackend(biHyperv)
    check b.id == biHyperv
    check b of HyperVBackend

  test "probeAvailability returns false off-Windows":
    let b = newHyperVBackend()
    check not b.probeAvailability()
