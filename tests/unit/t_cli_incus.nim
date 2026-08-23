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

  test "instance operations use typed Incus backend methods":
    when defined(linux):
      let work = createTempDir("vmh-cli-incus-instance", "")
      defer: removeDir(work)
      let logPath = work / "incus.log"
      let statePath = work / "state"
      let fakeIncus = work / "incus"
      let sourcePath = work / "source.txt"
      let pulledPath = work / "pulled.txt"
      writeFile(statePath, "STOPPED\n")
      writeFile(sourcePath, "payload\n")
      writeFile(fakeIncus,
        "#!/bin/sh\n" &
        "printf '%s\\n' \"$*\" >> '" & logPath & "'\n" &
        "case \"$*\" in\n" &
        "  'list reproos-instance --format csv -c s') cat '" & statePath & "' ;;\n" &
        "  'start reproos-instance') printf 'RUNNING\\n' > '" & statePath & "' ;;\n" &
        "  'stop --force reproos-instance') printf 'STOPPED\\n' > '" & statePath & "' ;;\n" &
        "  'exec reproos-instance -- /bin/echo contract') printf 'contract\\n' ;;\n" &
        "esac\n")
      setFilePermissions(fakeIncus, {fpUserRead, fpUserWrite, fpUserExec})

      let previous = getEnv("VMH_INCUS_CMD")
      putEnv("VMH_INCUS_CMD", fakeIncus)
      defer: putEnv("VMH_INCUS_CMD", previous)

      check runCli(@["instance", "start", "--backend", "incus",
                     "reproos-instance"]) == 0
      check runCli(@["instance", "wait", "--backend", "incus",
                     "reproos-instance"]) == 0
      check runCli(@["instance", "exec", "--backend", "incus",
                     "reproos-instance", "--", "/bin/echo", "contract"]) == 0
      check runCli(@["instance", "copy-to", "--backend", "incus",
                     "reproos-instance", sourcePath, "/tmp/source.txt"]) == 0
      check runCli(@["instance", "copy-from", "--backend", "incus",
                     "reproos-instance", "/tmp/result.txt", pulledPath]) == 0
      check runCli(@["instance", "stop", "--backend", "incus",
                     "reproos-instance"]) == 0

      let lines = readFile(logPath).splitLines()
      for expected in [
        "start reproos-instance",
        "exec reproos-instance -- true",
        "exec reproos-instance -- /bin/echo contract",
        "file push " & sourcePath & " reproos-instance/tmp/source.txt",
        "file pull -r reproos-instance/tmp/result.txt " & pulledPath,
        "stop --force reproos-instance",
      ]:
        check expected in lines
    else:
      skip()
