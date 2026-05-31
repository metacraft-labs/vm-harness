## Integration test: HyperVBackend lifecycle against a real Hyper-V VM.
##
## *STATUS: pending* — this test REQUIRES a Windows host with the
## Hyper-V Windows Optional Feature enabled and the M69 base VM (the
## ``repro-m69-hyperv`` Hyper-V VM with its ``base-clean`` snapshot)
## already provisioned by reprobuild's ``provision-base-vm.ps1``. On
## non-Windows hosts the test exits early.
##
## Per the M1 test methodology recap: ``integration_*`` tests cover
## one real backend + one real primitive. This file exercises every
## VmBackend method against the real Hyper-V backend in turn:
##
## - ``probeAvailability``: succeeds when ``Get-VM`` is importable.
## - ``revertToBaseline``: restores the ``base-clean`` snapshot and
##   returns a started VmHandle.
## - ``execInGuest``: PowerShell-Direct ``hostname`` returns non-empty.
## - ``copyToGuest`` / ``copyFromGuest``: roundtrip a 1-KB file.
## - ``installArgvTraceShim``: drops a shim wrapping ``useradd``;
##   subsequent guest invocation appends to the trace log.
## - ``stopAndCleanup``: ``Stop-VM -TurnOff`` leaves the VM in Off
##   state; never raises.
##
## The lifecycle exercise is wrapped in a Nim ``try/finally`` so a
## failed assertion still runs cleanup. Failure to revert mid-test
## leaves the VM in a state requiring manual cleanup by the operator;
## the suite's tear-down logs a clear warning so this is detectable.

import std/[os, strutils, tables, tempfiles, unittest]
import vm_harness

when not defined(windows):
  echo "[skip] t_hyperv_lifecycle: integration test requires a Windows host"
  quit(0)

suite "integration_vm_harness_hyperv_lifecycle":
  setup:
    let credPath = getEnv("VMH_HYPERV_CRED_XML",
                          getHomeDir() / "AppData" / "Local" /
                          "Repro" / "hyperv-m69" / "vm-cred.xml")
    let backend = newHyperVBackend(vmName = "repro-m69-hyperv",
                                   credentialCachePath = credPath)

  test "probeAvailability succeeds when Hyper-V module is importable":
    check backend.probeAvailability()

  test "revertToBaseline restores base-clean and returns a started VM":
    var vm: VmHandle
    try:
      vm = backend.revertToBaseline("base-clean")
      check vm.name == "repro-m69-hyperv"
      check vm.baseline == "base-clean"
      # PowerShell Direct should be responsive after the revert.
      let r = backend.execInGuest(vm, initTable[string, string](),
                                  @["powershell.exe", "-NoLogo",
                                    "-Command", "hostname"])
      check r.exitCode == 0
      check r.stdout.len > 0
    finally:
      if vm != nil: backend.stopAndCleanup(vm)

  test "copy roundtrip with a 1KB file":
    var vm: VmHandle
    try:
      vm = backend.revertToBaseline("base-clean")
      let host = createTempDir("vmh-hyperv-", "")
      defer: removeDir(host)
      let payload = repeat('A', 1024)
      writeFile(host / "send.bin", payload)
      backend.copyToGuest(vm, host / "send.bin", "C:\\Temp\\vmh-roundtrip.bin")
      backend.copyFromGuest(vm, "C:\\Temp\\vmh-roundtrip.bin",
                            host / "recv.bin")
      check readFile(host / "recv.bin") == payload
    finally:
      if vm != nil: backend.stopAndCleanup(vm)

  test "installArgvTraceShim writes wrapping invocations to the trace log":
    var vm: VmHandle
    try:
      vm = backend.revertToBaseline("base-clean")
      backend.installArgvTraceShim(vm,
        ArgvTraceShim(wrappedBinaryName: "net",
                      traceLogPath: "C:\\Temp\\net-trace.log"))
      # Trigger an invocation that the shim should capture.
      discard backend.execInGuest(vm, initTable[string, string](),
                                  @["net", "config", "workstation"])
      let host = createTempDir("vmh-hyperv-shim-", "")
      defer: removeDir(host)
      backend.copyFromGuest(vm, "C:\\Temp\\net-trace.log",
                            host / "trace.log")
      let lines = readFile(host / "trace.log")
      check lines.len > 0
    finally:
      if vm != nil: backend.stopAndCleanup(vm)

  test "stopAndCleanup is safe to call twice":
    var vm = backend.revertToBaseline("base-clean")
    backend.stopAndCleanup(vm)
    backend.stopAndCleanup(vm)   # must not raise

  test "auto-selection picks hyperv on a Windows / Windows-guest cell":
    let (id, _) = newBackendForGuest(hpWindows, goWindows,
                                     noopFallback = false)
    check id == biHyperv
