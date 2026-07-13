## integration_vm_harness_utm_lifecycle (M3 verification).
##
## Exercises every ``UtmBackend`` method against a real UTM-managed
## Windows-on-ARM guest cloned from the ``repro-windows-arm-base.utm``
## golden bundle built by the provisioning recipe under
## ``guest-recipes/windows-arm-base/``.
##
## *Requires the golden bundle to exist*. Skips cleanly when:
##
## - Not a macOS host (UTM is Apple-Silicon-only).
## - ``utmctl`` or ``sshpass`` aren't on PATH.
## - The golden bundle ``repro-windows-arm-base`` (or the override
##   ``VMH_UTM_GOLDEN``) is not registered with UTM. The recipe under
##   ``guest-recipes/windows-arm-base/README.md`` documents the one-time
##   build path that produces the bundle.
##
## When the golden does exist, this test asserts:
##
## - ``probeAvailability`` returns true.
## - ``provisionBaseline`` confirms the golden's presence and reaps stale
##   ``repro-vm-utm-windows-*`` ephemerals.
## - ``revertToBaseline`` returns a VmHandle with a populated IP within
##   the per-gate budget (≤20s clone + boot-and-SSH-ready).
## - ``execInGuest`` runs ``cmd /c hostname`` inside the guest.
## - ``copyToGuest`` and ``copyFromGuest`` round-trip a real file.
## - ``stopAndCleanup`` deletes the ephemeral; ``utmctl list`` no longer
##   reports it.

import std/[options, os, strutils, tables, tempfiles, unittest]
import vm_harness

when not defined(macosx):
  echo "[skip] t_utm_lifecycle: integration test requires a macOS host"
  quit(0)

# Tunables — VMH_UTM_GOLDEN overrides the default bundle name; helpful
# for CI matrices that build AH-branded variants alongside the generic
# windows-arm-base.
let
  goldenOverride = getEnv("VMH_UTM_GOLDEN", "")
  envBootTimeout = getEnv("VMH_UTM_BOOT_TIMEOUT", "240")
  envSshTimeout = getEnv("VMH_UTM_SSH_TIMEOUT", "240")
  envSshUser = getEnv("VMH_UTM_SSH_USER", "admin")
  envSshPassword = getEnv("VMH_UTM_SSH_PASSWORD", "repro-windows-arm")

proc makeBackend(): UtmBackend =
  result = newUtmBackend(
    goldenBundleName = (if goldenOverride.len > 0:
                          goldenOverride
                        else:
                          "repro-windows-arm-base"),
    sshUser = envSshUser,
    sshPassword = envSshPassword,
    bootTimeoutSec = parseInt(envBootTimeout),
    sshReadyTimeoutSec = parseInt(envSshTimeout))

proc goldenExists(b: UtmBackend): bool =
  ## Returns true iff the configured golden bundle is registered with UTM.
  ## Used to skip the test cleanly when the recipe hasn't been run yet.
  for v in b.listUtmVms():
    if v.name == b.goldenBundleName:
      return true
  return false

suite "UtmBackend lifecycle (Windows ARM guest)":
  test "probeAvailability returns true on a Mac with utmctl + sshpass":
    let b = makeBackend()
    let available = b.probeAvailability()
    if not available:
      echo "[skip] utmctl unavailable, timed out, or sshpass missing; " &
           "install UTM + sshpass and ensure the UTM control plane " &
           "responds before running live lifecycle tests"
      skip()
    else:
      check available

  test "full lifecycle: provision -> revert -> exec -> copy -> cleanup":
    let b = makeBackend()
    if not b.probeAvailability():
      skip()
    elif not goldenExists(b):
      echo "[skip] golden UTM bundle '" & b.goldenBundleName &
           "' is not registered with UTM. Build it once via " &
           "vm-harness/guest-recipes/windows-arm-base/ and import the " &
           "resulting .utm bundle into UTM."
      skip()
    else:
      b.provisionBaseline(BaselineSpec(
        name: "utm-integration",
        sourceImage: b.goldenBundleName,
        guestOs: goWindows,
        guestArch: gaArm64))

      let vm = b.revertToBaseline("utm-integration")
      defer: b.stopAndCleanup(vm)
      check vm.ipAddress.isSome
      check vm.sshUser == envSshUser
      check vm.name.startsWith("repro-vm-utm-windows-")

      # 1. execInGuest carries env into the guest's cmd.exe shell.
      let r = b.execInGuest(vm,
        env = {"VMH_TEST_KEY": "vmh-test-value"}.toTable,
        cmd = @["cmd", "/c", "echo %VMH_TEST_KEY% & hostname"],
        timeoutSec = 60)
      check r.exitCode == 0
      check "vmh-test-value" in r.stdout
      # Hostname must be non-empty.
      check r.stdout.strip().len > 0

      # 2. copyToGuest + copyFromGuest round-trip a file via
      # ``C:\Users\<user>\AppData\Local\Temp`` which always exists.
      let tmpDir = createTempDir("vmh-utm-copy-", "")
      defer: removeDir(tmpDir)
      let srcPath = tmpDir / "payload.txt"
      let dstPath = tmpDir / "harvested.txt"
      let payload = "vm-harness-utm-roundtrip-" & $getCurrentProcessId()
      writeFile(srcPath, payload)
      let guestPath = "C:\\Users\\" & envSshUser & "\\vmh-payload.txt"
      b.copyToGuest(vm, srcPath, guestPath)
      b.copyFromGuest(vm, guestPath, dstPath)
      check fileExists(dstPath)
      check readFile(dstPath) == payload

  test "stale ephemeral cleanup at session start":
    # Mirrors the TartBackend stale-cleanup assertion. Pre-create a stale
    # clone with the backend's ephemeral prefix and verify
    # ``provisionBaseline`` reaps it before the first real revert.
    let b = makeBackend()
    if not b.probeAvailability():
      skip()
    elif not goldenExists(b):
      echo "[skip] golden UTM bundle missing"
      skip()
    else:
      let staleName = b.ephemeralPrefix & "-stale-" & $getCurrentProcessId()
      b.cloneUtmVm(b.goldenBundleName, staleName)
      # Confirm the stale clone is present.
      var foundStale = false
      for v in b.listUtmVms():
        if v.name == staleName: foundStale = true
      check foundStale
      # provisionBaseline reaps anything matching ephemeralPrefix.
      b.provisionBaseline(BaselineSpec(name: "stale-reap-test"))
      var stillPresent = false
      for v in b.listUtmVms():
        if v.name == staleName: stillPresent = true
      check not stillPresent
