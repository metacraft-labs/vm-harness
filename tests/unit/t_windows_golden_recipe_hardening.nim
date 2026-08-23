## Static gates on the Windows golden answer files.
##
## Two defects were found on the live x64 golden after it had been in the
## field for weeks, and both are properties of the recipe rather than of the
## host:
##
##   1. the `admin` account was created with a password that expired 42 days
##      later (the local `MaxPasswordAge` default), which kills the SSH
##      retrofit route the recipes document as *the* way to touch an
##      already-built golden; and
##   2. the guest kept Windows' default sleep idle timer, so a runner that
##      stayed busy long enough suspended itself (S3) part-way through a job.
##
## Neither can be *fully* proven outside a booted guest: only Windows can say
## that `net accounts` really made the password non-expiring, or that
## `powercfg` really cleared the idle timer. What is provable here — and what
## these tests hold — is that the directive exists, in an answer-file pass
## that actually executes, ahead of the long-running steps that can strand
## the rest of the chain, inside a well-formed file whose `Order` sequences
## are contiguous and whose command lengths stay inside the unattend limits
## (259 chars for `RunSynchronousCommand/Path`, 1024 for
## `SynchronousCommand/CommandLine`). A recipe that passes these can still be
## defeated by Windows; a recipe that fails them cannot possibly work.
##
## A third defect, found the same way: the goldens ship only Windows
## PowerShell 5.1 and every ephemeral `eph-win-x64` job that reached a
## `shell: pwsh` step died with `pwsh: command not found`. The
## "PowerShell 7 is on the machine PATH" suite at the bottom of this file
## holds the recipe side of that fix, on exactly the terms above: the
## install step exists, is pinned by version AND SHA-256, verifies before
## it extracts, writes the PATH the way a SERVICE will read it, and is
## refused by a gate if any of that failed.

import std/[os, sequtils, streams, strutils, unittest, xmlparser, xmltree]

const
  # Machine-wide policy: no local account's password expires, including
  # accounts created after capture (cloudbase-init / GARM runner accounts).
  MaxPasswordAgeDirective = "net.exe accounts /maxpwage:unlimited"
  # Per-account belt: ADS_UF_DONT_EXPIRE_PASSWD on `admin` itself, so a later
  # policy change cannot silently re-arm the expiry. ADSI rather than
  # Set-LocalUser because the LocalAccounts module is not dependable on
  # Windows-on-ARM.
  AdminAccountAdsiPath = "WinNT://./admin,user"
  DontExpirePasswordFlag = "-bor 0x10000"
  HibernateOffDirective = "powercfg.exe /hibernate off"
  HibernateOffCmdDirective = "powercfg /hibernate off"

  PowerTimeouts = [
    "standby-timeout-ac", "standby-timeout-dc",
    "hibernate-timeout-ac", "hibernate-timeout-dc",
    "monitor-timeout-ac", "monitor-timeout-dc",
    "disk-timeout-ac", "disk-timeout-dc",
  ]

  # Documented unattend limits. Exceeding them is not a lint nit: Windows
  # Setup rejects the answer file (or silently truncates the command), which
  # on this recipe means an image captured without the directive.
  MaxRunSynchronousPathLen = 259
  MaxFirstLogonCommandLen = 1024

proc recipeFile(recipe, name: string): string =
  currentSourcePath().parentDir.parentDir.parentDir /
    "guest-recipes" / recipe / name

proc answerFile(recipe, name: string): XmlNode =
  parseXml(newStringStream(readFile(recipeFile(recipe, name))))

proc childElement(node: XmlNode, tag: string): XmlNode =
  for child in node:
    if child.kind == xnElement and child.tag == tag:
      return child

proc textContent(node: XmlNode): string =
  case node.kind
  of xnText, xnVerbatimText, xnCData, xnEntity:
    result = node.text
  of xnElement:
    for child in node:
      result.add child.textContent()
  else:
    discard

proc elementText(node: XmlNode, tag: string): string =
  let child = node.childElement(tag)
  if child != nil:
    result = child.textContent()

proc collectElements(node: XmlNode, tag: string, acc: var seq[XmlNode]) =
  if node.kind == xnElement and node.tag == tag:
    acc.add node
  for child in node:
    if child.kind == xnElement:
      collectElements(child, tag, acc)

proc elements(node: XmlNode, tag: string): seq[XmlNode] =
  collectElements(node, tag, result)

proc componentIn(xml: XmlNode, pass, component: string): XmlNode =
  for settings in xml.elements("settings"):
    if settings.attr("pass") != pass:
      continue
    for candidate in settings.elements("component"):
      if candidate.attr("name") == component:
        return candidate

proc firstLogonCommands(xml: XmlNode): seq[XmlNode] =
  let component = xml.componentIn("oobeSystem", "Microsoft-Windows-Shell-Setup")
  if component == nil:
    return
  let firstLogon = component.childElement("FirstLogonCommands")
  if firstLogon != nil:
    result = firstLogon.elements("SynchronousCommand")

proc specializeRunSynchronous(xml: XmlNode): seq[XmlNode] =
  let component = xml.componentIn("specialize", "Microsoft-Windows-Deployment")
  if component == nil:
    return
  let runSynchronous = component.childElement("RunSynchronous")
  if runSynchronous != nil:
    result = runSynchronous.elements("RunSynchronousCommand")

proc commandLines(commands: seq[XmlNode]): seq[string] =
  commands.mapIt(it.elementText("CommandLine"))

proc paths(commands: seq[XmlNode]): seq[string] =
  commands.mapIt(it.elementText("Path"))

## Index of the first command whose payload contains `needle`, or -1.
proc indexOfCommand(payloads: seq[string], needle: string): int =
  result = -1
  for i, payload in payloads:
    if needle in payload:
      return i

