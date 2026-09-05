## Integration test (no-live-virsh) for LibvirtBackend.
##
## Verifies the M4 Phase A slice's compile + boilerplate-correctness
## contract WITHOUT booting a real VM and WITHOUT requiring libvirtd
## to be running. The full live-virsh lifecycle test will land with
## M4 Phase B (snapshots) once a CI host with KVM is wired up.
##
## What this asserts:
##
##  - The libvirt module compiles into the vm-harness library on any
##    host (Linux/macOS/Windows).
##  - ``newLibvirtBackend()`` returns a populated backend with
##    sensible defaults.
##  - ``probeAvailability`` returns false (no libvirtd connection +
##    fake virsh path).
##  - ``stopAndCleanup`` on a fake VmHandle never raises (the
##    finally-safety contract).
##  - ``buildVirtInstallArgs`` produces a stable argv shape — pure
##    function, tested by string-match.
##  - ``exportBaseline`` / ``importBaseline`` still raise
##    ``BackendUnavailableError``, naming WR3 as their owner.
##  - The snapshot surface (campaign WR0) makes the right DECISIONS —
##    which is what the second suite in this file covers, against a fake
##    ``virsh`` binary. See the mock justification there.
##  - The backend is registered with the auto-selection factory.

import std/[options, os, sequtils, strutils, tables, tempfiles, unittest]
import vm_harness

