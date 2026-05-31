## Integration test: WslBackend lifecycle against a real WSL2 host.
##
## *STATUS: pending* — this test REQUIRES a Windows host with WSL2
## installed and the Ubuntu rootfs tarball already cached at
## ``$VMH_WSL_ROOTFS`` (defaults to
## ``D:\metacraft\wsl-m69-posix-cache\ubuntu-jammy-...rootfs.tar.gz``).
## On non-Windows hosts the test exits early.
##
## Covers the WslBackend's lifecycle methods one at a time, mirroring
## ``t_hyperv_lifecycle.nim`` in shape.

import std/[os, strutils, tables, tempfiles, unittest]
import vm_harness

when not defined(windows):
  echo "[skip] t_wsl_lifecycle: integration test requires a Windows host"
  quit(0)

suite "integration_vm_harness_wsl_lifecycle":
  setup:
    let rootfs = getEnv("VMH_WSL_ROOTFS",
                        DefaultRootfsTarballPath)
    let stateDir = getEnv("VMH_WSL_STATE_ROOT",
                         DefaultInstallRootDir)
    let backend = newWslBackend(distroPrefix = "vmh-it-wsl",
                                rootfsTarballPath = rootfs,
                                installRootDir = stateDir)

  test "probeAvailability succeeds when wsl --status returns 0":
    check backend.probeAvailability()

  test "provisionBaseline succeeds when rootfs is present":
    backend.provisionBaseline(BaselineSpec(name: "ubuntu",
                                          sourceImage: rootfs,
                                          guestOs: goLinux))

  test "revertToBaseline imports a throwaway distro and exec works":
    var vm: VmHandle
    try:
      vm = backend.revertToBaseline("ubuntu")
      check vm.name.startsWith("vmh-it-wsl-")
      let r = backend.execInGuest(vm, initTable[string, string](),
                                  @["whoami"])
      check r.exitCode == 0
      check r.stdout.strip() == "root"
    finally:
      if vm != nil: backend.stopAndCleanup(vm)

  test "env propagates and copy roundtrip works":
    var vm: VmHandle
    try:
      vm = backend.revertToBaseline("ubuntu")
      var env = initTable[string, string]()
      env["MY_VAR"] = "test-value"
      let r = backend.execInGuest(vm, env, @["sh", "-c", "echo $MY_VAR"])
      check r.exitCode == 0
      check r.stdout.strip() == "test-value"

      let host = createTempDir("vmh-wsl-", "")
      defer: removeDir(host)
      writeFile(host / "send.txt", "hello-from-host")
      backend.copyToGuest(vm, host / "send.txt", "/tmp/from-host.txt")
      let cat = backend.execInGuest(vm, initTable[string, string](),
                                    @["cat", "/tmp/from-host.txt"])
      check cat.stdout.strip() == "hello-from-host"
    finally:
      if vm != nil: backend.stopAndCleanup(vm)

  test "installArgvTraceShim records subsequent invocations":
    var vm: VmHandle
    try:
      vm = backend.revertToBaseline("ubuntu")
      backend.installArgvTraceShim(vm,
        ArgvTraceShim(wrappedBinaryName: "useradd",
                      traceLogPath: "/tmp/useradd-trace.log"))
      let r = backend.execInGuest(vm, initTable[string, string](),
                                  @["useradd", "-m", "vmh-test-user"])
      # We don't care about exit code (useradd may need privileges); we
      # do care that the trace log gained at least one row.
      let tail = backend.execInGuest(vm, initTable[string, string](),
                                     @["cat", "/tmp/useradd-trace.log"])
      check tail.exitCode == 0
      check tail.stdout.contains("useradd")
    finally:
      if vm != nil: backend.stopAndCleanup(vm)

  test "stopAndCleanup unregisters the throwaway distro":
    let vm = backend.revertToBaseline("ubuntu")
    let nameBefore = vm.name
    backend.stopAndCleanup(vm)
    check nameBefore notin backend.listDistros()

  test "auto-selection picks wsl on Windows / Linux-guest cell":
    let (id, _) = newBackendForGuest(hpWindows, goLinux,
                                     noopFallback = false)
    check id == biWsl
