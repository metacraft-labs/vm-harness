## LimaBackend — vm-harness adapter for Lima on macOS hosts.
## Per design doc §4 (backend trait + lifecycle) and M5 of the
## ``Multi-OS-VM-Automation-Campaign``. Targets Linux guests on Mac
## hosts as an *alternative* to the Tart backend; auto-selection still
## picks Tart for (macOS-arm, Linux) — Lima is opt-in via
## ``--backend lima``.
##
## *Transport*: ``limactl shell <instance> -- <cmd>``. Lima already
## handles SSH connection multiplexing internally via a ControlPath
## socket under ``~/.lima/<instance>/ssh.sock`` and keys at
## ``~/.lima/_config/user``. Going through ``limactl`` (instead of
## raw ``ssh``) is simpler, keeps auth opaque, and matches how every
## other Lima consumer drives the guest.
##
## *File transfer*: ``limactl copy <src> <dst>`` (instance-prefixed
## paths, e.g. ``my-vm:/tmp/foo``). Lima's ``copy`` picks rsync when
## available and falls back to scp.
##
## *Two-tier lifecycle* per the design contract:
##
## - *Session* (``provisionBaseline``): pre-fetch the chosen Ubuntu
##   template's base image so the first per-gate ``limactl create`` /
##   ``start`` doesn't bear the download cost, and reap any stale
##   ``repro-vm-lima-*`` instances left over from prior aborted runs.
## - *Per-gate* (``revertToBaseline``): ``limactl stop --force`` (no-op
##   if no instance exists) ``&& limactl delete --force && limactl
##   create --tty=false <template> && limactl start --tty=false
##   <instance>``. No native snapshot — full lifecycle every revert.
##   Target wall-clock ≤30s per the Per-Gate Reset Performance
##   Contract.
##
## *Provisioning*: Lima's built-in cloud-init handles first-boot SSH
## key + user setup. The backend embeds a minimal YAML template inline
## (see ``DefaultLimaTemplate`` below) so consumers don't need to
## supply one; pass ``BaselineSpec.sourceImage`` (or
## ``newLimaBackend(templateText=...)``) to override.

import std/[options, os, osproc, strtabs,
            strutils, tables, times]
import ../types
import ../auto

# ---------------------------------------------------------------------------
# Backend type.

type
  LimaBackend* = ref object of VmBackend
    ## Adapter around the ``limactl`` CLI.
    limactlCmd*: string
      ## Path to the ``limactl`` binary. Defaults to ``limactl`` on
      ## PATH (Homebrew puts it at ``/opt/homebrew/bin/limactl``; Nix
      ## profiles at ``~/.nix-profile/bin/limactl``).
    ephemeralPrefix*: string
      ## Prefix for ephemeral instance names. Default
      ## ``repro-vm-lima``. The session-start cleanup hunts any
      ## instance whose name starts with this prefix.
    templateText*: string
      ## YAML template body used by ``limactl create``. Defaults to
      ## :const:`DefaultLimaTemplate`. Per-gate ``revertToBaseline``
      ## writes this to a temp file and passes that path to
      ## ``limactl create``. Override via
      ## ``newLimaBackend(templateText=...)`` or
      ## ``BaselineSpec.sourceImage`` (which is treated as a path or
      ## ``template://...`` reference depending on whether it begins
      ## with ``template:`` / ``file://`` / ``http``).
    bootTimeoutSec*: int
      ## How long ``limactl start --timeout`` waits for the instance
      ## to be running. Default 180 (Lima boots cloud-init from cold
      ## first time, fast on warm cache).
    cpus*: int
      ## Override CPUs passed to ``limactl create --cpus``. ``0`` =
      ## defer to the template's default.
    memoryGiB*: int
      ## Override memory passed to ``limactl create --memory``. ``0`` =
      ## template default. Lima's ``--memory`` is in GiB.
    diskGiB*: int
      ## Override disk passed to ``limactl create --disk``. ``0`` =
      ## template default.

