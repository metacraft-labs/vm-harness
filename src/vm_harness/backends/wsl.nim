## WslBackend — vm-harness adapter for WSL2 on Windows hosts. Per
## design doc §4.2.
##
## *Transport*: ``wsl -d <distro> -- <cmd>`` direct exec. No SSH, no
## networking dance in the guest. The throwaway distro pattern from
## reprobuild's WSL harness is the reset mechanism.
##
## *Two modes of operation:*
##
## 1. *Generic lifecycle mode* (``newWslBackend(...)``). The backend
##    drives ``wsl.exe`` directly: ``wsl --import`` for provision /
##    revert, ``wsl -d <distro> --exec`` for exec, ``cp`` via the
##    ``/mnt/<drive>/`` 9P bridge for file transfer, ``wsl
##    --unregister`` for cleanup.
## 2. *Reprobuild script-wrapper mode* (``runViaReproScript``). The
##    backend invokes reprobuild's existing
##    ``run-wsl-m69-posix.ps1`` via ``osproc.startProcess`` and parses
##    its ``RESULT.txt``. The PowerShell script stays in reprobuild's
##    ``tools/`` directory.
##
## *Compile-time portability:* same arrangement as ``hyperv.nim`` —
## the module compiles cleanly on any host, but the methods raise
## ``BackendUnavailableError`` when called on a non-Windows host.

import std/[os, osproc, streams, strtabs, tables, times]
when defined(windows):
  import std/[options, strutils]
import ../types
import ../auto
import ../output
import ./process_helpers

type
  WslBackend* = ref object of VmBackend
    ## Adapter around ``wsl.exe``.
    distroPrefix*: string
      ## Name prefix for throwaway distros (e.g. ``repro-m69-posix``).
      ## ``revertToBaseline`` appends ``-<epoch>`` to avoid collisions
      ## across concurrent harness sessions on the same host.
    rootfsTarballPath*: string
      ## Path to the cached Ubuntu (or other) rootfs tarball. Used by
      ## ``wsl --import``.
    installRootDir*: string
      ## Directory under which the throwaway distros' VHDs are written.
      ## Each distro gets a subdir ``<installRootDir>/<distroName>/``.
    defaultUser*: string
      ## Default user for ``wsl -d ... --user``. Empty means use the
      ## distro's default (typically ``root`` for a fresh imported
      ## tarball).
    powershellLauncher*: PwshLauncher
      ## When invoking the reprobuild script-wrapper, which PS host to
      ## use. Defaults to ``pwsh``.
    runScriptPath*: string
      ## When non-empty, path to reprobuild's
      ## ``run-wsl-m69-posix.ps1``. Used by ``runViaReproScript``.
    defaultTimeoutMinutes*: int
      ## Optional timeout passed through to the reprobuild script.

const
  DefaultDistroPrefix* = "repro-vm-wsl"
  DefaultInstallRootDir* = "D:\\metacraft\\wsl-m69-posix-state"
  DefaultRootfsTarballPath* = "D:\\metacraft\\wsl-m69-posix-cache\\" &
    "ubuntu-jammy-wsl-amd64-ubuntu22.04lts.rootfs.tar.gz"

proc newWslBackend*(distroPrefix: string = DefaultDistroPrefix,
                    rootfsTarballPath: string = DefaultRootfsTarballPath,
                    installRootDir: string = DefaultInstallRootDir,
                    defaultUser: string = "root",
                    runScriptPath: string = "",
                    powershellLauncher: PwshLauncher = plPwsh,
                    defaultTimeoutMinutes: int = 0): WslBackend =
  ## Construct a WslBackend. All parameters are optional — the M0
  ## registry calls this with no arguments, so the defaults match the
  ## existing reprobuild M69 harness.
  result = WslBackend(
    id: biWsl,
    hostPlatform: hpWindows,
    supportedGuests: {goLinux},
    distroPrefix: distroPrefix,
    rootfsTarballPath: rootfsTarballPath,
    installRootDir: installRootDir,
    defaultUser: defaultUser,
    powershellLauncher: powershellLauncher,
    runScriptPath: runScriptPath,
    defaultTimeoutMinutes: defaultTimeoutMinutes)

