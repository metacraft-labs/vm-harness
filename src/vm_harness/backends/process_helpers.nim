## Shared helpers for backends that drive external processes
## (Hyper-V via PowerShell, WSL via ``wsl.exe``, or by invoking
## reprobuild's existing PowerShell harness scripts).
##
## *Why this module exists separately:* the M1 Hyper-V and WSL backends
## act as Nim adapters around the existing reprobuild PowerShell scripts.
## The actual subprocess invocation is trivial; the load-bearing parts
## are (a) building well-formed argument vectors, (b) parsing the
## ``RESULT.txt`` envelope each script writes, and (c) detecting the
## ``DONE`` sentinel. Those pieces are pure logic; this module exposes
## them as standalone procs so they can be unit-tested on any host —
## including macOS, where the backends themselves cannot actually run.
##
## All procs here are platform-independent; the OS-specific work lives
## in ``hyperv.nim`` and ``wsl.nim``.

import std/[os, strutils]
import ../output

type
  ScriptVerdictKind* = enum
    svPass
    svFail
    svTimeout
    svError
    svUnknown

  ScriptVerdict* = object
    ## Parsed ``VERDICT:`` line from a reprobuild harness ``RESULT.txt``.
    ## Both the PowerShell Hyper-V runner and the bash WSL runner emit
    ## the same shape so a single parser handles both.
    kind*: ScriptVerdictKind
    rawLine*: string
    exitCode*: int            ## populated for FAIL with ``exit=<n>`` suffix
    timeoutMinutes*: int      ## populated for TIMEOUT

  ScriptStep* = object
    ## A single ``step:`` row from a reprobuild ``RESULT.txt`` file.
    ## The reprobuild runners' RESULT.txt format is::
    ##
    ##     <step-name-padded>  <status-or-message>
    ##
    ## (column-aligned, NOT the ``step: foo  status: ok`` shape used by
    ## ``output.recordStep``). We tolerate both forms.
    name*: string
    status*: string
    elapsedMs*: int           ## -1 when the script didn't emit a timing

  ScriptResult* = object
    ## Aggregate of everything we can learn from a reprobuild harness
    ## output directory: the parsed verdict, the ordered step list, and
    ## whether the ``DONE`` sentinel is present.
    done*: bool
    verdict*: ScriptVerdict
    steps*: seq[ScriptStep]
    rawResultText*: string

# ---------------------------------------------------------------------------
# RESULT.txt and DONE parsing

proc parseScriptVerdict*(line: string): ScriptVerdict =
  ## Parse a single ``VERDICT: ...`` line emitted by either
  ## ``run-hyperv-m69-system.ps1`` or ``provision-and-run-m69-posix.sh``.
  ##
  ## Recognised shapes::
  ##
  ##     VERDICT: PASS
  ##     VERDICT: FAIL exit=1
  ##     VERDICT: TIMEOUT after 45 min
  ##     VERDICT: ERROR: <message>
  ##     VERDICT: UNKNOWN
  result.rawLine = line
  result.exitCode = -1
  result.timeoutMinutes = -1
  let stripped = line.strip()
  if not stripped.toLowerAscii.startsWith("verdict:"):
    result.kind = svUnknown
    return
  # Strip the leading "VERDICT:" (case-insensitive).
  var body = stripped[8 .. ^1].strip()
  let upper = body.toUpperAscii
  if upper.startsWith("PASS"):
    result.kind = svPass
  elif upper.startsWith("FAIL"):
    result.kind = svFail
    # Parse `FAIL exit=<n>` or `FAIL: ...`.
    let eq = body.find("exit=")
    if eq >= 0:
      let rest = body[eq + 5 .. ^1].strip()
      var n = ""
      for c in rest:
        if c in {'0'..'9', '-'}:
          n.add c
        else:
          break
      if n.len > 0:
        try: result.exitCode = parseInt(n)
        except ValueError: discard
  elif upper.startsWith("TIMEOUT"):
    result.kind = svTimeout
    # Parse `TIMEOUT after <N> min`.
    let after = body.find(' ')
    if after >= 0:
      let tail = body[after + 1 .. ^1].strip()
      var n = ""
      for c in tail:
        if c in {'0'..'9'}:
          n.add c
        elif n.len > 0:
          break
      if n.len > 0:
        try: result.timeoutMinutes = parseInt(n)
        except ValueError: discard
  elif upper.startsWith("ERROR"):
    result.kind = svError
  else:
    result.kind = svUnknown

