## t_libvirt_snapshot_surface_conformance (campaign WR0 gate).
##
## Round-trips the libvirt snapshot surface against REAL ``virsh`` and a
## REAL libvirt daemon — no fakes anywhere in this file. What it proves:
##
##   (a) SURFACE — ``snapshot`` / ``listSnapshots`` / ``restoreSnapshot`` /
##       ``removeSnapshot`` round-trip: a created snapshot appears in the
##       list, a removed one does not, and removing a missing one is a
##       no-op rather than an error.
##   (b) PRECONDITION — ``snapshotRunning`` against a shut-off domain
##       raises with the precondition message and creates NO snapshot. This
##       is the guard that stops a RAM-less snapshot from masquerading as a
##       warm one and quietly booting on restore.
##   (c) **The saved state is not rewritten by a restore.** The frozen disk
##       file is byte-identical, and its mtime unchanged, after two
##       restores — which is the property the warm-pool cost argument rests
##       on ("prepare once, restore many"). If a restore rewrote the saved
##       state, every recycle would pay a write proportional to the guest,
##       and WR1's sizing would be wrong.
##   (d) HOT-PATH MECHANISM — ``snapshotRunning`` against a RUNNING domain
##       succeeds: virsh accepts the ``--live`` + external-memspec argv, a
##       real memory image appears, the scratch overlay lands at exactly the
##       path ``snapshotDiskPathFor`` generates, ``restoreSnapshot`` consumes
##       the hot snapshot, and ``removeSnapshot`` sweeps the memory image.
##       The saved state survives a HOT restore too — the stronger form of
##       (c), since a memory image is the thing a restore might have been
##       expected to consume destructively.
##
## WHAT THIS TEST DOES NOT COVER, said plainly. The domain here has no
## operating system. That bounds (d) precisely: it proves the MECHANISM of a
## running-state snapshot, and proves nothing about resume-not-boot
## SEMANTICS — a kernel has to exist before it can survive a restore. It also
## says nothing about cost at Windows-lane memory sizes. Both of those are
## ``t_libvirt_live_snapshot_restore.nim``'s job, against a real guest. Do not
## read a green run here as evidence that warm restore is faster than booting.
##
## SAFETY. This test DEFINES a libvirt domain, so it refuses to run unless
## it is told to, twice over:
##
##   * ``VMH_LIBVIRT_SCRATCH=1`` must be set, and
##   * the connection URI must be a user-mode ``/session`` one.
##
## high-mem-server's ``qemu:///system`` carries the production ephemeral
## runner fleet (``garm-*``) and ``win-ci-vm-001``; a test must not be one
## typo away from defining domains next to them. The scratch domain is
## named ``vmh-wr0-conformance-<pid>``, is never asked to boot an OS, and is
## destroyed + undefined in a ``finally``.
##
## Run:
##   export LIBVIRT_DEFAULT_URI=qemu:///session
##   export VMH_LIBVIRT_SCRATCH=1
##   nim r --hints:off tests/e2e/t_libvirt_snapshot_surface_conformance.nim

import std/[os, osproc, strutils, times, unittest]
import vm_harness

when not defined(linux):
  echo "[skip] t_libvirt_snapshot_surface_conformance: Linux host required"
  quit(0)

if getEnv("VMH_LIBVIRT_SCRATCH") != "1":
  echo "[skip] t_libvirt_snapshot_surface_conformance: VMH_LIBVIRT_SCRATCH=1 " &
       "not set. This gate DEFINES a throwaway libvirt domain, so it is " &
       "opt-in by design — see the safety note in this file's header."
  quit(0)

let b = newLibvirtBackend()

if "/session" notin b.libvirtUri:
  echo "[skip] t_libvirt_snapshot_surface_conformance: refusing to define a " &
       "scratch domain on '" & b.libvirtUri & "'. Set " &
       "LIBVIRT_DEFAULT_URI=qemu:///session — the system connection on a " &
       "runner host carries the production fleet."
  quit(0)

if not b.probeAvailability():
  echo "[skip] t_libvirt_snapshot_surface_conformance: libvirt not reachable " &
       "at " & b.libvirtUri & " (is the user session libvirtd running?)"
  quit(0)

let domName = "vmh-wr0-conformance-" & $getCurrentProcessId()
let workDir = getTempDir() / domName
let diskPath = workDir / "disk.qcow2"

proc virsh(args: varargs[string]): tuple[output: string, exitCode: int] =
  var cmd = "virsh --connect " & quoteShell(b.libvirtUri)
  for a in args: cmd.add(" " & quoteShell(a))
  execCmdEx(cmd)

proc cleanup() =
  discard virsh("destroy", domName)
  discard virsh("undefine", domName)
  try: removeDir(workDir)
  except CatchableError: discard

proc fileFingerprint(path: string): string =
  ## Content + mtime. A restore that rewrote the saved state would move
  ## either one.
  let info = getFileInfo(path)
  readFile(path) & "|" & $info.lastWriteTime.toUnix() & "|" & $info.size

createDir(workDir)
# The domain deliberately has NO bootable media: `restoreSnapshot` passes
# --running, so the domain does start, and a guest that halts in firmware
# costs the host essentially nothing. `on_reboot=destroy` stops a firmware
# reboot loop from outliving the test.
let createRc = execCmdEx("qemu-img create -f qcow2 " & quoteShell(diskPath) &
                         " 64M")
