## TartBackend — vm-harness adapter for Tart on Apple Silicon Mac hosts.
## Per design doc §4.3.
##
## Supports both ``--guest macos`` and ``--guest linux-arm`` via the same
## ``tart`` binary; the chosen cirruslabs golden image is the only difference
## between the two registered backend instances (``biTartMacos``,
## ``biTartLinuxArm``).
##
## *Transport*: SSH over Tart's user-mode networking. ``tart ip --wait <s>
## <name>`` returns the auto-assigned IP. Authentication uses ``sshpass``
## with the cirruslabs golden's default ``admin/admin`` credential — the
## password is delivered to ``sshpass`` via a ``-f <fifo>`` so it never
## appears in the process argv (or, when ``--use-env`` is requested, via
## the ``SSHPASS`` environment variable / ``-e``).
##
## *File transfer*: ``scp`` over SSH, using the same ``sshpass``-mediated
## auth as ``execInGuest``. Chosen over ``tart run --dir`` for two reasons:
## (1) ``--dir`` mounts must be supplied at VM start time, so changing the
## set of mounts between gates requires restarting the VM, which the
## per-gate revert already does; (2) ``scp`` works identically for the
## macOS guest and the Linux-ARM guest so the backend has one code path.
##
## *Two-tier lifecycle* per the design contract:
##
## - *Session* (once per backend instance): ``tart pull <golden>`` (idempotent
##   — Tart's OCI cache is content-addressed, so re-pulling a present image
##   is effectively free). Stale ``repro-vm-*`` ephemerals from prior aborted
##   runs are also reaped at this step.
## - *Per-gate* (every revert): ``tart stop <eph> && tart delete <eph> &&
##   tart clone <golden> <eph> && tart run --no-graphics <eph> &`` followed
##   by ``tart ip --wait 60 <eph>`` and an SSH readiness poll. Target wall-
##   clock ≤30s per revert per the Per-Gate Reset Performance Contract.

import std/[os, osproc, options, streams, strtabs,
            strutils, tables, times]
import ../types
import ../auto

# ---------------------------------------------------------------------------
# Backend type.

type
  TartSharedDir = object
    tag: string
    hostPath: string
    guestPath: string
    readOnly: bool

  TartBackend* = ref object of VmBackend
    ## Adapter around the ``tart`` CLI.
    tartCmd*: string
      ## Path to the ``tart`` binary. Defaults to ``tart`` on PATH; can be
      ## set to ``/Users/me/.nix-profile/bin/tart`` for explicit pinning.
    sshpassCmd*: string
      ## Path to ``sshpass``. Defaults to ``sshpass`` on PATH.
    sshCmd*: string
      ## Path to ``ssh``. Defaults to ``ssh`` on PATH.
    scpCmd*: string
      ## Path to ``scp``. Defaults to ``scp`` on PATH.
    goldenImage*: string
      ## OCI reference of the cirruslabs golden image (set per registered
      ## instance — macOS or Linux-ARM).
    ephemeralPrefix*: string
      ## Prefix for ephemeral VM names. Default ``repro-vm-tart-macos`` or
      ## ``repro-vm-tart-linux``. The session-start cleanup hunts any VM
      ## whose name starts with this prefix.
    sshUser*: string
      ## Default ``admin`` (cirruslabs convention).
    sshPassword*: string
      ## Default ``admin`` (cirruslabs convention). Stored in the backend
      ## struct, NEVER passed via process argv.
    sshPort*: int
      ## Default ``22``.
    bootTimeoutSec*: int
      ## How long ``tart ip --wait`` polls for the auto-assigned IP.
      ## Default 90.
    sshReadyTimeoutSec*: int
      ## How long to retry the post-IP SSH-ready probe. Default 60.
    ephemeralPids*: Table[string, int]
      ## VM name → pid of the ``tart run --no-graphics`` background process.
      ## Stored so ``stopAndCleanup`` can issue an extra ``kill`` if the
      ## ``tart stop`` cmdlet leaves the run process hanging.
    sharedDirs*: seq[TartSharedDir]
      ## Host directories attached through Tart virtiofs and mounted inside
      ## the guest after SSH becomes ready.

const
  CirrusLabsMacosGolden* = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
    ## Default golden for ``biTartMacos``. Per the Tart research doc, the
    ## ``-base`` tier ships with Homebrew + ~15 dev tools pre-installed.
  CirrusLabsLinuxArmGolden* = "ghcr.io/cirruslabs/ubuntu:latest"
    ## Default golden for ``biTartLinuxArm``. Plain Ubuntu cloud image,
    ## ~3.5 GB compressed.
  DefaultCirrusLabsUser* = "admin"
  DefaultCirrusLabsPassword* = "admin"
  DefaultEphemeralPrefixMacos* = "repro-vm-tart-macos"
  DefaultEphemeralPrefixLinuxArm* = "repro-vm-tart-linux"

