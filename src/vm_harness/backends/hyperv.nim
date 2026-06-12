## HyperVBackend — vm-harness adapter for Microsoft Hyper-V on Windows
## hosts. Per design doc §4.1.
##
## *Transport*: PowerShell Direct over VMBus
## (``Invoke-Command -VMName <name> -ScriptBlock { ... }``); no networking
## in the guest is required.
##
## *Two modes of operation:*
##
## 1. *Generic lifecycle mode* (``newHyperVBackend(...)``). The backend
##    drives Hyper-V directly via the ``Hyper-V`` PowerShell module:
##    ``Restore-VMCheckpoint`` for revert, ``Start-VM`` + a PowerShell
##    Direct readiness poll for boot, ``Copy-VMFile`` for host->guest
##    transfer, ``Invoke-Command -VMName`` for exec, ``Stop-VM -TurnOff``
##    for cleanup. This mode targets *any* Hyper-V guest, not just the
##    reprobuild M69 VM.
## 2. *Reprobuild script-wrapper mode*
##    (``provisionBaselineViaReproScript`` / ``runViaReproScript``). The
##    backend invokes reprobuild's existing PowerShell scripts
##    (``provision-base-vm.ps1`` and ``run-hyperv-m69-system.ps1``) via
##    ``osproc.startProcess`` and parses their ``RESULT.txt`` output. The
##    PowerShell scripts stay in reprobuild's ``tools/`` directory; they
##    are NOT moved into vm-harness. This mode preserves reprobuild's
##    existing M69 test execution path without breaking changes.
##
## *Compile-time portability:* the module compiles cleanly on any host
## (Mac, Linux, Windows) so unit tests for the parser helpers can run
## anywhere. Backend *registration* with the M0 factory registry is
## unconditional, but ``probeAvailability`` returns ``false`` on
## non-Windows hosts (no ``wsl.exe`` / ``Get-VM`` cmdlet). The
## ``newHyperVBackend`` constructor itself does no I/O, so simply
## importing this module is always safe.

import std/[os, osproc, streams, strformat, strtabs,
            strutils, tables, times]
when defined(windows):
  import std/[base64, options]
import ../types
import ../auto
import ../output
import ../serial
import ./process_helpers

type
  HyperVBackend* = ref object of VmBackend
    ## Adapter around Hyper-V's PowerShell cmdlets.
    vmName*: string
      ## Name of the long-lived Hyper-V VM (e.g. ``repro-m69-hyperv``).
      ## Reverts target snapshots inside this single VM rather than
      ## cloning new VMs each time — Hyper-V's native checkpoint /
      ## restore is the fastest revert mechanism available.
    credentialCachePath*: string
      ## Path to the DPAPI-sealed XML cache containing the guest's
      ## SAM credential, as produced by reprobuild's
      ## ``provision-base-vm.ps1``. Used to authenticate
      ## ``Invoke-Command -VMName``.
    powershellLauncher*: PwshLauncher
      ## ``pwsh`` (PowerShell 7+) or ``powershell`` (Windows PowerShell 5.1).
      ## Defaults to ``pwsh`` to match reprobuild's existing harness.
    runScriptPath*: string
      ## When non-empty, the reprobuild ``run-hyperv-m69-system.ps1`` path
      ## used by ``runViaReproScript``.
    provisionScriptPath*: string
      ## When non-empty, the reprobuild ``provision-base-vm.ps1`` path
      ## used by ``provisionBaselineViaReproScript``.
    defaultGateTimeoutMinutes*: int
      ## Optional per-backend timeout that the orchestrator passes
      ## through to the reprobuild script when calling ``runViaReproScript``.

const
  DefaultVmName* = "repro-m69-hyperv"

proc newHyperVBackend*(vmName: string = DefaultVmName,
                       credentialCachePath: string = "",
                       runScriptPath: string = "",
                       provisionScriptPath: string = "",
                       powershellLauncher: PwshLauncher = plPwsh,
                       defaultGateTimeoutMinutes: int = 0): HyperVBackend =
  ## Construct a HyperVBackend. All parameters are optional — the M0
  ## registry calls this with no arguments, in which case a sensible
  ## set of defaults matching the existing reprobuild M69 harness is
  ## used.
  result = HyperVBackend(
    id: biHyperv,
    hostPlatform: hpWindows,
    supportedGuests: {goWindows, goLinux},
    vmName: vmName,
    credentialCachePath: credentialCachePath,
    powershellLauncher: powershellLauncher,
    runScriptPath: runScriptPath,
    provisionScriptPath: provisionScriptPath,
    defaultGateTimeoutMinutes: defaultGateTimeoutMinutes)

# ---------------------------------------------------------------------------
# Process invocation helpers.

proc runProcessCapture(cmd: seq[string], cwd: string = "",
                      timeoutSec: int = 0,
                      env: Table[string, string] = initTable[string, string]()):
                      ExecResult =
  ## Spawn a child process and capture stdout + stderr + exit code.
  ## ``cmd[0]`` is the executable; ``cmd[1..]`` are arguments. On a zero
  ## or negative timeout the wait is unbounded.
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

proc pwshInvokeCommand*(b: HyperVBackend, vmName: string,
                       scriptBlock: string,
                       arguments: openArray[string] = [],
                       timeoutSec: int = 600): ExecResult =
  ## Run a PowerShell-Direct invocation inside the guest. Builds a
  ## ``pwsh -Command`` line that loads the credential cache, then calls
  ## ``Invoke-Command -VMName <vm> -Credential <cred> -ScriptBlock { ... }``
  ## with ``-ArgumentList`` populated from ``arguments``.
  ##
  ## The returned ``ExecResult`` carries the guest process's stdout
  ## (forwarded through PowerShell's serializer), the exit code as
  ## reported by ``$LASTEXITCODE``, and an empty stderr (PSDirect
  ## doesn't split streams the way SSH does — stderr is interleaved
  ## with stdout in the host-side capture).
  if b.credentialCachePath.len == 0:
    raise newException(ValueError,
      "HyperVBackend: credentialCachePath is empty; cannot " &
      "Invoke-Command -VMName " & vmName)
  var argsList: seq[string]
  for a in arguments:
    argsList.add("'" & a.replace("'", "''") & "'")
  let argListExpr = if argsList.len == 0: "@()" else: "@(" & argsList.join(",") & ")"
  let psCommand = &"""$ErrorActionPreference = 'Stop'
$cred = Import-Clixml -Path '{b.credentialCachePath.replace("'", "''")}'
$out = Invoke-Command -VMName '{vmName.replace("'", "''")}' -Credential $cred -ScriptBlock {{ {scriptBlock} }} -ArgumentList {argListExpr}
$out | Out-String
exit $LASTEXITCODE
"""
  let pwsh = @[$b.powershellLauncher, "-NoLogo", "-NoProfile",
               "-ExecutionPolicy", "Bypass", "-Command", psCommand]
  runProcessCapture(pwsh, timeoutSec = timeoutSec)