# ---------------------------------------------------------------------------
# Process invocation helpers.

proc runProcessCapture(cmd: seq[string], cwd: string = "",
                      timeoutSec: int = 0,
                      env: Table[string, string] = initTable[string, string]()):
                      ExecResult {.used.} =
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
  let outStream = p.outputStream
  var stdout = ""
  var deadline = if timeoutSec > 0: epochTime() + timeoutSec.float else: 0.0
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
        result = ExecResult(
          exitCode: -1,
          stdout: stdout,
          stderr: "vm-harness: process timed out after " &
                  $timeoutSec & "s",
          elapsedMs: int((epochTime() - start) * 1000))
        return
      sleep(50)
  let code = p.waitForExit(timeout = -1)
  result = ExecResult(
    exitCode: code,
    stdout: stdout,
    stderr: "",
    elapsedMs: int((epochTime() - start) * 1000))

# ---------------------------------------------------------------------------
# WSL primitives.

proc listDistros*(b: WslBackend): seq[string] =
  ## ``wsl --list --quiet`` then strip the UTF-16 stray nulls. Returns
  ## an empty seq when ``wsl.exe`` isn't on PATH (i.e. on non-Windows
  ## hosts).
  when defined(windows):
    try:
      let r = runProcessCapture(buildWslListQuietArgs(), timeoutSec = 30)
      return parseWslListQuiet(r.stdout)
    except CatchableError:
      return @[]
  else:
    return @[]

proc terminateDistro*(b: WslBackend, distroName: string) =
  when defined(windows):
    discard runProcessCapture(buildWslTerminateArgs(distroName),
                              timeoutSec = 30)

proc unregisterDistro*(b: WslBackend, distroName: string) =
  when defined(windows):
    discard runProcessCapture(buildWslUnregisterArgs(distroName),
                              timeoutSec = 60)

proc importDistro*(b: WslBackend, distroName: string, version: int = 2) =
  ## ``wsl --import <name> <install-dir>/<name> <rootfs-tarball>
  ## [--version 2]``.
  when defined(windows):
    let dir = b.installRootDir / distroName
    createDir(dir)
    let inv = WslImportInvocation(distroName: distroName,
                                  installDir: dir,
                                  rootfsTarball: b.rootfsTarballPath,
                                  version: version)
    let r = runProcessCapture(buildWslImportArgs(inv), timeoutSec = 300)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpRevert,
        "wsl --import failed: " & r.stdout)
  else:
    raise newException(BackendUnavailableError,
      "WslBackend.importDistro requires a Windows host")

# ---------------------------------------------------------------------------
# VmBackend method overrides.

method probeAvailability*(b: WslBackend): bool =
  when defined(windows):
    try:
      let r = runProcessCapture(@["wsl.exe", "--status"], timeoutSec = 30)
      return r.exitCode == 0
    except CatchableError:
      return false
  else:
    return false

method provisionBaseline*(b: WslBackend, spec: BaselineSpec) =
  ## WSL has no "build a baseline VM" step — the rootfs tarball IS the
  ## baseline. We assert the tarball exists and is non-empty;
  ## downloading the tarball is the caller's responsibility (the
  ## reprobuild WSL runner does this in PowerShell with
  ## ``Invoke-WebRequest``). The ``BaselineSpec.sourceImage`` field, when
  ## non-empty, overrides the backend's default tarball path.
  if spec.sourceImage.len > 0:
    b.rootfsTarballPath = spec.sourceImage
  if not fileExists(b.rootfsTarballPath):
    raise newVmHarnessError($b.id, lpProvisioning,
      "WslBackend: rootfs tarball missing at " & b.rootfsTarballPath &
      "; download it via the reprobuild WSL runner or supply " &
      "--source-image <path>")