## Every element that has `Order`-bearing children, paired with those orders.
## Windows applies the commands in `Order` sequence and a gap (or a repeat,
## which is what a hand-renumbered insert produces) makes Setup skip or
## re-run a step, so contiguity is a correctness property of the file, not
## tidiness.
proc orderedGroups(node: XmlNode, acc: var seq[(string, seq[string])]) =
  if node.kind != xnElement:
    return
  var orders: seq[string]
  for child in node:
    if child.kind == xnElement and child.childElement("Order") != nil:
      orders.add child.elementText("Order").strip()
  if orders.len > 0:
    acc.add (node.tag, orders)
  for child in node:
    orderedGroups(child, acc)

proc orderedGroups(xml: XmlNode): seq[(string, seq[string])] =
  orderedGroups(xml, result)

const AnswerFiles = [
  ("windows-x64-base", "autounattend.xml"),
  ("windows-x64-base", "rearm-unattend.xml"),
  ("windows-arm-base", "autounattend.xml"),
  ("windows-arm-base", "repro-sysprep.xml"),
]

suite "Windows golden answer files are well-formed and hardened":

  test "every answer file parses and every Order sequence is contiguous from 1":
    for (recipe, name) in AnswerFiles:
      let xml = answerFile(recipe, name)
      for (container, orders) in xml.orderedGroups():
        let expected = toSeq(1 .. orders.len).mapIt($it)
        checkpoint recipe & "/" & name & " <" & container & ">"
        check orders == expected

  test "no command exceeds the unattend length limits":
    for (recipe, name) in AnswerFiles:
      let xml = answerFile(recipe, name)
      for command in xml.elements("RunSynchronousCommand"):
        checkpoint recipe & "/" & name & ": " & command.elementText("Description")
        check command.elementText("Path").len <= MaxRunSynchronousPathLen
      for command in xml.elements("SynchronousCommand"):
        checkpoint recipe & "/" & name & ": " & command.elementText("Description")
        check command.elementText("CommandLine").len <= MaxFirstLogonCommandLen

  test "windows-x64 golden creates an admin account whose password cannot expire":
    # The field failure: the golden's `admin` password expired 2026-08-03,
    # 42 days after capture, and Windows then refuses password auth — which
    # is exactly the `ssh admin@<ip>` route README.md documents as THE way
    # to retrofit an already-built golden. The account is created in the
    # oobeSystem pass, so the fix has to run after that: FirstLogonCommands.
    let payloads = answerFile("windows-x64-base", "autounattend.xml").
      firstLogonCommands().commandLines()
    let idx = payloads.indexOfCommand(MaxPasswordAgeDirective)
    check idx >= 0
    if idx >= 0:
      check AdminAccountAdsiPath in payloads[idx]
      check DontExpirePasswordFlag in payloads[idx]

  test "windows-x64 golden disables sleep, hibernation and idle timeouts":
    # The field failure: a runner suspended to S3 mid-job. Jobs used to die
    # in ~90s and never reached the idle timer; 30-minute jobs do.
    let payloads = answerFile("windows-x64-base", "autounattend.xml").
      firstLogonCommands().commandLines()
    let idx = payloads.indexOfCommand(HibernateOffDirective)
    check idx >= 0
    if idx >= 0:
      # Both rails: a VM has no battery, but Windows still applies the DC
      # profile when the hypervisor exposes no AC adapter.
      for timeout in PowerTimeouts:
        checkpoint timeout
        check timeout in payloads[idx]

  test "windows-x64 hardening runs before the steps that can strand the chain":
    # FirstLogonCommands run in sequence; the OpenSSH download in step 2 is
    # the one step that can block for minutes on a NAT'd guest. Both
    # hardening steps need neither network nor staged media, so they go
    # first — a chain that never gets past the download still yields an
    # image with a usable credential and no sleep timer.
    let payloads = answerFile("windows-x64-base", "autounattend.xml").
      firstLogonCommands().commandLines()
    let password = payloads.indexOfCommand(MaxPasswordAgeDirective)
    let power = payloads.indexOfCommand(HibernateOffDirective)
    let download = payloads.indexOfCommand("OpenSSH-Win64.zip")
    check password >= 0
    check power >= 0
    check download >= 0
    check password < download
    check power < download

  test "windows-arm golden applies the same credential and power hardening":
    # windows-arm-base/autounattend.xml shares the x64 shape: same `admin`
    # LocalAccount with no expiry control, same absence of a power policy.
    let payloads = answerFile("windows-arm-base", "autounattend.xml").
      firstLogonCommands().commandLines()
    let password = payloads.indexOfCommand(MaxPasswordAgeDirective)
    check password >= 0
    if password >= 0:
      check AdminAccountAdsiPath in payloads[password]
      check DontExpirePasswordFlag in payloads[password]

    let power = payloads.indexOfCommand(HibernateOffDirective)
    check power >= 0
    if power >= 0:
      for timeout in PowerTimeouts:
        checkpoint timeout
        check timeout in payloads[power]

  test "windows-arm clone answer file re-hardens the account it re-creates":
    # repro-sysprep.xml re-creates `admin` on every clone, which restarts
    # the expiry clock — so fixing the golden alone would leave every clone
    # expiring 42 days after it was cloned.
    let payloads = answerFile("windows-arm-base", "repro-sysprep.xml").
      firstLogonCommands().commandLines()
    let password = payloads.indexOfCommand(MaxPasswordAgeDirective)
    check password >= 0
    if password >= 0:
      check AdminAccountAdsiPath in payloads[password]
      check DontExpirePasswordFlag in payloads[password]

    let power = payloads.indexOfCommand(HibernateOffDirective)
    check power >= 0
    if power >= 0:
      for timeout in PowerTimeouts:
        checkpoint timeout
        check timeout in payloads[power]

  test "windows-x64 clone answer file re-asserts hardening in the specialize pass":
    # rearm-unattend.xml deliberately has no AutoLogon and no
    # FirstLogonCommands: a headless clone may never see an interactive
    # logon, so a FirstLogonCommand there could sit unexecuted forever.
    # specialize runs as SYSTEM during mini-setup on every clone, so the
    # re-assert goes there instead.
    let xml = answerFile("windows-x64-base", "rearm-unattend.xml")
    check xml.firstLogonCommands().len == 0

    let specialize = xml.specializeRunSynchronous().paths()
    check specialize.len > 0
    check specialize.indexOfCommand(MaxPasswordAgeDirective) >= 0
    check specialize.indexOfCommand(AdminAccountAdsiPath) >= 0
    check specialize.indexOfCommand(DontExpirePasswordFlag) >= 0
    check specialize.indexOfCommand(HibernateOffCmdDirective) >= 0
    for timeout in PowerTimeouts:
      checkpoint timeout
      check specialize.indexOfCommand(timeout) >= 0

  test "hardening cannot abort the chain it runs in":
    # Same contract as the rest of these recipes: a hardening step that
    # exits non-zero would take OOBE (or, in the specialize pass, the whole
    # clone boot) down with it.
    for (recipe, name) in AnswerFiles:
      let xml = answerFile(recipe, name)
      for payload in xml.firstLogonCommands().commandLines():
        if MaxPasswordAgeDirective in payload or
           HibernateOffDirective in payload:
          checkpoint recipe & "/" & name
          check payload.endsWith("exit 0\"")
      for payload in xml.specializeRunSynchronous().paths():
        if MaxPasswordAgeDirective in payload:
          checkpoint recipe & "/" & name
          check payload.endsWith("exit 0\"")
        if HibernateOffCmdDirective in payload:
          checkpoint recipe & "/" & name
          check payload.endsWith("exit /b 0")