if createRc.exitCode != 0:
  echo "[skip] t_libvirt_snapshot_surface_conformance: qemu-img create " &
       "failed: " & createRc.output
  quit(0)

writeFile(workDir / "domain.xml", """
<domain type='qemu'>
  <name>""" & domName & """</name>
  <memory unit='MiB'>64</memory>
  <vcpu>1</vcpu>
  <os><type arch='x86_64' machine='pc'>hvm</type></os>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>destroy</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='""" & diskPath & """'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
  </devices>
</domain>
""")

let defineRc = virsh("define", workDir / "domain.xml")
if defineRc.exitCode != 0:
  echo "[skip] t_libvirt_snapshot_surface_conformance: could not define the " &
       "scratch domain: " & defineRc.output
  removeDir(workDir)
  quit(0)

# The suite is wrapped so a failing assertion can never strand a scratch
# domain on the host. `cleanup` is idempotent; the last test calls it
# explicitly so its effect can be asserted.
try:
  suite "t_libvirt_snapshot_surface_conformance":

    test "a fresh domain has no snapshots":
      check b.listSnapshots(domName).len == 0

    test "snapshotRunning REFUSES a shut-off domain and creates nothing":
      check b.domainState(domName) == "shut off"
      var msg = ""
      try:
        discard b.snapshotRunning(domName, "warm")
      except VmHarnessError as e:
        msg = e.msg
      check "requires domain state 'running'" in msg
      # The important half: no snapshot was created behind the refusal.
      check "warm" notin b.listSnapshots(domName)

    test "snapshot creates a disk-only snapshot that lists":
      check b.snapshot(domName, "cold") == "cold"
      check "cold" in b.listSnapshots(domName)
      # The snapshot froze the ORIGINAL disk and layered a new active file on
      # top; the frozen file is the saved state.
      let (blk, rc) = virsh("domblklist", domName, "--details")
      check rc == 0
      let active = snapshotableDisks(parseDomblklistDetails(blk))
      check active.len == 1
      check active[0].source != diskPath   # active layer moved above the frozen one

    test "restoring does NOT rewrite the saved state (prepare once, restore many)":
      let before = fileFingerprint(diskPath)
      for i in 1 .. 2:
        b.restoreSnapshot(domName, "cold")
        # --running was honoured: the domain is live, not left shut off.
        check b.domainState(domName) == "running"
        discard virsh("destroy", domName)
        sleep(200)
      let after = fileFingerprint(diskPath)
      # Byte-identical AND same mtime: two restores read the saved state and
      # wrote only the disposable overlay above it. This is the measurement
      # behind the "warm state is prepared once and read many times" claim.
      check after == before

    test "removeSnapshot deletes it, and a second call is a no-op":
      b.removeSnapshot(domName, "cold")
      check "cold" notin b.listSnapshots(domName)
      b.removeSnapshot(domName, "cold")      # idempotent, must not raise
      check b.listSnapshots(domName).len == 0

    test "snapshotRunning SUCCEEDS on a running domain and writes a real memstate":
      # The hot path's MECHANISM, against real virsh. Reachable without a
      # guest OS: a domain that halts in firmware still has RAM, and RAM is
      # what --live streams. What this cannot show is resume-not-boot --
      # see the header.
      discard virsh("start", domName)
      sleep(500)
      check b.domainState(domName) == "running"

      # The disk that is about to be FROZEN by the snapshot.
      let frozen = snapshotableDisks(
        parseDomblklistDetails(virsh("domblklist", domName, "--details")[0]))[0].source
      let memPath = b.memoryStatePathFor(domName, "warm")
      check not fileExists(memPath)

      check b.snapshotRunning(domName, "warm") == "warm"
      check "warm" in b.listSnapshots(domName)
      # A real memory image, not an empty placeholder.
      check fileExists(memPath)
      check getFileSize(memPath) > 0
      # The scratch overlay went exactly where the backend said it would --
      # which is what makes snapshotStateDir a real knob rather than a hint.
      let afterSnap = snapshotableDisks(
        parseDomblklistDetails(virsh("domblklist", domName, "--details")[0]))[0].source
      check afterSnap == b.snapshotDiskPathFor(domName, "warm", "vda")
      check afterSnap != frozen

      # The stronger form of the "prepare once, restore many" measurement: a
      # HOT restore consumes neither the frozen disk nor the memory image.
      let frozenBefore = fileFingerprint(frozen)
      let memBefore = fileFingerprint(memPath)
      b.restoreSnapshot(domName, "warm")
      check b.domainState(domName) == "running"
      check fileFingerprint(frozen) == frozenBefore
      check fileFingerprint(memPath) == memBefore

      # Teardown sweeps the RAM image; leaking one per cycle would fill the
      # pool (16 GiB apiece on the Windows lane).
      discard virsh("destroy", domName)
      sleep(200)
      b.removeSnapshot(domName, "warm")
      check "warm" notin b.listSnapshots(domName)
      check not fileExists(memPath)

    test "teardown leaves no residual domain":
      cleanup()
      let (allDoms, rc) = virsh("list", "--all", "--name")
      check rc == 0
      check domName notin allDoms
      check not dirExists(workDir)
finally:
  cleanup()
