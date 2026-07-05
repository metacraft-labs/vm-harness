## t_incus_linux_jit_boot (campaign IM2 gate).
##
## Proves the ephemeral LINUX JIT-injection MECHANISM end-to-end on real
## Incus containers, with NO live GitHub (a mock GARM metadata + actions
## endpoint stands in). The container-based analog of the Windows M3 gate
## ``t_windows_golden_jit_boot`` — but simpler: cloud-init is native, the
## runner is a staged tarball, no sysprep / config-drive ISO.
##
##   * a container launched from the ``vmh-linux-runner`` image consumes an
##     INJECTED cloud-init user-data (delivered through the IM1 IncusBackend
##     seam ``incus config set <name> cloud-init.user-data ...``) carrying
##     GARM's Linux JIT bootstrap;
##   * on first boot cloud-init runs the bootstrap AUTONOMOUSLY: it fetches
##     the JIT config from the MOCK GARM metadata endpoint, authorized by a
##     per-instance JWT (a no-JWT request -> 401);
##   * it launches the actions runner via ``run.sh --jitconfig <blob>``,
##     which connects to the mock as its Actions server and creates a runner
##     session (reaches the configured/listening state);
##   * both containers are torn down leaving NO residue.
##
## The flow is orchestrated by the sibling driver
## ``linux-jit/run-linux-jit-gate.sh`` (incus CLI + a stdlib python mock);
## this Nim wrapper discovers the config, runs the driver in the FOREGROUND,
## streams its log, and asserts it reached ``LINUX_JIT_GATE_PASS`` (each
## sub-assertion is a ``PASS (x)`` line the driver emits). It SELF-SKIPS
## cleanly when Incus / the runner image / tooling isn't present.
##
## Config (env):
##   VMH_INCUS_CMD    incus invocation (default incus; use "sudo -n incus"
##                    when the incus-admin group is not active in the session)
##   VMH_RUNNER_ALIAS runner image alias (default vmh-linux-runner)
##
## Run (on a Linux host with Incus + the vmh-linux-runner image):
##   export VMH_INCUS_CMD="sudo -n incus"
##   nim r --hints:off tests/e2e/t_incus_linux_jit_boot.nim

import std/[os, osproc, strutils, unittest]

when not defined(linux):
  echo "[skip] t_incus_linux_jit_boot: Linux host required"
  quit(0)

let scriptDir = currentSourcePath().parentDir / "linux-jit"
let driver = scriptDir / "run-linux-jit-gate.sh"

let incusCmd =
  block:
    let e = getEnv("VMH_INCUS_CMD")
    if e.len > 0: e else: "incus"
let runnerAlias =
  block:
    let e = getEnv("VMH_RUNNER_ALIAS")
    if e.len > 0: e else: "vmh-linux-runner"

proc incusUsable(): bool =
  ## ``<incusCmd> info`` succeeds ⇒ the daemon is reachable.
  let (_, code) = execCmdEx(incusCmd & " info")
  code == 0

proc imagePresent(): bool =
  let (_, code) = execCmdEx(incusCmd & " image info " & quoteShell(runnerAlias))
  code == 0

proc haveTool(t: string): bool = findExe(t).len > 0

suite "t_incus_linux_jit_boot":
  test "prerequisites present (else skip)":
    if not haveTool("bash"):
      echo "[skip] bash absent"; skip()
    elif not haveTool("python3"):
      echo "[skip] python3 absent"; skip()
    elif not incusUsable():
      echo "[skip] incus not reachable via '" & incusCmd &
        "' (set VMH_INCUS_CMD=\"sudo -n incus\" if the incus-admin group " &
        "is not active in this session)"
      skip()
    elif not imagePresent():
      echo "[skip] runner image '" & runnerAlias & "' absent (build it: " &
        "guest-recipes/linux-x64-runner/build-runner-image.sh)"
      skip()
    else:
      check incusUsable()
      check imagePresent()

  test "ephemeral Linux container: cloud-init JIT injection -> runner " &
       "reaches session-create against the mock -> clean teardown":
    if not (haveTool("bash") and haveTool("python3") and incusUsable() and
            imagePresent()):
      echo "[skip] prerequisites not satisfied"; skip()
    else:
      # Run the driver in the foreground; stream its output.
      let (output, exitCode) = execCmdEx(
        "bash " & quoteShell(driver),
        options = {poStdErrToStdOut})
      echo output
      let lines = output.splitLines()
      if exitCode == 3 or (lines.len > 0 and "SKIP" in lines[^1]):
        echo "[skip] driver self-skipped (missing image/incus/tooling)"
        skip()
      else:
        # Each sub-assertion the driver proves must be present, and it must
        # end with LINUX_JIT_GATE_PASS.
        check "PASS (a):" in output   # JWT-authorized JIT delivery
        check "PASS (a'):" in output  # no-JWT rejected (401)
        check "PASS (b):" in output   # cloud-init ran bootstrap + run.sh --jitconfig
        check "PASS (c):" in output   # runner reached session-create
        check "PASS (d):" in output   # clean teardown, no residue
        check "LINUX_JIT_GATE_PASS" in output
        check exitCode == 0
