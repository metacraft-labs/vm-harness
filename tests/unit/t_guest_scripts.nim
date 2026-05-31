## Unit tests for the embedded guest scripts.
##
## Verifies that ``staticRead`` of ``guest-scripts/posix.sh`` and
## ``guest-scripts/windows.ps1`` actually baked the scripts into the
## binary and that the shim template can be rendered with placeholder
## substitution.

import std/[strutils, os, tempfiles, unittest]
import vm_harness/guest_scripts

suite "guest scripts":
  test "PosixRunner is non-empty and includes every subcommand":
    check PosixRunner.len > 0
    check "exec)" in PosixRunner or "exec) cmd_exec" in PosixRunner
    check "install-trace-shim)" in PosixRunner
    check "uninstall-trace-shim)" in PosixRunner
    check "write-result)" in PosixRunner
    check "finalize)" in PosixRunner

  test "WindowsRunner is non-empty and includes every subcommand":
    check WindowsRunner.len > 0
    check "Invoke-Exec" in WindowsRunner
    check "Invoke-InstallTraceShim" in WindowsRunner
    check "Invoke-UninstallTraceShim" in WindowsRunner
    check "Invoke-WriteResult" in WindowsRunner
    check "Invoke-Finalize" in WindowsRunner

  test "writeGuestRunner produces an identical file on disk":
    let dir = createTempDir("vmh-gs-", "")
    defer: removeDir(dir)
    writeGuestRunner(grPosix, dir / "runner.sh")
    let written = readFile(dir / "runner.sh")
    check written == PosixRunner

  test "renderShimScript substitutes placeholders":
    let posix = renderShimScript(grPosix,
                                tracePath = "/tmp/trace.log",
                                realBinPath = "/usr/bin/useradd.real")
    check "/tmp/trace.log" in posix
    check "/usr/bin/useradd.real" in posix
    check "@TRACE_LOG_PATH@" notin posix
    check "@REAL_BIN_PATH@" notin posix

    let win = renderShimScript(grWindows,
                              tracePath = "C:\\trace\\useradd.log",
                              realBinPath = "C:\\bin\\useradd.real.exe")
    check "C:\\trace\\useradd.log" in win
    check "C:\\bin\\useradd.real.exe" in win
