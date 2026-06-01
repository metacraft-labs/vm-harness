## UtmBackend — vm-harness adapter for UTM on Apple Silicon Mac hosts.
## Per design doc §4.4.
##
## Drives a UTM-managed Windows-on-ARM guest via the ``utmctl`` CLI
## (shipped inside ``/Applications/UTM.app/Contents/MacOS/utmctl`` and
## also installed onto the user's PATH via the UTM Homebrew cask). The
## backend assumes a *golden* UTM bundle named ``repro-windows-arm-base``
## (configurable) already exists on disk — built once via the
## ``guest-recipes/windows-arm-base/`` provisioning recipe, then cloned
## per-gate.
##
## *Transport*: SSH over UTM's user-mode networking. ``utmctl ip-address
## <name>`` returns the auto-assigned IP from the guest agent. Auth uses
## ``sshpass -f <pwd-file>`` so the autounattend-configured admin password
## never appears in process argv. Windows OpenSSH (built into Windows 11)
## is the guest-side daemon — the same in-guest ``windows.ps1`` runner
## that the Hyper-V backend uses works unchanged here because the only
## thing that swaps is the transport.
##
## *File transfer*: ``scp`` over SSH. UTM also supports virtio-9p/SMB
## shared folders, but those need bundle-time config and don't add value
## for the per-gate workflow.
##
## *Two-tier lifecycle* per the design contract (UTM target: ≤20s per
## revert — local-disk clone is faster than Tart's OCI-cache clone):
##
## - *Session* (``provisionBaseline``): verifies the golden bundle is
##   registered with UTM via ``utmctl status <golden>`` and reaps any
##   stale ``repro-vm-utm-windows-*`` ephemerals from prior aborted runs.
##   The actual *building* of the golden is the provisioning recipe's
##   job, not the backend's; backends consume already-baked images.
## - *Per-gate* (``revertToBaseline``): ``utmctl stop <eph> && utmctl
##   delete <eph> && utmctl clone <golden> --name <eph> && utmctl start
##   <eph>`` followed by ``utmctl ip-address`` polling and an SSH
##   readiness probe.

import std/[options, os, osproc, streams, strtabs,
            strutils, tables, times]
import ../types
import ../auto

# ---------------------------------------------------------------------------
# Backend type.

type
  UtmBackend* = ref object of VmBackend
    ## Adapter around the ``utmctl`` CLI.
    utmctlCmd*: string
      ## Path to the ``utmctl`` binary. Defaults to ``utmctl`` on PATH.
      ## On a normal UTM install the same binary also lives at
      ## ``/Applications/UTM.app/Contents/MacOS/utmctl``.
    sshpassCmd*: string
      ## Path to ``sshpass``. Defaults to ``sshpass`` on PATH.
    sshCmd*: string
      ## Path to ``ssh``. Defaults to ``ssh`` on PATH.
    scpCmd*: string
      ## Path to ``scp``. Defaults to ``scp`` on PATH.
    goldenBundleName*: string
      ## The name (or UUID) of the golden UTM bundle to clone per gate.
      ## Default ``repro-windows-arm-base`` matches the provisioning
      ## recipe under ``guest-recipes/windows-arm-base/``. ``utmctl``
      ## resolves either name or UUID interchangeably.
    ephemeralPrefix*: string
      ## Prefix for ephemeral VM names. Default
      ## ``repro-vm-utm-windows``. The session-start cleanup hunts any VM
      ## whose name starts with this prefix.
    sshUser*: string
      ## Default ``admin`` (matches the autounattend.xml ``Administrator``
      ## auto-logon override and the OpenSSH ``admin`` user the recipe
      ## creates).
    sshPassword*: string
      ## Default ``repro-windows-arm`` — matches the autounattend.xml in
      ## the windows-arm-base recipe. Override per-instance via
      ## ``newUtmBackend(sshPassword=...)`` when consuming a custom
      ## golden. Stored on the backend struct, NEVER passed via argv.
    sshPort*: int
      ## Default ``22``.
    bootTimeoutSec*: int
      ## How long to poll ``utmctl ip-address`` for a guest IP. Default
      ## 180 (Windows boot is slow even on Apple Silicon under hvf).
    sshReadyTimeoutSec*: int
      ## How long to retry the post-IP SSH-ready probe. Default 180
      ## (OpenSSH on Windows takes a while to come up after first boot).
    startTimeoutSec*: int
      ## Hard ceiling for the ``utmctl start`` invocation itself.
      ## Default 60.

