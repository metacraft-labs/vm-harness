## LibvirtBackend — vm-harness adapter for libvirt + QEMU/KVM on Linux
## hosts. Per design doc §4.5 and the M4 slice for the
## windows-runner-001 prototype on ``solunska-server``.
##
## *Scope of this slice (M4 Phase A):*
##
##  - Provision an x86_64 Windows guest (Win11 24H2 Pro) from an ISO +
##    autounattend.xml combo via ``virt-install`` + a small set of
##    ``virsh`` calls.
##  - Boot the guest, run an in-guest first-boot script via Windows
##    OpenSSH over the libvirt default network, and hand the running
##    domain to the caller. The domain is left ``autostart`` so a
##    reboot of the host (or libvirtd restart) brings the runner back.
##  - Provide the lifecycle methods needed by ``vm-harness run``:
##    ``probeAvailability``, ``provisionBaseline``, ``bootFromMedia``,
##    ``execInGuest``, ``copyToGuest``, ``copyFromGuest``,
##    ``startAndAwaitReady``, ``stopAndCleanup``.
##
## *Out of scope (tracked as later phases):*
##
##  - ``snapshot`` / ``restoreSnapshot`` / ``snapshotRunning`` /
##    ``listSnapshots`` / ``removeSnapshot`` (M4 Phase B — wraps
##    ``virsh snapshot-*``).
##  - ``exportBaseline`` / ``importBaseline`` (M4 Phase B — wraps
##    ``virsh save`` + qcow2 reflink copy).
##  - SR-IOV + GPU passthrough device wiring (M4 Phase C — needs
##    host-side IOMMU + bind/unbind helpers).
##  - ``installArgvTraceShim`` (M4 Phase B — Windows shim shape is
##    identical to ``hyperv.nim``'s, but the install path needs to
##    transit SSH instead of PowerShell Direct).
##  - ``captureSerial`` / ``expectLine`` / ``serialSend`` (M4 Phase B —
##    QEMU's ``-serial pty`` + named pipe wiring exists; threading it
##    through the ``SerialStream`` contract is deferred until the
##    Hyper-V boot-harness equivalent is needed on Linux hosts).
##
## *Transport*:
##
##  - **virsh**: per-domain lifecycle (define, start, destroy,
##    undefine, autostart).
##  - **virt-install**: one-shot baseline build from ISO+unattend; we
##    shell out to it because re-implementing all of QEMU's `-device`
##    matrix in Nim is out of scope for the slice.
##  - **SSH**: in-guest exec + file copy via Windows OpenSSH Server,
##    which the autounattend.xml in ``guest-recipes/windows-x64-base/``
##    enables at first boot.
##
## *Naming convention:*
##
##  - The libvirt domain name == ``BaselineSpec.name`` (e.g.
##    ``windows-runner-001``). Unlike the Tart/UTM clone-based
##    backends, libvirt has cheap native snapshot/revert, so we don't
##    spin up a separate per-gate ephemeral; the same long-lived domain
##    is reverted to a named snapshot each gate. (M4 Phase B will wire
##    that path. The M4 Phase A slice treats the domain as a
##    long-lived "runner" VM and skips per-gate revert.)
##  - The disk image lives at
##    ``/var/lib/libvirt/images/<name>.qcow2`` (the default libvirt
##    pool).
##  - The boot disk is virtio-blk; the network adapter is virtio-net
##    on the default ``virbr0`` bridge (NAT) — overridable via
##    ``newLibvirtBackend(networkBridge=...)``.
##
## *Why a long-lived domain instead of per-gate clones?* The
## windows-runner-001 use case is "register one Windows-CI runner with
## GitHub Actions and keep it online". A per-gate revert model would
## fight the runner's persistent state requirement. The harness still
## owns ``stopAndCleanup`` for tear-down between maintenance windows.
##
## *Compile-time portability:* this module compiles cleanly on any host
## (Mac, Linux, Windows) so the unit tests for the small parser
## helpers can run anywhere. Backend *registration* is unconditional,
## but ``probeAvailability`` returns false on non-Linux hosts.

import std/[options, os, osproc, streams, strtabs,
            strutils, tables, times]
import ../types
import ../auto

# ---------------------------------------------------------------------------
# Backend type.

type
  LibvirtBackend* = ref object of VmBackend
    ## Adapter around the ``virsh`` / ``virt-install`` CLIs.
    virshCmd*: string
      ## Path to the ``virsh`` binary. Defaults to ``virsh`` on PATH.
    virtInstallCmd*: string
      ## Path to the ``virt-install`` binary. Defaults to
      ## ``virt-install`` on PATH.
    qemuImgCmd*: string
      ## Path to ``qemu-img``. Used by helper paths that need a fresh
      ## qcow2 file (e.g. when ``provisionBaseline`` is called for a
      ## baseline whose disk doesn't yet exist).
    sshCmd*: string
      ## Path to ``ssh``. Defaults to ``ssh`` on PATH.
    scpCmd*: string
      ## Path to ``scp``. Defaults to ``scp`` on PATH.
    sshpassCmd*: string
      ## Path to ``sshpass`` (used when ``sshAuth.kind == saPassword``).
      ## Empty when key-based auth is used.
    libvirtUri*: string
      ## libvirt connection URI. Defaults to ``qemu:///system``
      ## (the rootful system instance, which is what
      ## solunska-server runs).
    imagePoolDir*: string
      ## Directory backing the default libvirt storage pool. Used to
      ## resolve where ``virt-install`` writes the qcow2 (and where
      ## ``stopAndCleanup`` deletes it from). Defaults to
      ## ``/var/lib/libvirt/images``.
    networkBridge*: string
      ## libvirt network for the guest's primary NIC. Defaults to
      ## ``virbr0`` (the libvirt-managed NAT bridge). Pass a host
      ## bridge name (e.g. ``br0``) for L2-bridged setups.
    sshUser*: string
      ## Default Windows admin user for the SSH transport. Matches the
      ## autounattend.xml in ``guest-recipes/windows-x64-base/``.
    sshPassword*: string
      ## Default Windows admin password. Stored in the backend struct,
      ## NEVER passed via process argv (transit is through
      ## ``sshpass -e``).
    sshPort*: int
      ## Default 22.
    bootTimeoutSec*: int
      ## How long ``virt-install --wait`` and the post-boot SSH probe
      ## tolerate before declaring boot failure.
    sshReadyTimeoutSec*: int
      ## How long to retry the post-IP SSH-ready probe.