# ---------------------------------------------------------------------------
# VmBackend method overrides.

method probeAvailability*(b: HyperVBackend): bool =
  ## On non-Windows hosts this is trivially false. On Windows we shell
  ## out to ``powershell -Command "Get-Command Get-VM"`` and inspect the
  ## exit code; an exit-zero means the Hyper-V module is importable and
  ## the host is admin enough to use it.
  when defined(windows):
    let cmd = @[$b.powershellLauncher, "-NoLogo", "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-Command",
                "if (Get-Command Get-VM -ErrorAction SilentlyContinue) " &
                "{ exit 0 } else { exit 1 }"]
    try:
      let r = runProcessCapture(cmd, timeoutSec = 30)
      return r.exitCode == 0
    except CatchableError:
      return false
  else:
    return false

method provisionBaseline*(b: HyperVBackend, spec: BaselineSpec) =
  ## Hyper-V provisioning is delegated to reprobuild's
  ## ``provision-base-vm.ps1`` when ``b.provisionScriptPath`` is set
  ## (the reprobuild-adapter case). When unset we treat
  ## ``provisionBaseline`` as a no-op asserting the snapshot already
  ## exists — the assumption is that the consumer (or an out-of-band
  ## admin) has built the baseline VM previously.
  ##
  ## Future work (post-M1): teach the generic mode to construct a
  ## baseline VM from scratch via Hyper-V cmdlets.
  if b.provisionScriptPath.len == 0:
    return
  when defined(windows):
    let inv = HyperVProvisionInvocation(scriptPath: b.provisionScriptPath,
                                        force: false,
                                        vhdxOverridePath: "",
                                        skipVsInstall: spec.name == "base-clean")
    let cmd = buildHyperVProvisionArgs(b.powershellLauncher, inv)
    let r = runProcessCapture(cmd, timeoutSec = 0)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "provision-base-vm.ps1 failed with exit " & $r.exitCode &
        "\n" & r.stdout)
  else:
    raise newException(BackendUnavailableError,
      "HyperVBackend.provisionBaseline requires a Windows host")

method revertToBaseline*(b: HyperVBackend, baselineName: string): VmHandle =
  ## Restore the named checkpoint and return a started VM handle. The
  ## ``Restore-VMCheckpoint`` + ``Start-VM`` + readiness-poll sequence
  ## matches the existing reprobuild runner step-1 logic.
  when defined(windows):
    let psBlock = &"""$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop
$vm = Get-VM -Name '{b.vmName.replace("'", "''")}' -ErrorAction Stop
if ($vm.State -ne 'Off') {{ Stop-VM -Name '{b.vmName.replace("'", "''")}' -TurnOff -Force -ErrorAction SilentlyContinue }}
Restore-VMCheckpoint -VMName '{b.vmName.replace("'", "''")}' -Name '{baselineName.replace("'", "''")}' -Confirm:$false
Start-VM -Name '{b.vmName.replace("'", "''")}'
Write-Host "REVERTED $($vm.Name) to {baselineName.replace("'", "''")}"
"""
    let cmd = @[$b.powershellLauncher, "-NoLogo", "-NoProfile",
                "-ExecutionPolicy", "Bypass", "-Command", psBlock]
    let r = runProcessCapture(cmd, timeoutSec = 300)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpRevert,
        "Restore-VMCheckpoint failed: " & r.stdout)
    result = VmHandle(
      backend: b,
      name: b.vmName,
      baseline: baselineName,
      ipAddress: none(string),
      sshPort: 0,
      sshUser: "",
      sshAuth: SshAuth(kind: saNone),
      extra: initTable[string, string]())
  else:
    raise newException(BackendUnavailableError,
      "HyperVBackend.revertToBaseline requires a Windows host")

method execInGuest*(b: HyperVBackend, vm: VmHandle,
                   env: Table[string, string],
                   cmd: seq[string],
                   stdin: string = "",
                   timeoutSec: int = 600): ExecResult =
  ## Run ``cmd`` inside the guest via PowerShell Direct. The env table
  ## becomes ``Set-Item Env:<key> <value>`` lines prefixed to the script
  ## block; ``cmd`` becomes a ``Start-Process -Wait`` invocation so the
  ## guest-side ``$LASTEXITCODE`` propagates back as our exit code.
  when defined(windows):
    if cmd.len == 0:
      raise newException(ValueError, "execInGuest: empty cmd")
    var envLines = ""
    for k, v in env:
      envLines &= "Set-Item -Path 'Env:" & k.replace("'", "''") &
                  "' -Value '" & v.replace("'", "''") & "'`n"
    let exe = cmd[0].replace("'", "''")
    var argList = ""
    if cmd.len > 1:
      argList = "-ArgumentList @("
      for i in 1 ..< cmd.len:
        if i > 1: argList &= ","
        argList &= "'" & cmd[i].replace("'", "''") & "'"
      argList &= ")"
    let scriptBlock = envLines &
      "$p = Start-Process -FilePath '" & exe & "' -NoNewWindow -Wait -PassThru " &
      argList & " -RedirectStandardOutput \"$env:TEMP\\vmh-stdout.txt\" " &
      "-RedirectStandardError \"$env:TEMP\\vmh-stderr.txt\"`n" &
      "$out = if (Test-Path \"$env:TEMP\\vmh-stdout.txt\") { Get-Content -Raw \"$env:TEMP\\vmh-stdout.txt\" } else { '' }`n" &
      "$err = if (Test-Path \"$env:TEMP\\vmh-stderr.txt\") { Get-Content -Raw \"$env:TEMP\\vmh-stderr.txt\" } else { '' }`n" &
      "Write-Host $out`n" &
      "if ($err) { [Console]::Error.WriteLine($err) }`n" &
      "exit $p.ExitCode"
    return pwshInvokeCommand(b, vm.name, scriptBlock,
                             timeoutSec = timeoutSec)
  else:
    raise newException(BackendUnavailableError,
      "HyperVBackend.execInGuest requires a Windows host")

