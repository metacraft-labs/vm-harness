## Integration test: NoopBackend exercises every lifecycle method.
##
## Per the test methodology (design doc §9.1), ``NoopBackend`` is the one
## allowed mock — it exists specifically to verify the harness
## scaffolding. This test calls every method and asserts that the
## back-end records the call, mutates its own fake filesystem, and
## propagates the expected errors.

import std/[options, os, strutils, tables, tempfiles, unittest]
import vm_harness

suite "NoopBackend lifecycle":
  test "provisionBaseline is idempotent and records the baseline":
    let b = newNoopBackend()
    b.provisionBaseline(BaselineSpec(name: "test-baseline",
                                     cpus: 2, memoryMB: 4096, diskGB: 50,
                                     guestOs: goLinux,
                                     guestArch: gaArm64))
    b.provisionBaseline(BaselineSpec(name: "test-baseline"))
    check b.provisioned == @["test-baseline"]
    check b.calls.len == 2
    check "provisionBaseline:test-baseline" in b.calls

  test "revertToBaseline raises when baseline missing":
    let b = newNoopBackend()
    expect VmHarnessError:
      discard b.revertToBaseline("never-provisioned")

  test "full revert + exec + cleanup roundtrip":
    let b = newNoopBackend()
    b.provisionBaseline(BaselineSpec(name: "base"))
    let vm = b.revertToBaseline("base")
    check vm.name.startsWith("noop-vm-")
    check vm.baseline == "base"
    check b.activeVms.len == 1

    let r = b.execInGuest(vm, initTable[string, string](),
                          @["/bin/echo", "hi"])
    check r.exitCode == 0
    check "echo" in r.stdout

    b.stopAndCleanup(vm, deleteVm = true)
    check b.activeVms.len == 0
    check b.cleanedVms == @[vm.name]

  test "copyToGuest + copyFromGuest roundtrip a real file":
    let b = newNoopBackend()
    b.provisionBaseline(BaselineSpec(name: "base"))
    let vm = b.revertToBaseline("base")
    defer: b.stopAndCleanup(vm)
    let host = createTempDir("vmh-noop-", "")
    defer: removeDir(host)
    writeFile(host / "payload.txt", "hello")
    b.copyToGuest(vm, host / "payload.txt", "/data/payload.txt")
    b.copyFromGuest(vm, "/data/payload.txt", host / "out.txt")
    check readFile(host / "out.txt") == "hello"

  test "installArgvTraceShim records the shim":
    let b = newNoopBackend()
    b.provisionBaseline(BaselineSpec(name: "base"))
    let vm = b.revertToBaseline("base")
    defer: b.stopAndCleanup(vm)
    b.installArgvTraceShim(vm,
      ArgvTraceShim(wrappedBinaryName: "useradd",
                    traceLogPath: "/tmp/useradd-trace.log"))
    check "useradd" in b.shims
    check b.shims["useradd"] == "/tmp/useradd-trace.log"

  test "stopAndCleanup never raises":
    let b = newNoopBackend()
    b.provisionBaseline(BaselineSpec(name: "base"))
    let vm = b.revertToBaseline("base")
    # Call twice; second call must be safe even though the VM is gone.
    b.stopAndCleanup(vm)
    b.stopAndCleanup(vm)
    check b.activeVms.len == 0