const
  DefaultLibvirtImagePool* = "/var/lib/libvirt/images"
  DefaultLibvirtBridge* = "virbr0"
  DefaultLibvirtUri* = "qemu:///system"
  DefaultLibvirtWindowsSshUser* = "admin"
  DefaultLibvirtWindowsSshPassword* = "repro-windows-x64"
    ## Matches ``guest-recipes/windows-x64-base/autounattend.xml``.
  DefaultLibvirtBootTimeoutSec* = 5400
    ## Win11 autounattend installs typically take 20-30 minutes on
    ## KVM, but slower hardware / disk-throughput-limited setups +
    ## Tiny11's extra de-bloat phase can stretch close to an hour. We
    ## give ample headroom (90 minutes) before failing a
    ## provision-from-ISO call — an early failure here is far more
    ## annoying than waiting a bit longer when the install is
    ## actually progressing.
  DefaultLibvirtSshReadyTimeoutSec* = 300

proc resolveLibvirtUri(libvirtUri: string): string =
  ## Honour the standard ``LIBVIRT_DEFAULT_URI`` env var when the
  ## caller didn't override the default. This is the convention
  ## ``virsh``/``virt-install`` themselves follow, and it lets the
  ## L3-REAL integration test redirect from ``qemu:///system`` to
  ## ``qemu:///session`` (user-mode libvirt — sudo-free) without
  ## changing the production registration.
  if libvirtUri != DefaultLibvirtUri:
    return libvirtUri
  let envUri = getEnv("LIBVIRT_DEFAULT_URI")
  if envUri.len > 0:
    return envUri
  return libvirtUri

proc resolveImagePoolDir(libvirtUri, imagePoolDir: string): string =
  ## When ``imagePoolDir`` is the system default but the URI is the
  ## user-mode session, swap to the user-mode pool the libvirt
  ## ``default`` storage-pool autocreates (``~/.local/share/libvirt/
  ## images``). Otherwise honour what the caller passed.
  if imagePoolDir != DefaultLibvirtImagePool:
    return imagePoolDir
  if libvirtUri == "qemu:///session" or libvirtUri.startsWith("qemu+") and
     libvirtUri.endsWith("/session"):
    let home = getEnv("HOME")
    if home.len > 0:
      return home / ".local" / "share" / "libvirt" / "images"
  return imagePoolDir

proc newLibvirtBackend*(virshCmd: string = "virsh",
                        virtInstallCmd: string = "virt-install",
                        qemuImgCmd: string = "qemu-img",
                        sshCmd: string = "ssh",
                        scpCmd: string = "scp",
                        sshpassCmd: string = "sshpass",
                        libvirtUri: string = DefaultLibvirtUri,
                        imagePoolDir: string = DefaultLibvirtImagePool,
                        networkBridge: string = DefaultLibvirtBridge,
                        sshUser: string = DefaultLibvirtWindowsSshUser,
                        sshPassword: string = DefaultLibvirtWindowsSshPassword,
                        sshPort: int = 22,
                        bootTimeoutSec: int = DefaultLibvirtBootTimeoutSec,
                        sshReadyTimeoutSec: int =
                          DefaultLibvirtSshReadyTimeoutSec): LibvirtBackend =
  ## Construct a LibvirtBackend. Defaults match the solunska-server
  ## windows-runner-001 prototype layout: ``qemu:///system``,
  ## ``virbr0`` NAT, qcow2 in ``/var/lib/libvirt/images``, Windows
  ## OpenSSH on TCP/22.
  let effUri = resolveLibvirtUri(libvirtUri)
  let effPool = resolveImagePoolDir(effUri, imagePoolDir)
  result = LibvirtBackend(
    id: biLibvirt,
    hostPlatform: hpLinux,
    supportedGuests: {goLinux, goWindows},
    virshCmd: virshCmd,
    virtInstallCmd: virtInstallCmd,
    qemuImgCmd: qemuImgCmd,
    sshCmd: sshCmd,
    scpCmd: scpCmd,
    sshpassCmd: sshpassCmd,
    libvirtUri: effUri,
    imagePoolDir: effPool,
    networkBridge: networkBridge,
    sshUser: sshUser,
    sshPassword: sshPassword,
    sshPort: sshPort,
    bootTimeoutSec: bootTimeoutSec,
    sshReadyTimeoutSec: sshReadyTimeoutSec)

# ---------------------------------------------------------------------------
# Process invocation helper.
#
# Mirrors ``runProcessCapture`` in hyperv.nim / wsl.nim. Standalone
# (not in process_helpers.nim) so the libvirt slice doesn't drag the
# Windows-only helpers behind it.