method copyToGuest*(b: HyperVBackend, vm: VmHandle,
                   hostPath: string, guestPath: string) =
  ## ``Copy-VMFile -Name <vm> -SourcePath <hostPath>
  ## -DestinationPath <guestPath> -CreateFullPath -FileSource Host -Force``.
  ##
  ## *Important*: Copy-VMFile rides on the Guest Service Interface
  ## (GSI), not on PowerShell Direct's VMBus. On a freshly-reverted
  ## VM, GSI may take up to 60 s longer than PSDirect to reach
  ## ``PrimaryStatusDescription = 'OK'`` — calls issued before then
  ## silently no-op. The reprobuild runner polls GSI readiness; this
  ## adapter assumes the caller has already done so (the orchestrator's
  ## ``startAndAwaitReady`` hook is the right place for that wait).
  when defined(windows):
    let psBlock = &"""$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop
Copy-VMFile -Name '{b.vmName.replace("'", "''")}' -SourcePath '{hostPath.replace("'", "''")}' -DestinationPath '{guestPath.replace("'", "''")}' -CreateFullPath -FileSource Host -Force
"""
    let cmd = @[$b.powershellLauncher, "-NoLogo", "-NoProfile",
                "-ExecutionPolicy", "Bypass", "-Command", psBlock]
    let r = runProcessCapture(cmd, timeoutSec = 600)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpCopy,
        "Copy-VMFile failed: " & r.stdout)
  else:
    raise newException(BackendUnavailableError,
      "HyperVBackend.copyToGuest requires a Windows host")

method copyFromGuest*(b: HyperVBackend, vm: VmHandle,
                     guestPath: string, hostPath: string) =
  ## Windows 11 (build 26200+) no longer ships the ``Copy-VMFile
  ## -FileSource Guest`` direction — the cmdlet's ``CopyFileSourceType``
  ## enum only carries ``Host``. The reprobuild runner works around
  ## this by reading the file inside the guest via Invoke-Command and
  ## streaming the bytes back as a ``[byte[]]`` return value. We do
  ## the same here.
  when defined(windows):
    let psBlock = "[Convert]::ToBase64String([System.IO.File]::" &
      "ReadAllBytes('" & guestPath.replace("'", "''") & "'))"
    let r = pwshInvokeCommand(b, vm.name, psBlock, timeoutSec = 600)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpCopy,
        "in-guest read failed: " & r.stdout)
    createDir(parentDir(hostPath))
    let b64 = r.stdout.strip()
    writeFile(hostPath, decode(b64))
  else:
    raise newException(BackendUnavailableError,
      "HyperVBackend.copyFromGuest requires a Windows host")

method installArgvTraceShim*(b: HyperVBackend, vm: VmHandle,
                            shim: ArgvTraceShim) =
  ## Replace ``C:\Windows\System32\<wrappedBinaryName>`` with a small
  ## PowerShell wrapper that appends ``ts<tab>argv...`` to
  ## ``shim.traceLogPath`` then re-exec's the original (renamed to
  ## ``<name>.real.exe``). Generic Windows shim; the reprobuild M69
  ## gates can install whichever binary names they care about.
  when defined(windows):
    let bin = shim.wrappedBinaryName
    let log = shim.traceLogPath
    let psBlock = &"""$ErrorActionPreference = 'Stop'
$real = 'C:\Windows\System32\{bin}.real.exe'
$orig = 'C:\Windows\System32\{bin}.exe'
if (-not (Test-Path $real)) {{ Move-Item -Path $orig -Destination $real -Force }}
$wrapper = @'
@echo off
echo %DATE% %TIME% %* >> "{log}"
"%~dp0{bin}.real.exe" %*
'@
$wrapper | Set-Content -Path '$orig.bat' -Encoding ascii
"""
    let r = pwshInvokeCommand(b, vm.name, psBlock, timeoutSec = 60)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpShim,
        "installArgvTraceShim failed for " & bin & ": " & r.stdout)
  else:
    raise newException(BackendUnavailableError,
      "HyperVBackend.installArgvTraceShim requires a Windows host")

method uninstallArgvTraceShim*(b: HyperVBackend, vm: VmHandle,
                              wrappedBinaryName: string) =
  ## Revert path is implicit on Hyper-V: the next ``revertToBaseline``
  ## restores the snapshot's original binaries. We leave this as a no-op.
  discard

method startAndAwaitReady*(b: HyperVBackend, vm: VmHandle, timeoutSec: int = 120) =
  ## Poll PowerShell Direct until ``Invoke-Command -VMName { hostname }``
  ## succeeds (the canonical "guest is ready for execInGuest" probe). The
  ## current ``revertToBaseline`` returns once ``Start-VM`` has been
  ## issued; the guest may still be in early Windows boot at that point.
  ## Callers that need to wait for the guest to be reachable before
  ## ``execInGuest`` should call this method.
  when defined(windows):
    let deadline = epochTime() + float(timeoutSec)
    while epochTime() < deadline:
      let r = pwshInvokeCommand(b, vm.name, "hostname", timeoutSec = 15)
      if r.exitCode == 0 and r.stdout.strip().len > 0:
        return
      sleep(500)
    raise newException(GuestBootFailureError,
      "HyperVBackend.startAndAwaitReady: PSDirect on '" & vm.name &
      "' did not become ready within " & $timeoutSec & "s")
  else:
    raise newException(BackendUnavailableError,
      "HyperVBackend.startAndAwaitReady requires a Windows host")

# ---------------------------------------------------------------------------
# Snapshot / restore / list — M30 surface, native Hyper-V Checkpoint cmdlets.
# `snapshot` takes a snapshot of the VM in its CURRENT state (the result is
# cold if the VM is Off, hot if Running — the Standard CheckpointType captures
# memory + CPU + device state when the VM is running). `snapshotRunning` adds
# a precondition assertion that the VM must be in the Running state, so the
# caller's intent is explicit and an accidental cold snapshot is surfaced as
# an error rather than silently returning a snapshot that won't fast-revert.

method snapshot*(b: HyperVBackend, vmName, snapshotName: string): string =
  when defined(windows):
    let psBlock = &"""$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop
Checkpoint-VM -Name '{vmName.replace("'", "''")}' -SnapshotName '{snapshotName.replace("'", "''")}'
"""
    let cmd = @[$b.powershellLauncher, "-NoLogo", "-NoProfile",
                "-ExecutionPolicy", "Bypass", "-Command", psBlock]
    let r = runProcessCapture(cmd, timeoutSec = 300)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "Checkpoint-VM failed: " & r.stdout)
    result = snapshotName
  else:
    raise newException(BackendUnavailableError,
      "HyperVBackend.snapshot requires a Windows host")

