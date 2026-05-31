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

method stopAndCleanup*(b: HyperVBackend, vm: VmHandle, deleteVm: bool = true) =
  ## Always ``Stop-VM -TurnOff -Force`` — never ``Save-VM`` (a
  ## saved-state revert desyncs the snapshot, per the reprobuild
  ## runner's safety comment). Never raises.
  when defined(windows):
    try:
      let psBlock = &"""try {{
  Import-Module Hyper-V -ErrorAction Stop
  $vm = Get-VM -Name '{b.vmName.replace("'", "''")}' -ErrorAction SilentlyContinue
  if ($vm -and $vm.State -ne 'Off') {{
    Stop-VM -Name '{b.vmName.replace("'", "''")}' -TurnOff -Force -ErrorAction SilentlyContinue
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

