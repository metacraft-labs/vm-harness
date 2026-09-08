import std/[tables, unittest]
import vm_harness/[ssh, process_capture, types]

when defined(posix):
  import std/[os, posix]
  if commandLineParams() == @["--close-stdin"]:
    # osproc may leave the original stdin pipe fd alongside its dup2'd fd 0.
    var input: Stat
    doAssert fstat(STDIN_FILENO, input) == 0
    for fd in 3..255:
      var candidate: Stat
      if fstat(cint(fd), candidate) == 0 and candidate.st_dev == input.st_dev and
          candidate.st_ino == input.st_ino:
        discard posix.close(cint(fd))
    discard posix.close(STDIN_FILENO)
    stdout.write("stdin-closed\n")
    stdout.flushFile()
    sleep(200)
    quit(0)

suite "SSH POSIX payloads":
  test "SSH config values quote whitespace without shell quoting":
    check quoteSshConfigValue("/tmp/two words") == "\"/tmp/two words\""
    check quoteSshConfigValue("simple-alias") == "simple-alias"
    expect ValueError: discard quoteSshConfigValue("bad\noption")
  test "argv is quoted exactly once, including empty arguments and shell syntax":
    check formatSshCommand(@["printf", "%s", "", "O'Brien", "$HOME; exit"], goLinux) ==
      "'printf' '%s' '' 'O'\"'\"'Brien' '$HOME; exit'"
    expect ValueError: discard formatSshCommand(@["a\0b"], goLinux)

  test "POSIX environment uses assignment words, not Windows set commands":
    check formatSshEnvironment({"VALUE": "a b'&$HOME"}.toTable(), goLinux) ==
      "VALUE='a b'\"'\"'&$HOME' "
    for name in ["", "9BAD", "A;false", "A=B", "A B"]:
      expect ValueError:
        discard formatSshEnvironment({name: "x"}.toTable(), goLinux)

suite "bounded process capture":
  test "a silent process cannot evade its timeout":
    when defined(posix):
      let r = captureCommand(@["sleep", "5"], timeoutSec = 1)
      check r.exitCode == 124
      check r.elapsedMs < 3000

  test "empty stdin sends EOF and stderr remains separate":
    when defined(posix):
      let r = captureCommand(@["sh", "-c", "cat; printf error >&2"],
                              timeoutSec = 1, mergeStderr = false)
      check r.exitCode == 0
      check r.stdout == ""
      check r.stderr == "error"

  test "capture drains output while delivering input larger than a pipe":
    when defined(posix):
      var input = newString(256 * 1024)
      for i in 0..<input.len: input[i] = 'a'
      let r = captureCommand(@["cat"], timeoutSec = 3, stdinData = input)
      check r.exitCode == 0
      check r.stdout == input

  test "a child may close stdin before reading the supplied payload":
    when defined(posix):
      let r = captureCommand(@[getAppFilename(), "--close-stdin"],
        timeoutSec = 2, stdinData = newString(256 * 1024))
      check r.exitCode == 0
      check r.stdout == "stdin-closed\n"