proc defaultSharedDirs(): seq[TartSharedDir] =
  let nixStore = getEnv("MCL_RUNNER_SHARED_NIX_STORE")
  if nixStore.len > 0 and dirExists(nixStore):
    result.add(TartSharedDir(
      tag: "mcl-nix-store",
      hostPath: nixStore,
      guestPath: "/nix/store",
      readOnly: true))
  let reproStore = getEnv("MCL_RUNNER_SHARED_REPRO_STORE")
  if reproStore.len > 0 and dirExists(reproStore):
    result.add(TartSharedDir(
      tag: "mcl-repro-store",
      hostPath: reproStore,
      guestPath: "/private/var/lib/reprobuild/shared-store",
      readOnly: false))

proc newTartBackend*(guestOs: GuestOs = goLinux,
                     goldenImage: string = "",
                     tartCmd: string = "tart",
                     sshpassCmd: string = "sshpass",
                     sshCmd: string = "ssh",
                     scpCmd: string = "scp",
                     sshUser: string = DefaultCirrusLabsUser,
                     sshPassword: string = DefaultCirrusLabsPassword,
                     sshPort: int = 22,
                     ephemeralPrefix: string = "",
                     bootTimeoutSec: int = 90,
                     sshReadyTimeoutSec: int = 60): TartBackend =
  ## Construct a TartBackend. ``guestOs`` selects which of the two
  ## registered IDs (``biTartMacos`` / ``biTartLinuxArm``) the resulting
  ## backend identifies as; the corresponding default golden image is
  ## picked when ``goldenImage`` is empty.
  let id = case guestOs
           of goMacos: biTartMacos
           of goLinux: biTartLinuxArm
           of goWindows:
             raise newException(BackendUnavailableError,
               "TartBackend does not support Windows guests on Mac hosts " &
               "(use UtmBackend / biUtmWindowsArm instead)")
  let golden = if goldenImage.len > 0:
                 goldenImage
               else:
                 case guestOs
                 of goMacos: CirrusLabsMacosGolden
                 of goLinux: CirrusLabsLinuxArmGolden
                 of goWindows: ""  ## unreachable, raised above
  let prefix = if ephemeralPrefix.len > 0:
                 ephemeralPrefix
               else:
                 case guestOs
                 of goMacos: DefaultEphemeralPrefixMacos
                 of goLinux: DefaultEphemeralPrefixLinuxArm
                 of goWindows: ""  ## unreachable
  let tartStateDir = getEnv("VM_HARNESS_TART_STATE_DIR")
  if tartStateDir.len > 0 and getEnv("TART_HOME").len == 0:
    createDir(tartStateDir)
    putEnv("TART_HOME", tartStateDir)
  result = TartBackend(
    id: id,
    hostPlatform: hpMacosArm,
    supportedGuests: {guestOs},
    tartCmd: tartCmd,
    sshpassCmd: sshpassCmd,
    sshCmd: sshCmd,
    scpCmd: scpCmd,
    goldenImage: golden,
    ephemeralPrefix: prefix,
    sshUser: sshUser,
    sshPassword: sshPassword,
    sshPort: sshPort,
    bootTimeoutSec: bootTimeoutSec,
    sshReadyTimeoutSec: sshReadyTimeoutSec,
    ephemeralPids: initTable[string, int](),
    sharedDirs: defaultSharedDirs())

# ---------------------------------------------------------------------------
# Process helper. Same shape as the helper used by hyperv.nim and wsl.nim
# (kept inline rather than promoted to process_helpers.nim because each
# backend has its own subtly different timeout / env handling).

proc runProcessCapture(cmd: seq[string], cwd: string = "",
                      timeoutSec: int = 0,
                      env: Table[string, string] = initTable[string, string](),
                      mergeStderr: bool = true): ExecResult =
  if cmd.len == 0:
    raise newException(ValueError, "runProcessCapture: empty cmd")
  let start = epochTime()
  var procEnv: StringTableRef = nil
  if env.len > 0:
    procEnv = newStringTable(modeStyleInsensitive)
    for k, v in env:
      procEnv[k] = v
  let opts = if mergeStderr:
               {poUsePath, poStdErrToStdOut}
             else:
               {poUsePath}
  var p = startProcess(cmd[0], workingDir = cwd, args = cmd[1 .. ^1],
                       env = procEnv, options = opts)
  defer: p.close()
  let outStream = p.outputStream
  let errStream = if mergeStderr: nil else: p.errorStream
  var stdout = ""
  var stderr = ""
  var deadline = if timeoutSec > 0: epochTime() + timeoutSec.float else: 0.0
  while true:
    var chunk = newString(4096)
    let n = outStream.readData(addr chunk[0], chunk.len)
    if n > 0:
      chunk.setLen(n)
      stdout.add(chunk)
    elif n == 0:
      if errStream != nil:
        var ec = newString(4096)
        let en = errStream.readData(addr ec[0], ec.len)
        if en > 0:
          ec.setLen(en)
          stderr.add(ec)
      if not p.running:
        # Drain any final stderr before exiting.
        if errStream != nil:
          var ec = newString(4096)
          let en = errStream.readData(addr ec[0], ec.len)
          if en > 0:
            ec.setLen(en)
            stderr.add(ec)
        break
      if timeoutSec > 0 and epochTime() > deadline:
        p.terminate()
        return ExecResult(
          exitCode: -1,
          stdout: stdout,
          stderr: stderr & "vm-harness: process timed out after " &
                  $timeoutSec & "s",
          elapsedMs: int((epochTime() - start) * 1000))
      sleep(50)
  let code = p.waitForExit(timeout = -1)
  ExecResult(
    exitCode: code,
    stdout: stdout,
    stderr: stderr,
    elapsedMs: int((epochTime() - start) * 1000))

