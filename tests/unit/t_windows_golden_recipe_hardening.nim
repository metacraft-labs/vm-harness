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
