## LibvirtBackend — vm-harness adapter for libvirt + QEMU/KVM on Linux
## hosts. Per design doc §4.5 and the M4 slice for the
## windows-runner-001 prototype on ``high-mem-server``.
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
##  - Serial capture for long-lived baseline guests beyond the transient
##    ``bootFromMedia`` path.
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

import std/[algorithm, options, os, osproc, sequtils, streams, strtabs,
            strutils, tables, times]
import ../types
import ../auto
import ../serial

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
      ## high-mem-server runs).
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
    sshKeyPath*: string
      ## Private key used when password authentication is disabled.
    sshKnownHostsPath*: string
      ## Persistent known-hosts file. Empty preserves the legacy ephemeral
      ## media-boot behavior that does not retain host identity.
    sshHostKeyAlias*: string
      ## Stable known-hosts lookup name, independent of forwarded host ports.
    sshGuestOs*: GuestOs
      ## Selects the remote shell quoting convention used by ``execInGuest``.
      ## Defaults to Windows for compatibility with the original libvirt
      ## runner; CLI callers can select a POSIX guest with ``--guest linux``.
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
                        sshKeyPath: string = "",
                        sshKnownHostsPath: string = "",
                        sshHostKeyAlias: string = "",
                        sshGuestOs: GuestOs = goWindows,
                        sshPort: int = 22,
                        bootTimeoutSec: int = DefaultLibvirtBootTimeoutSec,
                        sshReadyTimeoutSec: int =
                          DefaultLibvirtSshReadyTimeoutSec): LibvirtBackend =
  ## Construct a LibvirtBackend. Defaults match the high-mem-server
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
    sshKeyPath: sshKeyPath,
    sshKnownHostsPath: sshKnownHostsPath,
    sshHostKeyAlias: sshHostKeyAlias,
    sshGuestOs: sshGuestOs,
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

proc listAllDomainNames*(b: LibvirtBackend): seq[string] =
  ## ``virsh list --all --name`` — every defined domain (running or
  ## stopped). Used by the M2 ephemeral gate to assert NO residual
  ## per-job domain survives teardown. Returns an empty seq on error.
  let r = b.runVirsh(@["list", "--all", "--name"], timeoutSec = 30)
  if r.exitCode != 0:
    return @[]
  for line in r.stdout.splitLines():
    let s = line.strip()
    if s.len > 0: result.add(s)

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

proc domainDiskPath*(b: LibvirtBackend, name: string): string =
  ## The per-domain qcow2 disk path: ``<imagePoolDir>/<name>.qcow2``.
  ## Single source of truth so ``provisionBaseline`` (both the ISO and
  ## the qcow2-import branches) and ``deleteDomainDisk`` agree — and so
  ## the operator's ``--image-pool-dir`` override lands in one place.
  b.imagePoolDir / (name & ".qcow2")

proc deleteDomainDisk*(b: LibvirtBackend, name: string) =
  ## Delete only the per-VM qcow2 disk that ``bootFromMedia`` wrote
  ## out, never any other libvirt-tracked storage attached to the
  ## domain. See ``undefineDomain`` for the rationale.
  let qcow2 = b.domainDiskPath(name)
  if fileExists(qcow2):
    try: removeFile(qcow2)
    except CatchableError: discard

# ---------------------------------------------------------------------------
# M2 — per-job ephemeral CoW-clone reset.
#
# Each job gets a FRESH VM cloned from the golden qcow2 as a thin CoW
# overlay, booted on real KVM, then destroyed leaving NO residue
# (domain + overlay + nvram gone). This is the "destroy VM per job"
# ephemeral model the GARM provider drives: CreateInstance maps onto
# ``provisionEphemeralClone`` and DeleteInstance onto ``stopAndCleanup``
# (which now removes the per-job overlay).
#
# We build the transient domain XML ourselves and ``virsh define`` it —
# rather than shelling to ``virt-install`` — because (a) it keeps the
# per-job path dependency-light (virt-install isn't always installed on
# the runner host) and (b) it lets the OS-agnostic gate direct-kernel-
# boot a tiny golden (``golden-linux-tiny``) that boots in ~1-2 s and
# emits a serial marker, proving the reset primitive fast + hermetically
# WITHOUT the 81 GiB Windows golden. For a real disk-bootable golden
# (Windows M3) the same path is used with an empty kernel/initrd (the
# firmware boots the overlay directly).

type
  EphemeralCloneSpec* = object
    ## Inputs for one per-job CoW clone.
    name*: string                ## domain name (must be unique per job)
    goldenImage*: string         ## absolute path to the golden qcow2 to
                                 ## clone from (backing file of the overlay)
    cpus*: int                   ## defaults to 2 when 0
    memoryMB*: int               ## defaults to 1024 when 0
    kernel*: string              ## optional: direct-kernel-boot bzImage.
                                 ## When set, ``initrd`` + ``cmdline`` drive a
                                 ## QEMU ``-kernel/-initrd`` boot (the tiny
                                 ## Linux golden). When empty the firmware
                                 ## boots the overlay disk itself.
    initrd*: string              ## optional initramfs for direct-kernel boot
    cmdline*: string             ## optional kernel cmdline (e.g.
                                 ## ``console=ttyS0 quiet panic=1``)
    serialLogPath*: string       ## host path the guest's serial console is
                                 ## captured to (boot-marker harvest). When
                                 ## empty a temp path is chosen.
    configDriveIso*: string      ## optional: absolute path to a config-drive
                                 ## ISO (cloudbase-init ConfigDrive datasource,
                                 ## OpenStack layout ``openstack/latest/
                                 ## {meta_data.json,user_data}``, volume label
                                 ## ``config-2``). When set it is attached to
                                 ## the domain as a read-only CD-ROM so
                                 ## cloudbase-init consumes + runs the injected
                                 ## user_data on first boot. This is the M3 JIT
                                 ## bootstrap-injection seam.
    uefiLoader*: string          ## optional: OVMF code firmware
                                 ## (``edk2-x86_64-code.fd``). When set the
                                 ## domain boots UEFI (required by Windows 11);
                                 ## ``uefiNvramTemplate`` supplies the vars
                                 ## template and ``uefiNvram`` the per-job vars
                                 ## copy. Empty ⇒ legacy/direct-kernel boot
                                 ## (the tiny Linux golden path).
    uefiNvramTemplate*: string   ## OVMF vars template (read-only donor)
    uefiNvram*: string           ## per-job writable OVMF vars copy path

proc configDriveIsoPathFor*(b: LibvirtBackend, name: string): string =
  ## Per-job config-drive ISO path, named ``<domain>.config-drive.iso`` so
  ## the ephemeral teardown can find and remove exactly it (never a
  ## pool-shared install ISO).
  b.imagePoolDir / (name & ".config-drive.iso")