suite "LibvirtBackend smoke (no live virsh)":
  test "newLibvirtBackend populates defaults consistent with high-mem-server":
    let b = newLibvirtBackend()
    check b.id == biLibvirt
    check b.hostPlatform == hpLinux
    check goWindows in b.supportedGuests
    check goLinux in b.supportedGuests
    check b.libvirtUri == DefaultLibvirtUri
    check b.networkBridge == DefaultLibvirtBridge
    check b.imagePoolDir == DefaultLibvirtImagePool
    check b.sshUser == DefaultLibvirtWindowsSshUser
    check b.sshGuestOs == goWindows

  test "SSH command formatting follows the guest shell":
    check quotePosixShellArg("$artifact") == "'$artifact'"
    check quotePosixShellArg("O'Brien") == "'O'\"'\"'Brien'"
    check formatSshCommand(
      @["sh", "-c", "printf '%s' \"$artifact\""], goLinux) ==
        "'sh' '-c' 'printf '\"'\"'%s'\"'\"' \"$artifact\"'"
    check formatSshCommand(@["cmd", "/c", "echo %PATH%"], goWindows) ==
      "\"cmd\" \"/c\" \"echo %PATH%\""

  test "SSH host trust failures are distinguished from transient readiness":
    check isFatalSshTrustFailure(
      "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!")
    check isFatalSshTrustFailure("Host key verification failed.")
    check not isFatalSshTrustFailure("Connection refused")
    check not isFatalSshTrustFailure("Permission denied (publickey).")

  test "probeAvailability returns false when virsh path is bogus":
    # Use a non-existent binary so the probe definitely returns false
    # even on a host with libvirt installed.
    let b = newLibvirtBackend(virshCmd = "/nonexistent/virsh-no-such")
    check not b.probeAvailability()

  test "domainDiskPath uses the configured image pool (default + override)":
    # Default backend: disk lands under /var/lib/libvirt/images.
    let bDefault = newLibvirtBackend()
    check bDefault.imagePoolDir == DefaultLibvirtImagePool
    check bDefault.domainDiskPath("windows-runner-001") ==
      DefaultLibvirtImagePool / "windows-runner-001.qcow2"
    # Operator override: storage lives on a big ZFS pool at /storage.
    let bOverride = newLibvirtBackend(imagePoolDir = "/storage/libvirt")
    check bOverride.imagePoolDir == "/storage/libvirt"
    check bOverride.domainDiskPath("windows-runner-001") ==
      "/storage/libvirt/windows-runner-001.qcow2"

  test "buildVirtInstallArgs writes the disk at the overridden pool dir":
    # The disk path virt-install receives is computed by domainDiskPath,
    # so an --image-pool-dir override must surface in the --disk argv.
    let b = newLibvirtBackend(imagePoolDir = "/storage/libvirt")
    let diskPath = b.domainDiskPath("windows-runner-001")
    let argv = buildVirtInstallArgs(b,
      name = "windows-runner-001",
      diskPath = diskPath,
      diskGB = 80, memoryMB = 8192, vcpus = 4,
      isoPath = "/storage/iso/Win11.iso",
      unattendIsoPath = "/tmp/autounattend.iso",
      virtioWinIsoPath = "/tmp/virtio-win.iso",
      osVariant = "win11")
    var diskArg = ""
    for a in argv:
      if a.startsWith("path=/storage/libvirt/windows-runner-001.qcow2"):
        diskArg = a
    check diskArg.len > 0
    check diskArg.contains("format=qcow2")
    # And the default pool path must NOT appear anywhere in the argv.
    check not argv.anyIt(it.contains(DefaultLibvirtImagePool))

  test "buildVirtInstallArgs renders an argv with the expected key flags":
    let b = newLibvirtBackend(networkBridge = "br0",
                              libvirtUri = "qemu:///system")
    let argv = buildVirtInstallArgs(b,
      name = "windows-runner-001",
      diskPath = "/var/lib/libvirt/images/windows-runner-001.qcow2",
      diskGB = 80,
      memoryMB = 8192,
      vcpus = 4,
      isoPath = "/storage/iso/Win11_24H2_EnglishInternational_x64.iso",
      unattendIsoPath = "/tmp/autounattend.iso",
      virtioWinIsoPath = "/tmp/virtio-win.iso",
      osVariant = "win11")
    # Argv[0] is the binary.
    check argv[0].endsWith("virt-install")
    # Connection URI is threaded through.
    check "qemu:///system" in argv
    # Required Win11 flags.
    check "--osinfo" in argv
    check "win11" in argv
    check "--machine" in argv
    check "q35" in argv
    check "--boot" in argv
    # ``--boot`` is followed by a SINGLE combined value element
    # (``uefi,firmware.feature0...``), so a bare exact-element
    # ``"uefi" in argv`` never matches. Assert UEFI is actually
    # requested by checking the --boot value begins with ``uefi,``.
    let bootIdx = argv.find("--boot")
    check bootIdx >= 0 and bootIdx + 1 < argv.len
    check argv[bootIdx + 1].startsWith("uefi,")
    # Bridge override survives.
    let networkSpec = argv.filterIt(it.startsWith("bridge=br0"))
    check networkSpec.len == 1
    # Both companion ISOs are present.
    check argv.filterIt("virtio-win.iso" in it).len >= 1
    check argv.filterIt("autounattend.iso" in it).len >= 1

  test "stopAndCleanup on a fake handle never raises":
    let b = newLibvirtBackend(virshCmd = "/nonexistent/virsh-no-such")
    let vm = VmHandle(
      backend: b,
      name: "never-existed",
      baseline: "never-existed",
      ipAddress: none(string),
      sshPort: 0,
      sshUser: "",
      sshAuth: SshAuth(kind: saNone),
      extra: initTable[string, string]())
    # Must not raise — finally-safety contract.
    b.stopAndCleanup(vm, deleteVm = true)
    b.stopAndCleanup(vm, deleteVm = false)
    # And calling it twice in a row also must not raise.
    b.stopAndCleanup(vm, deleteVm = true)

  test "stopAndCleanup force-stops a paused transient domain":
    when defined(linux):
      let root = createTempDir("vmh-libvirt-paused-cleanup", "")
      defer: removeDir(root)
      let fakeVirsh = root / "virsh"
      let argvLog = root / "virsh.argv"
      writeFile(fakeVirsh,
        "#!/bin/sh\n" &
        "printf '%s\\n' \"$3\" >> '" & argvLog & "'\n" &
        "case \"$3\" in\n" &
        "  dominfo) exit 0 ;;\n" &
        "  domstate) printf 'paused\\n' ;;\n" &
        "  destroy|undefine) exit 0 ;;\n" &
        "  *) exit 2 ;;\n" &
        "esac\n")
      setFilePermissions(fakeVirsh, getFilePermissions(fakeVirsh) +
        {fpUserExec})
      let b = newLibvirtBackend(
        virshCmd = fakeVirsh, libvirtUri = "qemu:///test")
      let vm = VmHandle(
        backend: b, name: BootDomainNamePrefix & "paused",
        baseline: "<boot-from-media>", ipAddress: none(string),
        sshPort: 0, sshUser: "", sshAuth: SshAuth(kind: saNone),
        extra: initTable[string, string]())
      b.stopAndCleanup(vm, deleteVm = true)
      let commands = readFile(argvLog).splitLines()
      check "destroy" in commands
      check "undefine" in commands

  test "stopAndCleanup force-stops a paused persistent domain":
    when defined(linux):
      let root = createTempDir("vmh-libvirt-paused-persistent", "")
      defer: removeDir(root)
      let fakeVirsh = root / "virsh"
      let argvLog = root / "virsh.argv"
      writeFile(fakeVirsh,
        "#!/bin/sh\n" &
        "printf '%s\\n' \"$3\" >> '" & argvLog & "'\n" &
        "case \"$3\" in\n" &
        "  dominfo) exit 0 ;;\n" &
        "  domstate) printf 'paused\\n' ;;\n" &
        "  destroy|undefine) exit 0 ;;\n" &
        "  *) exit 2 ;;\n" &
        "esac\n")
      setFilePermissions(fakeVirsh, getFilePermissions(fakeVirsh) +
        {fpUserExec})
      let b = newLibvirtBackend(
        virshCmd = fakeVirsh, libvirtUri = "qemu:///test")
      let vm = VmHandle(
        backend: b, name: "persistent-paused", baseline: "baseline",
        ipAddress: none(string), sshPort: 0, sshUser: "",
        sshAuth: SshAuth(kind: saNone),
        extra: initTable[string, string]())
      b.stopAndCleanup(vm, deleteVm = true)
      let commands = readFile(argvLog).splitLines()
      check "destroy" in commands
      check "undefine" in commands

  test "only inactive libvirt states skip force-stop":
    check domainNeedsForceStop("running")
    check domainNeedsForceStop("paused")
    check domainNeedsForceStop("in shutdown")
    check not domainNeedsForceStop("shut off")
    check not domainNeedsForceStop("crashed")
    check not domainNeedsForceStop("")

  test "exportBaseline / importBaseline still raise, and say WR3 owns them":
    # Deliberately NOT implemented by WR0: a transferable baseline is the
    # operation that could materialise ONE warm state (machine name and DHCP
    # lease included) on many domains, which is the identity collision the
    # in-place surface refuses to create. Whoever implements it owes that an
    # answer, so the stub names the milestone rather than going quiet.
    let b = newLibvirtBackend()
    expect BackendUnavailableError:
      b.exportBaseline("any", "/tmp/x")
    expect BackendUnavailableError:
      discard b.importBaseline("/tmp/x")
    # The sentinel is asserted on BOTH, not just one: the old "M4 Phase B"
    # version of this test checked the marker string on a single method, and
    # a half-renamed pair is exactly how a reader ends up chasing the wrong
    # milestone.
    try:
      b.exportBaseline("any", "/tmp/x")
    except BackendUnavailableError as e:
      check "WR3" in e.msg
    try:
      discard b.importBaseline("/tmp/x")
    except BackendUnavailableError as e:
      check "WR3" in e.msg

