## Teardown gate for the boot-smoke harness (``boot_smoke.nim``).
##
## Hosts that run these gates also run production CI: on the development
## machine this was written against, ``libvirtd`` carries live ``garm-*``
## and ``win-ci-vm-001`` domains, and a boot gate that leaks a VM, a CoW
## overlay or a QEMU process degrades the machine every other gate runs
## on. So teardown is asserted here against *observed system state* — the
## process table via ``/proc``, the filesystem, and ``virsh list --all``
## — never against the code path that was supposed to do it.
##
## Two failure shapes are covered, because they take different exits out
## of the harness:
##
##  - an *assertion* failure (a line the guest never prints), where the
##    VM booted fine and the run ends in the middle of the expect loop; and
##  - a *setup* failure (an image that does not exist), where the boot
##    itself raises and the ``finally`` is reached with a partially built
##    or entirely absent VM.
##
## The gate also asserts a negative that matters on such hosts
## specifically: ``QemuBootBackend`` must never define a libvirt domain.
## It owns a child process, not an entry in a host-global namespace
## shared with production.
##
## *Mocking.* None. A real ``qemu-system-x86_64`` boots the real
## synthetic disk from ``writeSyntheticBootDisk``, and the post-conditions
## are read back from ``/proc``, the filesystem and ``virsh``.

import std/[os, osproc, strutils, unittest]
import vm_harness

when not defined(linux):
  echo "[skip] t_boot_smoke_harness_tears_down_on_failure: " &
    "requires a Linux host (QEMU direct-boot backend; teardown is " &
    "asserted through /proc)"
  quit(0)

const LibvirtUrisToInspect = ["qemu:///session", "qemu:///system"]
  ## Both, deliberately. On a workstation the user's default URI is the
  ## SESSION one, while production CI guests (``garm-*``,
  ## ``win-ci-vm-001``) live on the SYSTEM one. Reading only the default
  ## would make the "the harness defined no domain" assertion look green
  ## while never having looked where a domain would actually appear.

proc libvirtDomainNames(): tuple[names: seq[string], urisSeen: seq[string]] =
  ## Every domain ``virsh list --all --name`` reports, across the URIs in
  ## ``LibvirtUrisToInspect``, plus which of those URIs answered.
  ##
  ## READ-ONLY by construction: this runs ``list`` and nothing else. It
  ## exists to prove a NEGATIVE — that the boot harness never defines a
  ## libvirt domain — on a host whose libvirtd may carry live production
  ## CI guests that must not be touched. ``urisSeen`` is returned so a
  ## caller can tell "nothing matched" apart from "nothing was visible".
  let virsh = findExe("virsh")
  if virsh.len == 0:
    return (@[], @[])
  for uri in LibvirtUrisToInspect:
    try:
      let (output, code) = execCmdEx(
        virsh & " --connect " & uri & " list --all --name")
      if code != 0:
        continue
      result.urisSeen.add(uri)
      for raw in output.splitLines():
        let name = raw.strip()
        if name.len > 0:
          result.names.add(name)
    except CatchableError:
      discard

proc scratchDir(stem: string): string =
  getTempDir() / ("vmh-boot-smoke-teardown-" & stem & "-" &
                  $getCurrentProcessId())

template assertNothingSurvives(r: BootSmokeResult) =
  ## The shared post-conditions, asserted against real system state.
  ##
  ## A template rather than a proc on purpose: ``check`` reports through
  ## ``testStatusIMPL``, which only exists inside a ``test`` body. Called
  ## from a proc, a failing ``check`` still fails the process but the
  ## enclosing case is still printed ``[OK]`` — the failure would be
  ## attributed to no case at all. Expanding at the call site keeps the
  ## right case red.
  block:
    # 1. No QEMU process is still carrying this VM's name. Matching is on
    #    the ``-name <vm>`` argv entry the backend always emits, so this
    #    can only ever see processes this harness created.
    var survivingProcs: seq[string]
    for p in qemuBootProcessesMatching(QemuBootNamePrefix):
      if p.name == r.vmName:
        survivingProcs.add($p.pid & ":" & p.name)
    if survivingProcs.len > 0:
      echo "[diag] surviving QEMU processes: ", survivingProcs.join(", ")
    check survivingProcs.len == 0

    # 2. No run directory, and therefore no CoW overlay disk and no
    #    writable NVRAM copy, is left on the filesystem.
    if dirExists(r.runDir):
      echo "[diag] surviving run dir contents:"
      for kind, path in walkDir(r.runDir):
        echo "[diag]   ", kind, " ", path
    check not dirExists(r.runDir)
    check not fileExists(r.runDir / "overlay.qcow2")

    # 3. No libvirt domain was ever defined for it, on either the session
    #    or the system URI. Read-only: this lists domains, it never
    #    touches one. The visible-domain count is echoed so a reviewer
    #    can see the check had something to look at — where the system URI
    #    carries production guests, an empty match is a real negative and
    #    not a silent "virsh said nothing".
    let visibleDomains = libvirtDomainNames()
    echo "[diag] libvirt URIs answered: ", visibleDomains.urisSeen.join(", "),
         "; domains visible: ", visibleDomains.names.len
    var harnessDomains: seq[string]
    for name in visibleDomains.names:
      if name.startsWith(QemuBootNamePrefix):
        harnessDomains.add(name)
    if harnessDomains.len > 0:
      echo "[diag] unexpected libvirt domains: ", harnessDomains.join(", ")
    check harnessDomains.len == 0