# ---------------------------------------------------------------------------
# Tart CLI primitives.

proc listTartVms*(b: TartBackend): seq[string] =
  ## ``tart list`` and pull the ``Name`` column for ``local`` rows (the
  ## ``OCI`` rows are golden images, not VMs the backend should touch).
  ## Returns an empty seq on any failure — caller is responsible for
  ## checking ``probeAvailability`` separately.
  let r = runProcessCapture(@[b.tartCmd, "list"], timeoutSec = 30)
  if r.exitCode != 0:
    return @[]
  for line in r.stdout.splitLines():
    let stripped = line.strip()
    if stripped.len == 0 or stripped.startsWith("Source"):
      continue
    # Columns are whitespace-separated; we want "local <name> ..." rows.
    let parts = stripped.splitWhitespace()
    if parts.len < 2:
      continue
    if parts[0].toLowerAscii == "local":
      result.add(parts[1])

proc stopTartVm*(b: TartBackend, name: string) =
  ## ``tart stop <name>``. Never raises — a stopped VM returning non-zero
  ## here is harmless (we'll proceed to delete next).
  discard runProcessCapture(@[b.tartCmd, "stop", name], timeoutSec = 30)

proc deleteTartVm*(b: TartBackend, name: string) =
  ## ``tart delete <name>``. Returns silently on failure (the caller may be
  ## trying to delete a VM that's already gone).
  discard runProcessCapture(@[b.tartCmd, "delete", name], timeoutSec = 30)

proc cloneTartVm*(b: TartBackend, srcRef: string, ephemeral: string) =
  ## ``tart clone <src> <dst>`` followed by ``tart set --random-mac``.
  ## Tart clones inherit the source VM's MAC address.  Concurrent clones of
  ## one golden would therefore share a DHCP lease, causing ``tart ip`` to
  ## resolve both names to the same guest.  Every ephemeral needs a distinct
  ## MAC before it is started.
  let r = runProcessCapture(@[b.tartCmd, "clone", srcRef, ephemeral],
                            timeoutSec = 300)
  if r.exitCode != 0:
    raise newVmHarnessError($b.id, lpRevert,
      "tart clone failed: " & r.stdout & r.stderr)
  let randomMac = runProcessCapture(
    @[b.tartCmd, "set", ephemeral, "--random-mac"], timeoutSec = 30)
  if randomMac.exitCode != 0:
    b.deleteTartVm(ephemeral)
    raise newVmHarnessError($b.id, lpRevert,
      "tart set --random-mac failed: " &
      randomMac.stdout & randomMac.stderr)

proc pullTartImage*(b: TartBackend, imageRef: string) =
  ## ``tart pull <ref>``. Idempotent — Tart's OCI cache means re-pulling a
  ## present image is fast. Raises on failure so ``provisionBaseline``
  ## surfaces network problems.
  let r = runProcessCapture(@[b.tartCmd, "pull", imageRef], timeoutSec = 0)
  if r.exitCode != 0:
    raise newVmHarnessError($b.id, lpProvisioning,
      "tart pull " & imageRef & " failed: " & r.stdout & r.stderr)

proc runTartVmInBackground*(b: TartBackend, name: string): int =
  ## Spawn ``tart run --no-graphics <name>`` as a detached background
  ## process and return the child's PID. The caller (revertToBaseline)
  ## proceeds to ``tart ip --wait`` once the VM is on the wire. Note: the
  ## process is intentionally NOT reaped here — the VM lifecycle ends
  ## when ``stopAndCleanup`` issues ``tart stop`` (which causes the
  ## ``tart run`` process to exit cleanly on its own).
  var args = @["run", "--no-graphics"]
  for d in b.sharedDirs:
    var share = d.hostPath
    if d.readOnly:
      share.add(":ro")
    if d.tag.len > 0:
      share.add(if d.readOnly: ",tag=" else: ":tag=")
      share.add(d.tag)
    args.add("--dir")
    args.add(share)
  args.add(name)
  let p = startProcess(b.tartCmd,
                       args = args,
                       options = {poUsePath, poParentStreams, poDaemon})
  result = p.processID
  # Don't close(p): closing detaches our handle, but the process keeps
  # running. We can't waitForExit either — that would block until tart
  # stop. Just drop the handle; the OS keeps the child alive.
  # Nim's startProcess returns a ref that we let go of.