proc runProcessCapture(cmd: seq[string], cwd: string = "",
                       timeoutSec: int = 0,
                       env: Table[string, string] = initTable[string, string](),
                       stdinData: string = ""): ExecResult =
  if cmd.len == 0:
    raise newException(ValueError, "runProcessCapture: empty cmd")
  let start = epochTime()
  var procEnv: StringTableRef = nil
  if env.len > 0:
    procEnv = newStringTable(modeStyleInsensitive)
    for k, v in env:
      procEnv[k] = v
  var p = startProcess(cmd[0], workingDir = cwd, args = cmd[1 .. ^1],
                       env = procEnv,
                       options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  if stdinData.len > 0:
    try:
      let s = p.inputStream
      if s != nil:
        s.write(stdinData)
        s.close()
    except CatchableError: discard
  let outStream = p.outputStream
  var stdout = ""
  let deadline = if timeoutSec > 0: epochTime() + timeoutSec.float else: 0.0
  while true:
    var chunk = newString(4096)
    let n = outStream.readData(addr chunk[0], chunk.len)
    if n > 0:
      chunk.setLen(n)
      stdout.add(chunk)
    elif n == 0:
      if not p.running:
        break
      if timeoutSec > 0 and epochTime() > deadline:
        p.terminate()
        return ExecResult(
          exitCode: -1,
          stdout: stdout,
          stderr: "vm-harness: process timed out after " & $timeoutSec & "s",
          elapsedMs: int((epochTime() - start) * 1000))
      sleep(50)
  let code = p.waitForExit(timeout = -1)
  ExecResult(
    exitCode: code,
    stdout: stdout,
    stderr: "",
    elapsedMs: int((epochTime() - start) * 1000))

# ---------------------------------------------------------------------------
# virsh CLI primitives.

proc virshArgs(b: LibvirtBackend, sub: openArray[string]): seq[string] =
  ## Build a ``virsh --connect <uri> <sub...>`` invocation.
  result = @[b.virshCmd, "--connect", b.libvirtUri]
  for s in sub: result.add(s)

proc runVirsh(b: LibvirtBackend, sub: openArray[string],
              timeoutSec: int = 60): ExecResult =
  runProcessCapture(b.virshArgs(sub), timeoutSec = timeoutSec)

proc domainExists*(b: LibvirtBackend, name: string): bool =
  ## ``virsh dominfo <name>`` exits 0 if the domain is defined.
  let r = b.runVirsh(@["dominfo", name], timeoutSec = 30)
  r.exitCode == 0

proc domainState*(b: LibvirtBackend, name: string): string =
  ## Returns one of ``running``, ``paused``, ``shut off``, ``""``
  ## (when the domain doesn't exist). Used by ``startAndAwaitReady``
  ## and ``stopAndCleanup``.
  let r = b.runVirsh(@["domstate", name], timeoutSec = 30)
  if r.exitCode != 0:
    return ""
  result = r.stdout.strip()

proc domainIpAddress*(b: LibvirtBackend, name: string): string =
  ## Returns the first non-empty IPv4 the libvirt guest-agent or DHCP
  ## lease table knows about for the domain's first interface. Returns
  ## empty string when no address is available yet (caller polls).
  ##
  ## ``virsh domifaddr <name>`` reads from libvirt's DHCP lease table
  ## by default; ``--source agent`` reads from qemu-guest-agent (only
  ## works once the in-guest agent is installed). For an autounattended
  ## Windows install the agent isn't installed yet, so we stick with
  ## the lease table.
  let r = b.runVirsh(@["domifaddr", name], timeoutSec = 15)
  if r.exitCode != 0:
    return ""
  for line in r.stdout.splitLines():
    let stripped = line.strip()
    if stripped.len == 0: continue
    if stripped.startsWith("Name") or stripped.startsWith("-"):
      continue
    # Lines look like:
    #   vnet0      52:54:00:aa:bb:cc    ipv4         192.168.122.42/24
    let parts = stripped.splitWhitespace()
    if parts.len >= 4 and parts[2].startsWith("ipv4"):
      let ipField = parts[3]
      let slash = ipField.find('/')
      return if slash > 0: ipField[0 ..< slash] else: ipField

proc startDomain*(b: LibvirtBackend, name: string) =
  ## ``virsh start <name>``. Idempotent when the domain is already
  ## running. Raises ``VmHarnessError`` on a hard failure.
  if b.domainState(name) == "running":
    return
  let r = b.runVirsh(@["start", name], timeoutSec = 120)
  if r.exitCode != 0:
    raise newVmHarnessError($b.id, lpStartup,
      "virsh start " & name & " failed (exit " & $r.exitCode &
      "): " & r.stdout)

proc destroyDomain*(b: LibvirtBackend, name: string) =
  ## ``virsh destroy <name>`` (force-stop). Idempotent; returns
  ## silently when the domain is already stopped or undefined.
  if not b.domainExists(name): return
  if b.domainState(name) != "running": return
  discard b.runVirsh(@["destroy", name], timeoutSec = 60)

proc shutdownDomain*(b: LibvirtBackend, name: string,
                     waitSec: int = 60) =
  ## ``virsh shutdown <name>`` (ACPI graceful). Falls back to
  ## ``destroy`` if the guest doesn't react inside ``waitSec``. Safe
  ## from finally blocks.
  if not b.domainExists(name): return
  if b.domainState(name) != "running": return
  discard b.runVirsh(@["shutdown", name], timeoutSec = 30)
  let deadline = epochTime() + waitSec.float
  while epochTime() < deadline:
    if b.domainState(name) != "running":
      return
    sleep(1000)
  b.destroyDomain(name)

proc undefineDomain*(b: LibvirtBackend, name: string,
                     removeAllStorage: bool = false) =
  ## ``virsh undefine --nvram <name>``. The ``--nvram`` flag is
  ## required for UEFI domains (Win11 needs UEFI + SecureBoot for the
  ## install to proceed); without it virsh refuses to undefine the
  ## domain. Safe from finally blocks.
  ##
  ## We deliberately do NOT pass ``--remove-all-storage`` here even
  ## when the caller asks for it. virt-install attaches read-only
  ## shared resources (the Windows install ISO, virtio-win.iso, the
  ## per-run autounattend.iso) as block devices, and
  ## ``--remove-all-storage`` treats *every* device on the domain as
  ## VM-owned storage — including those shared paths. We saw it
  ## silently delete ``/storage/iso/Win11_*.iso`` during a normal
  ## teardown. Callers that want the qcow2 gone should use
  ## ``deleteDomainDisk``.
  if not b.domainExists(name): return
  discard b.runVirsh(@["undefine", "--nvram", name], timeoutSec = 60)

proc deleteDomainDisk*(b: LibvirtBackend, name: string) =
  ## Delete only the per-VM qcow2 disk that ``bootFromMedia`` wrote
  ## out, never any other libvirt-tracked storage attached to the
  ## domain. See ``undefineDomain`` for the rationale.
  let qcow2 = b.imagePoolDir / (name & ".qcow2")
  if fileExists(qcow2):
    try: removeFile(qcow2)
    except CatchableError: discard

proc autostartDomain*(b: LibvirtBackend, name: string,
                     enabled: bool = true) =
  ## ``virsh autostart [--disable] <name>``. Used to mark the
  ## windows-runner-001 domain as auto-starting after a host reboot.
  var args = @["autostart"]
  if not enabled: args.add("--disable")
  args.add(name)
  discard b.runVirsh(args, timeoutSec = 30)

# ---------------------------------------------------------------------------
# SSH transport helpers.

proc sshBaseArgs*(b: LibvirtBackend, host: string): seq[string] =
  ## Build a base ``ssh`` argv with the standard "non-interactive,
  ## don't pollute known_hosts, accept whatever key the guest presents"
  ## set of flags. Per-call args are appended by the caller.
  let userHost = b.sshUser & "@" & host
  result = @[
    b.sshCmd,
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=10",
    "-p", $b.sshPort,
    userHost]

proc sshpassPrefix*(b: LibvirtBackend): seq[string] =
  ## ``sshpass -e`` prefix; the password is delivered through the
  ## ``SSHPASS`` env var when ``runProcessCapture`` is called, never
  ## via argv. Returns empty seq when ``sshpassCmd`` isn't set (i.e.
  ## the caller has key-based auth).
  if b.sshpassCmd.len == 0 or b.sshPassword.len == 0:
    return @[]
  result = @[b.sshpassCmd, "-e"]

proc runSshExec(b: LibvirtBackend, host: string, command: string,
                env: Table[string, string],
                timeoutSec: int, stdinData: string = ""): ExecResult =
  ## Build a single SSH invocation that runs ``command`` in the guest
  ## with the supplied env table prefixed (Windows CMD/PowerShell
  ## conventions; the autounattend installs OpenSSH with the default
  ## CMD shell).
  var prefix = ""
  for k, v in env:
    # CMD doesn't have a uniform "set in same line" syntax that
    # survives an OpenSSH session, so we emit ``set KEY=VAL && ...``
    # which works under cmd.exe (the default OpenSSH shell on Windows
    # 11 until the registry override sets PowerShell).
    prefix.add("set ")
    prefix.add(k)
    prefix.add("=")
    prefix.add(v)
    prefix.add(" && ")
  let fullCmd = prefix & command
  var argv = b.sshpassPrefix() & b.sshBaseArgs(host) & @[fullCmd]
  var passEnv = initTable[string, string]()
  if b.sshpassCmd.len > 0 and b.sshPassword.len > 0:
    passEnv["SSHPASS"] = b.sshPassword
  runProcessCapture(argv, timeoutSec = timeoutSec, env = passEnv,
                    stdinData = stdinData)

proc scpToGuest(b: LibvirtBackend, host, hostPath, guestPath: string,
                timeoutSec: int = 600) =
  let target = b.sshUser & "@" & host & ":" & guestPath
  var argv = b.sshpassPrefix() & @[
    b.scpCmd,
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=10",
    "-P", $b.sshPort,
    hostPath, target]
  var passEnv = initTable[string, string]()
  if b.sshpassCmd.len > 0 and b.sshPassword.len > 0:
    passEnv["SSHPASS"] = b.sshPassword
  let r = runProcessCapture(argv, timeoutSec = timeoutSec, env = passEnv)
  if r.exitCode != 0:
    raise newVmHarnessError($b.id, lpCopy,
      "scp " & hostPath & " -> " & target & " failed (exit " &
      $r.exitCode & "): " & r.stdout)

proc scpFromGuest(b: LibvirtBackend, host, guestPath, hostPath: string,
                  timeoutSec: int = 600) =
  let src = b.sshUser & "@" & host & ":" & guestPath
  var argv = b.sshpassPrefix() & @[
    b.scpCmd,
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=10",
    "-P", $b.sshPort,
    src, hostPath]
  var passEnv = initTable[string, string]()
  if b.sshpassCmd.len > 0 and b.sshPassword.len > 0:
    passEnv["SSHPASS"] = b.sshPassword
  let r = runProcessCapture(argv, timeoutSec = timeoutSec, env = passEnv)
  if r.exitCode != 0:
    raise newVmHarnessError($b.id, lpCopy,
      "scp " & src & " -> " & hostPath & " failed (exit " &
      $r.exitCode & "): " & r.stdout)

# ---------------------------------------------------------------------------
# virt-install argv builder.
#
# Pure function — unit-testable on any host. The integration tests
# wire this through ``runProcessCapture``; the no-live-virsh smoke
# test asserts on argv shape only.

proc buildVirtInstallArgs*(b: LibvirtBackend, name: string,
                           diskPath: string, diskGB: int,
                           memoryMB: int, vcpus: int,
                           isoPath: string, unattendIsoPath: string,
                           virtioWinIsoPath: string,
                           osVariant: string): seq[string] =
  ## Build the argv for ``virt-install`` to provision a Win11 x64
  ## guest from an ISO + autounattend + virtio-win driver disk.
  ##
  ## Choices baked into the argv:
  ##
  ##  - ``--osinfo`` (libosinfo key) sets PV defaults, picks the
  ##    right q35 board, virtio drivers, secure-boot off for older
  ##    Win11 builds. For Win11 24H2 the key is ``win11`` (libosinfo
  ##    1.10+). Caller passes the value so newer/older virt-install
  ##    can be accommodated.
  ##  - ``--cpu host`` is required for Win11's CPU feature check
  ##    (NX, SSE4.2, POPCNT).
  ##  - ``--machine q35`` + ``--boot uefi`` is mandatory for Win11.
  ##  - Two ``--disk`` lines for the ISOs (Win + virtio-win) so the
  ##    autounattend can load the storage driver from the second CD.
  ##  - One ``--disk`` for the autounattend ISO (FAT12, label
  ##    ``AUTOUNATTEND``, generated by
  ##    ``guest-recipes/windows-x64-base/build-autounattend-iso.sh``).
  ##  - ``--noautoconsole --wait <timeout/60>`` returns control once
  ##    the domain finishes the install (or after the timeout); the
  ##    autounattend's last step shuts the guest down, which virt-
  ##    install treats as install-complete.
  ##  - ``--features smm.state=on`` + secure-boot OVMF needed for the
  ##    TPM-less Win11 install path.
  result = @[
    b.virtInstallCmd,
    "--connect", b.libvirtUri,
    "--name", name,
    "--osinfo", osVariant,
    "--vcpus", $vcpus,
    "--memory", $memoryMB,
    "--cpu", "host-model",
    "--machine", "q35",
    "--boot", "uefi",
    "--features", "smm.state=on",
    # Primary virtio-blk system disk (created on the default pool).
    # boot_order=1 — UEFI tries the system disk first. On the very
    # first boot it's empty, so BdsDxe falls through to boot_order=2
    # (the install CD). On EVERY subsequent boot — including the
    # mid-install reboots Windows Setup issues between WindowsPE
    # phase 1, "specialize", and "oobeSystem" — the disk now has
    # bootmgr written by Setup, so the firmware boots from it and
    # Setup continues on the disk's installed copy instead of
    # restarting from the CD. Without this, a Win11 ISO whose
    # bootloader has been patched to ``efisys_noprompt.bin`` will
    # loop forever: every reboot returns to firmware → CD → fresh
    # Setup launch → reformat → reboot → ... .
    "--disk", "path=" & diskPath & ",size=" & $diskGB &
              ",format=qcow2,bus=virtio,boot_order=1",
    # Windows install media (sata CD-ROM — Win11 Setup can load
    # without virtio drivers; the autounattend uses the virtio-win
    # CD below to inject storage drivers in the WindowsPE phase).
    # boot_order=2 — only used on the very first boot when the
    # primary disk has no bootloader yet.
    "--disk", "device=cdrom,path=" & isoPath &
              ",bus=sata,readonly=on,boot_order=2",
    # virtio-win driver disk (also sata; the autounattend's
    # <DriverPaths> entry pulls amd64\w11 from this CD).
    "--disk", "device=cdrom,path=" & virtioWinIsoPath &
              ",bus=sata,readonly=on",
    # Autounattend CD.
    "--disk", "device=cdrom,path=" & unattendIsoPath &
              ",bus=sata,readonly=on",
    # For qemu:///session we must use the SLIRP user-mode network — a
    # regular user can't create kernel bridges. The L3-REAL integration
    # test on a NixOS workstation runs this branch; production
    # (qemu:///system on solunska) takes the bridge branch.
    (if b.libvirtUri == "qemu:///session" or
        (b.libvirtUri.startsWith("qemu+") and b.libvirtUri.endsWith("/session")):
       "--network"
     else:
       "--network"),
    (if b.libvirtUri == "qemu:///session" or
        (b.libvirtUri.startsWith("qemu+") and b.libvirtUri.endsWith("/session")):
       "user,model=virtio"
     else:
       "bridge=" & b.networkBridge & ",model=virtio"),
    "--graphics", "vnc,listen=127.0.0.1",
    "--video", "qxl",
    "--noautoconsole",
    "--wait", $max(1, b.bootTimeoutSec div 60)]

# ---------------------------------------------------------------------------
# VmBackend method overrides.

method probeAvailability*(b: LibvirtBackend): bool =
  ## Trivially false on non-Linux hosts. On Linux we shell out to
  ## ``virsh --version`` and check the exit code; the helper does NOT
  ## try to ``connect`` to libvirtd because that adds privilege +
  ## socket-availability concerns that ``--backend auto`` callers may
  ## not have set up yet.
  when defined(linux):
    try:
      let r = runProcessCapture(@[b.virshCmd, "--version"],
                                timeoutSec = 5)
      if r.exitCode != 0:
        return false
      # Also verify the libvirtd connection works — this is the more
      # honest "can we drive this backend right now?" probe.
      let r2 = b.runVirsh(@["list", "--all", "--name"], timeoutSec = 10)
      return r2.exitCode == 0
    except CatchableError:
      return false
  else:
    return false

method provisionBaseline*(b: LibvirtBackend, spec: BaselineSpec) =
  ## *Provisioning contract*
  ##
  ## Idempotent: if the domain ``spec.name`` already exists, treat the
  ## call as a no-op (the operator can ``virsh destroy`` + ``virsh
  ## undefine`` between provisions when a re-install is wanted). If it
  ## doesn't exist, run ``virt-install`` against the Win11 x64 recipe
  ## with autounattend.xml + virtio-win driver injection.
  ##
  ## ``spec.sourceImage`` is interpreted as one of:
  ##
  ##  - An absolute path to the Windows install ISO (e.g.
  ##    ``/storage/iso/Win11_24H2_EnglishInternational_x64.iso``).
  ##  - A path to a pre-built qcow2 baseline (suffix ``.qcow2``) — in
  ##    that case we ``virsh define`` from a minimal XML pointing at
  ##    the existing disk, no virt-install needed.
  ##
  ## Companion ISOs (autounattend + virtio-win) are resolved relative
  ## to the recipe directory ``guest-recipes/windows-x64-base/build/``
  ## by default; override via ``BaselineSpec.extra`` keys ``autounattendIso``
  ## and ``virtioWinIso``.
  when defined(linux):
    if spec.name.len == 0:
      raise newException(ValueError,
        "LibvirtBackend.provisionBaseline: BaselineSpec.name is empty")
    if b.domainExists(spec.name):
      # Idempotent. Future re-install: virsh destroy + undefine first.
      return
    if spec.sourceImage.len == 0:
      # ``sourceImage`` empty means "the operator has already defined
      # the domain out-of-band; the harness just asserts it exists".
      # This is the path the e2e auto-selection test exercises on
      # Linux hosts (it can't supply a real ISO). Raise
      # ``BackendUnavailableError`` so the caller can distinguish
      # "domain not yet provisioned" from a programming bug.
      raise newException(BackendUnavailableError,
        "LibvirtBackend.provisionBaseline: domain '" & spec.name &
        "' is not defined and no sourceImage was supplied; either " &
        "pre-define the domain via virsh (the harness will then " &
        "treat the call as a no-op) or pass --source-image with " &
        "the Windows install ISO path")

    # qcow2 fast path: pre-built baseline — just define the domain and
    # return. virt-install is overkill for this case and would re-run
    # the install.
    if spec.sourceImage.endsWith(".qcow2"):
      raise newException(BackendUnavailableError,
        "LibvirtBackend.provisionBaseline: qcow2 import path is not " &
        "implemented in the M4 Phase A slice. Use the ISO+autounattend " &
        "code path, or define the domain manually via virsh.")

    if not fileExists(spec.sourceImage):
      raise newException(IOError,
        "LibvirtBackend.provisionBaseline: sourceImage does not " &
        "exist: " & spec.sourceImage)

    let cpus = if spec.cpus > 0: spec.cpus else: 2
    let mem = if spec.memoryMB > 0: spec.memoryMB else: 4096
    let disk = if spec.diskGB > 0: spec.diskGB else: 80
    let osVariant = case spec.guestOs
                    of goWindows: "win11"
                    of goLinux:   "linux2022"
                    of goMacos:
                      raise newException(BackendUnavailableError,
                        "LibvirtBackend: macOS guests are not supported")
    # Per-call network-bridge override: the canonical libvirt M4 command
    # threads --network-bridge through BaselineSpec.networkBridge. Keep
    # the backend's configured default when unset.
    if spec.networkBridge.len > 0:
      b.networkBridge = spec.networkBridge
    # Recipe directory resolution: prefer spec.recipeDir (the CLI
    # resolves --recipe at parse time and threads the absolute path
    # through); fall back to the historical convention-over-config
    # location for in-tree invocations that pre-date --recipe.
    let recipeDir =
      if spec.recipeDir.len > 0: spec.recipeDir
      else: getCurrentDir() / "guest-recipes" / "windows-x64-base"
    # The per-run build dir holds autounattend.iso (built here),
    # virtio-win.iso (downloaded by fetch-iso.sh or symlinked from
    # the operator's host pool), and the Win11_*.iso symlink. When
    # the operator passed --recipe-build-dir we use that — required
    # for a /nix/store-resident recipeDir that's read-only — and
    # otherwise fall back to ``<recipeDir>/build`` to preserve the
    # in-tree workflow.
    let recipeBuildDir =
      if spec.recipeBuildDir.len > 0: spec.recipeBuildDir
      else: recipeDir / "build"
    if spec.recipeBuildDir.len > 0:
      createDir(recipeBuildDir)
    # When the operator passed --first-boot-script, invoke the recipe's
    # build-autounattend-iso.sh helper (idempotent — it overwrites
    # build/autounattend.iso) before virt-install. This is what makes
    # the canonical libvirt M4 command work end-to-end: the script
    # embeds the operator's bootstrap into the ISO that Setup reads at
    # first boot.
    if spec.firstBootScript.len > 0 or spec.controllerPubKey.len > 0:
      let builder = recipeDir / "build-autounattend-iso.sh"
      if not fileExists(builder):
        raise newException(IOError,
          "LibvirtBackend.provisionBaseline: --first-boot-script / " &
          "--controller-pubkey was supplied but the recipe at " & recipeDir &
          " doesn't have a build-autounattend-iso.sh helper (looked at " &
          builder & ")")
      var buildArgv = @[builder]
      if spec.firstBootScript.len > 0:
        buildArgv.add("--first-boot-script")
        buildArgv.add(spec.firstBootScript)
      if spec.controllerPubKey.len > 0:
        # The pubkey is wrapped into the autounattend ISO alongside the
        # first-boot script; the autounattend.xml's FirstLogonCommands
        # block reads it from the removable medium and writes it into
        # authorized_keys before the controller first touches the guest.
        buildArgv.add("--controller-pubkey")
        buildArgv.add(spec.controllerPubKey)
      # Pass VMH_BUILD_DIR so the builder writes its outputs
      # (autounattend-stage, autounattend.iso) into the writable
      # recipe-build-dir instead of trying to write next to itself
      # when it lives under /nix/store.
      var builderEnv = initTable[string, string]()
      # Inherit existing PATH so xorriso/sed/awk that the unit's
      # runtimeInputs put on the PATH stay visible.
      for k in ["PATH", "HOME", "TMPDIR"]:
        let v = getEnv(k)
        if v.len > 0: builderEnv[k] = v
      builderEnv["VMH_BUILD_DIR"] = recipeBuildDir
      let br = runProcessCapture(buildArgv, cwd = recipeDir,
        timeoutSec = 120, env = builderEnv)
      if br.exitCode != 0:
        raise newVmHarnessError($b.id, lpProvisioning,
          "build-autounattend-iso.sh failed (exit " & $br.exitCode &
          "): " & br.stdout)
    let unattendCandidate = recipeBuildDir / "autounattend.iso"
    let virtioWinCandidate = recipeBuildDir / "virtio-win.iso"
    if not fileExists(unattendCandidate):
      raise newException(IOError,
        "LibvirtBackend.provisionBaseline: autounattend.iso not found " &
        "at " & unattendCandidate & " — run " &
        "guest-recipes/windows-x64-base/build-autounattend-iso.sh first " &
        "(or re-invoke vm-harness provision with --first-boot-script)")
    if spec.guestOs == goWindows and not fileExists(virtioWinCandidate):
      raise newException(IOError,
        "LibvirtBackend.provisionBaseline: virtio-win.iso not found at " &
        virtioWinCandidate & " — run guest-recipes/windows-x64-base/" &
        "fetch-iso.sh first")

    let diskPath = b.imagePoolDir / (spec.name & ".qcow2")
    let argv = buildVirtInstallArgs(b, spec.name, diskPath, disk, mem,
                                    cpus, spec.sourceImage,
                                    unattendCandidate, virtioWinCandidate,
                                    osVariant)
    let r = runProcessCapture(argv, timeoutSec = b.bootTimeoutSec + 120)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "virt-install failed (exit " & $r.exitCode & "): " & r.stdout)
    b.autostartDomain(spec.name, true)
  else:
    raise newException(BackendUnavailableError,
      "LibvirtBackend.provisionBaseline requires a Linux host")

