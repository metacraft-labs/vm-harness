import std/[os, strutils, tempfiles, unittest]
import vm_harness/backends/tart
import vm_harness/types

when defined(posix):
  import std/posix

proc writeExecutable(path, body: string) =
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

suite "Tart backend commands":
  when defined(macosx):
    test "defaults to the system OpenSSH transport on macOS":
      let backend = newTartBackend(guestOs = goMacos)
      check backend.sshCmd == "/usr/bin/ssh"
      check backend.scpCmd == "/usr/bin/scp"

  when defined(posix):
    test "background Tart run remains in the provider-owned process group":
      let tmp = createTempDir("vmh-tart-unit-", "")
      defer: removeDir(tmp)
      let tart = tmp / "tart"
      writeExecutable(tart, "#!/bin/sh\nexec sleep 60\n")

      let backend = newTartBackend(guestOs = goMacos, tartCmd = tart)
      let pid = backend.runTartVmInBackground("ephemeral")
      defer: discard posix.kill(Pid(pid), SIGTERM)
      sleep(100)

      check getpgid(Pid(pid)) == getpgrp()

  test "clone randomizes the ephemeral MAC before boot":
    let tmp = createTempDir("vmh-tart-unit-", "")
    defer: removeDir(tmp)
    let log = tmp / "tart.log"
    let tart = tmp / "tart"
    writeExecutable(tart, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '" & log & "'\n")

    let backend = newTartBackend(guestOs = goMacos, tartCmd = tart)
    backend.cloneTartVm("golden", "ephemeral")

    check readFile(log).splitLines() == @[
      "clone golden ephemeral",
      "set ephemeral --random-mac",
      ""]

  test "failed MAC randomization deletes the unusable clone":
    let tmp = createTempDir("vmh-tart-unit-", "")
    defer: removeDir(tmp)
    let log = tmp / "tart.log"
    let tart = tmp / "tart"
    writeExecutable(tart, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '" & log & "'\n" &
      "if [ \"$1\" = set ]; then exit 9; fi\n")

    let backend = newTartBackend(guestOs = goMacos, tartCmd = tart)
    expect VmHarnessError:
      backend.cloneTartVm("golden", "ephemeral")
    check "delete ephemeral" in readFile(log)

  test "SCP retries a transient authentication failure":
    let tmp = createTempDir("vmh-tart-unit-", "")
    defer: removeDir(tmp)
    let attempts = tmp / "attempts"
    let scp = tmp / "scp"
    let sshpass = tmp / "sshpass"
    let src = tmp / "payload"
    writeFile(src, "payload")
    writeExecutable(sshpass, "#!/bin/sh\nshift 2\nexec \"$@\"\n")
    writeExecutable(scp, "#!/bin/sh\n" &
      "count=0\n" &
      "[ ! -f '" & attempts & "' ] || count=$(cat '" & attempts & "')\n" &
      "count=$((count + 1))\n" &
      "printf '%s' \"$count\" > '" & attempts & "'\n" &
      "[ \"$count\" -ge 2 ]\n")

    let backend = newTartBackend(
      guestOs = goMacos, scpCmd = scp, sshpassCmd = sshpass)
    backend.scpCopy("192.0.2.1", src, "/tmp/payload",
      toGuest = true, recursive = false, timeoutSec = 10)
    check readFile(attempts) == "2"