const
  DefaultGoldenBundleName* = "repro-windows-arm-base"
    ## The bundle name the provisioning recipe writes. Override via
    ## ``newUtmBackend(goldenBundleName=...)`` when consuming a custom
    ## golden.
  DefaultEphemeralPrefix* = "repro-vm-utm-windows"
  DefaultAdminUser* = "admin"
  DefaultAdminPassword* = "repro-windows-arm"
    ## Matches the autounattend.xml shipped under
    ## ``guest-recipes/windows-arm-base/``. The password is *not* a
    ## secret — the guest is a disposable per-gate clone that only
    ## listens on UTM's NAT — but consumers shipping a non-default
    ## golden should override it.

proc newUtmBackend*(utmctlCmd: string = "utmctl",
                    sshpassCmd: string = "sshpass",
                    sshCmd: string = "ssh",
                    scpCmd: string = "scp",
                    goldenBundleName: string = DefaultGoldenBundleName,
                    ephemeralPrefix: string = DefaultEphemeralPrefix,
                    sshUser: string = DefaultAdminUser,
                    sshPassword: string = DefaultAdminPassword,
                    sshPort: int = 22,
                    bootTimeoutSec: int = 180,
                    sshReadyTimeoutSec: int = 180,
                    startTimeoutSec: int = 60): UtmBackend =
  ## Construct a UtmBackend. Defaults match the provisioning recipe under
  ## ``guest-recipes/windows-arm-base/``; override the golden name /
  ## credentials when consuming a custom bundle.
  result = UtmBackend(
    id: biUtmWindowsArm,
    hostPlatform: hpMacosArm,
    supportedGuests: {goWindows},
    utmctlCmd: utmctlCmd,
    sshpassCmd: sshpassCmd,
    sshCmd: sshCmd,
    scpCmd: scpCmd,
    goldenBundleName: goldenBundleName,
    ephemeralPrefix: ephemeralPrefix,
    sshUser: sshUser,
    sshPassword: sshPassword,
    sshPort: sshPort,
    bootTimeoutSec: bootTimeoutSec,
    sshReadyTimeoutSec: sshReadyTimeoutSec,
    startTimeoutSec: startTimeoutSec)

# ---------------------------------------------------------------------------
# Process helper. Same shape as the one used inline by tart.nim — kept
# inline here rather than promoted to process_helpers.nim because each
# backend's timeout/env handling differs subtly.

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
# UTM CLI primitives.

type
  UtmListEntry* = object
    ## One row from ``utmctl list`` (columns ``UUID Status Name``).
    uuid*: string
    status*: string
    name*: string

proc parseUtmListOutput*(raw: string): seq[UtmListEntry] =
  ## Pure parser for ``utmctl list``'s tabular output. ``utmctl`` prints
  ## a header (``UUID Status Name``) followed by zero-or-more rows; on
  ## hosts where the screen is locked or UTM emits ``Error from event``
  ## warnings, the warnings land on stderr (we merge stderr into stdout
  ## by default, but parsing remains tolerant — skip any line that
  ## doesn't have the expected three-column shape).
  for raw_line in raw.splitLines():
    let line = raw_line.strip()
    if line.len == 0: continue
    if line.startsWith("UUID"): continue
    # Skip well-known utmctl stderr warnings that get merged into stdout.
    if line.startsWith("Error from event"): continue
    if line.startsWith("NOTE:"): continue
    if line.startsWith("Warning:"): continue
    let parts = line.splitWhitespace()
    if parts.len < 3: continue
    # UUID is the canonical 36-char form; reject lines whose first token
    # isn't UUID-shaped so we don't misparse unrelated stderr lines.
    if parts[0].len != 36: continue
    if parts[0].count('-') != 4: continue
    result.add(UtmListEntry(
      uuid: parts[0],
      status: parts[1],
      name: parts[2 .. ^1].join(" ")))