# ---------------------------------------------------------------------------
# Snapshot surface (campaign WR0) — the decision logic, against a FAKE virsh.
#
# MOCK JUSTIFICATION (repo policy: every mock needs one).
#
# These tests substitute a 20-line shell script for the `virsh` BINARY. They
# do not mock the backend, the domain model, or any vm-harness type: the real
# LibvirtBackend methods run, build real argv, and parse real virsh-shaped
# text off a real process boundary. What is faked is only libvirt's ANSWER,
# and it is faked to reach states this host cannot be made to produce
# safely: a domain that is `shut off` when asked to be snapshotted hot, two
# domains sharing one writable disk, and a `snapshot-revert` that fails with
# "revert requires force". Every one of those is a branch that decides
# whether a warm pool member keeps a distinct identity, and none can be
# reached on high-mem-server without either booting Windows guests or
# deliberately mis-wiring domains next to the production CI fleet.
#
# The complementary REAL-virsh coverage is
# `tests/e2e/t_libvirt_snapshot_surface_conformance.nim` (an offline scratch
# domain, actual snapshot/revert/delete round trip) and the WR0 gate
# `tests/e2e/t_libvirt_live_snapshot_restore.nim` (a real running guest).
# Both self-skip when their prerequisites are absent; this suite does not,
# which is why the decision logic lives here.

proc writeFakeVirsh(path, argvLog, body: string) =
  ## A fake `virsh` that appends its full argv to `argvLog` and then runs
  ## `body` (a `case "$3" in ... esac`, where $3 is the subcommand because
  ## every call is `virsh --connect <uri> <sub> ...`).
  writeFile(path,
    "#!/bin/sh\n" &
    "printf '%s\\n' \"$*\" >> '" & argvLog & "'\n" &
    body)
  setFilePermissions(path, getFilePermissions(path) + {fpUserExec})

proc logLines(argvLog: string): seq[string] =
  if not fileExists(argvLog): return @[]
  for line in readFile(argvLog).splitLines():
    if line.strip().len > 0: result.add(line)

proc mentions(lines: seq[string], needle: string): bool =
  for l in lines:
    if needle in l: return true
  false