const
  DefaultLimaEphemeralPrefix* = "repro-vm-lima"
  DefaultLimaBootTimeoutSec* = 180

  DefaultLimaTemplate* = """# Embedded by vm_harness/backends/lima.nim.
# Minimal Lima template: Ubuntu LTS via Lima's bundled image set,
# vmType=vz (Apple Virtualization framework on macOS 13+ — falls back
# to qemu automatically on older hosts), no host mounts so per-gate
# revert is fast and the guest stays isolated from the host home.
minimumLimaVersion: 2.0.0

base:
- template:_images/ubuntu-lts
- template:_default/mounts

# Disable all mounts; vm-harness uses limactl copy for explicit
# host<->guest file transfer per gate.
mounts: []

# Headless: no display, no audio, no port-forward beyond SSH.
video:
  display: "none"
audio:
  device: ""

# Containerd is heavy and not needed for reprobuild gates; turn it
# off so the guest boots faster.
containerd:
  system: false
  user: false
"""

proc newLimaBackend*(limactlCmd: string = "limactl",
                     ephemeralPrefix: string = DefaultLimaEphemeralPrefix,
                     templateText: string = "",
                     bootTimeoutSec: int = DefaultLimaBootTimeoutSec,
                     cpus: int = 0,
                     memoryGiB: int = 0,
                     diskGiB: int = 0): LimaBackend =
  ## Construct a LimaBackend. ``templateText`` defaults to the
  ## embedded :const:`DefaultLimaTemplate`; pass a non-empty string
  ## to override (or set ``BaselineSpec.sourceImage`` per call).
  result = LimaBackend(
    id: biLima,
    hostPlatform: hpMacosArm,
    supportedGuests: {goLinux},
    limactlCmd: limactlCmd,
    ephemeralPrefix: ephemeralPrefix,
    templateText: if templateText.len > 0: templateText
                  else: DefaultLimaTemplate,
    bootTimeoutSec: bootTimeoutSec,
    cpus: cpus,
    memoryGiB: memoryGiB,
    diskGiB: diskGiB)

# ---------------------------------------------------------------------------
# Process helper.
#
# Lima needs special care: ``limactl start`` daemonizes a ``limactl
# hostagent`` process that inherits the parent's stdout/stderr file
# descriptors. If we hand the child a pipe, the hostagent keeps the
# write end alive for the entire instance lifetime, and any blocking
# read on the parent's read end hangs indefinitely — even after
# ``limactl start`` itself has exited.
#
# To avoid this trap we redirect stdout/stderr to a *temp file*
# (opened with O_WRONLY|O_CREAT|O_TRUNC), pass the file's FD to the
# child as both stdout (1) and stderr (2), and then read the file
# back after the child exits. The daemonized hostagent inherits the
# file FD instead of a pipe — no read-end blocking — and the file is
# unlinked once the parent has slurped its contents.
#
# This pattern is borrowed verbatim from the shell idiom
# ``cmd >/tmp/out 2>&1`` and yields identical capture semantics to
# the pipe-based helper used by tart.nim / utm.nim while side-
# stepping their FD-inheritance hazard.