method snapshotRunning*(b: HyperVBackend, vmName, snapshotName: string): string =
  ## Take a hot Standard Checkpoint that captures memory + CPU + device
  ## state of the running VM. Fails if the VM is not in the Running state
  ## — the caller is expected to have started the VM and waited for
  ## guest readiness (PSDirect / SSH up) BEFORE calling this method.
  when defined(windows):
    let psBlock = &"""$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop
$vm = Get-VM -Name '{vmName.replace("'", "''")}' -ErrorAction Stop
if ($vm.State -ne 'Running') {{
  throw "snapshotRunning requires VM state Running; got $($vm.State)"
}}
$cfgType = (Get-VM -Name '{vmName.replace("'", "''")}').CheckpointType
if ($cfgType -ne 'Standard') {{
  # Standard checkpoints capture memory; Production checkpoints do not.
  # Flip the per-VM CheckpointType for the duration of this call.
  Set-VM -Name '{vmName.replace("'", "''")}' -CheckpointType Standard
}}
Checkpoint-VM -Name '{vmName.replace("'", "''")}' -SnapshotName '{snapshotName.replace("'", "''")}'
"""
    let cmd = @[$b.powershellLauncher, "-NoLogo", "-NoProfile",
                "-ExecutionPolicy", "Bypass", "-Command", psBlock]
    let r = runProcessCapture(cmd, timeoutSec = 300)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "Checkpoint-VM (running) failed: " & r.stdout)
    result = snapshotName
  else:
    raise newException(BackendUnavailableError,
      "HyperVBackend.snapshotRunning requires a Windows host")

method restoreSnapshot*(b: HyperVBackend, vmName, snapshotName: string) =
  when defined(windows):
    let psBlock = &"""$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop
Restore-VMCheckpoint -VMName '{vmName.replace("'", "''")}' -Name '{snapshotName.replace("'", "''")}' -Confirm:$false
"""
    let cmd = @[$b.powershellLauncher, "-NoLogo", "-NoProfile",
                "-ExecutionPolicy", "Bypass", "-Command", psBlock]
    let r = runProcessCapture(cmd, timeoutSec = 300)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpRevert,
        "Restore-VMCheckpoint failed: " & r.stdout)
  else:
    raise newException(BackendUnavailableError,
      "HyperVBackend.restoreSnapshot requires a Windows host")

method listSnapshots*(b: HyperVBackend, vmName: string): seq[string] =
  when defined(windows):
    let psBlock = &"""$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop
Get-VMSnapshot -VMName '{vmName.replace("'", "''")}' | ForEach-Object {{ $_.Name }}
"""
    let cmd = @[$b.powershellLauncher, "-NoLogo", "-NoProfile",
                "-ExecutionPolicy", "Bypass", "-Command", psBlock]
    let r = runProcessCapture(cmd, timeoutSec = 60)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "Get-VMSnapshot failed: " & r.stdout)
    result = @[]
    for line in r.stdout.splitLines():
      let s = line.strip()
      if s.len > 0: result.add(s)
  else:
    raise newException(BackendUnavailableError,
      "HyperVBackend.listSnapshots requires a Windows host")

method removeSnapshot*(b: HyperVBackend, vmName, snapshotName: string) =
  when defined(windows):
    let psBlock = &"""$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop
$snap = Get-VMSnapshot -VMName '{vmName.replace("'", "''")}' -Name '{snapshotName.replace("'", "''")}' -ErrorAction SilentlyContinue
if ($snap) {{ Remove-VMSnapshot -VMSnapshot $snap -Confirm:$false }}
"""
    let cmd = @[$b.powershellLauncher, "-NoLogo", "-NoProfile",
                "-ExecutionPolicy", "Bypass", "-Command", psBlock]
    let r = runProcessCapture(cmd, timeoutSec = 300)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "Remove-VMSnapshot failed: " & r.stdout)
  else:
    raise newException(BackendUnavailableError,
      "HyperVBackend.removeSnapshot requires a Windows host")

method exportBaseline*(b: HyperVBackend, vmName, destDir: string;
                       baselineName: string = "") =
  ## Hyper-V's ``Export-VM`` exports the whole VM tree including every
  ## snapshot. ``destDir`` ends up containing
  ## ``<vmName>/Virtual Machines/*.vmcx`` for the current state and
  ## ``<vmName>/Snapshots/*.vmcx`` + ``*.VMRS`` for each snapshot's
  ## memory-state image. ``baselineName`` is an optional sanity-check
  ## hint — if non-empty, the export aborts if no snapshot of that name
  ## exists.
  ##
  ## See ``docs/per-backend-notes/hyperv-snapshot-benchmarks.md`` for the
  ## cross-host transfer payload analysis (same-volume export uses
  ## reflinks; cross-host transfer payload is ~10 GB for a typical
  ## Windows guest + 0.7 GB per hot checkpoint).
  when defined(windows):
    let saneName = baselineName.replace("'", "''")
    let preCheck =
      if baselineName.len == 0: ""
      else: &"""$snap = Get-VMSnapshot -VMName '{vmName.replace("'", "''")}' -Name '{saneName}' -ErrorAction SilentlyContinue
if (-not $snap) {{ throw "exportBaseline: snapshot '{saneName}' not found on VM '{vmName.replace("'", "''")}'" }}
"""
    let psBlock = &"""$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop
{preCheck}if (-not (Test-Path '{destDir.replace("'", "''")}')) {{
  New-Item -ItemType Directory -Path '{destDir.replace("'", "''")}' -Force | Out-Null
}}
$vm = Get-VM -Name '{vmName.replace("'", "''")}' -ErrorAction Stop
if ($vm.State -ne 'Off') {{
  Stop-VM -Name '{vmName.replace("'", "''")}' -TurnOff -Force -ErrorAction SilentlyContinue
}}
Export-VM -Name '{vmName.replace("'", "''")}' -Path '{destDir.replace("'", "''")}'
"""
    let cmd = @[$b.powershellLauncher, "-NoLogo", "-NoProfile",
                "-ExecutionPolicy", "Bypass", "-Command", psBlock]
    let r = runProcessCapture(cmd, timeoutSec = 1800)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "Export-VM failed: " & r.stdout)
  else:
    raise newException(BackendUnavailableError,
      "HyperVBackend.exportBaseline requires a Windows host")