method revertToBaseline*(b: WslBackend, baselineName: string): VmHandle =
  ## "Revert" means unregister-and-reimport the throwaway distro from
  ## the rootfs tarball. The result is a brand-new distro with the
  ## tarball's state, ready for exec.
  when defined(windows):
    let distroName = b.distroPrefix & "-" & $int(epochTime())
    # Clean up any stale distro with the same name.
    let existing = b.listDistros()
    if distroName in existing:
      b.terminateDistro(distroName)
      b.unregisterDistro(distroName)
    # Import a fresh throwaway distro.
    b.importDistro(distroName)
    result = VmHandle(
      backend: b,
      name: distroName,
      baseline: baselineName,
      ipAddress: none(string),
      sshPort: 0,
      sshUser: b.defaultUser,
      sshAuth: SshAuth(kind: saNone),
      extra: {"installDir": b.installRootDir / distroName}.toTable)
  else:
    raise newException(BackendUnavailableError,
      "WslBackend.revertToBaseline requires a Windows host")

method execInGuest*(b: WslBackend, vm: VmHandle,
                   env: Table[string, string],
                   cmd: seq[string],
                   stdin: string = "",
                   timeoutSec: int = 600): ExecResult =
  ## Build ``wsl -d <distro> --user <user> --exec /bin/bash -c
  ## '<env-prefix> <cmd-quoted>'`` and run it. The env table becomes a
  ## prefix string of ``KEY='value' ...`` pairs; the cmd is shell-quoted
  ## naively (single-quote wrap with embedded-single-quote escape).
  when defined(windows):
    var envPrefix = ""
    for k, v in env:
      envPrefix &= k & "='" & v.replace("'", "'\\''") & "' "
    var quoted = ""
    for i, a in cmd:
      if i > 0: quoted.add(' ')
      quoted.add('\'')
      quoted.add(a.replace("'", "'\\''"))
      quoted.add('\'')
    let line = envPrefix & quoted
    let inv = WslExecInvocation(
      distro: vm.name,
      user: vm.sshUser,
      workingDir: "",
      shell: "/bin/bash",
      command: line)
    let args = buildWslExecArgs(inv)
    return runProcessCapture(args, timeoutSec = timeoutSec)
  else:
    raise newException(BackendUnavailableError,
      "WslBackend.execInGuest requires a Windows host")

method copyToGuest*(b: WslBackend, vm: VmHandle,
                   hostPath: string, guestPath: string) =
  ## Use the WSL 9P bridge: ``cp /mnt/<drive>/<host-path> <guestPath>``
  ## from inside the distro. This is slower than copying inside the
  ## distro's own ext4 but Just Works without needing SSH or
  ## file-share configuration.
  when defined(windows):
    let mounted = hostPathToWslPath(hostPath)
    let mkdir = "mkdir -p \"" & parentDir(guestPath) & "\""
    let copy = "cp -a \"" & mounted & "\" \"" & guestPath & "\""
    let inv = WslExecInvocation(
      distro: vm.name,
      user: vm.sshUser,
      shell: "/bin/sh",
      command: mkdir & " && " & copy)
    let r = runProcessCapture(buildWslExecArgs(inv), timeoutSec = 600)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpCopy,
        "in-distro cp failed: " & r.stdout)
  else:
    raise newException(BackendUnavailableError,
      "WslBackend.copyToGuest requires a Windows host")

method copyFromGuest*(b: WslBackend, vm: VmHandle,
                     guestPath: string, hostPath: string) =
  ## Same trick in reverse: ``cp <guestPath> /mnt/<drive>/<hostPath>``.
  when defined(windows):
    let mounted = hostPathToWslPath(hostPath)
    let mkdir = "mkdir -p \"" & parentDir(mounted) & "\""
    let copy = "cp -a \"" & guestPath & "\" \"" & mounted & "\""
    let inv = WslExecInvocation(
      distro: vm.name,
      user: vm.sshUser,
      shell: "/bin/sh",
      command: mkdir & " && " & copy)
    let r = runProcessCapture(buildWslExecArgs(inv), timeoutSec = 600)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpCopy,
        "in-distro cp failed: " & r.stdout)
  else:
    raise newException(BackendUnavailableError,
      "WslBackend.copyFromGuest requires a Windows host")