suite "LibvirtBackend snapshot surface (fake virsh)":

  test "snapshotRunning refuses a domain that is not running":
    when defined(linux):
      let root = createTempDir("vmh-libvirt-snap-notrunning", "")
      defer: removeDir(root)
      let fakeVirsh = root / "virsh"
      let argvLog = root / "virsh.argv"
      writeFakeVirsh(fakeVirsh, argvLog,
        "case \"$3\" in\n" &
        "  dominfo) exit 0 ;;\n" &
        "  domstate) printf 'shut off\\n' ;;\n" &
        "  *) exit 2 ;;\n" &
        "esac\n")
      let b = newLibvirtBackend(virshCmd = fakeVirsh,
                                libvirtUri = "qemu:///test",
                                imagePoolDir = root)
      var msg = ""
      try:
        discard b.snapshotRunning("member-0", "warm")
      except VmHarnessError as e:
        msg = e.msg
      check "requires domain state 'running'" in msg
      check "shut off" in msg
      # And it must not have taken a snapshot anyway: a cold snapshot that
      # looks like a warm one is exactly the silent failure being prevented.
      check not logLines(argvLog).mentions("snapshot-create-as")

  test "snapshotRunning refuses when another domain shares the writable disk":
    when defined(linux):
      # The identity-collision guard. A running-state snapshot captures the
      # guest's machine name and DHCP lease; two domains on one disk file
      # would restore into one identity (measured on Hyper-V: two guests
      # both came up as WIN-EDC8DG9PTDT on 172.27.94.244).
      let root = createTempDir("vmh-libvirt-snap-shared", "")
      defer: removeDir(root)
      let fakeVirsh = root / "virsh"
      let argvLog = root / "virsh.argv"
      writeFakeVirsh(fakeVirsh, argvLog,
        "case \"$3\" in\n" &
        "  dominfo) exit 0 ;;\n" &
        "  domstate) printf 'running\\n' ;;\n" &
        "  list) printf 'member-0\\nmember-1\\n' ;;\n" &
        "  domblklist)\n" &
        "    printf ' Type   Device   Target   Source\\n'\n" &
        "    printf ' file   disk     vda      /pool/shared.qcow2\\n' ;;\n" &
        "  *) exit 2 ;;\n" &
        "esac\n")
      let b = newLibvirtBackend(virshCmd = fakeVirsh,
                                libvirtUri = "qemu:///test",
                                imagePoolDir = root)
      var msg = ""
      try:
        discard b.snapshotRunning("member-0", "warm")
      except VmHarnessError as e:
        msg = e.msg
      check "member-1" in msg
      check "identical network identity" in msg
      check not logLines(argvLog).mentions("snapshot-create-as")

  test "snapshotRunning refuses to overwrite an existing memory-state file":
    when defined(linux):
      let root = createTempDir("vmh-libvirt-snap-memexists", "")
      defer: removeDir(root)
      let fakeVirsh = root / "virsh"
      let argvLog = root / "virsh.argv"
      writeFakeVirsh(fakeVirsh, argvLog,
        "case \"$3\" in\n" &
        "  dominfo) exit 0 ;;\n" &
        "  domstate) printf 'running\\n' ;;\n" &
        "  list) printf 'member-0\\n' ;;\n" &
        "  domblklist)\n" &
        "    printf ' Type   Device   Target   Source\\n'\n" &
        "    printf ' file   disk     vda      /pool/member-0.qcow2\\n' ;;\n" &
        "  *) exit 2 ;;\n" &
        "esac\n")
      let b = newLibvirtBackend(virshCmd = fakeVirsh,
                                libvirtUri = "qemu:///test",
                                imagePoolDir = root)
      # A leftover memstate is another member's warm RAM. Silently reusing
      # it is the same identity collision by a different route.
      writeFile(b.memoryStatePathFor("member-0", "warm"), "stale-ram")
      var msg = ""
      try:
        discard b.snapshotRunning("member-0", "warm")
      except VmHarnessError as e:
        msg = e.msg
      check "already exists" in msg
      check not logLines(argvLog).mentions("snapshot-create-as")

  test "snapshotRunning issues --live with an external memspec when clean":
    when defined(linux):
      let root = createTempDir("vmh-libvirt-snap-live", "")
      defer: removeDir(root)
      let fakeVirsh = root / "virsh"
      let argvLog = root / "virsh.argv"
      writeFakeVirsh(fakeVirsh, argvLog,
        "case \"$3\" in\n" &
        "  dominfo) exit 0 ;;\n" &
        "  domstate) printf 'running\\n' ;;\n" &
        "  list) printf 'member-0\\n' ;;\n" &
        "  domblklist)\n" &
        "    printf ' Type   Device   Target   Source\\n'\n" &
        "    printf ' file   disk     vda      /pool/member-0.qcow2\\n'\n" &
        "    printf ' file   cdrom    sda      /iso/virtio-win.iso\\n' ;;\n" &
        "  snapshot-create-as) exit 0 ;;\n" &
        "  *) exit 2 ;;\n" &
        "esac\n")
      let b = newLibvirtBackend(virshCmd = fakeVirsh,
                                libvirtUri = "qemu:///test",
                                imagePoolDir = root)
      check b.snapshotRunning("member-0", "warm") == "warm"
      let lines = logLines(argvLog)
      check lines.mentions("snapshot-create-as")
      check lines.mentions("--live")
      check lines.mentions("--memspec")
      check lines.mentions(b.memoryStatePathFor("member-0", "warm") &
                           ",snapshot=external")
      # The shared install media is excluded explicitly.
      check lines.mentions("sda,snapshot=no")

  test "snapshot (cold) is --disk-only and carries no memory state":
    when defined(linux):
      let root = createTempDir("vmh-libvirt-snap-cold", "")
      defer: removeDir(root)
      let fakeVirsh = root / "virsh"
      let argvLog = root / "virsh.argv"
      writeFakeVirsh(fakeVirsh, argvLog,
        "case \"$3\" in\n" &
        "  dominfo) exit 0 ;;\n" &
        "  domblklist)\n" &
        "    printf ' Type   Device   Target   Source\\n'\n" &
        "    printf ' file   disk     vda      /pool/member-0.qcow2\\n' ;;\n" &
        "  snapshot-create-as) exit 0 ;;\n" &
        "  *) exit 2 ;;\n" &
        "esac\n")
      let b = newLibvirtBackend(virshCmd = fakeVirsh,
                                libvirtUri = "qemu:///test",
                                imagePoolDir = root)
      check b.snapshot("member-0", "cold") == "cold"
      let lines = logLines(argvLog)
      check lines.mentions("--disk-only")
      check not lines.mentions("--live")
      check not lines.mentions("--memspec")

  test "listSnapshots parses names, and a virsh failure raises":
    when defined(linux):
      let root = createTempDir("vmh-libvirt-snap-list", "")
      defer: removeDir(root)
      let fakeVirsh = root / "virsh"
      let argvLog = root / "virsh.argv"
      writeFakeVirsh(fakeVirsh, argvLog,
        "case \"$3\" in\n" &
        "  snapshot-list)\n" &
        "    case \"$5\" in\n" &
        "      member-0) printf 'pool-baseline-0\\n\\nwarm\\n' ;;\n" &
        "      *) printf 'error: failed to get domain\\n'; exit 1 ;;\n" &
        "    esac ;;\n" &
        "  *) exit 2 ;;\n" &
        "esac\n")
      let b = newLibvirtBackend(virshCmd = fakeVirsh,
                                libvirtUri = "qemu:///test",
                                imagePoolDir = root)
      check b.listSnapshots("member-0") == @["pool-baseline-0", "warm"]
      expect VmHarnessError:
        discard b.listSnapshots("no-such-domain")

  test "removeSnapshot is a no-op for an unknown snapshot, and sweeps the RAM image":
    when defined(linux):
      let root = createTempDir("vmh-libvirt-snap-remove", "")
      defer: removeDir(root)
      let fakeVirsh = root / "virsh"
      let argvLog = root / "virsh.argv"
      writeFakeVirsh(fakeVirsh, argvLog,
        "case \"$3\" in\n" &
        "  dominfo) exit 0 ;;\n" &
        "  snapshot-list) printf 'warm\\n' ;;\n" &
        "  snapshot-delete) exit 0 ;;\n" &
        "  *) exit 2 ;;\n" &
        "esac\n")
      let b = newLibvirtBackend(virshCmd = fakeVirsh,
                                libvirtUri = "qemu:///test",
                                imagePoolDir = root)
      # Idempotent: the base contract says removing a missing snapshot is a
      # no-op, because teardown blocks get re-entered.
      b.removeSnapshot("member-0", "never-existed")
      check not logLines(argvLog).mentions("snapshot-delete")

      # The RAM image is the guest's whole memory (16 GiB on the Windows
      # lane). Leaking one per teardown would fill the pool in a few cycles.
      let memPath = b.memoryStatePathFor("member-0", "warm")
      writeFile(memPath, "ram")
      b.removeSnapshot("member-0", "warm")
      check logLines(argvLog).mentions("snapshot-delete")
      check not fileExists(memPath)

  test "restoreSnapshot reverts --running and retries with --force ONLY on that refusal":
    when defined(linux):
      let root = createTempDir("vmh-libvirt-snap-revert", "")
      defer: removeDir(root)
      let fakeVirsh = root / "virsh"
      let argvLog = root / "virsh.argv"
      # First snapshot-revert fails the way libvirt refuses a risky revert
      # ("revert requires force"); the second, with --force, succeeds.
      writeFakeVirsh(fakeVirsh, argvLog,
        "case \"$3\" in\n" &
        "  dominfo) exit 0 ;;\n" &
        "  snapshot-revert)\n" &
        "    if [ -f '" & root & "/tried' ]; then exit 0; fi\n" &
        "    : > '" & root & "/tried'\n" &
        "    printf 'error: revert requires force\\n'; exit 1 ;;\n" &
        "  *) exit 2 ;;\n" &
        "esac\n")
      let b = newLibvirtBackend(virshCmd = fakeVirsh,
                                libvirtUri = "qemu:///test",
                                imagePoolDir = root)
      b.restoreSnapshot("member-0", "warm")
      let lines = logLines(argvLog)
      check lines.len == 3            # dominfo + revert + forced revert
      check lines[1].contains("--running")
      check not lines[1].contains("--force")
      check lines[2].contains("--force")

  test "restoreSnapshot does NOT force on an unrelated failure":
    when defined(linux):
      let root = createTempDir("vmh-libvirt-snap-revert-fail", "")
      defer: removeDir(root)
      let fakeVirsh = root / "virsh"
      let argvLog = root / "virsh.argv"
      writeFakeVirsh(fakeVirsh, argvLog,
        "case \"$3\" in\n" &
        "  dominfo) exit 0 ;;\n" &
        "  snapshot-revert)\n" &
        "    printf 'error: unsupported configuration\\n'; exit 1 ;;\n" &
        "  *) exit 2 ;;\n" &
        "esac\n")
      let b = newLibvirtBackend(virshCmd = fakeVirsh,
                                libvirtUri = "qemu:///test",
                                imagePoolDir = root)
      expect VmHarnessError:
        b.restoreSnapshot("member-0", "warm")
      # Exactly one revert attempt: --force must not paper over a real
      # incompatibility.
      var reverts = 0
      for l in logLines(argvLog):
        if "snapshot-revert" in l: inc reverts
      check reverts == 1

  test "restoreSnapshot refuses an undefined domain before touching virsh":
    when defined(linux):
      let root = createTempDir("vmh-libvirt-snap-revert-nodom", "")
      defer: removeDir(root)
      let fakeVirsh = root / "virsh"
      let argvLog = root / "virsh.argv"
      writeFakeVirsh(fakeVirsh, argvLog,
        "case \"$3\" in\n" &
        "  dominfo) exit 1 ;;\n" &
        "  *) exit 2 ;;\n" &
        "esac\n")
      let b = newLibvirtBackend(virshCmd = fakeVirsh,
                                libvirtUri = "qemu:///test",
                                imagePoolDir = root)
      expect VmHarnessError:
        b.restoreSnapshot("never-defined", "warm")
      check not logLines(argvLog).mentions("snapshot-revert")