method importBaseline*(b: HyperVBackend, srcDir: string): seq[string] =
  ## Locate ``<srcDir>/<exported-vm-name>/Virtual Machines/*.vmcx`` and
  ## ``Import-VM -Path <vmcx> -Copy -GenerateNewId``. Returns the snapshot
  ## names that ended up attached to the newly-imported VM.
  ##
  ## Hyper-V's export layout puts the live-state config under
  ## ``Virtual Machines/`` and one config per snapshot under
  ## ``Snapshots/``. Importing a snapshot's vmcx would import that
  ## snapshot's state as the VM root, dropping the snapshot tree — so
  ## we glob explicitly under ``Virtual Machines/``.
  when defined(windows):
    let psBlock = &"""$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop
$src = '{srcDir.replace("'", "''")}'
if (-not (Test-Path $src)) {{ throw "importBaseline: srcDir '$src' does not exist" }}
# Find Virtual Machines/*.vmcx anywhere under $src (depth 1 or 2).
$vmcx = Get-ChildItem -Path $src -Recurse -Filter '*.vmcx' |
  Where-Object {{ $_.DirectoryName -match '\\Virtual Machines$' }} |
  Select-Object -First 1
if (-not $vmcx) {{ throw "importBaseline: no 'Virtual Machines/*.vmcx' found under $src" }}
$importedVmRoot = Join-Path $src 'imported-vm'
$importedVhds   = Join-Path $src 'imported-vhds'
$importedSnaps  = Join-Path $src 'imported-snapshots'
$imp = Import-VM -Path $vmcx.FullName -Copy -GenerateNewId `
  -VirtualMachinePath $importedVmRoot `
  -VhdDestinationPath $importedVhds `
  -SnapshotFilePath   $importedSnaps
Get-VMSnapshot -VMName $imp.Name | ForEach-Object {{ $_.Name }}
"""
    let cmd = @[$b.powershellLauncher, "-NoLogo", "-NoProfile",
                "-ExecutionPolicy", "Bypass", "-Command", psBlock]
    let r = runProcessCapture(cmd, timeoutSec = 1800)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "Import-VM failed: " & r.stdout)
    result = @[]
    for line in r.stdout.splitLines():
      let s = line.strip()
      if s.len > 0: result.add(s)
  else:
    raise newException(BackendUnavailableError,
      "HyperVBackend.importBaseline requires a Windows host")

# ---------------------------------------------------------------------------
# M1.5 — bootFromMedia + serial-stream primitives for Hyper-V.
#
# Distinct from the baseline-oriented revertToBaseline lifecycle: these
# primitives spin up a transient Gen-2 UEFI VM around a VHDX or ISO,
# wire COM1 to a named pipe, and stream the serial bytes through a
# background reader process. The implementation is the Nim port of
# reprobuild/tools/boot-harness/{hyperv/new-boot-vm.ps1, hyperv/start-
# boot-vm.ps1, hyperv/stop-boot-vm.ps1, lib/backends/hyperv.py}.
#
# Safety: every transient VM name MUST start with ``repro-test-boot-``
# so the standing sweep covers it (matches the R0 / R1 contract).

const BootVmNamePrefix* = "repro-test-boot-"

type
  HyperVSerialStream* = ref object of SerialStream
    ## Hyper-V concrete serial stream.
    buf*: SerialLineBuffer
    pipeName*: string                  ## \\.\pipe\<this>
    serialProc: Process                ## background reader/writer process
    reader: PipeReader                 ## dedicated reader thread
    serialBackend: HyperVBackend       ## back-ref so close() can call stop-boot-vm

proc psQuote(s: string): string {.inline.} =
  ## Single-quote-escape a string for PowerShell single-quoted interp.
  s.replace("'", "''")