# ---------------------------------------------------------------------------
# PowerShell 7 (`pwsh`) provisioning
# ---------------------------------------------------------------------------
# THE FIELD FAILURE. Every ephemeral `eph-win-x64` job that reached a
# `shell: pwsh` step failed with:
#
#     ##[error]pwsh: command not found
#
# The goldens ship Windows PowerShell 5.1 (5.1.22621.x) and nothing ever
# installed PowerShell 7. GitHub-hosted Windows images bundle `pwsh`, so
# workflows written against the ecosystem's defaults assume it, and the
# Actions runner resolves a step's shell by EXECUTABLE NAME — `powershell.exe`
# cannot stand in for `pwsh.exe` however compatible the script body is.
#
# `pwsh.exe` is also required as a plain executable, independently of any
# step's `shell:`: metacraft-github-actions/setup-dev-env generates a
# `dev-exec.cmd` trampoline that shells out to `pwsh`, codetracer's bootstrap
# smoke job runs `pwsh -File ...` from inside other steps, and
# codetracer-native-recorder's Justfile sets `windows-shell := pwsh.exe`. So
# rewriting workflows to `shell: powershell` would not remove the dependency;
# the binary has to be in the image.
#
# What follows is the recipe half of that fix, asserted on the same terms as
# the Git provisioning: the pin exists and is a real checksum, the checksum is
# enforced BEFORE anything is extracted or run, the PATH is written the way
# the Service Control Manager will read it, the step cannot wedge the chain it
# runs in, and a gate refuses to capture an image where any of that failed.
# Whether `pwsh -v` actually answers for `NT AUTHORITY\SYSTEM` in session 0 is
# guest-only; the gate proves that, not this file.

proc libFile(name: string): string =
  currentSourcePath().parentDir.parentDir.parentDir /
    "guest-recipes" / "lib" / name

## A missing file reads as empty rather than raising: every assertion below
## then fails on its own terms, naming the token it wanted, instead of one
## IOError aborting the binary and hiding the rest of the verdict.
proc readLib(name: string): string =
  let path = libFile(name)
  if fileExists(path): readFile(path) else: ""

proc readRecipe(recipe, name: string): string =
  let path = recipeFile(recipe, name)
  if fileExists(path): readFile(path) else: ""

## `check`'s failure output prints its operands, and one operand here is a
## whole script. These templates keep the verdict readable: the checkpoint
## names the file and the missing token, and the assertion itself is a bool.
template mustContain(haystack: string, needle: string, label: string) =
  block:
    let found = needle in haystack
    if not found:
      checkpoint label & ": expected to contain " & strutils.escape(needle)
    check found

template mustNotContain(haystack: string, needle: string, label: string) =
  block:
    let absent = needle notin haystack
    if not absent:
      checkpoint label & ": expected NOT to contain " & strutils.escape(needle)
    check absent

## The value of a `$Name = 'value'` pin assignment, parsed exactly the way
## guest-recipes/lib/fetch-powershell.sh parses it: one line, single-quoted.
## Returns "" when the assignment is absent or reshaped — which is precisely
## what makes the shell-side parser refuse to fetch anything.
proc pinValue(script, name: string): string =
  for rawLine in script.splitLines():
    let line = rawLine.strip()
    if not line.startsWith("$" & name):
      continue
    let rest = line[("$" & name).len .. ^1].strip()
    if not rest.startsWith("="):
      continue
    let afterEq = rest[1 .. ^1].strip()
    if not afterEq.startsWith("'"):
      continue
    let closing = afterEq.find('\'', start = 1)
    if closing < 0:
      continue
    return afterEq[1 ..< closing]