proc parseScriptStep*(line: string): ScriptStep =
  ## Parse one row from ``RESULT.txt``. Recognises both the column-aligned
  ## reprobuild form (``<name padded>  <status>``) and the ``step: x
  ## status: y elapsed_ms: z`` form used by vm-harness's own
  ## ``output.recordStep``.
  result.elapsedMs = -1
  let stripped = line.strip()
  if stripped.len == 0:
    return
  if stripped.startsWith("step:"):
    # vm-harness native form.
    let rest = stripped[5 .. ^1].strip()
    let parts = rest.split("  ", maxsplit = 1)
    if parts.len == 0: return
    let nameAndRest = parts[0].split({' ', '\t'}, maxsplit = 1)
    result.name = if nameAndRest.len > 0: nameAndRest[0].strip() else: ""
    if parts.len < 2:
      return
    let tail = parts[1]
    let statusIdx = tail.find("status:")
    if statusIdx >= 0:
      let after = tail[statusIdx + 7 .. ^1].strip()
      let space = after.find({' ', '\t'})
      result.status =
        if space < 0: after else: after[0 ..< space].strip()
    let elapsedIdx = tail.find("elapsed_ms:")
    if elapsedIdx >= 0:
      let after = tail[elapsedIdx + 11 .. ^1].strip()
      var n = ""
      for c in after:
        if c in {'0'..'9'}:
          n.add c
        else:
          break
      if n.len > 0:
        try: result.elapsedMs = parseInt(n)
        except ValueError: discard
    return

  # Reprobuild column-aligned form: split on two or more spaces.
  var splitIdx = -1
  for i in 0 ..< stripped.len - 1:
    if stripped[i] == ' ' and stripped[i + 1] == ' ':
      splitIdx = i
      break
  if splitIdx < 0:
    # No double-space — treat as a name-only row.
    result.name = stripped
    result.status = ""
    return
  result.name = stripped[0 ..< splitIdx].strip()
  result.status = stripped[splitIdx .. ^1].strip()

proc parseScriptResult*(resultTxt: string, donePresent: bool): ScriptResult =
  ## Parse a complete ``RESULT.txt`` document. The leading prose lines
  ## (the runner banner with ``generated:``, ``host:`` etc.) are
  ## skipped. We treat any line starting with a known prelude key as
  ## metadata, anything ``VERDICT:`` as the verdict, and the rest as
  ## step rows.
  result.rawResultText = resultTxt
  result.done = donePresent
  result.verdict = ScriptVerdict(kind: svUnknown, rawLine: "",
                                 exitCode: -1, timeoutMinutes: -1)
  const PreludeKeys = [
    "M69 ", "M83 ", "generated:", "host:", "vm:", "gate:", "scenario:",
    "distro:", "wall-clock", "==="
  ]
  for raw in resultTxt.splitLines():
    let line = raw
    let stripped = line.strip()
    if stripped.len == 0:
      continue
    if stripped.toLowerAscii.startsWith("verdict:"):
      result.verdict = parseScriptVerdict(stripped)
      continue
    var isPrelude = false
    for k in PreludeKeys:
      if stripped.startsWith(k):
        isPrelude = true
        break
    if isPrelude:
      continue
    let step = parseScriptStep(stripped)
    if step.name.len > 0:
      result.steps.add(step)

proc readScriptResult*(outDir: string): ScriptResult =
  ## Convenience wrapper: read ``<outDir>/RESULT.txt`` and check for
  ## the ``DONE`` sentinel. Returns a fully-parsed ``ScriptResult``
  ## populated from disk. Missing files yield an empty result whose
  ## ``verdict.kind`` is ``svUnknown`` and ``done`` is false.
  let resultPath = outDir / "RESULT.txt"
  let donePath = outDir / "DONE"
  let donePresent = fileExists(donePath)
  let resultText =
    if fileExists(resultPath): readFile(resultPath)
    else: ""
  parseScriptResult(resultText, donePresent)

proc toVerdict*(v: ScriptVerdict): Verdict =
  ## Map a reprobuild ``ScriptVerdict`` onto the vm-harness ``Verdict``
  ## enum used by the orchestrator + output envelope.
  case v.kind
  of svPass: vPass
  of svFail: vFail
  of svTimeout: vError      # we surface timeout as ERROR in the envelope
  of svError: vError
  of svUnknown: vIncomplete

# ---------------------------------------------------------------------------
# Command-vector construction for the existing reprobuild scripts.
#
# These helpers exist so the backend modules don't grow string-concatenation
# logic inline (and so we can unit-test the produced argv).