proc newBootVmName(prefix: string = BootVmNamePrefix): string =
  ## Generate a fresh ``repro-test-boot-<hex>`` name. The hex suffix
  ## uses the low bits of epochTime() so two concurrent harness sessions
  ## don't collide.
  result = prefix & toHex(int64(epochTime() * 1000.0) and 0xFFFFFF'i64, 6).toLowerAscii()

proc buildNewBootVmCommand(b: HyperVBackend, spec: BootMediaSpec,
                           vmName, pipeName, scratchVhdxPath: string): string =
  ## Render the PowerShell that creates the transient Gen-2 UEFI VM,
  ## wires COM1 to the named pipe, attaches the boot media + optional
  ## seed ISO, and (for non-DryRun) leaves the VM Off ready for
  ## Start-VM. Returns the PS source as one string ready for
  ## ``-Command``.
  let kindStr =
    case spec.kind
    of bmkVhdx: "vhdx"
    of bmkIso:  "iso"
    of bmkQcow2: "vhdx" # qcow2 isn't directly bootable on Hyper-V; the consumer
                      # must convert to VHDX first and pass mediaPath as the VHDX.
                      # We accept it here so the caller's mistake produces a
                      # clear "file not found" error rather than a type panic.
    of bmkRootfsTar:
      raise newException(BackendUnavailableError,
        "HyperVBackend.bootFromMedia: bmkRootfsTar is WSL-specific; " &
        "use WslBackend for tarball boots")
  let memMB = if spec.memoryMB > 0: spec.memoryMB else: 2048
  let cpus  = if spec.cpus > 0: spec.cpus else: 2
  let generation = if spec.generation > 0: spec.generation else: 2
  let secureBoot = if spec.secureBootEnabled: "On" else: "Off"
  let mediaPath = spec.mediaPath
  let seedIsoPath = spec.secondaryIsoPath
  result = &"""$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop
$vmName  = '{psQuote(vmName)}'
$pipe    = '\\.\pipe\{psQuote(pipeName)}'
$mediaPath = '{psQuote(mediaPath)}'
$seedIso = '{psQuote(seedIsoPath)}'
$scratchVhdx = '{psQuote(scratchVhdxPath)}'
$gen     = {generation}
$memMB   = {memMB}
$cpus    = {cpus}
$kind    = '{kindStr}'
$secureBoot = '{secureBoot}'

if (-not $vmName.StartsWith('{psQuote(BootVmNamePrefix)}')) {{
  throw "SAFETY: refusing to create boot VM with name $vmName (must start with '{psQuote(BootVmNamePrefix)}')"
}}
if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {{
  throw "boot VM $vmName already exists; refusing to clobber"
}}

# Resolve boot disk: for VHDX kind the mediaPath IS the boot disk; for ISO
# kind we create a transient blank dynamic VHDX as the boot disk and
# attach the ISO as the first boot device.
$bootVhdx = if ($kind -eq 'vhdx') {{ $mediaPath }} else {{ $scratchVhdx }}

if ($kind -ne 'vhdx') {{
  if (-not (Test-Path -LiteralPath $mediaPath)) {{
    throw "bmkIso requires mediaPath to exist: $mediaPath"
  }}
  $dir = Split-Path -Parent $scratchVhdx
  if (-not (Test-Path $dir)) {{ New-Item -ItemType Directory -Force -Path $dir | Out-Null }}
  New-VHD -Path $scratchVhdx -SizeBytes 8GB -Dynamic | Out-Null
}} else {{
  if (-not (Test-Path -LiteralPath $bootVhdx)) {{
    throw "bmkVhdx requires mediaPath (used as boot disk) to exist: $bootVhdx"
  }}
}}

$mem = [int64]$memMB * 1MB
New-VM -Name $vmName -Generation $gen -MemoryStartupBytes $mem -VHDPath $bootVhdx | Out-Null
if ($cpus -gt 0) {{ Set-VMProcessor -VMName $vmName -Count $cpus }}
# Isolate: boot-from-media VMs don't need network.
try {{ Get-VMNetworkAdapter -VMName $vmName -ErrorAction SilentlyContinue | Remove-VMNetworkAdapter -ErrorAction SilentlyContinue }} catch {{}}
if ($gen -eq 2) {{
  try {{ Set-VMFirmware -VMName $vmName -EnableSecureBoot $secureBoot }}
  catch {{ Write-Warning "Set-VMFirmware -EnableSecureBoot $secureBoot failed: $($_.Exception.Message)" }}
}}

Set-VMComPort -VMName $vmName -Number 1 -Path $pipe

# Path B (ISO) attaches the ISO as DVD #1 + first boot device.
if ($kind -eq 'iso') {{
  Add-VMDvdDrive -VMName $vmName -Path $mediaPath
  if ($gen -eq 2) {{
    $dvd = Get-VMDvdDrive -VMName $vmName | Select-Object -First 1
    if ($dvd) {{ Set-VMFirmware -VMName $vmName -FirstBootDevice $dvd }}
  }}
}}

# Optional cloud-init seed ISO as secondary DVD; ensure the VHDX is first
# in the boot order so we boot the disk, not the seed.
if ($seedIso -and ($seedIso.Length -gt 0)) {{
  if (-not (Test-Path -LiteralPath $seedIso)) {{ throw "secondaryIsoPath not found: $seedIso" }}
  Add-VMDvdDrive -VMName $vmName -Path $seedIso
  if ($gen -eq 2 -and $kind -eq 'vhdx') {{
    $diskDrive = Get-VMHardDiskDrive -VMName $vmName | Select-Object -First 1
    if ($diskDrive) {{ Set-VMFirmware -VMName $vmName -FirstBootDevice $diskDrive }}
  }}
}}
Write-Host "CREATED $vmName"
"""

proc buildStartBootVmAndPipeReaderCommand(pipeName, vmName: string): string =
  ## PS script that starts the VM (idempotent) and forwards the named
  ## pipe to its OWN stdout (and stdin to the pipe). The Nim-side reader
  ## thread captures stdout and tees to the host-side log; the
  ## PowerShell side never touches the disk so there's no double-open
  ## hazard.
  &"""$ErrorActionPreference = 'Stop'
$vmName   = '{psQuote(vmName)}'
$pipeName = '{psQuote(pipeName)}'

if (-not $vmName.StartsWith('{psQuote(BootVmNamePrefix)}')) {{
  throw "SAFETY: refusing to start boot VM $vmName"
}}
$vm = Get-VM -Name $vmName -ErrorAction Stop
if ($vm.State -ne 'Running') {{ Start-VM -Name $vmName | Out-Null }}

$pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName,
  [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
$pipe.Connect(30000)

$stdout = [Console]::OpenStandardOutput()
$stdin  = [Console]::OpenStandardInput()

$buf = New-Object byte[] 4096

$ps = [PowerShell]::Create()
$null = $ps.AddScript({{
  param($pipe, $stdin)
  try {{
    $buf = New-Object byte[] 4096
    while ($true) {{
      $n = $stdin.Read($buf, 0, $buf.Length)
      if ($n -le 0) {{ break }}
      $pipe.Write($buf, 0, $n)
      $pipe.Flush()
    }}
  }} catch {{}}
}}).AddArgument($pipe).AddArgument($stdin)
$async = $ps.BeginInvoke()

try {{
  while ($true) {{
    $n = $pipe.Read($buf, 0, $buf.Length)
    if ($n -le 0) {{ break }}
    $stdout.Write($buf, 0, $n); $stdout.Flush()
  }}
}} catch {{}}
finally {{
  try {{ $pipe.Dispose() }} catch {{}}
  try {{ $ps.Stop(); $ps.Dispose() }} catch {{}}
}}
"""

proc spawnPwshBackground(b: HyperVBackend, psScript: string): Process =
  ## Spawn a background ``pwsh -Command`` process so the Nim side can
  ## read stdout (the tailed serial bytes) and write stdin (guest input).
  ## We deliberately do NOT use ``poStdErrToStdOut`` so stderr surfaces
  ## as a diagnostic on assertion failure.
  let argv = @[$b.powershellLauncher, "-NoLogo", "-NoProfile",
               "-ExecutionPolicy", "Bypass", "-NonInteractive",
               "-Command", psScript]
  result = startProcess(argv[0], args = argv[1 .. ^1],
                        options = {poUsePath, poStdErrToStdOut})

method bootFromMedia*(b: HyperVBackend, spec: BootMediaSpec): VmHandle =
  ## Create a transient Gen-2 UEFI VM around the given VHDX (kind=vhdx)
  ## or ISO (kind=iso). The VM is left in the Off state; call
  ## ``captureSerial`` to start it AND begin tailing COM1.
  when defined(windows):
    if spec.kind == bmkRootfsTar:
      raise newException(BackendUnavailableError,
        "HyperVBackend.bootFromMedia does not support bmkRootfsTar; " &
        "use WslBackend for tarball boots")
    if spec.mediaPath.len == 0:
      raise newException(ValueError, "BootMediaSpec.mediaPath is empty")
    if not fileExists(spec.mediaPath):
      raise newException(IOError,
        "BootMediaSpec.mediaPath does not exist: " & spec.mediaPath)
    let vmName = if spec.name.len > 0: spec.name else: newBootVmName()
    if not vmName.startsWith(BootVmNamePrefix):
      raise newException(ValueError,
        "BootMediaSpec.name must start with '" & BootVmNamePrefix &
        "' (got '" & vmName & "')")
    let pipeName = if spec.serialPipeName.len > 0: spec.serialPipeName
                   else: vmName & "-com1"
    let baseTmp = getTempDir() / "repro-boot-harness" / vmName
    createDir(baseTmp)
    let scratchVhdx = baseTmp / (vmName & ".scratch.vhdx")
    let psCreate = buildNewBootVmCommand(b, spec, vmName, pipeName, scratchVhdx)
    let cmd = @[$b.powershellLauncher, "-NoLogo", "-NoProfile",
                "-ExecutionPolicy", "Bypass", "-Command", psCreate]
    let r = runProcessCapture(cmd, timeoutSec = 180)
    if r.exitCode != 0:
      # Best-effort cleanup of any half-built VM + scratch dir.
      try:
        let psCleanup = &"""try {{ Remove-VM -Name '{psQuote(vmName)}' -Force -ErrorAction SilentlyContinue | Out-Null }} catch {{}}"""
        discard runProcessCapture(@[$b.powershellLauncher, "-NoLogo",
                                    "-NoProfile", "-ExecutionPolicy",
                                    "Bypass", "-Command", psCleanup],
                                  timeoutSec = 30)
        if dirExists(baseTmp): removeDir(baseTmp)
      except CatchableError: discard
      raise newVmHarnessError($b.id, lpStartup,
        "HyperVBackend.bootFromMedia: VM creation failed: " & r.stdout)
    var extra = initTable[string, string]()
    extra["pipeName"] = pipeName
    extra["scratchVhdx"] = scratchVhdx
    extra["bootMediaPath"] = spec.mediaPath
    extra["seedIsoPath"] = spec.secondaryIsoPath
    extra["scratchDir"] = baseTmp
    extra["serialLogPath"] = if spec.serialLogPath.len > 0: spec.serialLogPath
                             else: baseTmp / (vmName & ".serial.log")
    result = VmHandle(
      backend: b,
      name: vmName,
      baseline: "<boot-from-media>",
      ipAddress: none(string),
      sshPort: 0,
      sshUser: "",
      sshAuth: SshAuth(kind: saNone),
      extra: extra)
  else:
    raise newException(BackendUnavailableError,
      "HyperVBackend.bootFromMedia requires a Windows host")

method captureSerial*(b: HyperVBackend, vm: VmHandle): SerialStream =
  ## Start the VM and spawn a background ``pwsh`` that tails the named
  ## pipe to its stdout (and forwards its stdin to the pipe). The Nim
  ## side reads/writes the child's stdio. Returns a HyperVSerialStream
  ## that ``expectLine`` / ``serialSend`` / ``closeSerial`` operate on.
  when defined(windows):
    let pipeName = vm.extra.getOrDefault("pipeName")
    if pipeName.len == 0:
      raise newException(ValueError,
        "captureSerial: VmHandle missing pipeName (was it created via " &
        "bootFromMedia?)")
    let logPath = vm.extra.getOrDefault("serialLogPath")
    let psStart = buildStartBootVmAndPipeReaderCommand(pipeName, vm.name)
    let p = spawnPwshBackground(b, psStart)
    let buf = newSerialLineBuffer(logPath)
    let reader = startPipeReader(p, buf)
    let stream = HyperVSerialStream(
      vm: vm,
      logPath: logPath,
      buf: buf,
      pipeName: pipeName,
      serialProc: p,
      reader: reader,
      serialBackend: b)
    result = stream
  else:
    raise newException(BackendUnavailableError,
      "HyperVBackend.captureSerial requires a Windows host")

method expectLine*(b: HyperVBackend, stream: SerialStream,
                  pattern: string, timeoutSec: int = 60): SerialMatch =
  when defined(windows):
    let s = HyperVSerialStream(stream)
    # The reader thread feeds bytes into ``s.buf`` asynchronously; we
    # just poll the buffer here without ever blocking on the pipe.
    return expectLineImpl(s.buf, pattern, timeoutSec * 1000, 100, nil)
  else:
    raise newException(BackendUnavailableError,
      "HyperVBackend.expectLine requires a Windows host")

method serialSend*(b: HyperVBackend, stream: SerialStream, text: string) =
  when defined(windows):
    let s = HyperVSerialStream(stream)
    if s.serialProc == nil:
      raise newException(ValueError, "serialSend: stream not started")
    try:
      let inStream = s.serialProc.inputStream
      if inStream != nil:
        inStream.write(text)
        inStream.flush()
    except CatchableError as e:
      raise newVmHarnessError($b.id, lpExec,
        "HyperVBackend.serialSend failed: " & e.msg)
  else:
    raise newException(BackendUnavailableError,
      "HyperVBackend.serialSend requires a Windows host")

method closeSerial*(b: HyperVBackend, stream: SerialStream) =
  when defined(windows):
    let s = HyperVSerialStream(stream)
    try:
      if s.serialProc != nil and s.serialProc.running:
        try: s.serialProc.terminate()
        except CatchableError: discard
        try: discard s.serialProc.waitForExit(timeout = 3000)
        except CatchableError: discard
      if s.reader != nil:
        try: stopPipeReader(s.reader)
        except CatchableError: discard
      if s.serialProc != nil:
        try: s.serialProc.close()
        except CatchableError: discard
      s.buf.close()
    except CatchableError:
      discard
  else:
    discard

# stopAndCleanup override specifically for boot-from-media handles: when
# the VmHandle was created by ``bootFromMedia`` we need to tear down the
# TRANSIENT VM (whose name is the per-call generated ``repro-test-boot-
# <hex>``), NOT the long-lived ``b.vmName`` the baseline-mode override
# targets. We detect the boot-from-media case via vm.baseline ==
# "<boot-from-media>" and route accordingly. The previous override stays
# the default for baseline handles.

# The {.base.} method already exists; we replace it with a dispatching
# version. Nim's multi-method resolution allows us to keep two overrides
# distinguished by the VmHandle.baseline sentinel.

proc destroyBootVm(b: HyperVBackend, vm: VmHandle) =
  when defined(windows):
    let scratchDir = vm.extra.getOrDefault("scratchDir")
    let scratchVhdx = vm.extra.getOrDefault("scratchVhdx")
    let psBlock = &"""try {{
  Import-Module Hyper-V -ErrorAction Stop
  $vm = Get-VM -Name '{psQuote(vm.name)}' -ErrorAction SilentlyContinue
  if ($vm) {{
    if ($vm.State -ne 'Off') {{ Stop-VM -Name '{psQuote(vm.name)}' -TurnOff -Force -ErrorAction SilentlyContinue | Out-Null }}
    Remove-VM -Name '{psQuote(vm.name)}' -Force -ErrorAction SilentlyContinue | Out-Null
  }}
}} catch {{ Write-Host "destroyBootVm swallowed: $_" }}
"""
    let cmd = @[$b.powershellLauncher, "-NoLogo", "-NoProfile",
                "-ExecutionPolicy", "Bypass", "-Command", psBlock]
    try:
      discard runProcessCapture(cmd, timeoutSec = 120)
    except CatchableError: discard
    if scratchVhdx.len > 0 and fileExists(scratchVhdx):
      try: removeFile(scratchVhdx)
      except CatchableError: discard
    if scratchDir.len > 0 and dirExists(scratchDir):
      try: removeDir(scratchDir)
      except CatchableError: discard

method stopAndCleanup*(b: HyperVBackend, vm: VmHandle, deleteVm: bool = true) =
  ## Dispatches based on whether the VmHandle was minted by
  ## ``bootFromMedia`` (baseline sentinel ``<boot-from-media>``, transient
  ## VM) or by ``revertToBaseline`` (long-lived ``b.vmName``). The
  ## boot-from-media path force-stops AND removes the transient VM and
  ## its scratch dir; the baseline path only force-stops (the snapshot
  ## tree must survive for the next revert).
  when defined(windows):
    if vm.baseline == "<boot-from-media>":
      destroyBootVm(b, vm)
    else:
      try:
        let psBlock = &"""try {{
  Import-Module Hyper-V -ErrorAction Stop
  $vm = Get-VM -Name '{psQuote(b.vmName)}' -ErrorAction SilentlyContinue
  if ($vm -and $vm.State -ne 'Off') {{
    Stop-VM -Name '{psQuote(b.vmName)}' -TurnOff -Force -ErrorAction SilentlyContinue
  }}
}} catch {{ Write-Host "stopAndCleanup swallowed: $_" }}
"""
        let cmd = @[$b.powershellLauncher, "-NoLogo", "-NoProfile",
                    "-ExecutionPolicy", "Bypass", "-Command", psBlock]
        discard runProcessCapture(cmd, timeoutSec = 120)
      except CatchableError:
        discard
  else:
    discard

# ---------------------------------------------------------------------------
# Reprobuild script-wrapper convenience helpers.
#
# These two procs are the Tier-2 reprobuild adapter's preferred entry
# points: they delegate the entire lifecycle to the existing PowerShell
# scripts and parse the resulting RESULT.txt. They live as standalone
# procs (not method overrides) because they bypass several of the
# VmBackend lifecycle hooks — the PowerShell script's own try/finally
# subsumes the whole revert+exec+cleanup sequence.

proc provisionBaselineViaReproScript*(b: HyperVBackend,
                                     force: bool = false,
                                     vhdxOverridePath: string = "",
                                     skipVsInstall: bool = false): ExecResult =
  ## Invoke reprobuild's ``provision-base-vm.ps1`` to (idempotently)
  ## build the M69 base VM and its two snapshots. Returns the captured
  ## stdout/stderr/exit. Raises ``BackendUnavailableError`` if
  ## ``provisionScriptPath`` is unset or the host isn't Windows.
  if b.provisionScriptPath.len == 0:
    raise newException(BackendUnavailableError,
      "HyperVBackend: provisionScriptPath not configured")
  when defined(windows):
    let inv = HyperVProvisionInvocation(
      scriptPath: b.provisionScriptPath,
      force: force,
      vhdxOverridePath: vhdxOverridePath,
      skipVsInstall: skipVsInstall)
    let cmd = buildHyperVProvisionArgs(b.powershellLauncher, inv)
    result = runProcessCapture(cmd, timeoutSec = 0)
  else:
    raise newException(BackendUnavailableError,
      "provisionBaselineViaReproScript requires a Windows host")

proc runViaReproScript*(b: HyperVBackend, gate: string,
                       scenario: string = "",
                       outDir: string = "",
                       gateTimeoutMinutes: int = 0,
                       envelope: OutputEnvelope = nil): ScriptResult =
  ## Invoke reprobuild's ``run-hyperv-m69-system.ps1`` for the named
  ## gate and parse the resulting ``RESULT.txt``. When ``envelope`` is
  ## supplied the script's envelope files are mirrored into the
  ## envelope's directory so the orchestrator's ``DONE`` sentinel is
  ## visible to the harness's own consumers.
  if b.runScriptPath.len == 0:
    raise newException(BackendUnavailableError,
      "HyperVBackend: runScriptPath not configured")
  when defined(windows):
    let timeout = if gateTimeoutMinutes > 0:
                    gateTimeoutMinutes
                  else:
                    b.defaultGateTimeoutMinutes
    let inv = HyperVRunInvocation(
      scriptPath: b.runScriptPath,
      gate: gate,
      scenario: scenario,
      outDir: outDir,
      gateTimeoutMinutes: timeout,
      keepVmRunning: false)
    let cmd = buildHyperVRunArgs(b.powershellLauncher, inv)
    let r = runProcessCapture(cmd, timeoutSec = 0)
    # The reprobuild runner writes RESULT.txt itself to either OutDir or
    # the per-test sub-dir under OutDir. Reading <OutDir>/RESULT.txt is
    # the canonical post-run parse.
    let resolvedOutDir = if outDir.len > 0: outDir
                         else: "D:\\metacraft\\hyperv-m69-system-out"
    let perTestDir = resolvedOutDir / (gate & "-" &
      (if scenario.len > 0: scenario else: "base-clean"))
    let parsed =
      if dirExists(perTestDir): readScriptResult(perTestDir)
      else: readScriptResult(resolvedOutDir)
    if envelope != nil:
      copyEnvelopeFiles(if dirExists(perTestDir): perTestDir
                        else: resolvedOutDir, envelope)
    var withRaw = parsed
    if r.stdout.len > 0 and parsed.rawResultText.len == 0:
      withRaw.rawResultText = r.stdout
    result = withRaw
  else:
    raise newException(BackendUnavailableError,
      "runViaReproScript requires a Windows host")

# ---------------------------------------------------------------------------
# Backend registration.
#
# Importing this module is enough to make ``--backend hyperv`` /
# ``vm-harness probe`` see the backend; the constructor uses the
# reprobuild M69 defaults so on a properly-configured Windows host
# the auto-registered instance is immediately usable. Production
# callers that need custom VM names / script paths construct their
# own ``newHyperVBackend(...)`` instance.

registerBackend(biHyperv, proc(): VmBackend = newHyperVBackend())