proc listUtmVms*(b: UtmBackend): seq[UtmListEntry] =
  ## ``utmctl list`` parsed. Returns an empty seq on failure — caller
  ## handles ``probeAvailability`` separately.
  let r = runProcessCapture(@[b.utmctlCmd, "list"], timeoutSec = 30)
  if r.exitCode != 0:
    return @[]
  parseUtmListOutput(r.stdout)

proc statusUtmVm*(b: UtmBackend, ident: string): string =
  ## ``utmctl status <ident>``. Returns the trimmed status string
  ## (``stopped``, ``starting``, ``started``, …) or empty on failure.
  let r = runProcessCapture(@[b.utmctlCmd, "status", ident], timeoutSec = 30)
  if r.exitCode != 0:
    return ""
  result = r.stdout.strip()

proc stopUtmVm*(b: UtmBackend, ident: string) =
  ## ``utmctl stop <ident> --force``. Never raises — stop on an already-
  ## stopped VM returns non-zero, which is harmless here.
  discard runProcessCapture(@[b.utmctlCmd, "stop", "--force", ident],
                            timeoutSec = 60)

proc deleteUtmVm*(b: UtmBackend, ident: string) =
  ## ``utmctl delete <ident>``. Returns silently on failure (the caller
  ## may be trying to delete a VM that's already gone).
  discard runProcessCapture(@[b.utmctlCmd, "delete", ident], timeoutSec = 60)

proc cloneUtmVm*(b: UtmBackend, srcIdent: string, ephemeralName: string) =
  ## ``utmctl clone <src> --name <eph>``. Raises on failure since revert
  ## can't continue without the clone. UTM's clone is local-disk APFS
  ## copy-on-write — fast (≤few seconds) once the bundle is on disk.
  let r = runProcessCapture(
    @[b.utmctlCmd, "clone", srcIdent, "--name", ephemeralName],
    timeoutSec = 300)
  if r.exitCode != 0:
    raise newVmHarnessError($b.id, lpRevert,
      "utmctl clone " & srcIdent & " --name " & ephemeralName &
      " failed: " & r.stdout & r.stderr)

proc startUtmVm*(b: UtmBackend, ident: string) =
  ## ``utmctl start --hide <ident>``. We pass ``--hide`` to keep the UTM
  ## window from popping up on every per-gate revert (the harness is
  ## headless; the user sees only console output). Raises on failure.
  let r = runProcessCapture(
    @[b.utmctlCmd, "start", "--hide", ident],
    timeoutSec = b.startTimeoutSec)
  if r.exitCode != 0:
    raise newVmHarnessError($b.id, lpStartup,
      "utmctl start --hide " & ident & " failed (exit " & $r.exitCode &
      "): " & r.stdout & r.stderr)

proc parseIpAddressOutput*(raw: string): seq[string] =
  ## ``utmctl ip-address`` prints one IP per line (IPv4 first), with
  ## optional interface-name annotations. We accept the simple "one
  ## token per line" form and skip empties / well-known stderr warnings.
  for raw_line in raw.splitLines():
    let line = raw_line.strip()
    if line.len == 0: continue
    if line.startsWith("Error"): continue
    if line.startsWith("NOTE:"): continue
    if line.startsWith("Warning:"): continue
    # The first whitespace-separated token is the IP.
    let parts = line.splitWhitespace()
    if parts.len == 0: continue
    let candidate = parts[0]
    # Trivial sanity: an IPv4 address has three dots; an IPv6 has at
    # least one colon. Skip anything that doesn't look like either.
    if '.' in candidate or ':' in candidate:
      result.add(candidate)