suite "t_boot_smoke_harness_tears_down_on_failure":
  test "a failed serial assertion leaves no VM, no overlay and no process":
    let dir = scratchDir("assertion")
    createDir(dir)
    defer:
      try: removeDir(dir)
      except CatchableError: discard
    let disk = writeSyntheticBootDisk(dir / "synthetic.raw")

    let r = runBootSmoke(BootSmokeSpec(
      caseName: "teardown-after-assertion-failure",
      imagePath: disk,
      imageFormat: "raw",
      generation: 1,
      memoryMB: 256,
      cpus: 1,
      acceleration: baTcg,
      steps: @[
        BootSmokeStep(pattern: SyntheticStage1Marker, timeoutSec: 60,
                      label: "the guest really did boot"),
        BootSmokeStep(pattern: "REPRO-TEARDOWN-GATE-NEVER-PRINTED",
                      timeoutSec: 8,
                      label: "a line the guest never prints"),
      ]))

    # The run really did fail, and really did get far enough to have
    # created something worth tearing down. Without this the teardown
    # assertions below would hold vacuously.
    check r.outcome == bsPatternNotSeen
    check r.matches.len == 2
    check r.matches[0].matched
    check r.vmName.startsWith(QemuBootNamePrefix)
    check r.runDir.len > 0
    check fileExists(r.serialLogPath)

    assertNothingSurvives(r)

  test "a boot that fails during setup leaves nothing behind either":
    let dir = scratchDir("setup")
    createDir(dir)
    defer:
      try: removeDir(dir)
      except CatchableError: discard

    let r = runBootSmoke(BootSmokeSpec(
      caseName: "teardown-after-setup-failure",
      imagePath: dir / "this-image-does-not-exist.qcow2",
      imageFormat: "raw",
      generation: 1,
      memoryMB: 256,
      cpus: 1,
      acceleration: baTcg,
      steps: @[
        BootSmokeStep(pattern: SyntheticStage1Marker, timeoutSec: 5,
                      label: "unreachable — the boot cannot start"),
      ]))

    check r.outcome == bsSetupFailed
    check "does not exist" in r.failureMessage
    assertNothingSurvives(r)

  test "the serial-log artifact survives teardown on the failure path":
    # Teardown removes the run directory; the transcript must NOT be
    # in it, or every failed boot would destroy its own evidence.
    let dir = scratchDir("artifact")
    createDir(dir)
    defer:
      try: removeDir(dir)
      except CatchableError: discard
    let disk = writeSyntheticBootDisk(dir / "synthetic.raw")

    let r = runBootSmoke(BootSmokeSpec(
      caseName: "teardown-preserves-artifact",
      imagePath: disk,
      imageFormat: "raw",
      generation: 1,
      memoryMB: 256,
      cpus: 1,
      acceleration: baTcg,
      steps: @[
        BootSmokeStep(pattern: "REPRO-TEARDOWN-GATE-NEVER-PRINTED",
                      timeoutSec: 8, label: "never printed"),
      ]))

    check r.outcome == bsPatternNotSeen
    check not dirExists(r.runDir)
    check fileExists(r.serialLogPath)
    check not r.serialLogPath.startsWith(r.runDir & DirSep)
    check getFileSize(r.serialLogPath) > 0
    check SyntheticStage1Marker in readFile(r.serialLogPath)