proc tartIpWait*(b: TartBackend, name: string,
                waitSec: int = 90): string =
  ## ``tart ip --wait <s> <name>`` — blocks until the VM has a DHCP lease.
  ## Returns the IP or raises ``GuestBootFailureError`` on timeout.
  let r = runProcessCapture(
    @[b.tartCmd, "ip", "--wait", $waitSec, name],
    timeoutSec = waitSec + 30)
  if r.exitCode != 0:
    var e = newVmHarnessError($b.id, lpStartup,
      "tart ip --wait " & $waitSec & " " & name & " failed: " &
      r.stdout & r.stderr)
    raise (ref GuestBootFailureError)(
      msg: e.msg, backend: e.backend, phase: e.phase, cause: e.cause)
  result = r.stdout.strip()
  if result.len == 0:
    raise (ref GuestBootFailureError)(
      msg: "tart ip returned empty for " & name,
      backend: $b.id, phase: lpStartup)

# ---------------------------------------------------------------------------
# SSH primitives. The password is delivered to sshpass via a temp-file FIFO
# so it never appears in the process argv. We use ``sshpass -f <path>``
# which reads the password from the first line of <path>.

proc writePasswordFile(password: string): string =
  ## Write the SSH password to a temp file (mode 0600). Returns the path.
  ## Caller is responsible for ``removeFile`` after use.
  let path = getTempDir() / "vm-harness-tart-pwd-" & $epochTime() & "-" &
             $getCurrentProcessId()
  writeFile(path, password)
  # Tighten permissions; sshpass refuses world-readable password files
  # when warned (this is also just-in-case hygiene).
  when defined(posix):
    discard execShellCmd("chmod 600 " & path)
  result = path

proc sshArgsBase(b: TartBackend, host: string): seq[string] =
  ## Common SSH flags: disable strict host key checking (ephemeral VMs
  ## have fresh keys every clone), point known_hosts at /dev/null so we
  ## don't pollute the user's file with churn, set a fast connect
  ## timeout.
  result = @[
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "GlobalKnownHostsFile=/dev/null",
    "-o", "PreferredAuthentications=password",
    "-o", "PubkeyAuthentication=no",
    "-o", "IdentitiesOnly=yes",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=10",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=4",
    "-p", $b.sshPort,
    b.sshUser & "@" & host]

proc sshpassPrefix(b: TartBackend, pwdFile: string): seq[string] =
  @[b.sshpassCmd, "-f", pwdFile]

proc waitForSshReady*(b: TartBackend, host: string,
                    timeoutSec: int = 60): bool =
  ## Poll ``ssh ... echo ready`` until exit-zero or timeout.
  let deadline = epochTime() + timeoutSec.float
  let pwdFile = writePasswordFile(b.sshPassword)
  defer:
    try: removeFile(pwdFile)
    except CatchableError: discard
  while epochTime() < deadline:
    let cmd = sshpassPrefix(b, pwdFile) & @[b.sshCmd] &
              sshArgsBase(b, host) & @["echo", "ready"]
    let r = runProcessCapture(cmd, timeoutSec = 15)
    if r.exitCode == 0 and "ready" in r.stdout:
      return true
    sleep(2000)
  false

proc scpCopy*(b: TartBackend, host: string, src: string, dest: string,
              toGuest: bool, recursive: bool = true,
              timeoutSec: int = 600)