method revertToBaseline*(b: LibvirtBackend, baselineName: string): VmHandle =
  ## *Per-gate revert*
  ##
  ## The M4 Phase A slice does NOT implement a per-gate-revert clone
  ## model — windows-runner-001 is a long-lived runner, not a test
  ## fixture. ``revertToBaseline`` therefore just confirms the domain
  ## exists, starts it if it isn't running, polls for the leased IP +
  ## SSH-ready, and returns a VmHandle pointing at the live domain.
  ##
  ## M4 Phase B will wire ``virsh snapshot-revert --running`` here for
  ## the test-fixture use case.
  when defined(linux):
    if not b.domainExists(baselineName):
      raise newVmHarnessError($b.id, lpRevert,
        "LibvirtBackend.revertToBaseline: domain '" & baselineName &
        "' is not defined; run provisionBaseline first")
    b.startDomain(baselineName)
    # Poll for a leased IP. Win11's first DHCP burst usually arrives
    # within 30s of the OS reaching the desktop.
    let deadline = epochTime() + b.sshReadyTimeoutSec.float
    var ip = ""
    while epochTime() < deadline:
      ip = b.domainIpAddress(baselineName)
      if ip.len > 0: break
      sleep(2000)
    if ip.len == 0:
      raise (ref GuestBootFailureError)(
        backend: $b.id, phase: lpStartup,
        msg: "LibvirtBackend.revertToBaseline: domain " & baselineName &
             " never acquired an IP within " & $b.sshReadyTimeoutSec & "s",
        cause: nil)
    var extra = initTable[string, string]()
    extra["libvirtUri"] = b.libvirtUri
    extra["networkBridge"] = b.networkBridge
    extra["domain"] = baselineName
    result = VmHandle(
      backend: b,
      name: baselineName,
      baseline: baselineName,
      ipAddress: some(ip),
      sshPort: b.sshPort,
      sshUser: b.sshUser,
      sshAuth: SshAuth(kind: saPassword, password: b.sshPassword),
      extra: extra)
  else:
    raise newException(BackendUnavailableError,
      "LibvirtBackend.revertToBaseline requires a Linux host")