proc buildConfigDriveIso*(isoPath, userData: string;
                          metaData: string = ""): string =
  ## Build a cloudbase-init ConfigDrive ISO at ``isoPath`` carrying the
  ## OpenStack config-drive layout:
  ##
  ##   openstack/latest/meta_data.json   (instance identity)
  ##   openstack/latest/user_data        (the rendered GARM bootstrap;
  ##                                       cloudbase-init's userdata plugin
  ##                                       executes it on first boot)
  ##
  ## The ISO is ISO9660 (Rock-Ridge + Joliet) with the volume label
  ## ``config-2`` — the label cloudbase-init's ConfigDrive datasource
  ## probes for. Returns ``isoPath`` on success; raises on failure.
  ##
  ## ``metaData`` may be a JSON string; when empty a minimal
  ## ``meta_data.json`` is synthesised (uuid + hostname derived from the
  ## ISO basename) so cloudbase-init's datasource is satisfied.
  let staging = getTempDir() / ("vm-harness-configdrive-" &
    toHex(int64(epochTime() * 1000.0) and 0xFFFFFFFF'i64, 8).toLowerAscii())
  let osDir = staging / "openstack" / "latest"
  createDir(osDir)
  var meta = metaData
  if meta.len == 0:
    let base = splitFile(isoPath).name
    meta = "{\"uuid\": \"" & base & "\", \"hostname\": \"" & base &
      "\", \"name\": \"" & base & "\"}"
  writeFile(osDir / "meta_data.json", meta)
  writeFile(osDir / "user_data", userData)
  # Prefer genisoimage/mkisofs; fall back to xorriso (its mkisofs-compat
  # emulation). The volume label MUST be ``config-2``.
  var built = false
  for tool in ["genisoimage", "mkisofs"]:
    if findExe(tool).len > 0:
      let res = runProcessCapture(@[tool,
        "-quiet",
        "-output", isoPath,
        "-volid", "config-2",
        "-joliet", "-rock",
        staging], timeoutSec = 120)
      if res.exitCode == 0:
        built = true
        break
  if not built and findExe("xorriso").len > 0:
    let res = runProcessCapture(@["xorriso", "-as", "mkisofs",
      "-quiet",
      "-o", isoPath,
      "-V", "config-2",
      "-J", "-R",
      staging], timeoutSec = 120)
    if res.exitCode == 0:
      built = true
  try: removeDir(staging)
  except CatchableError: discard
  if not built:
    raise newException(IOError,
      "buildConfigDriveIso: no ISO tool (genisoimage/mkisofs/xorriso) " &
      "succeeded building " & isoPath)
  result = isoPath

proc overlayPathFor*(b: LibvirtBackend, name: string): string =
  ## The per-job CoW overlay lives next to the other pool images and is
  ## named ``<domain>.overlay.qcow2`` so ``stopAndCleanup`` can find and
  ## remove exactly it (never the golden, never a shared ISO).
  b.imagePoolDir / (name & ".overlay.qcow2")

proc buildEphemeralDomainXml*(b: LibvirtBackend, spec: EphemeralCloneSpec,
                              overlayPath, serialLogPath: string): string =
  ## Render a minimal transient domain XML around the per-job overlay.
  ## Pure function — unit-testable without libvirtd. Uses ``type='kvm'``
  ## (real /dev/kvm boot) with a virtio-blk overlay disk and a
  ## file-backed serial console so the harness can read the boot marker.
  let cpus = if spec.cpus > 0: spec.cpus else: 2
  let mem = if spec.memoryMB > 0: spec.memoryMB else: 1024
  # UEFI (Windows 11) needs a pflash loader + writable nvram vars. When a
  # loader is supplied we emit the <loader>/<nvram> pair; otherwise the
  # domain uses SeaBIOS (legacy/direct-kernel — the tiny Linux golden).
  let uefi = spec.uefiLoader.len > 0
  var osBlock = "  <os>\n" &
    "    <type arch='x86_64' machine='q35'>hvm</type>\n"
  if uefi:
    osBlock.add("    <loader readonly='yes' type='pflash' format='raw'>" &
      spec.uefiLoader & "</loader>\n")
    if spec.uefiNvram.len > 0:
      if spec.uefiNvramTemplate.len > 0:
        osBlock.add("    <nvram template='" & spec.uefiNvramTemplate &
          "' templateFormat='raw' format='raw'>" & spec.uefiNvram &
          "</nvram>\n")
      else:
        osBlock.add("    <nvram format='raw'>" & spec.uefiNvram & "</nvram>\n")
  if spec.kernel.len > 0:
    osBlock.add("    <kernel>" & spec.kernel & "</kernel>\n")
    if spec.initrd.len > 0:
      osBlock.add("    <initrd>" & spec.initrd & "</initrd>\n")
    if spec.cmdline.len > 0:
      osBlock.add("    <cmdline>" & spec.cmdline & "</cmdline>\n")
  else:
    osBlock.add("    <boot dev='hd'/>\n")
  osBlock.add("  </os>\n")
  # Optional config-drive CD-ROM (M3 cloudbase-init ConfigDrive datasource).
  # Attached read-only on the SATA bus so a Windows guest's cloudbase-init
  # finds a labelled ``config-2`` volume and runs the injected user_data.
  var configDriveDisk = ""
  if spec.configDriveIso.len > 0:
    configDriveDisk =
      "    <disk type='file' device='cdrom'>\n" &
      "      <driver name='qemu' type='raw'/>\n" &
      "      <source file='" & spec.configDriveIso & "'/>\n" &
      "      <target dev='sda' bus='sata'/>\n" &
      "      <readonly/>\n" &
      "    </disk>\n"
  # A firmware (disk-boot) golden — the real Windows golden — needs a
  # network interface so cloudbase-init can reach the mock/real GARM
  # metadata endpoint. A direct-kernel tiny-Linux golden does not (it
  # self-terminates without networking); we only add the NIC for the
  # firmware-boot path so the existing M2 tiny-golden gate is unchanged.
  var netIface = ""
  if spec.kernel.len == 0:
    netIface =
      "    <interface type='network'>\n" &
      "      <source network='default'/>\n" &
      "      <model type='virtio'/>\n" &
      "    </interface>\n"
  # Windows 11 on UEFI requires SMM + APIC; hyperv enlightenments improve
  # stability. The tiny-Linux path keeps the minimal <acpi/>-only features.
  var featuresBlock = "  <features><acpi/></features>\n"
  var clockBlock = ""
  if uefi:
    featuresBlock =
      "  <features>\n" &
      "    <acpi/>\n    <apic/>\n" &
      "    <hyperv mode='custom'>\n" &
      "      <relaxed state='on'/>\n" &
      "      <vapic state='on'/>\n" &
      "      <spinlocks state='on' retries='8191'/>\n" &
      "    </hyperv>\n" &
      "    <smm state='on'/>\n" &
      "  </features>\n"
    clockBlock =
      "  <clock offset='localtime'>\n" &
      "    <timer name='rtc' tickpolicy='catchup'/>\n" &
      "    <timer name='hpet' present='no'/>\n" &
      "    <timer name='hypervclock' present='yes'/>\n" &
      "  </clock>\n"
  result =
    "<domain type='kvm'>\n" &
    "  <name>" & spec.name & "</name>\n" &
    "  <memory unit='MiB'>" & $mem & "</memory>\n" &
    "  <vcpu>" & $cpus & "</vcpu>\n" &
    osBlock &
    featuresBlock &
    (if uefi: "  <cpu mode='host-passthrough'/>\n" else: "") &
    clockBlock &
    "  <devices>\n" &
    "    <disk type='file' device='disk'>\n" &
    "      <driver name='qemu' type='qcow2'/>\n" &
    "      <source file='" & overlayPath & "'/>\n" &
    "      <target dev='vda' bus='virtio'/>\n" &
    "    </disk>\n" &
    configDriveDisk &
    netIface &
    "    <serial type='file'>\n" &
    "      <source path='" & serialLogPath & "'/>\n" &
    "      <target port='0'/>\n" &
    "    </serial>\n" &
    "    <console type='file'>\n" &
    "      <source path='" & serialLogPath & "'/>\n" &
    "      <target type='serial' port='0'/>\n" &
    "    </console>\n" &
    "  </devices>\n" &
    "</domain>\n"

proc removeEphemeralOverlay*(b: LibvirtBackend, name: string) =
  ## Delete the per-job CoW overlay written by ``provisionEphemeralClone``.
  ## Unlike ``--remove-all-storage`` (which refuses non-pool-managed files
  ## and can nuke shared ISOs), this removes ONLY the ``.overlay.qcow2``
  ## for this domain. Idempotent; never raises.
  let overlay = b.overlayPathFor(name)
  if fileExists(overlay):
    try: removeFile(overlay)
    except CatchableError: discard

method provisionEphemeralClone*(b: LibvirtBackend,
                                spec: EphemeralCloneSpec): VmHandle {.base.} =
  ## Materialise ONE fresh per-job VM: CoW-clone the golden into a thin
  ## overlay, define a transient domain on it, and start it on KVM.
  ##
  ## Steps (exact commands):
  ##   1. ``qemu-img create -f qcow2 -b <golden> -F qcow2 <overlay>``
  ##      — thin CoW overlay; writes stay local to the overlay so the
  ##      golden backs any number of concurrent jobs untouched.
  ##   2. ``virsh define <xml>`` — a transient q35/KVM domain on the
  ##      overlay (direct-kernel-boot when ``spec.kernel`` is set,
  ##      firmware disk-boot otherwise), serial console → a host file.
  ##   3. ``virsh start <name>`` — boot on /dev/kvm.
  ##
  ## The returned handle carries ``overlayPath`` + ``serialLogPath`` in
  ## ``extra`` and is marked ``ephemeral=true`` so ``stopAndCleanup`` (the
  ## DeleteInstance path) destroys + undefines the domain AND removes the
  ## overlay + nvram, leaving no residue.
  when defined(linux):
    if spec.name.len == 0:
      raise newException(ValueError,
        "provisionEphemeralClone: spec.name is empty")
    if spec.goldenImage.len == 0:
      raise newException(ValueError,
        "provisionEphemeralClone: spec.goldenImage is empty")
    if not fileExists(spec.goldenImage):
      raise newException(IOError,
        "provisionEphemeralClone: golden image does not exist: " &
        spec.goldenImage)
    if b.domainExists(spec.name):
      raise newVmHarnessError($b.id, lpProvisioning,
        "provisionEphemeralClone: domain '" & spec.name &
        "' already exists; per-job clones require a fresh name")

    createDir(b.imagePoolDir)
    let overlay = b.overlayPathFor(spec.name)
    # Start from a clean overlay so a stale file from a crashed prior run
    # can't leak state into this job.
    if fileExists(overlay):
      try: removeFile(overlay)
      except CatchableError: discard
    let createArgs = @[b.qemuImgCmd, "create",
      "-f", "qcow2",
      "-b", spec.goldenImage,
      "-F", "qcow2",
      overlay]
    let createRes = runProcessCapture(createArgs, timeoutSec = 60)
    if createRes.exitCode != 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "qemu-img create (CoW overlay over " & spec.goldenImage &
        ") failed (exit " & $createRes.exitCode & "): " & createRes.stdout)

    let serialLogPath =
      if spec.serialLogPath.len > 0: spec.serialLogPath
      else: getTempDir() / "vm-harness-ephemeral" / (spec.name & ".serial.log")
    createDir(parentDir(serialLogPath))
    # Truncate any stale serial log for this domain name.
    try: writeFile(serialLogPath, "")
    except CatchableError: discard

    let xml = b.buildEphemeralDomainXml(spec, overlay, serialLogPath)
    let xmlPath = getTempDir() / "vm-harness-ephemeral" / (spec.name & ".xml")
    createDir(parentDir(xmlPath))
    writeFile(xmlPath, xml)
    let defineRes = b.runVirsh(@["define", xmlPath], timeoutSec = 60)
    if defineRes.exitCode != 0:
      b.removeEphemeralOverlay(spec.name)
      raise newVmHarnessError($b.id, lpProvisioning,
        "virsh define (ephemeral) failed (exit " & $defineRes.exitCode &
        "): " & defineRes.stdout)

    let startRes = b.runVirsh(@["start", spec.name], timeoutSec = 120)
    if startRes.exitCode != 0:
      # Best-effort teardown of the half-built domain.
      try: b.undefineDomain(spec.name)
      except CatchableError: discard
      b.removeEphemeralOverlay(spec.name)
      raise newVmHarnessError($b.id, lpStartup,
        "virsh start (ephemeral) failed (exit " & $startRes.exitCode &
        "): " & startRes.stdout)

    var extra = initTable[string, string]()
    extra["libvirtUri"] = b.libvirtUri
    extra["domain"] = spec.name
    extra["ephemeral"] = "true"
    extra["overlayPath"] = overlay
    extra["goldenImage"] = spec.goldenImage
    extra["serialLogPath"] = serialLogPath
    if spec.configDriveIso.len > 0:
      extra["configDriveIso"] = spec.configDriveIso
    if spec.uefiNvram.len > 0:
      extra["uefiNvram"] = spec.uefiNvram
    result = VmHandle(
      backend: b,
      name: spec.name,
      baseline: spec.goldenImage,
      ipAddress: none(string),
      sshPort: b.sshPort,
      sshUser: b.sshUser,
      sshAuth: SshAuth(kind: saNone),
      extra: extra)
  else:
    raise newException(BackendUnavailableError,
      "provisionEphemeralClone requires a Linux host")

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

proc configuredSshAuth(b: LibvirtBackend): SshAuth =
  if b.sshKeyPath.len > 0:
    SshAuth(kind: saKeyFile, keyPath: b.sshKeyPath)
  elif b.sshPassword.len > 0:
    SshAuth(kind: saPassword, password: b.sshPassword)
  else:
    SshAuth(kind: saNone)

proc sshHostKeyArgs*(b: LibvirtBackend): seq[string] =
  if b.sshKnownHostsPath.len == 0:
    return @[
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null",
    ]
  result = @[
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "UserKnownHostsFile=" & b.sshKnownHostsPath,
  ]
  if b.sshHostKeyAlias.len > 0:
    result.add(@["-o", "HostKeyAlias=" & b.sshHostKeyAlias])

proc sshBaseArgs*(b: LibvirtBackend, host: string): seq[string] =
  ## Build a non-interactive SSH argv. Callers may opt into persistent
  ## trust-on-first-use host identity with ``sshKnownHostsPath``.
  let userHost = b.sshUser & "@" & host
  result = @[b.sshCmd] & b.sshHostKeyArgs() & @[
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=10",
    "-p", $b.sshPort]
  if b.sshKeyPath.len > 0:
    result.add(@["-o", "IdentitiesOnly=yes", "-i", b.sshKeyPath])
  result.add(userHost)

proc sshpassPrefix*(b: LibvirtBackend): seq[string] =
  ## ``sshpass -e`` prefix; the password is delivered through the
  ## ``SSHPASS`` env var when ``runProcessCapture`` is called, never
  ## via argv. Returns empty seq when ``sshpassCmd`` isn't set (i.e.
  ## the caller has key-based auth).
  if b.sshKeyPath.len > 0 or b.sshpassCmd.len == 0 or
      b.sshPassword.len == 0:
    return @[]
  result = @[b.sshpassCmd, "-e"]

proc quotePosixShellArg*(arg: string): string =
  ## Single-quote one argument for a POSIX login shell. Embedded single quotes
  ## leave and re-enter the quoted region without exposing any argument bytes.
  "'" & arg.replace("'", "'\"'\"'") & "'"

proc formatSshCommand*(cmd: openArray[string]; guestOs: GuestOs): string =
  ## OpenSSH servers pass their command payload through the guest's configured
  ## login shell, so argv must be rendered for that shell rather than merely
  ## concatenated.
  case guestOs
  of goLinux, goMacos:
    for arg in cmd:
      if result.len > 0:
        result.add(' ')
      result.add(quotePosixShellArg(arg))
  of goWindows:
    for arg in cmd:
      if result.len > 0:
        result.add(' ')
      result.add('"')
      result.add(arg.replace("\"", "\\\""))
      result.add('"')

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
  if b.sshKeyPath.len == 0 and b.sshpassCmd.len > 0 and
      b.sshPassword.len > 0:
    passEnv["SSHPASS"] = b.sshPassword
  runProcessCapture(argv, timeoutSec = timeoutSec, env = passEnv,
                    stdinData = stdinData)

proc scpToGuest(b: LibvirtBackend, host, hostPath, guestPath: string,
                timeoutSec: int = 600) =
  let target = b.sshUser & "@" & host & ":" & guestPath
  var argv = b.sshpassPrefix() & @[b.scpCmd] & b.sshHostKeyArgs() & @[
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=10",
    "-P", $b.sshPort]
  if b.sshKeyPath.len > 0:
    argv.add(@["-o", "IdentitiesOnly=yes", "-i", b.sshKeyPath])
  argv.add(@[hostPath, target])
  var passEnv = initTable[string, string]()
  if b.sshKeyPath.len == 0 and b.sshpassCmd.len > 0 and
      b.sshPassword.len > 0:
    passEnv["SSHPASS"] = b.sshPassword
  let r = runProcessCapture(argv, timeoutSec = timeoutSec, env = passEnv)
  if r.exitCode != 0:
    raise newVmHarnessError($b.id, lpCopy,
      "scp " & hostPath & " -> " & target & " failed (exit " &
      $r.exitCode & "): " & r.stdout)

proc scpFromGuest(b: LibvirtBackend, host, guestPath, hostPath: string,
                  timeoutSec: int = 600) =
  let src = b.sshUser & "@" & host & ":" & guestPath
  var argv = b.sshpassPrefix() & @[b.scpCmd] & b.sshHostKeyArgs() & @[
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=10",
    "-P", $b.sshPort]
  if b.sshKeyPath.len > 0:
    argv.add(@["-o", "IdentitiesOnly=yes", "-i", b.sshKeyPath])
  argv.add(@[src, hostPath])
  var passEnv = initTable[string, string]()
  if b.sshKeyPath.len == 0 and b.sshpassCmd.len > 0 and
      b.sshPassword.len > 0:
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
    # Disable secure-boot for the OVMF firmware. The libosinfo win11
    # profile activates secure-boot=yes by default, which requires
    # Microsoft's UEFI CA keys to be enrolled in the per-VM nvram
    # vars file. The nixpkgs OVMF derivation in current use only
    # ships the bare ``edk2-i386-vars.fd`` template (no
    # key-enrolled variant), so secure-boot=yes silently rejects the
    # Microsoft-signed bootmgr off the Win11 install CD and stalls
    # at ``BdsDxe: No bootable option or device was found``.
    #
    # Win11's setup-time policy only enforces TPM 2.0 (which the
    # ``tpm`` block above provides); secure-boot enforcement at
    # install time is checked but doesn't block installation when
    # disabled at the firmware level. The runner workload doesn't
    # need secure-boot post-install either — it's an ephemeral CI
    # box that reverts to a clean snapshot between jobs.
    "--boot",
    "uefi,firmware.feature0.enabled=no,firmware.feature0.name=secure-boot,loader.secure=no",
    "--features", "smm.state=on",
    # Primary virtio-blk system disk (created on the default pool).
    # boot_order=2 — UEFI tries the install CD first. Once Setup
    # writes bootmgr to the disk in WindowsPE phase 1, the Windows
    # bootloader registers itself as a UEFI boot entry (BOOTX64.EFI
    # under \EFI\Microsoft\Boot\), and the firmware's
    # ``BootOrder`` variable starts preferring it ahead of the
    # ``boot_order`` knob virt-install set here. Subsequent
    # mid-install reboots therefore boot from the disk, not from
    # the CD — exactly the convergence we want — and the install
    # finishes without looping on the CD's "Press any key to boot
    # from CD" prompt.
    #
    # We previously kept the disk at boot_order=1 (CD at 2) to lean
    # on UEFI's "try next boot option on failure" behavior on the
    # first boot, but Tianocore's BdsDxe doesn't reliably fall
    # through from an empty virtio-blk disk to a SATA CD-ROM — it
    # stalls at "No bootable option or device was found" instead
    # of advancing to the next entry. Putting the CD first dodges
    # that codepath entirely.
    "--disk", "path=" & diskPath & ",size=" & $diskGB &
              ",format=qcow2,bus=virtio,boot_order=2",
    # Windows install media (sata CD-ROM — Win11 Setup can load
    # without virtio drivers; the autounattend uses the virtio-win
    # CD below to inject storage drivers in the WindowsPE phase).
    # boot_order=1 — primary boot source for the install lifecycle.
    "--disk", "device=cdrom,path=" & isoPath &
              ",bus=sata,readonly=on,boot_order=1",
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
    # (qemu:///system on high-mem-server) takes the bridge branch.
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
# UEFI El Torito ISO validation.
#
# The libvirt Win11 domain is UEFI-only (q35 + OVMF). A BIOS-only install
# ISO — one whose only El Torito boot image has platform BIOS — boots to
# nothing: OVMF finds no UEFI boot option and silently drops to the UEFI
# shell, and ``virt-install --wait`` then sits for ~90 minutes before
# timing out with no actionable cause. ``provisionBaseline`` validates the
# ISO up front so the ONE-COMMAND CLI flow (``vm-harness provision
# --backend libvirt --recipe windows-x64-base ...``) fails fast even when
# the operator skipped the optional ``guest-recipes/.../fetch-iso.sh`` prep
# (which performs the identical check via
# ``guest-recipes/lib/validate-uefi-iso.sh``).
#
# The decision logic here is a faithful port of that shell helper's
# ``uefi_report_indicates_uefi`` so both entry points agree exactly.

proc isoHasUefiElTorito*(report: string): bool =
  ## Pure decision over an ``xorriso -report_el_torito`` dump (``plain`` or
  ## ``as_mkisofs`` form) — or an isoinfo/iso-info dump. Returns true when
  ## the report indicates a UEFI (EFI) El Torito boot image, false
  ## otherwise. No I/O; this is the unit-tested core.
  # Strategy 1 — `-report_el_torito plain`: each boot image is a line like
  #   El Torito boot img :   2  UEFI  y   none  0x0000  0x00  5760   34
  # whose platform column is BIOS or UEFI. A BIOS-only ISO only shows BIOS.
  for rawLine in report.splitLines():
    let low = rawLine.toLowerAscii()
    if "torito" in low and "boot img" in low:
      for tok in rawLine.splitWhitespace():
        if tok.toLowerAscii() == "uefi":
          return true
  # Strategy 2 — `-report_el_torito as_mkisofs`: an EFI image is emitted as
  # a `-eltorito-alt-boot` section carrying an EFI boot image (`-e <img>` /
  # `--efi-boot <img>`) or an explicit EFI platform selector. None of these
  # tokens appear for a BIOS-only ISO.
  block asMkisofs:
    var hasAltBoot = false
    var hasEfiImage = false
    let toks = report.splitWhitespace()
    for i, tok in toks:
      let low = tok.toLowerAscii()
      if low == "-eltorito-alt-boot":
        hasAltBoot = true
      elif low == "-e" or low == "--efi-boot":
        hasEfiImage = true
      elif low == "-eltorito-platform" and i + 1 < toks.len:
        let nxt = toks[i + 1].toLowerAscii()
        if nxt == "0xef" or nxt == "efi" or nxt == "uefi":
          hasEfiImage = true
      elif "efi" in low and (low.endsWith(".bin") or low.endsWith(".img") or
                             low.endsWith(".efi")):
        hasEfiImage = true
    if hasAltBoot and hasEfiImage:
      return true
  # Strategy 3 — generic textual fallback (isoinfo/iso-info, or an xorriso
  # form that spells out the platform). Accept only an El Torito record
  # that explicitly names a UEFI/EFI platform, so a stray "efi" token in an
  # unrelated field can't produce a false accept.
  for rawLine in report.splitLines():
    let low = rawLine.toLowerAscii()
    if "torito" in low and "platform" in low and
       ("uefi" in low or "efi" in low):
      return true
    if "platform id" in low and "0xef" in low:
      return true
    if "platform id" in low and ("(uefi)" in low or "(efi)" in low):
      return true
  return false

proc queryIsoElToritoReport*(isoPath: string,
                             xorrisoCmd: string = "xorriso"): Option[string] =
  ## Run ``xorriso -indev <iso> -report_el_torito`` (``plain``, falling back
  ## to ``as_mkisofs``) and return its report text. Returns ``none`` when
  ## no ``xorriso`` binary is available (so the caller can WARN rather than
  ## fail, mirroring the shell helper's missing-tooling semantics).
  if findExe(xorrisoCmd).len == 0:
    return none(string)
  var r = runProcessCapture(@[xorrisoCmd, "-indev", isoPath,
                              "-report_el_torito", "plain"], timeoutSec = 60)
  if r.exitCode != 0 or r.stdout.strip().len == 0:
    r = runProcessCapture(@[xorrisoCmd, "-indev", isoPath,
                            "-report_el_torito", "as_mkisofs"], timeoutSec = 60)
  return some(r.stdout)

proc validateWindowsIsoBootable*(b: LibvirtBackend, isoPath: string,
                                 xorrisoCmd: string = "xorriso") =
  ## Fail fast when ``isoPath`` is a BIOS-only Windows install ISO that
  ## would silently stall the UEFI q35 install. When ``xorriso`` is present
  ## and finds NO UEFI El Torito record, raise a ``VmHarnessError``
  ## (``lpProvisioning``) whose message matches
  ## ``guest-recipes/lib/validate-uefi-iso.sh``. When ``xorriso`` is absent,
  ## WARN and skip (missing tooling is never a hard failure).
  let report = queryIsoElToritoReport(isoPath, xorrisoCmd)
  if report.isNone:
    stderr.writeLine("vm-harness libvirt: WARNING — no xorriso on PATH; " &
      "skipping the UEFI El Torito validation of " & isoPath &
      ". Install xorriso (provided by the vm-harness dev shell) to enable " &
      "this check.")
    return
  if isoHasUefiElTorito(report.get):
    return
  raise newVmHarnessError($b.id, lpProvisioning,
    "The Windows install ISO " & isoPath & " has no UEFI (EFI) El Torito " &
    "boot record — this ISO is BIOS-boot only and will NOT boot the UEFI " &
    "q35/virt Win11 domain (OVMF drops to the UEFI shell, and virt-install " &
    "then stalls on --wait for ~90 minutes with no clear cause). Supply a " &
    "UEFI-bootable Windows 11 ISO instead — a stock Microsoft ISO from " &
    "microsoft.com carries both BIOS and UEFI El Torito boot records and " &
    "works out of the box (pass its path via --source-image, or drop it at " &
    "the recipe's expected location / set VMH_WIN11_X64_ISO).")

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

    # Operator override: place the domain disk in a pool directory of
    # their choosing (e.g. a large ZFS pool at ``/storage``) instead of
    # the default ``/var/lib/libvirt/images``. Applied once here so both
    # the qcow2-import fast path and the ISO+autounattend path (and the
    # ``domainDiskPath`` helper they share) honour it. Empty ⇒ the
    # backend's configured pool is used unchanged.
    if spec.imagePoolDir.len > 0:
      b.imagePoolDir = spec.imagePoolDir

    # qcow2 fast path: pre-built baseline. The operator points
    # ``--source-image`` at a known-good Win11 qcow2 (e.g. a snapshot
    # created from a successful prior install). We clone it as the
    # per-VM disk via a qcow2 backing-file relationship and define a
    # minimal domain — no virt-install, no autounattend, no install
    # ISOs. ``virsh start`` then boots the cloned image directly.
    #
    # Use case: the libvirt M4 install path requires a Win11 ISO with
    # both BIOS and UEFI El Torito records AND an OVMF that auto-boots
    # the UEFI eltorito image. When either is missing (BIOS-only ISOs,
    # OVMF versions that don't auto-discover) the install path stalls
    # at the firmware boot menu. The qcow2 path side-steps the entire
    # firmware-discovery layer.
    if spec.sourceImage.endsWith(".qcow2"):
      if not fileExists(spec.sourceImage):
        raise newException(IOError,
          "LibvirtBackend.provisionBaseline: --source-image qcow2 " &
          "does not exist: " & spec.sourceImage)
      let cpus = if spec.cpus > 0: spec.cpus else: 2
      let mem = if spec.memoryMB > 0: spec.memoryMB else: 4096
      if spec.networkBridge.len > 0:
        b.networkBridge = spec.networkBridge
      let diskPath = b.domainDiskPath(spec.name)
      # Clone-on-write: the per-VM qcow2 is a thin overlay over the
      # operator-supplied baseline. Writes are local to the overlay so
      # the baseline stays clean and can back any number of runners.
      let createArgs = @["qemu-img", "create",
        "-F", "qcow2",
        "-b", spec.sourceImage,
        "-f", "qcow2",
        diskPath]
      let createRes = runProcessCapture(createArgs, timeoutSec = 60)
      if createRes.exitCode != 0:
        raise newVmHarnessError($b.id, lpProvisioning,
          "qemu-img create (qcow2 backing " & spec.sourceImage &
          ") failed (exit " & $createRes.exitCode &
          "): " & createRes.stdout)
      # Define the minimal q35 UEFI domain via a per-call virsh
      # define so the firmware path matches the install branch.
      # virt-install --import does this in one shot.
      let importArgs = @[
        "virt-install",
        "--connect", b.libvirtUri,
        "--name", spec.name,
        "--osinfo", "win11",
        "--vcpus", $cpus,
        "--memory", $mem,
        "--cpu", "host-model",
        "--machine", "q35",
        # Match the install path's secure-boot stance (see the
        # ISO+autounattend branch below for the rationale).
        "--boot",
        "uefi,firmware.feature0.enabled=no,firmware.feature0.name=secure-boot,loader.secure=no",
        "--features", "smm.state=on",
        "--disk", "path=" & diskPath & ",format=qcow2,bus=virtio",
        "--network", "bridge=" & b.networkBridge & ",model=virtio",
        "--graphics", "vnc,listen=127.0.0.1",
        "--video", "qxl",
        "--noautoconsole",
        "--import",
        "--noreboot"
      ]
      let importRes = runProcessCapture(importArgs, timeoutSec = 120)
      if importRes.exitCode != 0:
        raise newVmHarnessError($b.id, lpProvisioning,
          "virt-install --import failed (exit " & $importRes.exitCode &
          "): " & importRes.stdout)
      # Start the domain (--noreboot above keeps it powered off after
      # the import).
      let startArgs = b.virshArgs(@["start", spec.name])
      let startRes = runProcessCapture(startArgs, timeoutSec = 60)
      if startRes.exitCode != 0:
        raise newVmHarnessError($b.id, lpProvisioning,
          "virsh start failed (exit " & $startRes.exitCode &
          "): " & startRes.stdout)
      return

    if not fileExists(spec.sourceImage):
      raise newException(IOError,
        "LibvirtBackend.provisionBaseline: sourceImage does not " &
        "exist: " & spec.sourceImage)

    # Fail fast on a BIOS-only Windows ISO BEFORE launching virt-install —
    # a UEFI q35 domain can't boot it (OVMF drops to the UEFI shell and
    # --wait stalls ~90 min). This protects the one-command CLI flow even
    # when the operator skipped the recipe's fetch-iso.sh prep. Only the
    # Windows install ISO carries the UEFI-El-Torito requirement here; a
    # Linux guest install ISO is left unchecked (it isn't the trap this
    # guards, and Linux media is commonly hybrid/UEFI already).
    if spec.guestOs == goWindows:
      b.validateWindowsIsoBootable(spec.sourceImage)

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

    let diskPath = b.domainDiskPath(spec.name)
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
      sshAuth: b.configuredSshAuth(),
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
  ## Run ``cmd`` in the guest via SSH using the quoting rules for the guest's
  ## configured login shell.
  when defined(linux):
    if vm.ipAddress.isNone:
      raise newException(ValueError,
        "LibvirtBackend.execInGuest: VmHandle has no IP address")
    if cmd.len == 0:
      raise newException(ValueError, "execInGuest: empty cmd")
    let line = formatSshCommand(cmd, b.sshGuestOs)
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
  ##
  ## For M2 per-job EPHEMERAL clones (``vm.extra["ephemeral"] == "true"``,
  ## set by ``provisionEphemeralClone``) this is the DeleteInstance path:
  ## the domain is force-destroyed and undefined, and the per-job CoW
  ## overlay is removed, leaving NO residual domain/disk. The golden is
  ## never touched (only the ``.overlay.qcow2`` is removed).
  when defined(linux):
    let isEphemeral = vm.extra.getOrDefault("ephemeral", "") == "true"
    let isTransientBoot = vm.baseline == "<boot-from-media>"
    let preserveBootDisk =
      vm.extra.getOrDefault("preserveBootDisk", "") == "true"
    try:
      if isEphemeral or isTransientBoot:
        # Force-stop immediately — a per-job VM has no state worth a
        # graceful ACPI shutdown, and it may already have powered itself
        # off (the tiny golden's init calls ``poweroff -f``).
        try: b.destroyDomain(vm.name)
        except CatchableError: discard
      else:
        # Graceful shutdown first; fall back to destroy.
        try: b.shutdownDomain(vm.name)
        except CatchableError: discard
      if deleteVm:
        try: b.undefineDomain(vm.name)
        except CatchableError: discard
        if isEphemeral:
          # Remove ONLY this job's CoW overlay (never the golden or a
          # shared ISO). Equivalent to the design-doc's
          # ``undefine --remove-all-storage`` for the ephemeral case, but
          # scoped so it can't delete pool-shared read-only media.
          try: b.removeEphemeralOverlay(vm.name)
          except CatchableError: discard
          # Also remove this job's injected config-drive ISO + per-job
          # OVMF nvram vars copy (M3). Both are per-job artifacts named
          # after the domain; the golden + the OVMF template are untouched.
          let cdIso = vm.extra.getOrDefault("configDriveIso", "")
          if cdIso.len > 0 and fileExists(cdIso):
            try: removeFile(cdIso)
            except CatchableError: discard
          let nvram = vm.extra.getOrDefault("uefiNvram", "")
          if nvram.len > 0 and fileExists(nvram):
            try: removeFile(nvram)
            except CatchableError: discard
        elif not preserveBootDisk:
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
# virt-install. Libvirt writes the serial stream to a durable host file from
# the first firmware byte, and the assertion path incrementally polls it.

const BootDomainNamePrefix* = "repro-test-boot-libvirt-"

proc newBootDomainName(prefix: string = BootDomainNamePrefix): string =
  ## Generate a fresh ``repro-test-boot-libvirt-<hex>`` name. The hex
  ## suffix uses the low bits of epochTime() so two concurrent harness
  ## sessions don't collide.
  prefix & toHex(int64(epochTime() * 1000.0) and 0xFFFFFF'i64, 6).toLowerAscii()

proc transientBootCompatibilityArgs*(): seq[string] =
  ## Flags required by current virt-install releases.
  @["--osinfo", "detect=on,require=off"]

proc transientBootSerialArgs*(serialLogPath: string): seq[string] =
  ## Let QEMU own the durable serial log from the first firmware byte. This
  ## avoids losing early diagnostics while a separate console client attaches.
  @["--serial", "file,path=" & serialLogPath]

proc transientBootFirmwareArgs*(spec: BootMediaSpec,
                                loaderPath = "",
                                nvramTemplate = ""): seq[string] =
  ## Translate the cross-backend generation contract to virt-install. An
  ## explicit loader pair avoids firmware-autodetection gaps on NixOS hosts.
  let generation = if spec.generation > 0: spec.generation else: 2
  if generation notin [1, 2]:
    raise newException(ValueError,
      "BootMediaSpec.generation must be 1 or 2")
  if generation == 1:
    return @[]
  if (loaderPath.len == 0) != (nvramTemplate.len == 0):
    raise newException(ValueError,
      "UEFI boot requires both a loader and an NVRAM template")
  if loaderPath.len == 0:
    return @["--boot", "uefi"]
  let secure = if spec.secureBootEnabled: "yes" else: "no"
  @["--boot", "loader=" & loaderPath &
      ",loader.readonly=yes,loader.type=pflash,loader.secure=" & secure &
      ",nvram.template=" & nvramTemplate]

proc transientBootGraphicsArgs*(spec: BootMediaSpec): seq[string] =
  ## Graphical consoles listen on loopback only. ``virtio`` is broadly
  ## supported by modern Linux guests while callers can select another model.
  let videoModel = if spec.videoModel.len > 0: spec.videoModel else: "virtio"
  case spec.graphics
  of bgNone:
    @["--graphics", "none"]
  of bgVnc:
    @["--graphics", "vnc,listen=127.0.0.1", "--video", videoModel]
  of bgSpice:
    @["--graphics", "spice,listen=127.0.0.1", "--video", videoModel]

proc transientBootNetworkArgs*(spec: BootMediaSpec): seq[string] =
  ## Direct boots are network-isolated unless a caller explicitly requests an
  ## SSH forward. The user-mode NIC remains reachable only through loopback.
  if spec.sshForwardPort == 0:
    return @["--network", "none"]
  if spec.sshForwardPort notin 1 .. 65535:
    raise newException(ValueError,
      "BootMediaSpec.sshForwardPort must be 0 or a TCP port from 1 to 65535")
  @["--network", "user,model=virtio"]

proc transientBootHostForwardHmp*(spec: BootMediaSpec): string =
  ## Add the loopback forward after libvirt has created its user-mode netdev.
  ## QEMU processes command-line property overrides before netdev creation, so
  ## the monitor command is the first point where ``hostnet0`` exists.
  if spec.sshForwardPort == 0:
    return ""
  if spec.sshForwardPort notin 1 .. 65535:
    raise newException(ValueError,
      "BootMediaSpec.sshForwardPort must be 0 or a TCP port from 1 to 65535")
  "hostfwd_add hostnet0 tcp:127.0.0.1:" & $spec.sshForwardPort & "-:22"

proc resolveTransientOvmf(spec: BootMediaSpec): tuple[loader, nvram: string] =
  ## Resolve OVMF without assuming that libvirt's firmware descriptor search
  ## path includes Nix store packages. Explicit CLI flags and environment
  ## variables take precedence over conventional distro locations.
  let generation = if spec.generation > 0: spec.generation else: 2
  if generation != 2:
    return

  proc acceptPair(loader, nvram: string): bool =
    if loader.len == 0 and nvram.len == 0:
      return false
    if loader.len == 0 or nvram.len == 0:
      raise newException(ValueError,
        "UEFI boot requires both a loader and an NVRAM template")
    if not fileExists(loader):
      raise newException(IOError, "UEFI loader does not exist: " & loader)
    if not fileExists(nvram):
      raise newException(IOError,
        "UEFI NVRAM template does not exist: " & nvram)
    result = true

  let explicitLoader = spec.extra.getOrDefault("uefiLoader")
  let explicitNvram = spec.extra.getOrDefault("uefiNvramTemplate")
  if acceptPair(explicitLoader, explicitNvram):
    return (explicitLoader, explicitNvram)

  let envLoader = getEnv("VMH_OVMF_CODE")
  let envNvram = getEnv("VMH_OVMF_VARS")
  if acceptPair(envLoader, envNvram):
    return (envLoader, envNvram)

  const conventionalPairs = [
    ("/run/libvirt/nix-ovmf/edk2-x86_64-code.fd",
     "/run/libvirt/nix-ovmf/edk2-i386-vars.fd"),
    ("/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_VARS.fd"),
    ("/usr/share/edk2/ovmf/OVMF_CODE.fd",
     "/usr/share/edk2/ovmf/OVMF_VARS.fd"),
    ("/usr/share/edk2/x64/OVMF_CODE.fd",
     "/usr/share/edk2/x64/OVMF_VARS.fd"),
  ]
  for pair in conventionalPairs:
    if fileExists(pair[0]) and fileExists(pair[1]):
      return pair

  when defined(linux):
    var nixLoaders = toSeq(
      walkPattern("/nix/store/*-OVMF-*-fd/FV/OVMF_CODE.fd"))
    nixLoaders.sort()
    for loader in nixLoaders.reversed():
      let nvram = loader.parentDir / "OVMF_VARS.fd"
      if fileExists(nvram):
        return (loader, nvram)

  # Let virt-install try its native firmware descriptors. Its error includes
  # distro-specific remediation when none are installed.
  return ("", "")

type
  LibvirtSerialStream* = ref object of SerialStream
    buf*: SerialLineBuffer
    fileOffset*: int64

proc pumpSerialFile(s: LibvirtSerialStream) =
  if s == nil or not fileExists(s.logPath):
    return
  try:
    let size = getFileSize(s.logPath)
    if size < s.fileOffset:
      s.fileOffset = 0
    if size <= s.fileOffset:
      return
    var f = open(s.logPath, fmRead)
    defer: f.close()
    setFilePos(f, s.fileOffset)
    let bytes = f.readAll()
    s.fileOffset += bytes.len.int64
    s.buf.feed(bytes)
  except CatchableError:
    discard

method bootFromMedia*(b: LibvirtBackend, spec: BootMediaSpec): VmHandle =
  ## *Transient boot from media*
  ##
  ## Spins up a one-off libvirt domain around the given qcow2/ISO. The
  ## ``M4 Phase A`` slice supports the qcow2 path (``bmkQcow2`` /
  ## ``bmkVhdx``) and the ISO path (``bmkIso``); rootfs tarballs are
  ## WSL-only.
  ##
  ## *Important*: this method returns a started VmHandle but does not begin
  ## polling its file-backed serial output. Pass the handle to
  ## ``captureSerial`` and always finish with ``stopAndCleanup``.
  when defined(linux):
    if spec.kind == bmkRootfsTar:
      raise newException(BackendUnavailableError,
        "LibvirtBackend.bootFromMedia does not support bmkRootfsTar; " &
        "use WslBackend for tarball boots")
    if spec.targetDiskPath.len > 0 and spec.kind != bmkIso:
      raise newException(ValueError,
        "BootMediaSpec.targetDiskPath is valid only with bmkIso")
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
    let serialLogPath = if spec.serialLogPath.len > 0:
                          spec.serialLogPath
                        else:
                          getTempDir() / "repro-boot-harness" /
                            (domainName & ".serial.log")
    let serialLogDir = parentDir(serialLogPath)
    if serialLogDir.len > 0:
      createDir(serialLogDir)
    if fileExists(serialLogPath):
      removeFile(serialLogPath)
    writeFile(serialLogPath, "")
    setFilePermissions(serialLogPath, {
      fpUserRead, fpUserWrite,
      fpGroupRead, fpGroupWrite,
      fpOthersRead, fpOthersWrite})

    let ovmf = resolveTransientOvmf(spec)
    var attachedMediaPath = spec.mediaPath
    if spec.kind == bmkQcow2:
      createDir(b.imagePoolDir)
      attachedMediaPath = b.domainDiskPath(domainName)
      if fileExists(attachedMediaPath):
        removeFile(attachedMediaPath)
      let overlay = runProcessCapture(@[
        b.qemuImgCmd, "create", "-f", "qcow2",
        "-b", absolutePath(spec.mediaPath), "-F", "qcow2",
        attachedMediaPath], timeoutSec = 120)
      if overlay.exitCode != 0:
        raise newVmHarnessError($b.id, lpStartup,
          "LibvirtBackend.bootFromMedia: qemu-img overlay failed (exit " &
          $overlay.exitCode & "): " & overlay.stdout)
    elif spec.kind == bmkIso and spec.targetDiskPath.len > 0:
      attachedMediaPath = absolutePath(spec.targetDiskPath)
      if fileExists(attachedMediaPath) or dirExists(attachedMediaPath):
        raise newException(ValueError,
          "BootMediaSpec.targetDiskPath already exists: " & attachedMediaPath)
      let targetDir = parentDir(attachedMediaPath)
      if targetDir.len > 0:
        createDir(targetDir)
      let diskGB = if spec.diskGB > 0: spec.diskGB else: 8
      let createDisk = runProcessCapture(@[
        b.qemuImgCmd, "create", "-f", "qcow2",
        attachedMediaPath, $diskGB & "G"], timeoutSec = 120)
      if createDisk.exitCode != 0:
        raise newVmHarnessError($b.id, lpStartup,
          "LibvirtBackend.bootFromMedia: target disk creation failed (exit " &
          $createDisk.exitCode & "): " & createDisk.stdout)
      setFilePermissions(attachedMediaPath, {
        fpUserRead, fpUserWrite,
        fpGroupRead, fpGroupWrite,
        fpOthersRead, fpOthersWrite})

    var argv: seq[string] = @[
      b.virtInstallCmd,
      "--connect", b.libvirtUri,
      "--name", domainName,
      "--memory", $mem,
      "--vcpus", $cpus,
      "--cpu", "host-model",
      "--machine", "q35"]
    argv.add(transientBootNetworkArgs(spec))
    argv.add("--noautoconsole")
    argv.add(transientBootFirmwareArgs(spec, ovmf.loader, ovmf.nvram))
    argv.add(transientBootGraphicsArgs(spec))
    argv.add(transientBootCompatibilityArgs())
    argv.add(transientBootSerialArgs(serialLogPath))
    case spec.kind
    of bmkQcow2, bmkVhdx:
      argv.add("--import")
      argv.add("--disk")
      argv.add("path=" & attachedMediaPath & ",format=qcow2,bus=virtio")
    of bmkIso:
      # Empty boot disk; we boot off the CD.
      argv.add("--disk")
      if spec.targetDiskPath.len > 0:
        argv.add("path=" & attachedMediaPath & ",format=qcow2,bus=virtio")
      else:
        let diskGB = if spec.diskGB > 0: spec.diskGB else: 8
        argv.add("size=" & $diskGB & ",format=qcow2,bus=virtio")
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

    if spec.sshForwardPort > 0:
      let forward = b.runVirsh(@["qemu-monitor-command", domainName,
        "--hmp", transientBootHostForwardHmp(spec)], timeoutSec = 30)
      if forward.exitCode != 0:
        try:
          b.destroyDomain(domainName)
          b.undefineDomain(domainName)
          b.deleteDomainDisk(domainName)
        except CatchableError: discard
        raise newVmHarnessError($b.id, lpStartup,
          "LibvirtBackend.bootFromMedia: SSH port forward failed (exit " &
          $forward.exitCode & "): " & forward.stdout)

    var extra = initTable[string, string]()
    extra["mediaPath"] = spec.mediaPath
    if attachedMediaPath != spec.mediaPath:
      extra["transientDiskPath"] = attachedMediaPath
    if spec.targetDiskPath.len > 0:
      extra["targetDiskPath"] = attachedMediaPath
      extra["preserveBootDisk"] = "true"
    extra["serialLogPath"] = serialLogPath
    result = VmHandle(
      backend: b,
      name: domainName,
      baseline: "<boot-from-media>",
      ipAddress: (if spec.sshForwardPort > 0:
                    some("127.0.0.1")
                  else:
                    none(string)),
      sshPort: spec.sshForwardPort,
      sshUser: (if spec.sshForwardPort > 0: b.sshUser else: ""),
      sshAuth: (if spec.sshForwardPort > 0:
                  b.configuredSshAuth()
                else:
                  SshAuth(kind: saNone)),
      extra: extra)
  else:
    raise newException(BackendUnavailableError,
      "LibvirtBackend.bootFromMedia requires a Linux host")

method waitForShutdown*(b: LibvirtBackend, vm: VmHandle,
                        timeoutSec: int): bool =
  when defined(linux):
    let deadline = epochTime() + max(timeoutSec, 0).float
    while true:
      if b.domainState(vm.name) == "shut off":
        return true
      if epochTime() >= deadline:
        return false
      sleep(1000)
  else:
    raise newException(BackendUnavailableError,
      "LibvirtBackend.waitForShutdown requires a Linux host")

method captureSerial*(b: LibvirtBackend, vm: VmHandle): SerialStream =
  ## Poll the file-backed serial device created with the domain. QEMU writes
  ## it before this method returns, so early firmware failures remain visible.
  when defined(linux):
    let logPath = vm.extra.getOrDefault("serialLogPath")
    result = LibvirtSerialStream(
      vm: vm,
      logPath: logPath,
      buf: newSerialLineBuffer(),
      fileOffset: 0)
  else:
    raise newException(BackendUnavailableError,
      "LibvirtBackend.captureSerial requires a Linux host")

method captureScreenshot*(b: LibvirtBackend, vm: VmHandle,
                          outputPath: string) =
  ## ``virsh screenshot`` captures the primary QEMU graphical console. The
  ## output format follows the filename extension; use ``.png`` for visual
  ## assertion tools.
  when defined(linux):
    if outputPath.len == 0:
      raise newException(ValueError,
        "LibvirtBackend.captureScreenshot: output path is empty")
    let destination = absolutePath(outputPath)
    let outputDir = parentDir(destination)
    if outputDir.len > 0:
      createDir(outputDir)
    if fileExists(destination):
      removeFile(destination)
    let r = b.runVirsh(@[
      "screenshot", vm.name, destination, "--screen", "0"],
      timeoutSec = 60)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpExec,
        "virsh screenshot " & vm.name & " failed (exit " &
        $r.exitCode & "): " & r.stdout)
    if not fileExists(destination) or getFileSize(destination) <= 0:
      raise newVmHarnessError($b.id, lpExec,
        "virsh screenshot did not create a non-empty file: " & destination)
  else:
    raise newException(BackendUnavailableError,
      "LibvirtBackend.captureScreenshot requires a Linux host")

method expectLine*(b: LibvirtBackend, stream: SerialStream,
                   pattern: string, timeoutSec: int = 60): SerialMatch =
  when defined(linux):
    let s = LibvirtSerialStream(stream)
    result = expectLineImpl(s.buf, pattern, timeoutSec * 1000, 100,
      proc() = pumpSerialFile(s))
  else:
    raise newException(BackendUnavailableError,
      "LibvirtBackend.expectLine requires a Linux host")

method serialSend*(b: LibvirtBackend, stream: SerialStream, text: string) =
  when defined(linux):
    raise newException(BackendUnavailableError,
      "LibvirtBackend.serialSend is unavailable for file-backed capture")
  else:
    raise newException(BackendUnavailableError,
      "LibvirtBackend.serialSend requires a Linux host")

method closeSerial*(b: LibvirtBackend, stream: SerialStream) =
  when defined(linux):
    let s = LibvirtSerialStream(stream)
    if s != nil and s.buf != nil:
      s.buf.close()
  else:
    discard

# ---------------------------------------------------------------------------
# Backend registration. Importing this module is enough to make
# ``--backend libvirt`` and ``vm-harness probe`` see the backend.

registerBackend(biLibvirt,
  proc(): VmBackend = newLibvirtBackend())