suite "LibvirtBackend (continued)":

  test "bootFromMedia rejects rootfs-tar (WSL-only) cleanly":
    let b = newLibvirtBackend()
    expect BackendUnavailableError:
      discard b.bootFromMedia(BootMediaSpec(
        name: "repro-test-boot-libvirt-x",
        kind: bmkRootfsTar,
        mediaPath: "/tmp/never.tar"))

  test "bootFromMedia rejects an unprefixed name":
    let b = newLibvirtBackend()
    when defined(linux):
      # On Linux the call will try to do real work; we only verify it
      # rejects the safety-prefix violation before any subprocess call.
      # The test fixture uses a non-existent media path so the fileExists
      # check fires first and the name validation order means we still
      # get the IOError instead. To test the prefix check we need a
      # fake-existing file: use the test binary itself.
      let tmpExisting = getAppFilename()
      expect ValueError:
        discard b.bootFromMedia(BootMediaSpec(
          name: "bad-name-no-prefix",
          kind: bmkQcow2,
          mediaPath: tmpExisting))
    else:
      # On non-Linux hosts the method raises BackendUnavailableError
      # before any input validation, so the prefix check isn't reached.
      expect BackendUnavailableError:
        discard b.bootFromMedia(BootMediaSpec(
          name: "bad-name-no-prefix",
          kind: bmkQcow2,
          mediaPath: "/tmp/never.qcow2"))

  test "transient boot flags support modern virt-install and serial capture":
    let argv = transientBootCompatibilityArgs()
    check argv[argv.find("--osinfo") + 1] == "detect=on,require=off"
    check "--console" notin argv
    let serial = transientBootSerialArgs("/tmp/reproos.serial.log")
    check serial == @["--serial", "file,path=/tmp/reproos.serial.log"]

  test "transient boot honors UEFI generation and explicit NixOS firmware":
    let spec = BootMediaSpec(
      kind: bmkQcow2,
      generation: 2,
      secureBootEnabled: false,
      extra: initTable[string, string]())
    let argv = transientBootFirmwareArgs(spec,
      "/nix/store/ovmf/FV/OVMF_CODE.fd",
      "/nix/store/ovmf/FV/OVMF_VARS.fd")
    check argv[0] == "--boot"
    check "loader=/nix/store/ovmf/FV/OVMF_CODE.fd" in argv[1]
    check "loader.secure=no" in argv[1]
    check "nvram.template=/nix/store/ovmf/FV/OVMF_VARS.fd" in argv[1]

  test "legacy transient boot does not request UEFI firmware":
    let spec = BootMediaSpec(kind: bmkQcow2, generation: 1)
    check transientBootFirmwareArgs(spec).len == 0

  test "transient graphical consoles are loopback-only":
    let vnc = transientBootGraphicsArgs(BootMediaSpec(
      graphics: bgVnc, videoModel: "virtio"))
    check vnc == @["--graphics", "vnc,listen=127.0.0.1",
                   "--video", "virtio"]
    let headless = transientBootGraphicsArgs(BootMediaSpec())
    check headless == @["--graphics", "none"]

  test "transient boot acceleration selects compatible CPU models":
    check transientBootAccelerationArgs(BootMediaSpec(
      acceleration: baAuto)) == @["--cpu", "host-model"]
    check transientBootAccelerationArgs(BootMediaSpec(
      acceleration: baKvm)) ==
        @["--virt-type", "kvm", "--cpu", "host-model"]
    check transientBootAccelerationArgs(BootMediaSpec(
      acceleration: baTcg)) ==
        @["--virt-type", "qemu", "--cpu", "qemu64"]

  test "transient SSH forwarding is explicit and loopback-only":
    check transientBootNetworkArgs(BootMediaSpec()) ==
      @["--network", "none"]
    let forwarded = transientBootNetworkArgs(BootMediaSpec(
      sshForwardPort: 22022))
    check forwarded == @["--network", "user,model=virtio"]
    check transientBootHostForwardHmp(BootMediaSpec()) == ""
    check transientBootHostForwardHmp(BootMediaSpec(
      sshForwardPort: 22022)) ==
        "hostfwd_add hostnet0 tcp:127.0.0.1:22022-:22"
    expect ValueError:
      discard transientBootNetworkArgs(BootMediaSpec(sshForwardPort: -1))

  test "ISO install preserves an explicit caller-owned target disk":
    when defined(linux):
      let root = createTempDir("vmh-libvirt-install", "")
      defer: removeDir(root)
      let media = root / "installer.iso"
      let target = root / "reproos-installed.qcow2"
      let qemuImg = root / "qemu-img"
      let virtInstall = root / "virt-install"
      let argvLog = root / "virt-install.argv"
      writeFile(media, "installer")
      writeFile(qemuImg,
        "#!/bin/sh\n" &
        "test \"$1\" = create || exit 2\n" &
        ": > \"$4\"\n")
      writeFile(virtInstall,
        "#!/bin/sh\n" &
        "printf '%s\\n' \"$@\" > '" & argvLog & "'\n")
      setFilePermissions(qemuImg, getFilePermissions(qemuImg) + {fpUserExec})
      setFilePermissions(virtInstall,
        getFilePermissions(virtInstall) + {fpUserExec})
      let b = newLibvirtBackend(
        virshCmd = "/nonexistent/virsh-no-such",
        virtInstallCmd = virtInstall,
        qemuImgCmd = qemuImg,
        imagePoolDir = root)
      let vm = b.bootFromMedia(BootMediaSpec(
        name: BootDomainNamePrefix & "persistent-disk",
        kind: bmkIso,
        mediaPath: media,
        targetDiskPath: target,
        generation: 1,
        diskGB: 12))
      check fileExists(target)
      check vm.extra.getOrDefault("targetDiskPath") == absolutePath(target)
      check vm.extra.getOrDefault("preserveBootDisk") == "true"
      check ("path=" & absolutePath(target) &
        ",format=qcow2,bus=virtio") in readFile(argvLog)
      b.stopAndCleanup(vm, deleteVm = true)
      check fileExists(target)

  test "captureScreenshot writes a non-empty console frame":
    when defined(linux):
      let root = createTempDir("vmh-libvirt-screenshot", "")
      defer: removeDir(root)
      let fakeVirsh = root / "virsh"
      writeFile(fakeVirsh,
        "#!/bin/sh\n" &
        "test \"$3\" = screenshot || exit 2\n" &
        "printf fake-png > \"$5\"\n")
      setFilePermissions(fakeVirsh, getFilePermissions(fakeVirsh) +
        {fpUserExec})
      let b = newLibvirtBackend(
        virshCmd = fakeVirsh, libvirtUri = "qemu:///test")
      let vm = VmHandle(
        backend: b, name: "repro-test-boot-libvirt-frame",
        baseline: "<boot-from-media>", ipAddress: none(string),
        sshPort: 0, sshUser: "", sshAuth: SshAuth(kind: saNone),
        extra: initTable[string, string]())
      let output = root / "frame.png"
      b.captureScreenshot(vm, output)
      check readFile(output) == "fake-png"

  test "installArgvTraceShim raises a clear M4 Phase B error":
    let b = newLibvirtBackend()
    let vm = VmHandle(
      backend: b, name: "x", baseline: "x",
      ipAddress: some("127.0.0.1"), sshPort: 22, sshUser: "admin",
      sshAuth: SshAuth(kind: saNone),
      extra: initTable[string, string]())
    expect BackendUnavailableError:
      b.installArgvTraceShim(vm, ArgvTraceShim(
        wrappedBinaryName: "useradd",
        traceLogPath: "C:\\trace.log"))

  test "uninstallArgvTraceShim is a no-op (Phase A)":
    let b = newLibvirtBackend()
    let vm = VmHandle(
      backend: b, name: "x", baseline: "x",
      ipAddress: some("127.0.0.1"), sshPort: 22, sshUser: "admin",
      sshAuth: SshAuth(kind: saNone),
      extra: initTable[string, string]())
    b.uninstallArgvTraceShim(vm, "useradd")  # must not raise

  test "biLibvirt is registered with the auto-selection factory":
    check biLibvirt in registeredBackends()
    # And the (linux, windows) dispatch picks libvirt.
    check autoSelectBackendId(hpLinux, goWindows) == biLibvirt
    check autoSelectBackendId(hpLinux, goLinux) == biLibvirt

  # ---- M3: config-drive injection + UEFI ephemeral domain rendering ----

  test "buildEphemeralDomainXml attaches the config-drive CD-ROM + NIC " &
       "for a firmware (Windows) golden":
    let b = newLibvirtBackend()
    let spec = EphemeralCloneSpec(
      name: "m3-eph",
      goldenImage: "/storage/iso/golden-win11-cloudbase.qcow2",
      cpus: 4, memoryMB: 4096,
      configDriveIso: "/var/lib/libvirt/images/m3-eph.config-drive.iso")
    let xml = b.buildEphemeralDomainXml(spec,
      "/var/lib/libvirt/images/m3-eph.overlay.qcow2",
      "/tmp/m3-eph.serial.log")
    # The overlay disk is the boot disk.
    check "m3-eph.overlay.qcow2" in xml
    # The config-drive is attached read-only as a CD-ROM (cloudbase-init
    # ConfigDrive datasource consumes it).
    check "device='cdrom'" in xml
    check "m3-eph.config-drive.iso" in xml
    check "<readonly/>" in xml
    # A firmware-boot golden gets a NIC so cloudbase-init can reach the
    # metadata endpoint.
    check "<interface type='network'>" in xml
    # No direct-kernel boot for a firmware golden.
    check "<kernel>" notin xml
    check "<boot dev='hd'/>" in xml

  test "buildEphemeralDomainXml renders UEFI (OVMF) loader + per-job nvram":
    let b = newLibvirtBackend()
    let spec = EphemeralCloneSpec(
      name: "m3-uefi",
      goldenImage: "/storage/iso/golden-win11-cloudbase.qcow2",
      uefiLoader: "/run/libvirt/nix-ovmf/edk2-x86_64-code.fd",
      uefiNvramTemplate: "/run/libvirt/nix-ovmf/edk2-i386-vars.fd",
      uefiNvram: "/var/lib/libvirt/images/m3-uefi_VARS.fd")
    let xml = b.buildEphemeralDomainXml(spec,
      "/var/lib/libvirt/images/m3-uefi.overlay.qcow2",
      "/tmp/m3-uefi.serial.log")
    check "edk2-x86_64-code.fd" in xml
    check "<loader" in xml and "pflash" in xml
    check "m3-uefi_VARS.fd" in xml
    check "template='/run/libvirt/nix-ovmf/edk2-i386-vars.fd'" in xml
    # Windows on UEFI needs SMM.
    check "<smm state='on'/>" in xml

  test "the tiny-Linux (direct-kernel) ephemeral path is unchanged (no NIC/" &
       "config-drive/UEFI)":
    let b = newLibvirtBackend()
    let spec = EphemeralCloneSpec(
      name: "m2-tiny",
      goldenImage: "/tmp/golden.qcow2",
      kernel: "/tmp/kernel", initrd: "/tmp/initramfs.gz",
      cmdline: "console=ttyS0 quiet panic=1")
    let xml = b.buildEphemeralDomainXml(spec,
      "/tmp/m2-tiny.overlay.qcow2", "/tmp/m2-tiny.serial.log")
    check "<kernel>/tmp/kernel</kernel>" in xml
    # M2 tiny golden self-terminates without networking; no NIC is added.
    check "<interface" notin xml
    check "device='cdrom'" notin xml
    check "<loader" notin xml

  test "buildConfigDriveIso writes the openstack config-drive layout + " &
       "labels it config-2 (when an ISO tool is available)":
    if findExe("genisoimage").len == 0 and findExe("mkisofs").len == 0 and
       findExe("xorriso").len == 0:
      echo "[skip] no genisoimage/mkisofs/xorriso on PATH"
      skip()
    else:
      let iso = getTempDir() / "m3-configdrive-unit.iso"
      removeFile(iso)
      let ud = "#ps1_sysnative\nWrite-Output HELLO-M3\n"
      let meta = "{\"uuid\":\"unit-test\",\"hostname\":\"unit-test\"}"
      let got = buildConfigDriveIso(iso, ud, meta)
      check got == iso
      check fileExists(iso)
      # The ISO must carry the config-2 volume label + the user_data. We
      # grep the raw ISO bytes for the volume id + payload marker.
      let raw = readFile(iso)
      check "config-2" in raw
      check "HELLO-M3" in raw
      check "user_data" in raw
      removeFile(iso)