proc isLowerHex64(s: string): bool =
  s.len == 64 and s.allIt(it in {'0' .. '9', 'a' .. 'f'})

proc isDottedVersion(s: string): bool =
  let parts = s.split('.')
  parts.len >= 3 and parts.allIt(it.len > 0 and it.allIt(it in {'0' .. '9'}))

## The script with whole-line comments removed. Negative assertions run
## against this: these recipes document their traps at length, and naming a
## forbidden API in prose must stay legal while using it must not.
proc codeOnly(script: string): string =
  var kept: seq[string]
  for rawLine in script.splitLines():
    if rawLine.strip().startsWith("#"):
      continue
    kept.add rawLine
  kept.join("\n")

## Non-comment lines containing `needle`. Several assertions below care about
## the line that DOES a thing, not merely that the file mentions it somewhere:
## a mutation-test run found that `MachineEnvKey`, `DoNotExpandEnvironmentNames`
## and `RegistryValueKind]::ExpandString` each appear more than once (in prose,
## and in a later read-back check), so a whole-file `contains` stayed green with
## the actual write mutated.
proc codeLinesWith(script, needle: string): seq[string] =
  for rawLine in script.splitLines():
    let line = rawLine.strip()
    if line.startsWith("#"):
      continue
    if needle in line:
      result.add line

## Non-comment lines that invoke the named PowerShell variable as a native
## command. Comments are skipped deliberately: these recipes explain the
## quoting traps at length, and quoting a forbidden form in prose is fine.
proc invocationsOf(script, varName: string): seq[string] =
  for rawLine in script.splitLines():
    let line = rawLine.strip()
    if line.startsWith("#"):
      continue
    if ("& $" & varName) in line:
      result.add line

## Non-comment lines that INVOKE the named cmdlet as a statement, as opposed
## to merely naming it inside a string. A gate is allowed — and expected — to
## quote `Remove-MpPreference …` in its failure message as the operator's
## remedy; what it must not do is call it. A bare `contains` cannot tell those
## apart, so anchor on the statement position: an invocation begins the line,
## whereas the message occurrence sits behind an opening quote.
proc invokesCmdlet(script, cmdlet: string): seq[string] =
  for rawLine in script.splitLines():
    let line = rawLine.strip()
    if line.startsWith("#"):
      continue
    if line.startsWith(cmdlet) or line.startsWith("| " & cmdlet):
      result.add line

## Index of the FirstLogonCommand that runs provision-pwsh.ps1 with an
## explicit -Arch, or -1. The staging copy also names the script, so the
## -Arch flag is what distinguishes the invocation from the copy.
proc pwshInvocationIndex(payloads: seq[string]): int =
  result = -1
  for i, payload in payloads:
    if "provision-pwsh.ps1" in payload and "-Arch" in payload:
      return i

const
  PwshInstallDir = "C:\\pwsh"
  # The machine environment block the Service Control Manager reads ONCE at
  # boot and hands to every service it launches — including the Actions
  # runner. This, and not the current process's $env:Path, is the property
  # that survives capture.
  MachineEnvKey = "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment"