proc runLimactl(cmd: seq[string], cwd: string = "",
                timeoutSec: int = 0,
                env: Table[string, string] = initTable[string, string](),
                stdinData: string = ""): ExecResult =
  if cmd.len == 0:
    raise newException(ValueError, "runLimactl: empty cmd")
  let start = epochTime()
  # Generate a temp file path for captured output.
  let outPath = getTempDir() / "vm-harness-lima-out-" &
                $int(epochTime() * 1000000) & "-" &
                $getCurrentProcessId() & ".log"
  defer:
    try: removeFile(outPath)
    except CatchableError: discard
  # Build a shell wrapper that redirects stdout+stderr to outPath.
  # We use ``/bin/sh -c '<argv as one quoted line>'`` so the daemonized
  # hostagent inherits the file FD rather than our parent pipes.
  var quoted = ""
  for i, a in cmd:
    if i > 0: quoted.add(' ')
    quoted.add('\'')
    quoted.add(a.replace("'", "'\\''"))
    quoted.add('\'')
  # Escape the outPath the same way; paths from getTempDir() are
  # whitespace-free in practice but defensive quoting doesn't hurt.
  let outQuoted = "'" & outPath.replace("'", "'\\''") & "'"
  # When the caller has stdin data, materialize it to a temp file and
  # redirect from there — this keeps the same "no live FDs the daemon
  # could inherit" property as the stdout temp-file pattern. When
  # there's no stdin, redirect from /dev/null so the daemon doesn't
  # inherit our pipe stdin either.
  var stdinFile = ""
  var redirectIn = " </dev/null"
  if stdinData.len > 0:
    stdinFile = getTempDir() / "vm-harness-lima-in-" &
                $int(epochTime() * 1000000) & "-" &
                $getCurrentProcessId() & ".log"
    writeFile(stdinFile, stdinData)
    redirectIn = " <'" & stdinFile.replace("'", "'\\''") & "'"
  defer:
    if stdinFile.len > 0:
      try: removeFile(stdinFile)
      except CatchableError: discard
  let shellLine = quoted & redirectIn & " >" & outQuoted & " 2>&1"
  var procEnv: StringTableRef = nil
  if env.len > 0:
    procEnv = newStringTable(modeStyleInsensitive)
    for k, v in env:
      procEnv[k] = v
  var p = startProcess("/bin/sh", workingDir = cwd,
                       args = @["-c", shellLine],
                       env = procEnv, options = {poUsePath})
  defer: p.close()
  let deadline = if timeoutSec > 0: epochTime() + timeoutSec.float else: 0.0
  while p.running:
    if timeoutSec > 0 and epochTime() > deadline:
      p.terminate()
      let partialOut =
        try: readFile(outPath)
        except CatchableError: ""
      return ExecResult(
        exitCode: -1,
        stdout: partialOut,
        stderr: "vm-harness: process timed out after " & $timeoutSec & "s",
        elapsedMs: int((epochTime() - start) * 1000))
    sleep(50)
  let code = p.waitForExit(timeout = -1)
  let captured =
    try: readFile(outPath)
    except CatchableError: ""
  ExecResult(
    exitCode: code,
    stdout: captured,
    stderr: "",
    elapsedMs: int((epochTime() - start) * 1000))

# ---------------------------------------------------------------------------
# limactl CLI primitives.

proc listLimaInstances*(b: LimaBackend): seq[string] =
  ## ``limactl ls --quiet`` returns one instance name per line. Returns
  ## an empty seq on any failure — caller is responsible for checking
  ## ``probeAvailability`` separately.
  ##
  ## Note: Lima writes its structured log output (``time="..." level=
  ## ...`` lines) to stderr. ``runLimactl`` merges stderr into stdout
  ## via ``2>&1``, so we filter out those log lines before treating
  ## anything as an instance name. The "no instance found" warning
  ## that Lima emits when the registry is empty is the canonical
  ## example.
  let r = runLimactl(@[b.limactlCmd, "ls", "--quiet"],
                     timeoutSec = 30)
  if r.exitCode != 0:
    return @[]
  for line in r.stdout.splitLines():
    let stripped = line.strip()
    if stripped.len == 0:
      continue
    if stripped.startsWith("time=\"") or
       stripped.startsWith("time=") or
       stripped.startsWith("{\"") or  # JSON log format
       "level=" in stripped[0 .. min(50, stripped.len - 1)]:
      continue
    result.add(stripped)