# ---------------------------------------------------------------------------
# UEFI El Torito ISO validation (Gap 1, backend side).
#
# MOCK JUSTIFICATION (per design.md §9.1): no backend or process mocks.
# The pure decision `isoHasUefiElTorito` is fed representative
# `xorriso -report_el_torito` output (the same BIOS-only vs BIOS+UEFI
# samples the shell unit test uses; we cannot ship real multi-GB ISOs).
# `validateWindowsIsoBootable` is driven against a REAL `xorriso` shell
# shim on PATH (a genuine osproc spawn, per §9.1's "shell shim that
# records/emits and exits" allowance) — never a mocked process.

const Win11PlainBiosPlusUefi = """
El Torito catalog  : 20  2
El Torito images   :   N  Pltf  B   Emul  Ld_seg  Hdpt  Ldsiz         LBA
El Torito boot img :   1  BIOS  y   none  0x0000  0x00  8             27
El Torito boot img :   2  UEFI  y   none  0x0000  0x00  5760          35
"""

const BiosOnlyPlain = """
El Torito catalog  : 20  1
El Torito images   :   N  Pltf  B   Emul  Ld_seg  Hdpt  Ldsiz         LBA
El Torito boot img :   1  BIOS  y   none  0x0000  0x00  4             27
"""