suite "Windows goldens put PowerShell 7 on the machine PATH":

  test "provision-pwsh.ps1 pins a version and a per-architecture SHA-256":
    # A floating "latest PowerShell" download would make the golden
    # non-reproducible, which is the one property these images exist to have.
    # The pin is also the only thing between a tampered or truncated download
    # and code running as SYSTEM inside the image the whole fleet clones.
    check fileExists(libFile("provision-pwsh.ps1"))
    let script = readLib("provision-pwsh.ps1")
    const label = "provision-pwsh.ps1"

    let version = script.pinValue("PwshVersion")
    checkpoint label & ": PwshVersion = " & strutils.escape(version)
    check version.isDottedVersion()

    let x64 = script.pinValue("PwshSha256X64")
    checkpoint label & ": PwshSha256X64 = " & strutils.escape(x64)
    check x64.isLowerHex64()

    let arm64 = script.pinValue("PwshSha256Arm64")
    checkpoint label & ": PwshSha256Arm64 = " & strutils.escape(arm64)
    check arm64.isLowerHex64()

    # Two different assets cannot share a checksum. If they do, one pin was
    # pasted over the other and one architecture is effectively unverified.
    checkpoint label & ": the x64 and arm64 pins must differ"
    check x64 != arm64

    # The pin must actually address the release it claims to, by version.
    script.mustContain(
      "github.com/PowerShell/PowerShell/releases/download/v$PwshVersion/", label)
    script.mustContain("PowerShell-$PwshVersion-win-x64.zip", label)
    script.mustContain("PowerShell-$PwshVersion-win-arm64.zip", label)

  test "provision-pwsh.ps1 verifies the checksum before it extracts":
    # Ordering is the whole point: a hash computed after extraction proves
    # nothing, because the untrusted bytes are already on disk by then.
    let script = readLib("provision-pwsh.ps1").codeOnly()
    # The `throw`, not just the hashing: what has to precede extraction is the
    # point where a bad archive STOPS, and it is the throw that stops it.
    let hashAt = script.find("(Get-FileHash -LiteralPath $archive")
    let throwAt = script.find("throw \"SHA-256 mismatch")
    let extractAt = script.find("]::ExtractToDirectory(")
    checkpoint "provision-pwsh.ps1: Get-FileHash at " & $hashAt &
      ", mismatch throw at " & $throwAt & ", ExtractToDirectory at " & $extractAt
    check hashAt >= 0
    check throwAt >= 0
    check extractAt >= 0
    check hashAt < extractAt
    check throwAt < extractAt

  test "provision-pwsh.ps1 writes the MACHINE PATH as raw REG_EXPAND_SZ":
    # The Actions runner is a SERVICE. services.exe builds one environment
    # block at boot from HKLM Session Manager\Environment; a user-scoped or
    # process-scoped PATH is invisible to it forever. The value must also
    # stay REG_EXPAND_SZ and be read WITHOUT expansion, or this build host's
    # %SystemRoot% is baked into every clone's PATH.
    let script = readLib("provision-pwsh.ps1")
    const label = "provision-pwsh.ps1"
    script.codeOnly().mustContain(MachineEnvKey, label & " (code)")
    script.codeOnly().mustContain(PwshInstallDir, label & " (code)")

    # The WRITE itself must name ExpandString. Asserting only that the token
    # appears somewhere is satisfied by the read-back check further down, which
    # leaves the write free to demote the value to REG_SZ.
    let writes = script.codeLinesWith("SetValue(\'Path\'")
    checkpoint label & ": found " & $writes.len & " machine-PATH writes"
    check writes.len > 0
    for w in writes:
      w.mustContain("RegistryValueKind]::ExpandString", label & " PATH write")

    # Likewise EVERY read of the value must suppress expansion, not just one of
    # them: a single expanding read is enough to bake this build host's
    # %SystemRoot% into the value that gets written back.
    # Likewise EVERY read of the value must suppress expansion, not just one of
    # them: a single expanding read is enough to bake this build host's
    # %SystemRoot% into the value that gets written back. These calls wrap
    # across two lines, so scan each call's text up to its closing paren
    # rather than line by line.
    let code = script.codeOnly()
    var readIdx = 0
    var expandingReads = 0
    while true:
      let at = code.find("GetValue(", readIdx)
      if at < 0: break
      let close = code.find(')', start = at)
      let call = if close > at: code[at .. close] else: code[at .. ^1]
      if "\'Path\'" in call and "DoNotExpandEnvironmentNames" notin call:
        expandingReads.inc
        checkpoint label & ": expanding read of the machine PATH: " & call
      readIdx = at + 1
    checkpoint label & ": machine-PATH reads that would expand tokens"
    check expandingReads == 0

    # setx.exe truncates a PATH past 2047 chars, which would brick the image
    # for every process on it, so the write goes through the registry API.
    script.codeOnly().mustNotContain("setx", label & " (code)")
    # [Environment]::SetEnvironmentVariable(..., 'Machine') EXPANDS the value
    # it round-trips, which is the same defect under another name.
    script.codeOnly().mustNotContain("SetEnvironmentVariable", label & " (code)")

  test "provision-pwsh.ps1 cannot wedge the chain it runs in":
    # It runs from FirstLogonCommands, where a non-zero exit can strand the
    # rest of the chain — including the install-done sentinel and the
    # shutdown that signals install-complete. So it exits 0 even on failure,
    # which is only safe because the gate below refuses to capture the image.
    let script = readLib("provision-pwsh.ps1")
    const label = "provision-pwsh.ps1"
    script.mustContain("vmh-pwsh-provision-failed", label)
    script.mustContain("vmh-pwsh-provision-done", label)
    # The last statement of the catch block, so no path out of it can carry a
    # non-zero status back to Windows Setup.
    checkpoint label & ": the catch block must end with `exit 0`"
    check script.strip().endsWith("exit 0\n}")

  test "provision-pwsh.ps1 avoids the PowerShell 5.1 native-quoting trap":
    # This script is executed BY `powershell.exe` (5.1) from an answer file.
    # 5.1 does not escape double quotes embedded in an argument when it builds
    # a native command line, so `& $exe -Command "<script>"` arrives mangled.
    # That exact bug once shipped a verification probe that failed on every
    # image while saying nothing about its subject. Handing the child a FILE
    # path — no spaces, no quotes — makes every argument-passing mode produce
    # the same argv.
    let calls = readLib("provision-pwsh.ps1").invocationsOf("pwshExe")
    checkpoint "provision-pwsh.ps1: found " & $calls.len & " `& $pwshExe` calls"
    check calls.len > 0
    for call in calls:
      call.mustContain("-File", "provision-pwsh.ps1 pwsh invocation")
      call.mustNotContain("-Command", "provision-pwsh.ps1 pwsh invocation")
      call.mustNotContain("\"", "provision-pwsh.ps1 pwsh invocation")

  test "assert-pwsh-provisioned.ps1 gates the property services depend on":
    # "pwsh.exe is on disk" is not the property that matters. "The machine
    # PATH a service will inherit contains it" is.
    check fileExists(libFile("assert-pwsh-provisioned.ps1"))
    let gate = readLib("assert-pwsh-provisioned.ps1")
    const label = "assert-pwsh-provisioned.ps1"

    # All of these run against CODE, not prose: this gate's header explains the
    # mechanism at length and quotes the same registry key, so a whole-file
    # `contains` stays green even with the check itself removed.
    let gateCode = gate.codeOnly()
    gateCode.mustContain("vmh-pwsh-provision-failed", label & " (code)")
    gateCode.mustContain(MachineEnvKey, label & " (code)")
    gateCode.mustContain("DoNotExpandEnvironmentNames", label & " (code)")
    gateCode.mustContain("RegistryValueKind]::ExpandString", label & " (code)")
    gateCode.mustContain(PwshInstallDir, label & " (code)")
    # A gate that cannot fail is documentation.
    gateCode.mustContain("exit 1", label & " (code)")

    # Same 5.1 trap: the gate is run by powershell.exe too, and a gate that
    # fails for a quoting reason says nothing about its subject.
    let calls = gate.invocationsOf("pwshExe")
    checkpoint label & ": found " & $calls.len & " `& $pwshExe` calls"
    check calls.len > 0
    for call in calls:
      call.mustContain("-File", label & " pwsh invocation")
      call.mustNotContain("-Command", label & " pwsh invocation")
      call.mustNotContain("\"", label & " pwsh invocation")

  test "the x64 golden stages and runs provision-pwsh.ps1":
    let payloads = answerFile("windows-x64-base", "autounattend.xml").
      firstLogonCommands().commandLines()

    let staged = payloads.indexOfCommand("provision-pwsh.ps1")
    checkpoint "windows-x64-base: staging step index " & $staged
    check staged >= 0

    let invoked = payloads.pwshInvocationIndex()
    checkpoint "windows-x64-base: invocation step index " & $invoked
    check invoked >= 0
    if invoked >= 0:
      payloads[invoked].mustContain("-Arch x64", "windows-x64-base invocation")
      # The copy to C: has to happen before the script is run from C:.
      checkpoint "windows-x64-base: staging must precede invocation"
      check staged <= invoked
      checkpoint "windows-x64-base: invocation must end with `exit 0\"`"
      check payloads[invoked].endsWith("exit 0\"")

  test "x64 pwsh provisioning runs after the hardening that must not be stranded":
    # The download is a multi-minute step. The credential and power hardening
    # need neither network nor staged media, so they stay ahead of it: a chain
    # that never gets past a stalled download still yields an image with a
    # usable credential and no sleep timer.
    let payloads = answerFile("windows-x64-base", "autounattend.xml").
      firstLogonCommands().commandLines()
    let password = payloads.indexOfCommand(MaxPasswordAgeDirective)
    let power = payloads.indexOfCommand(HibernateOffDirective)
    let pwsh = payloads.pwshInvocationIndex()
    checkpoint "indices: password=" & $password & " power=" & $power &
      " pwsh=" & $pwsh
    check password >= 0
    check power >= 0
    check pwsh >= 0
    check password < pwsh
    check power < pwsh

  test "the arm golden stages provision-pwsh.ps1 and selects the arm64 asset":
    # windows-arm-base has its install media detached by the time
    # FirstLogonCommands run, so both scripts are copied to C: during the
    # SPECIALIZE pass — the same shape provision-git.ps1 uses there.
    let xml = answerFile("windows-arm-base", "autounattend.xml")
    let payloads = xml.firstLogonCommands().commandLines()

    let invoked = payloads.pwshInvocationIndex()
    checkpoint "windows-arm-base: invocation step index " & $invoked
    check invoked >= 0
    if invoked >= 0:
      payloads[invoked].mustContain("-Arch arm64", "windows-arm-base invocation")
      checkpoint "windows-arm-base: invocation must end with `exit 0\"`"
      check payloads[invoked].endsWith("exit 0\"")

    var stagedProvision = false
    var stagedGate = false
    for path in xml.specializeRunSynchronous().paths():
      if "provision-pwsh.ps1" in path and "C:\\Windows\\Temp" in path:
        stagedProvision = true
      if "assert-pwsh-provisioned.ps1" in path and "C:\\Windows\\Temp" in path:
        stagedGate = true
    checkpoint "windows-arm-base: provision-pwsh.ps1 staged in specialize"
    check stagedProvision
    # That recipe is captured by a MANUAL sysprep, so the gate has to already
    # be inside the guest or nobody can run it.
    checkpoint "windows-arm-base: assert-pwsh-provisioned.ps1 staged in specialize"
    check stagedGate

  test "the golden build refuses to capture an image without pwsh":
    # provision-pwsh.ps1 exits 0 on failure. This is what makes that safe.
    let build = readRecipe("windows-x64-base", "build-sysprep-golden.sh")
    const label = "build-sysprep-golden.sh"
    let buildCode = build.codeOnly()
    buildCode.mustContain("assert-pwsh-provisioned.ps1", label & " (code)")
    buildCode.mustContain("VMH_SKIP_PWSH_GATE", label & " (code)")

    # The gate's failure must ABORT the build, not warn and continue -- and the
    # abort must be the one guarding the GATE RUN, not the incidental
    # "gate script not found" guard. Anchor on the message so a mutation that
    # swaps `fail` for `log` there cannot hide behind the other line.
    let aborts = buildCode.codeLinesWith("PowerShell 7 gate FAILED")
    checkpoint label & ": found " & $aborts.len &
      " lines reporting a failed pwsh gate"
    check aborts.len == 1
    for a in aborts:
      a.mustContain("fail \"", label & " pwsh-gate abort")

  test "both ISO builders stage provision-pwsh.ps1 and its gate":
    # Assert the COPY, not a mention. Both names also appear in these scripts'
    # existence preflight, so a whole-file `contains` stays green with the
    # staging removed -- which would ship an ISO whose guest has nothing to run.
    for recipe in ["windows-x64-base", "windows-arm-base"]:
      let iso = readRecipe(recipe, "build-autounattend-iso.sh").codeOnly()
      let label = recipe & "/build-autounattend-iso.sh"
      for script in ["provision-pwsh.ps1", "assert-pwsh-provisioned.ps1"]:
        let staging = iso.codeLinesWith("${STAGE_DIR}/" & script)
        checkpoint label & ": staging lines for " & script & ": " & $staging.len
        check staging.len > 0
        for line in staging:
          line.mustContain("cp \"${LIB_DIR}/" & script & "\"", label)

  test "fetch-powershell.sh reads the pin instead of duplicating it":
    # Two copies of a checksum is one copy too many: the day they diverge the
    # host stages one build and the guest verifies another.
    check fileExists(libFile("fetch-powershell.sh"))
    let fetch = readLib("fetch-powershell.sh")
    const label = "fetch-powershell.sh"
    fetch.mustContain("provision-pwsh.ps1", label)
    fetch.mustContain("PwshVersion", label)
    fetch.mustContain("PwshSha256X64", label)
    fetch.mustContain("PwshSha256Arm64", label)

    # The checksums themselves must NOT be repeated here.
    let script = readLib("provision-pwsh.ps1")
    fetch.mustNotContain(script.pinValue("PwshSha256X64"), label)
    fetch.mustNotContain(script.pinValue("PwshSha256Arm64"), label)

  test "provision-pwsh.ps1 does not bake a dangling Defender exclusion into the golden":
    # Found by inspecting a live clone of the promoted golden, 2026-08-23:
    #
    #     Get-MpPreference -> ExclusionPath:
    #       C:\pwsh
    #       C:\Windows\Temp\vmh-pwsh-extract-6752
    #
    # The second one is this script's own PID-named staging directory. It is
    # added before the extract and never removed, so it is CAPTURED into the
    # image and inherited by every ephemeral runner cloned from it -- pointing
    # at a directory that stopped existing the moment the tree was moved into
    # place.
    #
    # That is not merely untidy. Windows reuses PIDs freely, so any later
    # process that happens to draw 6752 recreates that exact path, and it is
    # then an UNSCANNED directory under C:\Windows\Temp on a machine whose
    # whole job is executing pull-request code. The image ships an
    # antivirus hole whose address is a lottery number.
    #
    # The `C:\pwsh` exclusion is deliberate and stays: MsMpEng quarantines
    # pwsh.exe as a `PUA:Win32/PowerShellCore` false positive. What must not
    # survive the run is the STAGING exclusion.
    check fileExists(libFile("provision-pwsh.ps1"))
    let script = readLib("provision-pwsh.ps1")
    const label = "provision-pwsh.ps1"

    # Non-vacuity: this test is meaningless if the staging path is gone or
    # renamed, so locate it first and fail loudly rather than pass on nothing.
    let stagingLines = script.codeLinesWith("vmh-pwsh-extract-")
    checkpoint label & ": lines naming the staging directory: " & $stagingLines.len
    check stagingLines.len > 0

    let added = script.codeLinesWith("Add-MpPreference")
    checkpoint label & ": Add-MpPreference lines: " & $added.len
    check added.len > 0

    let removed = script.codeLinesWith("Remove-MpPreference")
    checkpoint label & ": Remove-MpPreference lines: " & $removed.len
    check removed.len > 0

    # The removal must name the staging variable, not $InstallDir -- removing
    # the wrong one would drop the false-positive protection and leave the
    # dangling rule exactly where it was.
    var removesStaging = false
    for line in removed:
      if "$staging" in line:
        removesStaging = true
    checkpoint label & ": a Remove-MpPreference names $staging: " & $removesStaging
    check removesStaging

    var removesInstallDir = false
    for line in removed:
      if "$InstallDir" in line:
        removesInstallDir = true
    checkpoint label & ": no Remove-MpPreference names $InstallDir: " & $(not removesInstallDir)
    check not removesInstallDir

    # Ordering: the exclusion has to outlive the extract (that is what it is
    # for) and must not outlive the move into place.
    let code = script.codeOnly()
    let extractAt = code.find("]::ExtractToDirectory(")
    let moveAt = code.find("Move-Item -LiteralPath $staging")
    let removeAt = code.find("Remove-MpPreference -ExclusionPath $staging")
    checkpoint label & ": extract at " & $extractAt & ", move at " & $moveAt &
      ", exclusion removed at " & $removeAt
    check extractAt > 0
    check moveAt > 0
    check removeAt > 0
    check extractAt < removeAt
    check moveAt < removeAt

