## Unit tests for the output envelope writer.
##
## These tests verify the *file shape* contract — the harness writes
## ``00-provision.log``, per-command artifacts, ``RESULT.txt`` rows, and
## the ``DONE`` sentinel in the expected order and format. The envelope
## writer is pure host-side logic with no VM interaction, so unit-level
## coverage is sufficient.

import std/[os, strutils, tempfiles, unittest]
import vm_harness/types
import vm_harness/output

suite "OutputEnvelope":
  test "newOutputEnvelope creates fresh files and removes stale DONE":
    let dir = createTempDir("vmh-env-", "")
    defer: removeDir(dir)
    # Pre-create a stale DONE sentinel from a "prior run".
    writeFile(dir / "DONE", "STALE\n")

    let env = newOutputEnvelope(dir)

    check fileExists(dir / "00-provision.log")
    check fileExists(dir / "RESULT.txt")
    check not fileExists(dir / "DONE")
    check not env.isComplete()

  test "logProvision appends timestamped lines":
    let dir = createTempDir("vmh-env-", "")
    defer: removeDir(dir)
    let env = newOutputEnvelope(dir)
    env.logProvision("hello world")
    env.logProvision("second line")
    let content = readFile(dir / "00-provision.log")
    check "hello world" in content
    check "second line" in content
    # Each line is timestamped (ISO 8601 with 'Z' suffix).
    check 'Z' in content

  test "writeCommandRun renders the canonical header and uniques names":
    let dir = createTempDir("vmh-env-", "")
    defer: removeDir(dir)
    let env = newOutputEnvelope(dir)
    env.writeCommandRun(@["/bin/echo", "hello"],
                       ExecResult(exitCode: 0, stdout: "hello\n",
                                  stderr: "", elapsedMs: 12))
    env.writeCommandRun(@["/bin/echo", "again"],
                       ExecResult(exitCode: 0, stdout: "again\n",
                                  stderr: "", elapsedMs: 8))
    check fileExists(dir / "02-echo-run.txt")
    check fileExists(dir / "02-echo-1-run.txt")
    let first = readFile(dir / "02-echo-run.txt")
    check "# cmd: /bin/echo hello" in first
    check "# exit_code: 0" in first
    check "# elapsed_ms: 12" in first
    check "hello" in first

  test "recordStep + finalize produce the expected RESULT.txt + DONE":
    let dir = createTempDir("vmh-env-", "")
    defer: removeDir(dir)
    let env = newOutputEnvelope(dir)
    env.recordStep("revert", ssOk, 1234)
    env.recordStep("exec", ssOk, 567)
    env.recordStep("cleanup", ssOk, 8)
    env.finalize(vPass)
    let result = readFile(dir / "RESULT.txt")
    check "step: revert  status: ok  elapsed_ms: 1234" in result
    check "step: exec  status: ok  elapsed_ms: 567" in result
    check "verdict: PASS" in result
    check fileExists(dir / "DONE")
    check readFile(dir / "DONE").strip == "PASS"
    check env.isComplete()

  test "finalize is idempotent":
    let dir = createTempDir("vmh-env-", "")
    defer: removeDir(dir)
    let env = newOutputEnvelope(dir)
    env.finalize(vPass)
    env.finalize(vFail)  # second call should be a no-op
    let result = readFile(dir / "RESULT.txt")
    check result.count("verdict:") == 1
    check readFile(dir / "DONE").strip == "PASS"