method startAndAwaitReady*(b: LibvirtBackend, vm: VmHandle,
                          timeoutSec: int = 120) =
  ## Probe SSH connectivity by running ``hostname`` repeatedly until
  ## it succeeds or ``timeoutSec`` elapses. ``revertToBaseline`` only
  ## waits for an IP; the OpenSSH service may still be starting.
  when defined(linux):
    if vm.ipAddress.isNone:
      raise newException(ValueError,
        "LibvirtBackend.startAndAwaitReady: VmHandle has no IP address")
    let host = vm.ipAddress.get
    let deadline = epochTime() + timeoutSec.float
    while epochTime() < deadline:
      let r = b.runSshExec(host, "hostname",
                           initTable[string, string](),
                           timeoutSec = 15)
      if r.exitCode == 0 and r.stdout.strip().len > 0:
        return
      sleep(2000)
    raise (ref GuestBootFailureError)(
      backend: $b.id, phase: lpStartup,
      msg: "LibvirtBackend.startAndAwaitReady: SSH on " & host &
           " did not become ready within " & $timeoutSec & "s",
      cause: nil)
  else:
    raise newException(BackendUnavailableError,
      "LibvirtBackend.startAndAwaitReady requires a Linux host")

method execInGuest*(b: LibvirtBackend, vm: VmHandle,
                   env: Table[string, string],
                   cmd: seq[string],
                   stdin: string = "",
                   timeoutSec: int = 600): ExecResult =
  ## Run ``cmd`` in the guest via SSH. The argv is joined with spaces
  ## and quoted to survive Windows OpenSSH's CMD-default shell. For
  ## cross-platform parity callers should pass a single-element
  ## ``cmd`` like ``@["powershell.exe", "-NoProfile", "-Command",
  ## "<script>"]``.
  when defined(linux):
    if vm.ipAddress.isNone:
      raise newException(ValueError,
        "LibvirtBackend.execInGuest: VmHandle has no IP address")
    if cmd.len == 0:
      raise newException(ValueError, "execInGuest: empty cmd")
    var line = ""
    for i, a in cmd:
      if i > 0: line.add(' ')
      # Conservative quoting: wrap each arg in double-quotes and
      # escape embedded double-quotes. cmd.exe quoting is famously
      # baroque; this rule is the one that matches OpenSSH-on-Windows's
      # behaviour with `cmd /c`.
      line.add('"')
      line.add(a.replace("\"", "\\\""))
      line.add('"')
    return b.runSshExec(vm.ipAddress.get, line, env, timeoutSec, stdin)
  else:
    raise newException(BackendUnavailableError,
      "LibvirtBackend.execInGuest requires a Linux host")