proc mountMacosSharedDirs*(b: TartBackend, vm: VmHandle) =
  if b.sharedDirs.len == 0:
    return
  if vm.ipAddress.isNone:
    raise newVmHarnessError($b.id, lpStartup,
      "TartBackend: cannot mount shared directories without VM IP address")
  var lines: seq[string] = @[
    "exec >/tmp/vm-harness-mount-shares.log 2>&1",
    "set -x",
    "set -eu",
    "sleep 3",
    "if [ ! -e /nix ]; then",
    "  sudo -n mkdir -p /System/Volumes/Data/nix",
    "  if [ ! -f /etc/synthetic.conf ] || ! grep -q '^nix[[:space:]]' /etc/synthetic.conf; then",
    "    printf \"nix\\tSystem/Volumes/Data/nix\\n\" | sudo -n tee -a /etc/synthetic.conf >/dev/null",
    "  fi",
    "  sudo -n /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -t || true",
    "  if [ ! -e /nix ]; then",
    "    echo \"synthetic /nix was not materialized\" >&2",
    "    exit 1",
    "  fi",
    "fi"
  ]
  for d in b.sharedDirs:
    lines.add("sudo -n mkdir -p " & d.guestPath)
    lines.add("attempt=1")
    lines.add("while :; do")
    lines.add("  if mount | grep -F \" on " & d.guestPath & " \" >/dev/null 2>&1; then")
    lines.add("    break")
    lines.add("  fi")
    lines.add("  if sudo -n mount_virtiofs " & d.tag & " " & d.guestPath & " 2>&1; then")
    lines.add("    break")
    lines.add("  fi")
    lines.add("  if [ \"$attempt\" -ge 5 ]; then")
    lines.add("    echo \"mount_virtiofs failed for tag " & d.tag & " at " & d.guestPath & "\" >&2")
    lines.add("    exit 1")
    lines.add("  fi")
    lines.add("  attempt=$((attempt + 1))")
    lines.add("  sleep 1")
    lines.add("done")
    lines.add("test -d " & d.guestPath)
  let hostScript = getTempDir() / "vm-harness-tart-mount-shares-" &
                   $getCurrentProcessId() & ".sh"
  let guestScript = "/tmp/vm-harness-mount-shares.sh"
  writeFile(hostScript, lines.join("\n") & "\n")
  defer:
    try: removeFile(hostScript)
    except CatchableError: discard
  b.scpCopy(vm.ipAddress.get(), hostScript, guestScript,
            toGuest = true, recursive = false, timeoutSec = 60)
  let r = b.execInGuest(vm, initTable[string, string](),
                        @["/bin/sh", guestScript], timeoutSec = 120)
  if r.exitCode != 0:
    let hostLog = getTempDir() / "vm-harness-tart-mount-shares-" &
                  $getCurrentProcessId() & ".log"
    var mountLog = ""
    try:
      b.scpCopy(vm.ipAddress.get(), "/tmp/vm-harness-mount-shares.log",
                hostLog, toGuest = false, recursive = false, timeoutSec = 30)
      mountLog = readFile(hostLog)
      removeFile(hostLog)
    except CatchableError:
      discard
    raise newVmHarnessError($b.id, lpStartup,
      "TartBackend: mounting shared directories failed (exit " &
      $r.exitCode & "): " & r.stdout & r.stderr & mountLog)

# ---------------------------------------------------------------------------
# VmBackend method overrides.

method probeAvailability*(b: TartBackend): bool =
  ## Tart only runs on Apple Silicon Macs; on any other host this is
  ## trivially false. On a Mac we check that ``tart --version`` exits 0
  ## AND ``sshpass`` is on PATH (we need both for the full lifecycle).
  when defined(macosx):
    try:
      let rTart = runProcessCapture(@[b.tartCmd, "--version"], timeoutSec = 10)
      if rTart.exitCode != 0:
        return false
      let rSshpass = runProcessCapture(@[b.sshpassCmd, "-V"], timeoutSec = 10)
      # sshpass exits 0 with -V on most distros; some return 1 with version
      # printed to stderr. Accept either as long as some "sshpass" text is
      # present.
      return "ssh" in (rSshpass.stdout & rSshpass.stderr).toLowerAscii
    except CatchableError:
      return false
  else:
    return false

method provisionBaseline*(b: TartBackend, spec: BaselineSpec) =
  ## *Session* phase. Two responsibilities:
  ##
  ## 1. Pull the cirruslabs golden into the local OCI cache (idempotent).
  ##    ``BaselineSpec.sourceImage``, when non-empty, overrides the
  ##    backend's default ``goldenImage`` for the rest of the session.
  ## 2. Reap any stale ``repro-vm-tart-*`` ephemerals left over from
  ##    prior aborted runs. The same cleanup is invoked by
  ##    ``stopAndCleanup`` so the matched-pair contract holds, but doing
  ##    it again here protects against the case where a previous run was
  ##    SIGKILL'd before the ``finally`` block could fire.
  if spec.sourceImage.len > 0:
    b.goldenImage = spec.sourceImage
  if "ephemeralPrefix" in spec.backendOptions:
    b.ephemeralPrefix = spec.backendOptions["ephemeralPrefix"]
  if b.goldenImage.len == 0:
    raise newVmHarnessError($b.id, lpProvisioning,
      "TartBackend: no golden image configured (set BaselineSpec." &
      "sourceImage or pass goldenImage to newTartBackend)")
  # Reap stale ephemerals.
  for v in b.listTartVms():
    if v.startsWith(b.ephemeralPrefix):
      b.stopTartVm(v)
      b.deleteTartVm(v)
  # Pull the golden.
  b.pullTartImage(b.goldenImage)