proc instanceStatus*(b: LimaBackend, name: string): string =
  ## Return the ``status`` field of the named instance, or empty when
  ## the instance does not exist. Statuses Lima emits include
  ## ``Running``, ``Stopped``, ``Broken``.
  ##
  ## Same stderr-merging caveat as ``listLimaInstances``: skip Lima's
  ## structured log lines and return the first non-log line.
  let r = runLimactl(
    @[b.limactlCmd, "ls", "--format", "{{.Status}}", name],
    timeoutSec = 15)
  if r.exitCode != 0:
    return ""
  for line in r.stdout.splitLines():
    let stripped = line.strip()
    if stripped.len == 0:
      continue
    if stripped.startsWith("time=") or "level=" in stripped[0 .. min(50, stripped.len - 1)]:
      continue
    return stripped
  return ""

proc stopLimaInstance*(b: LimaBackend, name: string) =
  ## ``limactl stop --force <name>``. Never raises — a stopped
  ## instance returning non-zero here is harmless (we'll proceed to
  ## delete next).
  discard runLimactl(
    @[b.limactlCmd, "stop", "--force", name],
    timeoutSec = 60)

proc deleteLimaInstance*(b: LimaBackend, name: string) =
  ## ``limactl delete --force <name>``. Returns silently on failure
  ## (the caller may be trying to delete an instance that's already
  ## gone).
  discard runLimactl(
    @[b.limactlCmd, "delete", "--force", name],
    timeoutSec = 60)

proc writeTemplateFile(b: LimaBackend, sourceImage: string): string =
  ## Materialize the YAML template to a temp file. Returns the
  ## absolute path; caller is responsible for ``removeFile``.
  ##
  ## If ``sourceImage`` is non-empty it overrides ``templateText``:
  ##
  ## - ``template:foo`` → write a thin wrapper that bases off it.
  ## - any other value is treated as a path or URL accepted directly
  ##   by ``limactl create``; in that case we return the value
  ##   verbatim and signal "no temp file" via an empty result.
  if sourceImage.len > 0:
    if sourceImage.startsWith("template:") or
       sourceImage.startsWith("file://") or
       sourceImage.startsWith("http://") or
       sourceImage.startsWith("https://") or
       fileExists(sourceImage):
      # Pass-through: limactl create accepts these directly.
      return sourceImage
  let path = getTempDir() / "vm-harness-lima-tmpl-" &
             $int(epochTime() * 1000) & "-" &
             $getCurrentProcessId() & ".yaml"
  writeFile(path, b.templateText)
  result = path

proc createLimaInstance*(b: LimaBackend, name: string,
                        sourceImage: string = "") =
  ## ``limactl create --tty=false --name=<name> <template-or-path>``.
  ## Raises on failure since revert can't continue without the
  ## create.
  let templ = b.writeTemplateFile(sourceImage)
  let tempCreated = sourceImage.len == 0 or
                    (sourceImage.len > 0 and templ != sourceImage)
  defer:
    if tempCreated:
      try: removeFile(templ)
      except CatchableError: discard
  var cmd = @[b.limactlCmd, "create", "--tty=false",
              "--name=" & name]
  if b.cpus > 0:
    cmd.add("--cpus=" & $b.cpus)
  if b.memoryGiB > 0:
    cmd.add("--memory=" & $b.memoryGiB)
  if b.diskGiB > 0:
    cmd.add("--disk=" & $b.diskGiB)
  cmd.add(templ)
  let r = runLimactl(cmd, timeoutSec = b.bootTimeoutSec + 60)
  if r.exitCode != 0:
    raise newVmHarnessError($b.id, lpRevert,
      "limactl create " & name & " failed (exit " & $r.exitCode &
      "): " & r.stdout & r.stderr)

proc startLimaInstance*(b: LimaBackend, name: string) =
  ## ``limactl start --tty=false --timeout <s> <name>``. Raises on
  ## failure so ``revertToBaseline`` surfaces boot problems.
  let r = runLimactl(
    @[b.limactlCmd, "start", "--tty=false",
      "--timeout=" & $b.bootTimeoutSec & "s", name],
    timeoutSec = b.bootTimeoutSec + 30)
  if r.exitCode != 0:
    var e = newVmHarnessError($b.id, lpStartup,
      "limactl start " & name & " failed (exit " & $r.exitCode &
      "): " & r.stdout & r.stderr)
    raise (ref GuestBootFailureError)(
      msg: e.msg, backend: e.backend, phase: e.phase, cause: e.cause)