## ---------------------------------------------------------------------------
## The image-side half of the dangling-exclusion defect.
##
## The suite above holds the RECIPE: provision-pwsh.ps1 now scopes its staging
## exclusion to the extract and drops it in a `finally`. That is necessary and
## not sufficient, and the gap is the whole lesson of this incident.
##
## A recipe fix reaches the fleet only when a golden is next BUILT or
## RETROFITTED. The already-promoted `golden-win11-cloudbase.qcow2` still
## carried
##
##     Get-MpPreference -> ExclusionPath:
##       C:\pwsh
##       C:\Windows\Temp\vmh-pwsh-extract-6752
##
## weeks after the recipe was correct, and every `eph-win-x64` clone inherited
## it. Nothing anywhere refused to ship that image -- which is precisely how it
## got promoted in the first place, and precisely what the pwsh and Git gates
## exist to prevent for their own properties.
##
## So these tests hold the missing gate, on the same terms as the others: they
## cannot prove Windows really dropped the rule (only a booted guest can say
## that, and one did), but they prove the golden build REFUSES to capture an
## image that still has one, that the gate tests the general invariant rather
## than one PID, and that it cannot pass by finding nothing.
suite "Windows goldens ship no Defender exclusion that outlived its directory":

  const DefenderGate = "assert-defender-exclusions-sane.ps1"

  test "the Defender gate asserts an invariant, not the one PID that was found":
    # The stale rule was `vmh-pwsh-extract-6752`. The NEXT one will carry a
    # different PID, from a different run, possibly from a recipe that does not
    # exist yet. A gate that greps for 6752 -- or for `vmh-pwsh-extract-` --
    # would pass the next golden while it shipped the same hole.
    check fileExists(libFile(DefenderGate))
    let gate = readLib(DefenderGate)
    const label = DefenderGate
    let code = gate.codeOnly()

    # The mechanism: enumerate ExclusionPath, and decide by whether the path
    # EXISTS. Both halves are load-bearing, so both are asserted on code.
    code.mustContain("ExclusionPath", label & " (code)")
    code.mustContain("Test-Path", label & " (code)")
    code.mustContain("Get-MpPreference", label & " (code)")
    # A gate that cannot fail is documentation.
    code.mustContain("exit 1", label & " (code)")

    # The specific PID, and the staging prefix, must not appear in CODE. The
    # header explains the incident and names both, which is why this runs
    # against codeOnly() rather than the whole file.
    code.mustNotContain("6752", label & " (code)")
    code.mustNotContain("vmh-pwsh-extract", label & " (code)")

    # Finding a stale rule must FAIL the gate, not merely narrate it. The
    # script has several `exit 1`s (the non-vacuity refusals), so asserting
    # "an exit 1 exists" does not pin THIS branch: a mutation swapping the
    # stale branch's `Fail` for an `Info` would sail past it and leave a gate
    # that reports the defect and then certifies the image anyway. Anchor on
    # the stale branch actually reaching a Fail.
    let staleAt = code.find("$stale.Count -gt 0")
    let failAfterStale = code.find("Fail (", start = max(staleAt, 0))
    checkpoint label & ": stale branch at " & $staleAt &
      ", next Fail( at " & $failAfterStale
    check staleAt > 0
    check failAfterStale > staleAt

  test "the Defender gate cannot pass by finding nothing":
    # The failure mode that matters for a checker like this: a broken
    # Get-MpPreference, a Defender-less SKU, or a mistyped property all yield
    # an empty list, and "no stale exclusions" then reads exactly like "no
    # exclusions were examined". The gate must refuse to certify a list it
    # could not read.
    let gate = readLib(DefenderGate)
    const label = DefenderGate
    let code = gate.codeOnly()

    # It proves the cmdlet is actually there before trusting an empty answer.
    code.mustContain("Get-Command Get-MpPreference", label & " (code)")
    # A throw from Get-MpPreference must be a failure, not a silent empty list.
    code.mustContain("catch", label & " (code)")
    # And a $null result must not be read as "zero exclusions, all fine".
    code.mustContain("$null -eq $prefs", label & " (code)")

    # Each of those three refusals must reach an `exit 1`. Counting them keeps
    # a mutation that turns one into a warning from hiding behind the others.
    let exits = code.codeLinesWith("exit 1")
    checkpoint label & ": lines that exit 1: " & $exits.len
    check exits.len >= 1

    # It must report how many it examined, so a zero is visible in the log
    # rather than indistinguishable from success.
    code.mustContain("examined ", label & " (code)")

  test "the Defender gate keeps the exclusions that are deliberate":
    # `C:\pwsh` exists on purpose: MsMpEng quarantines pwsh.exe as a
    # `PUA:Win32/PowerShellCore` false positive, so dropping that exclusion
    # would brick every `shell: pwsh` step -- a worse defect than the one being
    # fixed. The gate must therefore never remove or rewrite anything, and must
    # not require the list to be empty.
    let gate = readLib(DefenderGate)
    const label = DefenderGate
    let code = gate.codeOnly()

    # A gate mutates nothing. These are the APIs that would.
    #
    # Checked as INVOCATIONS, not as substrings: the failure message quotes
    # `Remove-MpPreference -ExclusionPath '<path>'` on purpose, because an
    # operator reading it needs the remedy. Naming it is right; calling it is
    # not, and only the statement position separates the two.
    for cmdlet in ["Remove-MpPreference", "Set-MpPreference", "Add-MpPreference"]:
      let calls = gate.invokesCmdlet(cmdlet)
      checkpoint label & ": invocations of " & cmdlet & ": " & $calls.len
      check calls.len == 0

    # And it must not smuggle in "the exclusion list must be non-empty" as the
    # invariant. An image legitimately carrying zero exclusions is fine; what
    # the gate rejects is a list it could not READ, which is a different test.
    # (`$stale.Count -gt 0` IS expected — that is the stale-rule branch.)
    code.mustNotContain("$paths.Count -eq 0", label & " (code) empty-list demand")
    code.mustContain("$stale.Count -gt 0", label & " (code) stale branch")

  test "the golden build refuses to capture an image with a stale exclusion":
    # The pwsh gate's argument, applied to the defect that slipped past it.
    let build = readRecipe("windows-x64-base", "build-sysprep-golden.sh")
    const label = "build-sysprep-golden.sh"
    let code = build.codeOnly()

    code.mustContain(DefenderGate, label & " (code)")
    code.mustContain("VMH_SKIP_DEFENDER_GATE", label & " (code)")

    # The gate must be RUN, not merely copied in. Anchor on the invocation.
    let runs = code.codeLinesWith("-File C:\\Windows\\Temp\\" & DefenderGate)
    checkpoint label & ": lines running the Defender gate in the guest: " & $runs.len
    check runs.len == 1

    # Its failure must ABORT the build rather than log and continue -- and the
    # abort asserted here must be the one guarding the GATE RUN, not the
    # incidental "gate script not found" guard. Anchoring on the message keeps
    # a mutation that swaps `fail` for `log` from hiding behind the other line.
    let aborts = code.codeLinesWith("Defender exclusion gate FAILED")
    checkpoint label & ": lines reporting a failed Defender gate: " & $aborts.len
    check aborts.len == 1
    for a in aborts:
      a.mustContain("fail \"", label & " defender-gate abort")

    # The gate must run BEFORE the ~45-minute DISM /ResetBase, so a bad image
    # fails in seconds rather than after the long leg.
    let gateAt = code.find(DefenderGate)
    let resetBaseAt = code.find("/ResetBase")
    checkpoint label & ": Defender gate at " & $gateAt & ", /ResetBase at " & $resetBaseAt
    check gateAt > 0
    check resetBaseAt > 0
    check gateAt < resetBaseAt