method revertToBaseline*(b: TartBackend, baselineName: string): VmHandle =
  ## *Per-gate* phase. ``tart stop && tart delete && tart clone && tart
  ## run --no-graphics && tart ip --wait && SSH readiness poll``.
  ##
  ## The ephemeral name is ``<prefix>-<epoch-ms>-<pid>`` so concurrent
  ## sessions on the same host don't collide.
  let ephemeral = b.ephemeralPrefix & "-" & $int(epochTime() * 1000) &
                  "-" & $getCurrentProcessId()
  # Defensive: if a VM with this name somehow exists, nuke it first.
  let existing = b.listTartVms()
  if ephemeral in existing:
    b.stopTartVm(ephemeral)
    b.deleteTartVm(ephemeral)
  b.cloneTartVm(b.goldenImage, ephemeral)
  let pid = b.runTartVmInBackground(ephemeral)
  b.ephemeralPids[ephemeral] = pid
  let ip = b.tartIpWait(ephemeral, b.bootTimeoutSec)
  if not b.waitForSshReady(ip, b.sshReadyTimeoutSec):
    # SSH didn't come up; clean up before raising so callers don't have to.
    b.stopTartVm(ephemeral)
    b.deleteTartVm(ephemeral)
    b.ephemeralPids.del(ephemeral)
    raise (ref GuestBootFailureError)(
      msg: "TartBackend: SSH did not become ready on " & ip &
           " within " & $b.sshReadyTimeoutSec & "s",
      backend: $b.id, phase: lpStartup)
  var handle = VmHandle(
    backend: b,
    name: ephemeral,
    baseline: baselineName,
    ipAddress: some(ip),
    sshPort: b.sshPort,
    sshUser: b.sshUser,
    sshAuth: SshAuth(kind: saPassword, password: b.sshPassword),
    extra: {"tartRunPid": $pid, "goldenImage": b.goldenImage}.toTable)
  if b.id == biTartMacos:
    try:
      b.mountMacosSharedDirs(handle)
    except CatchableError:
      b.stopTartVm(ephemeral)
      b.deleteTartVm(ephemeral)
      b.ephemeralPids.del(ephemeral)
      raise
  result = handle