type
  HyperVRunInvocation* = object
    ## Argument vector for invoking ``run-hyperv-m69-system.ps1``.
    scriptPath*: string
    gate*: string             ## ``feature-capability`` | ``vs-installer``
    scenario*: string         ## ``base-clean`` | ``base-with-vs`` (or "")
    outDir*: string           ## host-side output dir
    gateTimeoutMinutes*: int  ## 0 = use script default
    keepVmRunning*: bool

  HyperVProvisionInvocation* = object
    ## Argument vector for invoking ``provision-base-vm.ps1``.
    scriptPath*: string
    force*: bool
    vhdxOverridePath*: string
    skipVsInstall*: bool

  WslRunInvocation* = object
    ## Argument vector for invoking ``run-wsl-m69-posix.ps1``.
    scriptPath*: string
    timeoutMinutes*: int      ## 0 = use script default
    keepDistro*: bool

  PwshLauncher* = enum
    plPwsh = "pwsh"             ## PowerShell 7+
    plPowershell = "powershell" ## Windows PowerShell 5.1

proc buildPwshArgs*(launcher: PwshLauncher, scriptPath: string,
                   scriptArgs: openArray[string]): seq[string] =
  ## Construct the argv for running a PowerShell script.
  ##
  ## Result starts with the launcher name (``pwsh`` or ``powershell``)
  ## followed by the standard hardening flags (``-NoLogo``,
  ## ``-NoProfile``, ``-ExecutionPolicy Bypass``), then ``-File <path>``,
  ## then the user-supplied script args.
  result = @[$launcher, "-NoLogo", "-NoProfile",
             "-ExecutionPolicy", "Bypass",
             "-File", scriptPath]
  for a in scriptArgs:
    result.add(a)

proc buildHyperVRunArgs*(launcher: PwshLauncher,
                        inv: HyperVRunInvocation): seq[string] =
  ## Build the argv for invoking ``run-hyperv-m69-system.ps1``.
  ##
  ## The PowerShell script's parameter surface is::
  ##
  ##   -Gate <feature-capability|vs-installer>
  ##   [-Scenario <base-clean|base-with-vs>]
  ##   [-OutDir <path>]
  ##   [-GateTimeoutMinutes <int>]
  ##   [-KeepVmRunning]
  ##
  ## Empty optional strings and zero ints are omitted so the script's
  ## own defaults apply.
  var scriptArgs = @["-Gate", inv.gate]
  if inv.scenario.len > 0:
    scriptArgs.add(@["-Scenario", inv.scenario])
  if inv.outDir.len > 0:
    scriptArgs.add(@["-OutDir", inv.outDir])
  if inv.gateTimeoutMinutes > 0:
    scriptArgs.add(@["-GateTimeoutMinutes", $inv.gateTimeoutMinutes])
  if inv.keepVmRunning:
    scriptArgs.add("-KeepVmRunning")
  buildPwshArgs(launcher, inv.scriptPath, scriptArgs)

proc buildHyperVProvisionArgs*(launcher: PwshLauncher,
                              inv: HyperVProvisionInvocation): seq[string] =
  ## Build the argv for invoking ``provision-base-vm.ps1``. Surface::
  ##
  ##   [-Force]
  ##   [-VhdxOverridePath <path>]
  ##   [-SkipVsInstall]
  var scriptArgs: seq[string]
  if inv.force:
    scriptArgs.add("-Force")
  if inv.vhdxOverridePath.len > 0:
    scriptArgs.add(@["-VhdxOverridePath", inv.vhdxOverridePath])
  if inv.skipVsInstall:
    scriptArgs.add("-SkipVsInstall")
  buildPwshArgs(launcher, inv.scriptPath, scriptArgs)

proc buildWslRunArgs*(launcher: PwshLauncher,
                     inv: WslRunInvocation): seq[string] =
  ## Build the argv for invoking ``run-wsl-m69-posix.ps1``. Surface::
  ##
  ##   [-TimeoutMinutes <int>]
  ##   [-KeepDistro]
  var scriptArgs: seq[string]
  if inv.timeoutMinutes > 0:
    scriptArgs.add(@["-TimeoutMinutes", $inv.timeoutMinutes])
  if inv.keepDistro:
    scriptArgs.add("-KeepDistro")
  buildPwshArgs(launcher, inv.scriptPath, scriptArgs)

# ---------------------------------------------------------------------------
# wsl.exe argv construction.