method installArgvTraceShim*(b: WslBackend, vm: VmHandle,
                            shim: ArgvTraceShim) =
  ## Drop the shim wrapper into ``/usr/local/bin/<binary>``, after
  ## backing up the original to ``<binary>.real``. Pure POSIX, so we
  ## can re-use the embedded ``guest-scripts/posix.sh install-trace-
  ## shim`` subcommand by piping it through ``wsl --exec sh``.
  when defined(windows):
    let cmd = "/usr/local/bin/" & shim.wrappedBinaryName &
              ".real 2>/dev/null || mv \"$(command -v " & shim.wrappedBinaryName &
              ")\" /usr/local/bin/" & shim.wrappedBinaryName & ".real; " &
              "cat > /usr/local/bin/" & shim.wrappedBinaryName &
              " <<'SHIM'\n#!/bin/sh\nprintf '%s\\t%s\\n' \"$(date +%s%N 2>/dev/null || date +%s)\" \"" &
              shim.wrappedBinaryName & " $*\" >> \"" & shim.traceLogPath &
              "\"\nexec /usr/local/bin/" & shim.wrappedBinaryName &
              ".real \"$@\"\nSHIM\nchmod +x /usr/local/bin/" &
              shim.wrappedBinaryName
    let inv = WslExecInvocation(
      distro: vm.name,
      user: vm.sshUser,
      shell: "/bin/sh",
      command: cmd)
    let r = runProcessCapture(buildWslExecArgs(inv), timeoutSec = 60)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpShim,
        "installArgvTraceShim failed for " & shim.wrappedBinaryName &
        ": " & r.stdout)
  else:
    raise newException(BackendUnavailableError,
      "WslBackend.installArgvTraceShim requires a Windows host")

method uninstallArgvTraceShim*(b: WslBackend, vm: VmHandle,
                              wrappedBinaryName: string) =
  ## Reverting the throwaway distro re-establishes the baseline; we
  ## leave this as a no-op rather than restoring the ``.real`` backup.
  discard

method stopAndCleanup*(b: WslBackend, vm: VmHandle, deleteVm: bool = true) =
  ## ``wsl --terminate <distro>`` followed by ``wsl --unregister
  ## <distro>``. Also removes the distro's install dir under
  ## ``installRootDir``. Never raises.
  when defined(windows):
    try:
      b.terminateDistro(vm.name)
      if deleteVm:
        b.unregisterDistro(vm.name)
        let dir = b.installRootDir / vm.name
        if dirExists(dir):
          try: removeDir(dir)
          except CatchableError: discard
    except CatchableError:
      discard
  else:
    discard

# ---------------------------------------------------------------------------
# Reprobuild script-wrapper convenience helper.

proc runViaReproScript*(b: WslBackend,
                       timeoutMinutes: int = 0,
                       keepDistro: bool = false,
                       envelope: OutputEnvelope = nil,
                       outDirOverride: string = ""): ScriptResult =
  ## Invoke reprobuild's ``run-wsl-m69-posix.ps1`` and parse the
  ## resulting ``RESULT.txt``. When ``envelope`` is supplied the
  ## script's envelope files are mirrored into the envelope's
  ## directory.
  if b.runScriptPath.len == 0:
    raise newException(BackendUnavailableError,
      "WslBackend: runScriptPath not configured")
  when defined(windows):
    let timeout = if timeoutMinutes > 0:
                    timeoutMinutes
                  else:
                    b.defaultTimeoutMinutes
    let inv = WslRunInvocation(
      scriptPath: b.runScriptPath,
      timeoutMinutes: timeout,
      keepDistro: keepDistro)
    let cmd = buildWslRunArgs(b.powershellLauncher, inv)
    let r = runProcessCapture(cmd, timeoutSec = 0)
    let outDir = if outDirOverride.len > 0: outDirOverride
                 else: "D:\\metacraft\\wsl-m69-posix-out"
    let parsed = readScriptResult(outDir)
    if envelope != nil:
      copyEnvelopeFiles(outDir, envelope)
    var withRaw = parsed
    if r.stdout.len > 0 and parsed.rawResultText.len == 0:
      withRaw.rawResultText = r.stdout
    result = withRaw
  else:
    raise newException(BackendUnavailableError,
      "runViaReproScript requires a Windows host")

# ---------------------------------------------------------------------------
# Backend registration.

registerBackend(biWsl, proc(): VmBackend = newWslBackend())