method execInGuest*(b: TartBackend, vm: VmHandle,
                   env: Table[string, string],
                   cmd: seq[string],
                   stdin: string = "",
                   timeoutSec: int = 600): ExecResult =
  if cmd.len == 0:
    raise newException(ValueError, "execInGuest: empty cmd")
  if vm.ipAddress.isNone:
    raise newVmHarnessError($b.id, lpExec,
      "TartBackend.execInGuest: VM has no IP address")
  let host = vm.ipAddress.get()
  # Build the remote command. We shell-quote each argv element (single-
  # quote wrap with embedded-single-quote escape) and prepend a
  # ``KEY='value' ...`` env prefix so the guest-side bash sees the right
  # environment.
  var envPrefix = ""
  for k, v in env:
    envPrefix.add(k)
    envPrefix.add("='")
    envPrefix.add(v.replace("'", "'\\''"))
    envPrefix.add("' ")
  var quoted = ""
  for i, a in cmd:
    if i > 0: quoted.add(' ')
    quoted.add('\'')
    quoted.add(a.replace("'", "'\\''"))
    quoted.add('\'')
  let line = envPrefix & quoted
  let pwdFile = writePasswordFile(b.sshPassword)
  defer:
    try: removeFile(pwdFile)
    except CatchableError: discard
  let sshCmd = sshpassPrefix(b, pwdFile) & @[b.sshCmd] &
               sshArgsBase(b, host) & @[line]
  # Note: SSH carries stdin from our process. We pass `stdin` through
  # via the started process's input stream. The current helper merges
  # stderr; SSH already does the right thing forwarding stderr from the
  # guest to its own stderr.
  if stdin.len == 0:
    return runProcessCapture(sshCmd, timeoutSec = timeoutSec)
  # Stdin path — same as runProcessCapture but writes `stdin` first.
  let start = epochTime()
  var p = startProcess(sshCmd[0], args = sshCmd[1 .. ^1],
                       options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  let inStream = p.inputStream
  inStream.write(stdin)
  inStream.close()
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
      if not p.running: break
      if timeoutSec > 0 and epochTime() > deadline:
        p.terminate()
        return ExecResult(exitCode: -1, stdout: stdout, stderr: "",
                          elapsedMs: int((epochTime() - start) * 1000))
      sleep(50)
  let code = p.waitForExit(timeout = -1)
  ExecResult(exitCode: code, stdout: stdout, stderr: "",
             elapsedMs: int((epochTime() - start) * 1000))

proc scpCopy*(b: TartBackend, host: string, src: string, dest: string,
              toGuest: bool, recursive: bool = true,
              timeoutSec: int = 600) =
  ## Internal helper used by both copyToGuest and copyFromGuest.
  let pwdFile = writePasswordFile(b.sshPassword)
  defer:
    try: removeFile(pwdFile)
    except CatchableError: discard
  var args = sshpassPrefix(b, pwdFile) & @[b.scpCmd,
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "GlobalKnownHostsFile=/dev/null",
    "-o", "PreferredAuthentications=password",
    "-o", "PubkeyAuthentication=no",
    "-o", "IdentitiesOnly=yes",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=10",
    "-P", $b.sshPort]
  if recursive:
    args.add("-r")
  if toGuest:
    args.add(src)
    args.add(b.sshUser & "@" & host & ":" & dest)
  else:
    args.add(b.sshUser & "@" & host & ":" & src)
    args.add(dest)
  let r = runProcessCapture(args, timeoutSec = timeoutSec)
  if r.exitCode != 0:
    raise newVmHarnessError($b.id, lpCopy,
      "scp " & (if toGuest: "to" else: "from") &
      " " & host & " failed (exit " & $r.exitCode & "): " &
      r.stdout & r.stderr)

method copyToGuest*(b: TartBackend, vm: VmHandle,
                   hostPath: string, guestPath: string) =
  if vm.ipAddress.isNone:
    raise newVmHarnessError($b.id, lpCopy,
      "TartBackend.copyToGuest: VM has no IP address")
  if not fileExists(hostPath) and not dirExists(hostPath):
    raise newVmHarnessError($b.id, lpCopy,
      "TartBackend.copyToGuest: source not found: " & hostPath)
  # Ensure the destination parent directory exists in the guest.
  let parent = parentDir(guestPath)
  if parent.len > 0 and parent != "/" and parent != ".":
    discard b.execInGuest(vm, initTable[string, string](),
                          @["mkdir", "-p", parent], timeoutSec = 30)
  b.scpCopy(vm.ipAddress.get(), hostPath, guestPath,
            toGuest = true, recursive = dirExists(hostPath))

method copyFromGuest*(b: TartBackend, vm: VmHandle,
                     guestPath: string, hostPath: string) =
  if vm.ipAddress.isNone:
    raise newVmHarnessError($b.id, lpCopy,
      "TartBackend.copyFromGuest: VM has no IP address")
  createDir(parentDir(hostPath))
  # Recursive is safe even for a single file; scp -r on a file Just Works.
  b.scpCopy(vm.ipAddress.get(), guestPath, hostPath,
            toGuest = false, recursive = true)

method installArgvTraceShim*(b: TartBackend, vm: VmHandle,
                            shim: ArgvTraceShim) =
  ## The shim contract: rename ``<binary>`` to ``<binary>.real`` (if not
  ## already done) and drop a wrapper that appends argv to
  ## ``shim.traceLogPath`` then exec's the real binary. The wrapper is
  ## the same template the M0 ``guest-scripts/posix.sh`` defines; we
  ## render it here and ``cat`` it into place inside the guest via SSH.
  ##
  ## Supports both Linux and macOS guests — both have POSIX sh and the
  ## same shim shape. The wrapper lives in ``/usr/local/bin/<name>`` so
  ## ``$PATH`` resolution prefers it over the original.
  let bin = shim.wrappedBinaryName
  let logPath = shim.traceLogPath
  let parentDirGuest = parentDir(logPath)
  let parentClause =
    if parentDirGuest.len > 0 and parentDirGuest != "/" and parentDirGuest != ".":
      "sudo mkdir -p \"" & parentDirGuest & "\" && "
    else: ""
  let escapedLog = logPath.replace("\"", "\\\"")
  let q = "\""
  # The shell snippet below is run as ``admin`` on the cirruslabs golden;
  # we use ``sudo`` for the privileged moves. Sudo is password-less on
  # the cirruslabs goldens.
  #
  # Build line-by-line with explicit ``"\n"`` separators rather than via
  # ``"""...""" & x & """..."""``. Nim's triple-quote literal strips the
  # newline that immediately follows the opening ``"""``; the
  # reopened-block pattern therefore swallows the first ``\n`` of every
  # subsequent block and fuses adjacent shell statements onto a single
  # line (rendered output was ``sudo touch "<log>"sudo chmod 0666 "<log>"
  # REAL_PATH=""``). Discovered while implementing M5's LimaBackend,
  # which uses the same line-by-line pattern (see ``lima.nim:
  # renderShimSnippet``).
  let shimBody = "#!/bin/sh\n" &
                 "printf '%s\\t%s\\n' \"$(date +%s%N 2>/dev/null || date +%s)\" \"$0 $*\" >> " &
                 q & escapedLog & q & "\n" &
                 "exec \"$BACKUP_PATH\" \"$@\"\n"
  let snippet = "set -eu\n" &
                parentClause & "sudo touch " & q & escapedLog & q & "\n" &
                "sudo chmod 0666 " & q & escapedLog & q & "\n" &
                "REAL_PATH=\"\"\n" &
                "if command -v " & bin & " >/dev/null 2>&1; then\n" &
                "  REAL_PATH=$(command -v " & bin & ")\n" &
                "fi\n" &
                "if [ -z \"$REAL_PATH\" ]; then\n" &
                "  echo \"installArgvTraceShim: binary not found: " & bin & "\" >&2\n" &
                "  exit 1\n" &
                "fi\n" &
                "BACKUP=\"${REAL_PATH}.real\"\n" &
                "if [ ! -e \"$BACKUP\" ]; then\n" &
                "  sudo mv \"$REAL_PATH\" \"$BACKUP\"\n" &
                "fi\n" &
                "SHIM_PATH=\"/usr/local/bin/" & bin & "\"\n" &
                "sudo mkdir -p /usr/local/bin\n" &
                "sudo tee \"$SHIM_PATH\" >/dev/null <<'SHIMEOF'\n" &
                shimBody &
                "SHIMEOF\n" &
                "sudo sed -i.bak \"s|\\$BACKUP_PATH|$BACKUP|g\" \"$SHIM_PATH\" || sudo sed -i \"\" \"s|\\$BACKUP_PATH|$BACKUP|g\" \"$SHIM_PATH\"\n" &
                "sudo rm -f \"${SHIM_PATH}.bak\"\n" &
                "sudo chmod +x \"$SHIM_PATH\"\n"
  let r = b.execInGuest(vm, initTable[string, string](),
                        @["/bin/sh", "-c", snippet], timeoutSec = 60)
  if r.exitCode != 0:
    raise newVmHarnessError($b.id, lpShim,
      "installArgvTraceShim failed for " & bin & ": exit " &
      $r.exitCode & "\n" & r.stdout)

method uninstallArgvTraceShim*(b: TartBackend, vm: VmHandle,
                              wrappedBinaryName: string) =
  ## Revert-to-baseline destroys the ephemeral VM entirely, so a
  ## per-binary uninstall is academic. We leave this as a no-op to match
  ## the WSL/Hyper-V backends.
  discard

method stopAndCleanup*(b: TartBackend, vm: VmHandle, deleteVm: bool = true) =
  ## ``tart stop <eph> && tart delete <eph>``. Never raises. Also wipes
  ## the pid bookkeeping so a re-cleanup is harmless. The cirruslabs
  ## ``tart run`` background process exits on its own when ``tart stop``
  ## fires; if it somehow doesn't, we issue a kill as a fallback.
  try:
    b.stopTartVm(vm.name)
    # Give tart a moment to release the disk lock; without this, very
    # fast back-to-back delete sometimes returns "VM still running".
    sleep(500)
    if deleteVm:
      b.deleteTartVm(vm.name)
    # Cleanup the background `tart run` process if it's still alive.
    if vm.name in b.ephemeralPids:
      let pid = b.ephemeralPids[vm.name]
      when defined(posix):
        # SIGTERM the process group; ignore errors.
        discard execShellCmd("kill " & $pid & " 2>/dev/null || true")
      b.ephemeralPids.del(vm.name)
  except CatchableError:
    discard

# ---------------------------------------------------------------------------
# M30: snapshot/restore. Tart has no incremental snapshot mechanism; the
# cross-backend convention is "snapshot = `tart clone`" and "restore = stop +
# delete + re-clone". Snapshot ids are derived as ``<vm>-snap-<name>`` so
# callers can list them by scanning ``tart list``. This mirrors the Rust
# ``ah-vm::backends::tart`` implementation byte-for-byte.

method snapshot*(b: TartBackend, vmName: string, snapshotName: string): string =
  let snapId = vmName & "-snap-" & snapshotName
  if snapId in b.listTartVms():
    raise newVmHarnessError($b.id, lpProvisioning,
      "tart snapshot '" & snapId & "' already exists")
  b.cloneTartVm(vmName, snapId)
  snapId

method restoreSnapshot*(b: TartBackend, vmName: string, snapshotName: string) =
  # Accept either the user-friendly snapshot name or the full snap id.
  let derived = vmName & "-snap-" & snapshotName
  let vms = b.listTartVms()
  let snapId =
    if snapshotName in vms: snapshotName
    elif derived in vms: derived
    else:
      raise newVmHarnessError($b.id, lpRevert,
        "tart snapshot '" & snapshotName & "' not found for VM '" & vmName & "'")
  b.stopTartVm(vmName)
  sleep(500)
  b.deleteTartVm(vmName)
  b.cloneTartVm(snapId, vmName)

method listSnapshots*(b: TartBackend, vmName: string): seq[string] =
  let prefix = vmName & "-snap-"
  for v in b.listTartVms():
    if v.startsWith(prefix):
      result.add(v[prefix.len .. ^1])

# ---------------------------------------------------------------------------
# Backend registration. Each registered factory captures its target
# guest OS so ``newBackend(biTartMacos)`` produces a macOS-configured
# instance and ``newBackend(biTartLinuxArm)`` produces the Linux one.

registerBackend(biTartMacos,
  proc(): VmBackend = newTartBackend(goMacos))
registerBackend(biTartLinuxArm,
  proc(): VmBackend = newTartBackend(goLinux))