proc utmIpAddress*(b: UtmBackend, ident: string): seq[string] =
  ## ``utmctl ip-address <ident>`` parsed. Returns the IPs the guest
  ## agent reports; empty if the agent hasn't reported yet.
  let r = runProcessCapture(
    @[b.utmctlCmd, "ip-address", ident], timeoutSec = 15)
  if r.exitCode != 0:
    return @[]
  parseIpAddressOutput(r.stdout)

proc isLikelyHostReachable(ip: string): bool =
  ## Heuristic: exclude link-local IPv6 (``fe80:``), loopback, and
  ## empty-string. Returns true for IPv4 addresses with three dots and
  ## any other IPv6 address. The UTM user-mode networking typically
  ## hands out an IPv4 in the ``192.168.64.0/24`` range.
  if ip.len == 0: return false
  if ip.startsWith("fe80"): return false
  if ip == "127.0.0.1" or ip == "::1": return false
  # IPv4 sanity: must contain three dots, not start with 0., and not be
  # the autoconfig 169.254.0.0/16 link-local range.
  if '.' in ip:
    if ip.startsWith("169.254."): return false
    if ip.startsWith("0."): return false
    return ip.count('.') == 3
  # IPv6 fallback.
  return ':' in ip

proc waitForUtmIp*(b: UtmBackend, ident: string,
                  timeoutSec: int): string =
  ## Poll ``utmctl ip-address`` until the guest reports a routable
  ## address or we time out. Returns the chosen IP or raises
  ## ``GuestBootFailureError``.
  let deadline = epochTime() + timeoutSec.float
  while epochTime() < deadline:
    let ips = b.utmIpAddress(ident)
    for ip in ips:
      if isLikelyHostReachable(ip):
        return ip
    sleep(2000)
  raise (ref GuestBootFailureError)(
    msg: "UtmBackend: guest " & ident & " did not report an IP within " &
         $timeoutSec & "s (is the UTM guest agent installed in the " &
         "golden bundle?)",
    backend: $biUtmWindowsArm, phase: lpStartup)

# ---------------------------------------------------------------------------
# SSH primitives. Mirrors TartBackend's sshpass-via-temp-file approach so
# the password never appears in argv. ``sshpass -f <path>`` reads the
# password from the first line of <path>.

proc writePasswordFile(password: string): string =
  ## Write the SSH password to a temp file (mode 0600). Returns the
  ## path. Caller is responsible for ``removeFile`` after use.
  let path = getTempDir() / "vm-harness-utm-pwd-" & $epochTime() & "-" &
             $getCurrentProcessId()
  writeFile(path, password)
  when defined(posix):
    discard execShellCmd("chmod 600 " & path)
  result = path

proc sshArgsBase(b: UtmBackend, host: string): seq[string] =
  ## Common SSH flags: disable strict host key checking (ephemeral VMs
  ## have fresh host keys every clone — a stale known_hosts entry would
  ## block reconnects), point known_hosts at /dev/null so we don't
  ## pollute the user's file with churn, set a fast connect timeout.
  result = @[
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "GlobalKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=15",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=4",
    "-p", $b.sshPort,
    b.sshUser & "@" & host]

proc sshpassPrefix(b: UtmBackend, pwdFile: string): seq[string] =
  @[b.sshpassCmd, "-f", pwdFile]

proc waitForSshReady*(b: UtmBackend, host: string,
                    timeoutSec: int): bool =
  ## Poll ``ssh ... cmd /c echo ready`` until exit-zero or timeout. We
  ## use ``cmd /c echo`` (not bare ``echo``) because the guest's default
  ## shell is PowerShell, and PowerShell-mode ``echo`` quirks (e.g. ``$``
  ## interpolation) don't matter here — but ``cmd /c echo`` is portable
  ## across both PowerShell and cmd.exe default-shell configurations.
  let deadline = epochTime() + timeoutSec.float
  let pwdFile = writePasswordFile(b.sshPassword)
  defer:
    try: removeFile(pwdFile)
    except CatchableError: discard
  while epochTime() < deadline:
    let cmd = sshpassPrefix(b, pwdFile) & @[b.sshCmd] &
              sshArgsBase(b, host) & @["cmd", "/c", "echo", "ready"]
    let r = runProcessCapture(cmd, timeoutSec = 20)
    if r.exitCode == 0 and "ready" in r.stdout:
      return true
    sleep(3000)
  false