proc preFetchTemplate*(b: LimaBackend) =
  ## *Pre-fetch the base image so the first per-gate ``limactl
  ## create`` doesn't bear the download cost*. We do this by creating
  ## (and immediately deleting) a throwaway instance from the
  ## template. ``limactl create`` downloads images on first use and
  ## caches them under ``~/.lima/cache/``; subsequent creates against
  ## the same template hit the cache.
  ##
  ## Best-effort: failures here only cost the first revert its
  ## download time, so we don't raise.
  let warmName = b.ephemeralPrefix & "-warm-" & $getCurrentProcessId()
  try:
    b.createLimaInstance(warmName)
  except CatchableError:
    discard
  b.stopLimaInstance(warmName)
  b.deleteLimaInstance(warmName)

# ---------------------------------------------------------------------------
# Argv shim helper — shared with TartBackend's POSIX shim shape so the
# same Tier-1 ``guest-scripts/posix.sh`` semantics hold inside Lima
# guests. Lima provisions cloud-init with a passwordless sudo for the
# default user, so ``sudo`` calls below need no password prompt.

proc renderShimSnippet(bin, logPath: string): string =
  let parentDirGuest = parentDir(logPath)
  let parentClause =
    if parentDirGuest.len > 0 and parentDirGuest != "/" and parentDirGuest != ".":
      "sudo mkdir -p \"" & parentDirGuest & "\" && "
    else: ""
  let escapedLog = logPath.replace("\"", "\\\"")
  let q = "\""
  # Build line-by-line so the multi-line shape survives Nim's
  # triple-quote "strip leading newline" behavior. The pattern of
  # gluing literals via ``"""..."""`` swallows the first newline of
  # every reopened block, fusing adjacent statements onto one line in
  # the rendered output.
  let shimBody = """#!/bin/sh
printf '%s\t%s\n' "$(date +%s%N 2>/dev/null || date +%s)" "$0 $*" >> """ & q & escapedLog & q & "\n" &
                 "exec \"$BACKUP_PATH\" \"$@\"\n"
  result = "set -eu\n" &
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
           "sudo sed -i.bak \"s|\\$BACKUP_PATH|$BACKUP|g\" \"$SHIM_PATH\"\n" &
           "sudo rm -f \"${SHIM_PATH}.bak\"\n" &
           "sudo chmod +x \"$SHIM_PATH\"\n"

# ---------------------------------------------------------------------------
# VmBackend method overrides.

method probeAvailability*(b: LimaBackend): bool =
  ## Lima only runs on macOS hosts (it also runs on Linux but
  ## reprobuild uses libvirt there); we keep this gate scoped to
  ## macOS to match the design doc's "Lima is the macOS alternative"
  ## intent. On macOS we check ``limactl --version`` exits 0.
  when defined(macosx):
    try:
      let r = runLimactl(@[b.limactlCmd, "--version"],
                                timeoutSec = 10)
      return r.exitCode == 0
    except CatchableError:
      return false
  else:
    return false