method copyToGuest*(b: LibvirtBackend, vm: VmHandle,
                   hostPath: string, guestPath: string) =
  when defined(linux):
    if vm.ipAddress.isNone:
      raise newException(ValueError,
        "LibvirtBackend.copyToGuest: VmHandle has no IP address")
    if not fileExists(hostPath) and not dirExists(hostPath):
      raise newVmHarnessError($b.id, lpCopy,
        "LibvirtBackend.copyToGuest: source not found: " & hostPath)
    b.scpToGuest(vm.ipAddress.get, hostPath, guestPath)
  else:
    raise newException(BackendUnavailableError,
      "LibvirtBackend.copyToGuest requires a Linux host")

method copyFromGuest*(b: LibvirtBackend, vm: VmHandle,
                     guestPath: string, hostPath: string) =
  when defined(linux):
    if vm.ipAddress.isNone:
      raise newException(ValueError,
        "LibvirtBackend.copyFromGuest: VmHandle has no IP address")
    createDir(parentDir(hostPath))
    b.scpFromGuest(vm.ipAddress.get, guestPath, hostPath)
  else:
    raise newException(BackendUnavailableError,
      "LibvirtBackend.copyFromGuest requires a Linux host")

method stopAndCleanup*(b: LibvirtBackend, vm: VmHandle,
                      deleteVm: bool = true) =
  ## Safe from finally blocks: never raises. When ``deleteVm`` is
  ## true and the domain was created by the harness (its name matches
  ## the VmHandle), the domain is force-stopped and undefined; when
  ## false, the harness only force-stops the domain (the long-lived
  ## runner survives across maintenance windows).
  ##
  ## For the windows-runner-001 prototype, the orchestrator invokes
  ## ``stopAndCleanup(vm, deleteVm = false)`` so the runner persists
  ## between vm-harness invocations.
  when defined(linux):
    try:
      # Graceful shutdown first; fall back to destroy.
      try: b.shutdownDomain(vm.name)
      except CatchableError: discard
      if deleteVm:
        try: b.undefineDomain(vm.name)
        except CatchableError: discard
        try: b.deleteDomainDisk(vm.name)
        except CatchableError: discard
    except CatchableError:
      discard
  else:
    discard