# ---------------------------------------------------------------------------
# VmBackend method overrides.

method probeAvailability*(b: UtmBackend): bool =
  ## UTM only runs on Apple Silicon Macs (well, Macs in general — but
  ## ARM64 guests via UTM/QEMU+hvf need an Apple Silicon host). On other
  ## hosts this is trivially false. On a Mac we check that ``utmctl
  ## list`` exits 0 and ``sshpass`` is on PATH.
  ##
  ## Note: ``utmctl`` prints ``Error from event`` warnings to stderr when
  ## invoked from an SSH session or a locked-screen context, but the
  ## subcommand still returns exit-0 with the actual list on stdout —
  ## we tolerate the noise.
  when defined(macosx):
    try:
      let rUtm = runProcessCapture(@[b.utmctlCmd, "list"], timeoutSec = 15)
      if rUtm.exitCode != 0:
        return false
      let rSshpass = runProcessCapture(@[b.sshpassCmd, "-V"], timeoutSec = 10)
      return "ssh" in (rSshpass.stdout & rSshpass.stderr).toLowerAscii
    except CatchableError:
      return false
  else:
    return false

method provisionBaseline*(b: UtmBackend, spec: BaselineSpec) =
  ## *Session* phase. Two responsibilities:
  ##
  ## 1. Verify the golden UTM bundle is registered with UTM via
  ##    ``utmctl status``. The actual *build* of the golden is the
  ##    provisioning recipe's job; if the golden isn't present we raise
  ##    so the consumer can fall back to running the recipe.
  ## 2. Reap any stale ``repro-vm-utm-windows-*`` ephemerals left over
  ##    from prior aborted runs. Mirrors TartBackend's stale-reap.
  ##
  ## ``BaselineSpec.sourceImage``, when non-empty, overrides the
  ## backend's default ``goldenBundleName`` for the rest of the session.
  if spec.sourceImage.len > 0:
    b.goldenBundleName = spec.sourceImage
  if b.goldenBundleName.len == 0:
    raise newVmHarnessError($b.id, lpProvisioning,
      "UtmBackend: no golden bundle name configured (set BaselineSpec." &
      "sourceImage or pass goldenBundleName to newUtmBackend)")
  let status = b.statusUtmVm(b.goldenBundleName)
  if status.len == 0:
    raise newVmHarnessError($b.id, lpProvisioning,
      "UtmBackend: golden bundle '" & b.goldenBundleName & "' is not " &
      "registered with UTM. Build it once via the provisioning recipe " &
      "under vm-harness/guest-recipes/windows-arm-base/, then import " &
      "the resulting .utm bundle into UTM (double-click in Finder or " &
      "drag onto the UTM app).")
  # Reap stale ephemerals from prior runs.
  for v in b.listUtmVms():
    if v.name.startsWith(b.ephemeralPrefix):
      b.stopUtmVm(v.uuid)
      b.deleteUtmVm(v.uuid)