method provisionBaseline*(b: LimaBackend, spec: BaselineSpec) =
  ## *Session* phase. Two responsibilities:
  ##
  ## 1. Reap stale ``repro-vm-lima-*`` instances from prior aborted
  ##    runs. The same cleanup is invoked by ``stopAndCleanup`` so
  ##    the matched-pair contract holds, but doing it again here
  ##    protects against the case where a previous run was SIGKILL'd
  ##    before the ``finally`` block could fire.
  ## 2. Pre-fetch the base image so the first per-gate ``limactl
  ##    create`` doesn't bear the download cost (best-effort, never
  ##    raises).
  ##
  ## ``BaselineSpec.sourceImage``, when non-empty, overrides the
  ## backend's default template for subsequent ``createLimaInstance``
  ## calls. We don't pre-fetch when ``sourceImage`` is set — the user
  ## may have supplied a one-off template that isn't worth caching.
  if spec.cpus > 0 and b.cpus == 0:
    b.cpus = spec.cpus
  if spec.memoryMB > 0 and b.memoryGiB == 0:
    # round up to whole GiB.
    b.memoryGiB = max(1, (spec.memoryMB + 1023) div 1024)
  if spec.diskGB > 0 and b.diskGiB == 0:
    b.diskGiB = spec.diskGB
  # Reap stale ephemerals.
  for v in b.listLimaInstances():
    if v.startsWith(b.ephemeralPrefix):
      b.stopLimaInstance(v)
      b.deleteLimaInstance(v)
  # Pre-fetch only when using the embedded template (no per-call
  # source override). Best-effort.
  if spec.sourceImage.len == 0:
    try:
      b.preFetchTemplate()
    except CatchableError:
      discard

method revertToBaseline*(b: LimaBackend, baselineName: string): VmHandle =
  ## *Per-gate* phase. ``limactl stop --force && limactl delete
  ## --force && limactl create --tty=false && limactl start
  ## --tty=false``.
  ##
  ## The ephemeral name is ``<prefix>-<epoch-ms>-<pid>`` so
  ## concurrent sessions on the same host don't collide.
  let ephemeral = b.ephemeralPrefix & "-" & $int(epochTime() * 1000) &
                  "-" & $getCurrentProcessId()
  # Defensive: if an instance with this name somehow exists, nuke it.
  let existing = b.listLimaInstances()
  if ephemeral in existing:
    b.stopLimaInstance(ephemeral)
    b.deleteLimaInstance(ephemeral)
  b.createLimaInstance(ephemeral)
  b.startLimaInstance(ephemeral)
  # ``limactl start`` returns after the instance reaches Running; SSH
  # is already up because Lima's start path blocks on hostagent
  # readiness which includes the SSH probe. No extra wait needed.
  result = VmHandle(
    backend: b,
    name: ephemeral,
    baseline: baselineName,
    ipAddress: some("127.0.0.1"),
    # Lima's SSH port is per-instance and dynamic; we don't expose it
    # because ``execInGuest`` goes through ``limactl shell``. Store
    # the conventional 22 so VmHandle is well-formed for inspection.
    sshPort: 22,
    sshUser: "",  # filled by Lima from the user's config
    sshAuth: SshAuth(kind: saKeyFile,
                     keyPath: getHomeDir() / ".lima" / "_config" / "user"),
    extra: {"limaTemplate": "embedded",
            "instanceName": ephemeral}.toTable)

method execInGuest*(b: LimaBackend, vm: VmHandle,
                   env: Table[string, string],
                   cmd: seq[string],
                   stdin: string = "",
                   timeoutSec: int = 600): ExecResult =
  if cmd.len == 0:
    raise newException(ValueError, "execInGuest: empty cmd")
  # Build the remote command. We shell-quote each argv element
  # (single-quote wrap with embedded-single-quote escape) and prepend
  # a ``KEY='value' ...`` env prefix so the guest-side bash sees the
  # right environment. ``limactl shell`` runs ``/bin/bash -c "<line>"``
  # by default.
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
  let shellCmd = @[b.limactlCmd, "shell", vm.name,
                   "bash", "-c", line]
  runLimactl(shellCmd, timeoutSec = timeoutSec,
                    stdinData = stdin)

