import std/[os, strutils, tempfiles, unittest]
import vm_harness/backends/tart
import vm_harness/types

proc writeExecutable(path, body: string) =
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

suite "Tart backend commands":
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