method installArgvTraceShim*(b: LibvirtBackend, vm: VmHandle,
                            shim: ArgvTraceShim) =
  ## The Windows shim shape from hyperv.nim ports cleanly here — same
  ## ``.real`` rename + CMD wrapper — but the install path needs to
  ## transit SSH instead of PSDirect, and per-binary integration tests
  ## for that combination haven't been written yet. Deferred to M4
  ## Phase B.
  raise newException(BackendUnavailableError,
    "LibvirtBackend.installArgvTraceShim — M4 libvirt slice (Phase B)" &
    " has not implemented the Windows argv shim install path yet")

method uninstallArgvTraceShim*(b: LibvirtBackend, vm: VmHandle,
                              wrappedBinaryName: string) =
  ## No-op: the M4 Phase A slice doesn't install shims, so there's
  ## nothing to revert. A future Phase B that wires the shim install
  ## should also wire the uninstall.
  discard

# ---------------------------------------------------------------------------
# M30 surface — snapshot / restore / list / hot snapshots / export /
# import. The M4 Phase A slice ships clear NotImplementedDefect stubs
# so the conformance surface is unambiguous and the call sites either
# work or fail loudly. Each method documents the wrapped virsh call
# planned for Phase B.

method snapshot*(b: LibvirtBackend, vmName, snapshotName: string): string =
  raise newException(BackendUnavailableError,
    "LibvirtBackend.snapshot — M4 libvirt slice (Phase B) will wrap " &
    "`virsh snapshot-create-as " & vmName & " " & snapshotName &
    " --disk-only --atomic`. Snapshot support tracked as M4 Phase B.")

method snapshotRunning*(b: LibvirtBackend, vmName,
                        snapshotName: string): string =
  raise newException(BackendUnavailableError,
    "LibvirtBackend.snapshotRunning — M4 libvirt slice (Phase B) will " &
    "wrap `virsh snapshot-create-as " & vmName & " " & snapshotName &
    " --live` (memory + CPU + device state). Tracked as M4 Phase B.")

method restoreSnapshot*(b: LibvirtBackend, vmName, snapshotName: string) =
  raise newException(BackendUnavailableError,
    "LibvirtBackend.restoreSnapshot — M4 libvirt slice (Phase B) will " &
    "wrap `virsh snapshot-revert " & vmName & " " & snapshotName &
    " --running`. Tracked as M4 Phase B.")