proc limactlCopy*(b: LimaBackend, src: string, dest: string,
                 recursive: bool = false,
                 timeoutSec: int = 600) =
  ## Internal helper used by both copyToGuest and copyFromGuest. The
  ## caller is responsible for constructing instance-prefixed paths
  ## (e.g. ``my-vm:/tmp/file``).
  ##
  ## We pin ``--backend=scp`` because Lima's auto-backend defaults to
  ## rsync, and rsync (unlike scp) refuses ``-r`` on a single-file
  ## source with ``change_dir failed: Not a directory``. The
  ## ``copyFromGuest`` contract intentionally always passes
  ## ``recursive = true`` so a single backend handles both file and
  ## directory sources — scp's ``-r`` is the degenerate-safe choice.
  var args = @[b.limactlCmd, "copy", "--backend=scp"]
  if recursive:
    args.add("--recursive")
  args.add(src)
  args.add(dest)
  let r = runLimactl(args, timeoutSec = timeoutSec)
  if r.exitCode != 0:
    raise newVmHarnessError($b.id, lpCopy,
      "limactl copy '" & src & "' '" & dest & "' failed (exit " &
      $r.exitCode & "): " & r.stdout & r.stderr)

method copyToGuest*(b: LimaBackend, vm: VmHandle,
                   hostPath: string, guestPath: string) =
  if not fileExists(hostPath) and not dirExists(hostPath):
    raise newVmHarnessError($b.id, lpCopy,
      "LimaBackend.copyToGuest: source not found: " & hostPath)
  # Ensure the destination parent directory exists in the guest.
  let parent = parentDir(guestPath)
  if parent.len > 0 and parent != "/" and parent != ".":
    discard b.execInGuest(vm, initTable[string, string](),
                          @["mkdir", "-p", parent], timeoutSec = 30)
  b.limactlCopy(hostPath, vm.name & ":" & guestPath,
                recursive = dirExists(hostPath))

method copyFromGuest*(b: LimaBackend, vm: VmHandle,
                     guestPath: string, hostPath: string) =
  createDir(parentDir(hostPath))
  # ``--recursive`` with the scp backend is safe even for a single
  # file (scp -r tolerates non-directory sources); the rsync backend
  # would error out here, which is why ``limactlCopy`` pins
  # ``--backend=scp``.
  b.limactlCopy(vm.name & ":" & guestPath, hostPath,
                recursive = true)

method installArgvTraceShim*(b: LimaBackend, vm: VmHandle,
                            shim: ArgvTraceShim) =
  ## Same shim shape as TartBackend's POSIX path: rename
  ## ``<binary>`` to ``<binary>.real`` (if not already done) and drop
  ## a wrapper that appends argv to ``shim.traceLogPath`` then exec's
  ## the real binary. Lima's default Ubuntu user has passwordless
  ## sudo so ``sudo`` here doesn't need a TTY prompt.
  let snippet = renderShimSnippet(shim.wrappedBinaryName,
                                  shim.traceLogPath)
  let r = b.execInGuest(vm, initTable[string, string](),
                        @["/bin/sh", "-c", snippet], timeoutSec = 60)
  if r.exitCode != 0:
    raise newVmHarnessError($b.id, lpShim,
      "installArgvTraceShim failed for " & shim.wrappedBinaryName &
      ": exit " & $r.exitCode & "\n" & r.stdout)

method uninstallArgvTraceShim*(b: LimaBackend, vm: VmHandle,
                              wrappedBinaryName: string) =
  ## Revert-to-baseline destroys the ephemeral instance entirely, so
  ## a per-binary uninstall is academic. Matches the TartBackend
  ## no-op for the same reason.
  discard

method stopAndCleanup*(b: LimaBackend, vm: VmHandle, deleteVm: bool = true) =
  ## ``limactl stop --force <eph> && limactl delete --force <eph>``.
  ## Never raises.
  try:
    b.stopLimaInstance(vm.name)
    # Give Lima a moment to release the disk image; without this, very
    # fast back-to-back delete sometimes returns "instance still
    # running".
    sleep(500)
    if deleteVm:
      b.deleteLimaInstance(vm.name)
  except CatchableError:
    discard

# ---------------------------------------------------------------------------
# Backend registration. Lima is auto-dispatched as the *alternative*
# (not the default) backend for (macOS-arm, Linux); ``selectBackendId``
# still returns ``biTartLinuxArm`` for that cell. Lima is opt-in via
# ``--backend lima``.

registerBackend(biLima,
  proc(): VmBackend = newLimaBackend())
