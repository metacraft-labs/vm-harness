import std/[os, strutils, tempfiles, unittest]
import vm_harness/cli

suite "CLI Incus lifecycle":
  test "ephemeral-destroy delegates only the named container to Incus":
    when defined(linux):
      let work = createTempDir("vmh-cli-incus", "")
      defer: removeDir(work)
      let logPath = work / "incus.log"
      let fakeIncus = work / "incus"
      writeFile(fakeIncus,
        "#!/bin/sh\n" &
        "printf '%s\\n' \"$*\" >> '" & logPath & "'\n")
      setFilePermissions(fakeIncus, {fpUserRead, fpUserWrite, fpUserExec})

      let previous = getEnv("VMH_INCUS_CMD")
      putEnv("VMH_INCUS_CMD", fakeIncus)
      defer: putEnv("VMH_INCUS_CMD", previous)

      check runCli(@[
        "ephemeral-destroy",
        "--backend", "incus",
        "--baseline", "reproos-only-this",
      ]) == 0
      check readFile(logPath).strip() ==
        "delete --force reproos-only-this"
    else:
      skip()