method revertToBaseline*(b: UtmBackend, baselineName: string): VmHandle =
  ## *Per-gate* phase. ``utmctl stop && utmctl delete && utmctl clone &&
  ## utmctl start && utmctl ip-address poll && SSH readiness poll``.
  ##
  ## The ephemeral name is ``<prefix>-<epoch-ms>-<pid>`` so concurrent
  ## sessions on the same host don't collide.
  let ephemeral = b.ephemeralPrefix & "-" & $int(epochTime() * 1000) &
                  "-" & $getCurrentProcessId()
  # Defensive: if an ephemeral with this exact name already exists
  # (shouldn't, given the timestamp+pid suffix), nuke it first.
  for v in b.listUtmVms():
    if v.name == ephemeral:
      b.stopUtmVm(v.uuid)
      b.deleteUtmVm(v.uuid)
  b.cloneUtmVm(b.goldenBundleName, ephemeral)
  b.startUtmVm(ephemeral)
  let ip = b.waitForUtmIp(ephemeral, b.bootTimeoutSec)
  if not b.waitForSshReady(ip, b.sshReadyTimeoutSec):
    # SSH didn't come up; clean up before raising so callers don't have
    # to handle this case explicitly.
    b.stopUtmVm(ephemeral)
    b.deleteUtmVm(ephemeral)
    raise (ref GuestBootFailureError)(
      msg: "UtmBackend: SSH did not become ready on " & ip &
           " within " & $b.sshReadyTimeoutSec & "s (is OpenSSH server " &
           "enabled in the golden bundle?)",
      backend: $b.id, phase: lpStartup)
  result = VmHandle(
    backend: b,
    name: ephemeral,
    baseline: baselineName,
    ipAddress: some(ip),
    sshPort: b.sshPort,
    sshUser: b.sshUser,
    sshAuth: SshAuth(kind: saPassword, password: b.sshPassword),
    extra: {"goldenBundle": b.goldenBundleName}.toTable)