method listSnapshots*(b: LibvirtBackend, vmName: string): seq[string] =
  raise newException(BackendUnavailableError,
    "LibvirtBackend.listSnapshots — M4 libvirt slice (Phase B) will " &
    "wrap `virsh snapshot-list " & vmName & " --name`. Tracked as M4 " &
    "Phase B.")

method removeSnapshot*(b: LibvirtBackend, vmName, snapshotName: string) =
  raise newException(BackendUnavailableError,
    "LibvirtBackend.removeSnapshot — M4 libvirt slice (Phase B) will " &
    "wrap `virsh snapshot-delete " & vmName & " " & snapshotName &
    "`. Tracked as M4 Phase B.")

method exportBaseline*(b: LibvirtBackend, vmName, destDir: string;
                       baselineName: string = "") =
  raise newException(BackendUnavailableError,
    "LibvirtBackend.exportBaseline — M4 libvirt slice (Phase B) will " &
    "wrap `virsh dumpxml " & vmName & "` + `qemu-img convert` (reflinks " &
    "where the destination volume supports them). Tracked as M4 Phase B.")

method importBaseline*(b: LibvirtBackend, srcDir: string): seq[string] =
  raise newException(BackendUnavailableError,
    "LibvirtBackend.importBaseline — M4 libvirt slice (Phase B) will " &
    "consume the dumpxml/qemu-img bundle produced by exportBaseline. " &
    "Tracked as M4 Phase B.")

# ---------------------------------------------------------------------------
# M1.5 — bootFromMedia + serial-stream primitives.
#
# The base method handles ISO and qcow2 BootMediaSpec.kind values via
# virt-install --import; serial-stream capture is deferred to M4
# Phase B (the implementation pattern mirrors hyperv.nim's named-pipe
# wiring but uses QEMU's `-serial pty` + `virsh console` instead).

const BootDomainNamePrefix* = "repro-test-boot-libvirt-"

proc newBootDomainName(prefix: string = BootDomainNamePrefix): string =
  ## Generate a fresh ``repro-test-boot-libvirt-<hex>`` name. The hex
  ## suffix uses the low bits of epochTime() so two concurrent harness
  ## sessions don't collide.
  prefix & toHex(int64(epochTime() * 1000.0) and 0xFFFFFF'i64, 6).toLowerAscii()

method bootFromMedia*(b: LibvirtBackend, spec: BootMediaSpec): VmHandle =
  ## *Transient boot from media*
  ##
  ## Spins up a one-off libvirt domain around the given qcow2/ISO. The
  ## ``M4 Phase A`` slice supports the qcow2 path (``bmkQcow2`` /
  ## ``bmkVhdx``) and the ISO path (``bmkIso``); rootfs tarballs are
  ## WSL-only.
  ##
  ## *Important*: this method returns a started VmHandle but does NOT
  ## capture serial output — that is the captureSerial path, deferred
  ## to M4 Phase B. The handle MUST be passed to ``stopAndCleanup``.
  when defined(linux):
    if spec.kind == bmkRootfsTar:
      raise newException(BackendUnavailableError,
        "LibvirtBackend.bootFromMedia does not support bmkRootfsTar; " &
        "use WslBackend for tarball boots")
    if spec.mediaPath.len == 0:
      raise newException(ValueError, "BootMediaSpec.mediaPath is empty")
    if not fileExists(spec.mediaPath):
      raise newException(IOError,
        "BootMediaSpec.mediaPath does not exist: " & spec.mediaPath)
    let domainName = if spec.name.len > 0: spec.name else: newBootDomainName()
    if not domainName.startsWith(BootDomainNamePrefix):
      raise newException(ValueError,
        "BootMediaSpec.name must start with '" & BootDomainNamePrefix &
        "' for safety-sweep coverage (got '" & domainName & "')")
    let mem = if spec.memoryMB > 0: spec.memoryMB else: 2048
    let cpus = if spec.cpus > 0: spec.cpus else: 2

    var argv: seq[string] = @[
      b.virtInstallCmd,
      "--connect", b.libvirtUri,
      "--name", domainName,
      "--memory", $mem,
      "--vcpus", $cpus,
      "--cpu", "host",
      "--machine", "q35",
      "--network", "none",   # transient boot — no network exposure
      "--graphics", "none",
      "--noautoconsole",
      "--noreboot"]
    case spec.kind
    of bmkQcow2, bmkVhdx:
      argv.add("--import")
      argv.add("--disk")
      argv.add("path=" & spec.mediaPath & ",format=qcow2,bus=virtio")
    of bmkIso:
      # Empty boot disk; we boot off the CD.
      argv.add("--disk")
      argv.add("size=8,format=qcow2,bus=virtio")
      argv.add("--cdrom")
      argv.add(spec.mediaPath)
    of bmkRootfsTar:
      doAssert false  # guarded above
    if spec.secondaryIsoPath.len > 0:
      argv.add("--disk")
      argv.add("device=cdrom,path=" & spec.secondaryIsoPath & ",readonly=on")

    let r = runProcessCapture(argv, timeoutSec = 120)
    if r.exitCode != 0:
      # Best-effort cleanup of any half-built domain.
      try:
        b.destroyDomain(domainName)
        b.undefineDomain(domainName)
        b.deleteDomainDisk(domainName)
      except CatchableError: discard
      raise newVmHarnessError($b.id, lpStartup,
        "LibvirtBackend.bootFromMedia: virt-install failed (exit " &
        $r.exitCode & "): " & r.stdout)

    var extra = initTable[string, string]()
    extra["mediaPath"] = spec.mediaPath
    extra["serialLogPath"] = if spec.serialLogPath.len > 0:
                               spec.serialLogPath
                             else:
                               getTempDir() / "repro-boot-harness" /
                                 (domainName & ".serial.log")
    result = VmHandle(
      backend: b,
      name: domainName,
      baseline: "<boot-from-media>",
      ipAddress: none(string),
      sshPort: 0,
      sshUser: "",
      sshAuth: SshAuth(kind: saNone),
      extra: extra)
  else:
    raise newException(BackendUnavailableError,
      "LibvirtBackend.bootFromMedia requires a Linux host")

# ---------------------------------------------------------------------------
# Backend registration. Importing this module is enough to make
# ``--backend libvirt`` and ``vm-harness probe`` see the backend.

registerBackend(biLibvirt,
  proc(): VmBackend = newLibvirtBackend())