const Win11AsMkisofs = """
-V 'CCCOMA_X64FRE_EN-US_DV9'
-boot-load-size 8 -no-emul-boot -boot-info-table
-eltorito-boot boot/etfsboot.com
-eltorito-alt-boot -e efi/microsoft/boot/efisys.bin -no-emul-boot
"""

const BiosOnlyAsMkisofs = """
-V 'SOME_BIOS_ONLY_ISO'
-boot-load-size 4 -no-emul-boot -boot-info-table
-eltorito-boot isolinux/isolinux.bin
"""

const IsoinfoUefiPlatform = """
El Torito VD version 1 found, boot catalog is in sector 20
Platform Id 0xEF (UEFI)
Bootoff 23 0x17
"""

proc writeXorrisoStub(dir, report: string): string =
  ## Write an executable `xorriso` shim into `dir` that ignores its args
  ## and prints `report` on stdout, exit 0. Returns `dir` (to prepend to
  ## PATH). This is a real binary spawned by osproc — not a mock.
  createDir(dir)
  let stub = dir / "xorriso"
  # Single-quote the heredoc-free body; embed the report via a Nim string.
  writeFile(stub, "#!/usr/bin/env bash\ncat <<'__RPT__'\n" & report &
    "\n__RPT__\n")
  setFilePermissions(stub, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  dir

template withPath(newPath: string, body: untyped) =
  let savedPath = getEnv("PATH")
  putEnv("PATH", newPath)
  try:
    body
  finally:
    putEnv("PATH", savedPath)

suite "LibvirtBackend UEFI El Torito ISO validation":
  test "isoHasUefiElTorito ACCEPTS a plain report with a UEFI boot image":
    check isoHasUefiElTorito(Win11PlainBiosPlusUefi)

  test "isoHasUefiElTorito REJECTS a BIOS-only plain report":
    check not isoHasUefiElTorito(BiosOnlyPlain)

  test "isoHasUefiElTorito ACCEPTS an as_mkisofs report with alt-boot + EFI":
    check isoHasUefiElTorito(Win11AsMkisofs)

  test "isoHasUefiElTorito REJECTS a BIOS-only as_mkisofs report":
    check not isoHasUefiElTorito(BiosOnlyAsMkisofs)

  test "isoHasUefiElTorito ACCEPTS an isoinfo dump naming the EFI platform":
    check isoHasUefiElTorito(IsoinfoUefiPlatform)

  test "isoHasUefiElTorito REJECTS an empty report":
    check not isoHasUefiElTorito("")

  test "validateWindowsIsoBootable RAISES on a BIOS-only ISO (xorriso present)":
    let b = newLibvirtBackend()
    let dir = writeXorrisoStub(
      getTempDir() / "vmh-xorriso-bios-" & $getCurrentProcessId(),
      BiosOnlyPlain)
    defer: removeDir(dir)
    withPath(dir & ":" & getEnv("PATH")):
      var raised = false
      try:
        b.validateWindowsIsoBootable("/tmp/fake-bios-only.iso")
      except VmHarnessError as e:
        raised = true
        check e.phase == lpProvisioning
        check "BIOS-boot only" in e.msg
        check "UEFI shell" in e.msg
        check "/tmp/fake-bios-only.iso" in e.msg
      check raised

  test "validateWindowsIsoBootable PASSES on a UEFI ISO (xorriso present)":
    let b = newLibvirtBackend()
    let dir = writeXorrisoStub(
      getTempDir() / "vmh-xorriso-uefi-" & $getCurrentProcessId(),
      Win11PlainBiosPlusUefi)
    defer: removeDir(dir)
    withPath(dir & ":" & getEnv("PATH")):
      # Must not raise.
      b.validateWindowsIsoBootable("/tmp/fake-uefi.iso")

  test "validateWindowsIsoBootable WARNS + SKIPS when xorriso is absent":
    let b = newLibvirtBackend()
    let emptyDir = getTempDir() / "vmh-noxorriso-" & $getCurrentProcessId()
    createDir(emptyDir)
    defer: removeDir(emptyDir)
    # PATH with no xorriso ⇒ findExe returns "" ⇒ warn + return (no raise).
    withPath(emptyDir):
      b.validateWindowsIsoBootable("/tmp/whatever.iso", xorrisoCmd = "xorriso")