method execInGuest*(b: UtmBackend, vm: VmHandle,
                   env: Table[string, string],
                   cmd: seq[string],
                   stdin: string = "",
                   timeoutSec: int = 600): ExecResult =
  if cmd.len == 0:
    raise newException(ValueError, "execInGuest: empty cmd")
  if vm.ipAddress.isNone:
    raise newVmHarnessError($b.id, lpExec,
      "UtmBackend.execInGuest: VM has no IP address")
  let host = vm.ipAddress.get()
  # The remote line: build a ``cmd.exe /c "set K=V & set K2=V2 & <cmd>"``
  # invocation. Windows ``cmd /c`` is the most portable shell across
  # default-shell variations (PowerShell vs cmd.exe), and ``set X=Y &
  # <next>`` is the standard cmd.exe env-prefix idiom. We single-quote
  # the whole inner thing on the SSH command line to avoid Bourne-shell
  # interpretation host-side, then let ``cmd /c`` parse it guest-side.
  var inner = ""
  for k, v in env:
    # cmd.exe ``set`` quoting: the value runs to the next ``&`` token, so
    # we escape embedded ``&`` characters by quoting the whole value.
    inner.add("set \"")
    inner.add(k)
    inner.add('=')
    inner.add(v.replace("\"", "\"\""))
    inner.add("\" & ")
  for i, a in cmd:
    if i > 0: inner.add(' ')
    # Windows quoting differs from POSIX. The simplest portable form:
    # wrap each argv element in double-quotes, escape internal
    # double-quotes by doubling.
    if a.len == 0:
      inner.add("\"\"")
    elif " " in a or "\t" in a or "\"" in a:
      inner.add('"')
      inner.add(a.replace("\"", "\"\""))
      inner.add('"')
    else:
      inner.add(a)
  # The outer single-quoting: SSH invokes the remote command via the
  # user's login shell. For Windows OpenSSH the default is ``cmd.exe``
  # (configurable via the ``DefaultShell`` registry key); we send the
  # ``cmd /c "..."`` line directly so the result is the same regardless
  # of the configured default shell.
  # The host-side single-quote wraps the whole remote command so the
  # host's bash doesn't interpret the inner quotes / ``&`` tokens.
  let remoteCmd = "cmd /c \"" & inner.replace("\"", "\"") & "\""
  # We just escape single quotes by closing-quoting-reopening:
  let hostQuoted = "'" & remoteCmd.replace("'", "'\\''") & "'"
  let pwdFile = writePasswordFile(b.sshPassword)
  defer:
    try: removeFile(pwdFile)
    except CatchableError: discard
  # Build via a single shell invocation so we get host-side quoting:
  # sshpass -f F ssh ... 'cmd /c "..."'
  let sshLine = b.sshpassCmd & " -f " & pwdFile & " " & b.sshCmd & " " &
                sshArgsBase(b, host).join(" ") & " " & hostQuoted
  let shellCmd = @["/bin/sh", "-c", sshLine]
  if stdin.len == 0:
    return runProcessCapture(shellCmd, timeoutSec = timeoutSec)
  # Stdin path — mirror the runProcessCapture body but feed stdin.
  let start = epochTime()
  var p = startProcess(shellCmd[0], args = shellCmd[1 .. ^1],
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

proc scpCopy*(b: UtmBackend, host: string, src: string, dest: string,
              toGuest: bool, recursive: bool = true,
              timeoutSec: int = 600) =
  ## Internal helper used by both copyToGuest and copyFromGuest. Mirrors
  ## the TartBackend implementation; Windows OpenSSH ships ``scp`` so
  ## the call shape is identical.
  let pwdFile = writePasswordFile(b.sshPassword)
  defer:
    try: removeFile(pwdFile)
    except CatchableError: discard
  var args = sshpassPrefix(b, pwdFile) & @[b.scpCmd,
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "GlobalKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=15",
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

method copyToGuest*(b: UtmBackend, vm: VmHandle,
                   hostPath: string, guestPath: string) =
  if vm.ipAddress.isNone:
    raise newVmHarnessError($b.id, lpCopy,
      "UtmBackend.copyToGuest: VM has no IP address")
  if not fileExists(hostPath) and not dirExists(hostPath):
    raise newVmHarnessError($b.id, lpCopy,
      "UtmBackend.copyToGuest: source not found: " & hostPath)
  # We don't pre-create the parent directory: Windows OpenSSH's ``scp``
  # requires the parent to exist, but ``mkdir -p`` doesn't translate
  # cleanly to Windows ``cmd``. Consumers that need nested directories
  # should ``execInGuest`` a ``cmd /c mkdir <path>`` first. The common
  # case (copy into ``C:\Users\admin\...``) Just Works because the user
  # profile already exists.
  b.scpCopy(vm.ipAddress.get(), hostPath, guestPath,
            toGuest = true, recursive = dirExists(hostPath))

method copyFromGuest*(b: UtmBackend, vm: VmHandle,
                     guestPath: string, hostPath: string) =
  if vm.ipAddress.isNone:
    raise newVmHarnessError($b.id, lpCopy,
      "UtmBackend.copyFromGuest: VM has no IP address")
  createDir(parentDir(hostPath))
  b.scpCopy(vm.ipAddress.get(), guestPath, hostPath,
            toGuest = false, recursive = true)

method installArgvTraceShim*(b: UtmBackend, vm: VmHandle,
                            shim: ArgvTraceShim) =
  ## Replace ``C:\Windows\System32\<wrappedBinaryName>.exe`` with a
  ## ``.bat`` wrapper that appends ``date time argv...`` to
  ## ``shim.traceLogPath`` then re-exec's the original (renamed to
  ## ``<name>.real.exe``). Mirrors the HyperVBackend shim; the only
  ## thing that differs is the transport (SSH via sshpass vs Invoke-
  ## Command via PSDirect).
  let bin = shim.wrappedBinaryName
  let log = shim.traceLogPath
  # Build a PowerShell block (delivered via ``cmd /c powershell -Command``)
  # that does the move-then-write atomically.
  let psBlock = """$ErrorActionPreference = 'Stop'
$real = 'C:\Windows\System32\""" & bin & """.real.exe'
$orig = 'C:\Windows\System32\""" & bin & """.exe'
if (-not (Test-Path $real)) { Move-Item -Path $orig -Destination $real -Force }
$wrapper = "@echo off`r`necho %DATE% %TIME% %*  >> `"""" & log & """`"`r`n`"%~dp0""" & bin & """.real.exe`" %*"
$wrapper | Set-Content -Path 'C:\Windows\System32\""" & bin & """.bat' -Encoding ascii
"""
  # Encode the PS block to base64 to avoid quoting nightmares through
  # cmd /c. PowerShell's -EncodedCommand expects UTF-16LE base64.
  var utf16: string = ""
  for ch in psBlock:
    utf16.add(ch)
    utf16.add('\0')
  # Naive base64 (avoids std/base64 import for one-place use).
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  var enc = ""
  var i = 0
  while i < utf16.len:
    var b0 = utf16[i].uint32
    var b1: uint32 = 0
    var b2: uint32 = 0
    var pad = 0
    if i + 1 < utf16.len: b1 = utf16[i + 1].uint32 else: pad += 1
    if i + 2 < utf16.len: b2 = utf16[i + 2].uint32 else: pad += 1
    let n = (b0 shl 16) or (b1 shl 8) or b2
    enc.add(alphabet[((n shr 18) and 0x3F).int])
    enc.add(alphabet[((n shr 12) and 0x3F).int])
    if pad <= 1: enc.add(alphabet[((n shr 6) and 0x3F).int]) else: enc.add('=')
    if pad == 0: enc.add(alphabet[(n and 0x3F).int]) else: enc.add('=')
    i += 3
  let r = b.execInGuest(vm, initTable[string, string](),
    @["powershell", "-NoLogo", "-NoProfile", "-EncodedCommand", enc],
    timeoutSec = 60)
  if r.exitCode != 0:
    raise newVmHarnessError($b.id, lpShim,
      "installArgvTraceShim failed for " & bin & ": exit " &
      $r.exitCode & "\n" & r.stdout)

method uninstallArgvTraceShim*(b: UtmBackend, vm: VmHandle,
                              wrappedBinaryName: string) =
  ## Revert-to-baseline destroys the ephemeral VM entirely, so a
  ## per-binary uninstall is academic. We leave this as a no-op to
  ## match the Tart and Hyper-V backends.
  discard

method stopAndCleanup*(b: UtmBackend, vm: VmHandle, deleteVm: bool = true) =
  ## ``utmctl stop --force <eph> && utmctl delete <eph>``. Never raises.
  try:
    b.stopUtmVm(vm.name)
    # Give UTM a moment to release the disk before delete.
    sleep(500)
    if deleteVm:
      b.deleteUtmVm(vm.name)
  except CatchableError:
    discard

# ---------------------------------------------------------------------------
# M30: snapshot/restore via ``utmctl clone``. UTM has no incremental snapshot
# mechanism either; we mirror the Tart pattern so consumers see uniform
# semantics across the Mac-host backends. The Rust port in
# ``ah-vm::backends::utm`` uses the same naming convention.

method snapshot*(b: UtmBackend, vmName: string, snapshotName: string): string =
  let snapId = vmName & "-snap-" & snapshotName
  for v in b.listUtmVms():
    if v.name == snapId:
      raise newVmHarnessError($b.id, lpProvisioning,
        "utm snapshot '" & snapId & "' already exists")
  b.cloneUtmVm(vmName, snapId)
  snapId

method restoreSnapshot*(b: UtmBackend, vmName: string, snapshotName: string) =
  let derived = vmName & "-snap-" & snapshotName
  let entries = b.listUtmVms()
  var snapId = ""
  for v in entries:
    if v.name == snapshotName:
      snapId = snapshotName
      break
    elif v.name == derived:
      snapId = derived
      break
  if snapId.len == 0:
    raise newVmHarnessError($b.id, lpRevert,
      "utm snapshot '" & snapshotName & "' not found for VM '" & vmName & "'")
  b.stopUtmVm(vmName)
  sleep(500)
  b.deleteUtmVm(vmName)
  b.cloneUtmVm(snapId, vmName)

method listSnapshots*(b: UtmBackend, vmName: string): seq[string] =
  let prefix = vmName & "-snap-"
  for v in b.listUtmVms():
    if v.name.startsWith(prefix):
      result.add(v.name[prefix.len .. ^1])

# ---------------------------------------------------------------------------
# Backend registration. One factory — the UTM backend always targets
# Windows-ARM guests on Mac hosts; there's no dual-guest pattern like
# Tart's (where one binary can host both macOS and Linux ARM).

registerBackend(biUtmWindowsArm,
  proc(): VmBackend = newUtmBackend())