type
  WslExecInvocation* = object
    ## Argument vector for ``wsl.exe -d <distro> --user <user> --exec
    ## /bin/bash -c <cmd>``. The ``--exec`` form is preferred over plain
    ## positional because it avoids PowerShell flag-stealing when the
    ## launching process is pwsh, and bypasses login-shell rc files for
    ## predictable env handling.
    distro*: string
    user*: string             ## empty = default user
    workingDir*: string       ## empty = default
    shell*: string            ## defaults to ``/bin/bash`` when empty
    command*: string          ## full shell command line (after ``-c``)

  WslImportInvocation* = object
    ## ``wsl --import <name> <install-dir> <rootfs-tarball> [--version 2]``.
    distroName*: string
    installDir*: string
    rootfsTarball*: string
    version*: int             ## 0 = no --version flag

proc buildWslExecArgs*(inv: WslExecInvocation): seq[string] =
  ## Construct the wsl.exe argv for an in-distro exec call.
  result = @["wsl.exe", "-d", inv.distro]
  if inv.user.len > 0:
    result.add(@["--user", inv.user])
  if inv.workingDir.len > 0:
    result.add(@["--cd", inv.workingDir])
  result.add("--exec")
  let sh = if inv.shell.len > 0: inv.shell else: "/bin/bash"
  result.add(@[sh, "-c", inv.command])

proc buildWslImportArgs*(inv: WslImportInvocation): seq[string] =
  ## Construct the wsl.exe argv for an ``--import`` call.
  result = @["wsl.exe", "--import",
             inv.distroName, inv.installDir, inv.rootfsTarball]
  if inv.version > 0:
    result.add(@["--version", $inv.version])

proc buildWslUnregisterArgs*(distroName: string): seq[string] =
  ## ``wsl --terminate`` followed by ``wsl --unregister`` is the safe
  ## teardown pair. This proc just builds the unregister argv; callers
  ## that want the terminate-first pattern can compose two calls.
  @["wsl.exe", "--unregister", distroName]

proc buildWslTerminateArgs*(distroName: string): seq[string] =
  @["wsl.exe", "--terminate", distroName]

proc buildWslListQuietArgs*(): seq[string] =
  ## ``wsl --list --quiet`` for distro enumeration. Output is UTF-16LE
  ## on Windows; the backend caller is responsible for the encoding
  ## conversion.
  @["wsl.exe", "--list", "--quiet"]

proc parseWslListQuiet*(rawOutput: string): seq[string] =
  ## Parse the output of ``wsl --list --quiet``. Strips BOM, null bytes
  ## (UTF-16 -> ASCII fallback), and whitespace-only lines.
  for raw in rawOutput.splitLines():
    var line = raw
    # Strip UTF-16 stray nulls and BOM marker.
    line = line.replace("\x00", "")
    line = line.replace("\xEF\xBB\xBF", "")
    let s = line.strip()
    if s.len > 0:
      result.add(s)

# ---------------------------------------------------------------------------
# In-distro path translation for WSL.

proc hostPathToWslPath*(hostPath: string): string =
  ## Translate a Windows-style host path (``D:\metacraft\foo``) to the
  ## WSL 9P-mount form (``/mnt/d/metacraft/foo``) so an in-distro shell
  ## can read it. Already-POSIX paths pass through unchanged.
  if hostPath.len >= 2 and hostPath[1] == ':' and hostPath[0] in {'A'..'Z', 'a'..'z'}:
    let drive = ($hostPath[0]).toLowerAscii
    let rest = hostPath[2 .. ^1].replace('\\', '/')
    if rest.len == 0:
      return "/mnt/" & drive
    if rest[0] == '/':
      return "/mnt/" & drive & rest
    return "/mnt/" & drive & "/" & rest
  hostPath

# ---------------------------------------------------------------------------
# Result -> envelope translation.

proc copyEnvelopeFiles*(scriptOutDir: string, envelope: OutputEnvelope) =
  ## After a reprobuild script run completes, mirror its standardized
  ## envelope files (``00-provision.log``, ``02-*-run.txt``,
  ## ``RESULT.txt``, ``DONE``) into the harness output dir. Skipped if
  ## ``scriptOutDir == envelope.dir``.
  if scriptOutDir == envelope.dir:
    return
  if not dirExists(scriptOutDir):
    return
  for kind, path in walkDir(scriptOutDir):
    if kind != pcFile:
      continue
    let name = extractFilename(path)
    let dest = envelope.dir / name
    try:
      copyFile(path, dest)
    except CatchableError:
      discard
