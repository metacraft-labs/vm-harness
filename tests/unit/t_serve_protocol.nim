## unit_serve_protocol — pure wire-contract checks for the RA1 remoting
## protocol (``src/vm_harness/serve/protocol.nim`` + ``client.parseAddr``).
##
## No sockets, no processes — this is the deterministic, host-independent
## layer that both the daemon and the client depend on. Runs in the
## universal test layer (design doc §9.3).

import std/[json, os, strutils, unittest]
import vm_harness

suite "unit_serve_protocol":
  test "constantTimeEq matches identical strings, rejects differences":
    check constantTimeEq("s3cret-token", "s3cret-token")
    check not constantTimeEq("s3cret-token", "s3cret-toker")
    check not constantTimeEq("s3cret-token", "s3cret")     # length mismatch
    check not constantTimeEq("", "x")
    check constantTimeEq("", "")                           # both empty

  test "parseBearer extracts the token, case-insensitive scheme":
    check parseBearer("Bearer abc123") == "abc123"
    check parseBearer("bearer   abc123  ") == "abc123"
    check parseBearer("Basic abc123") == ""
    check parseBearer("") == ""

  test "ExecRequest round-trips through JSON":
    let req = ExecRequest(v: ProtocolVersion,
                          argv: @["run", "--backend", "noop", "--", "echo"],
                          stdin: "hi", timeoutSec: 42,
                          userData: "#cloud-config\nruncmd: [echo hi]\n")
    let decoded = parseExecRequest($toJson(req))
    check decoded.v == ProtocolVersion
    check decoded.argv == req.argv
    check decoded.stdin == "hi"
    check decoded.timeoutSec == 42
    check decoded.userData == req.userData

  test "userData defaults to empty when absent (backward compatible)":
    # A client that predates the field omits it; the server must not fail.
    let decoded = parseExecRequest($(%*{"v": ProtocolVersion,
                                        "argv": @["provision"]}))
    check decoded.userData == ""

  test "parseExecRequest rejects a version mismatch":
    let body = $(%*{"v": "999", "argv": @["probe"]})
    expect ValueError:
      discard parseExecRequest(body)

  test "parseExecRequest rejects a missing argv array":
    expect ValueError:
      discard parseExecRequest($(%*{"v": ProtocolVersion}))
    expect ValueError:
      discard parseExecRequest("not json at all")

  test "event serialization + decoding round-trips":
    let logEv = parseEvent(logEvent("a boot line"))
    check logEv.kind == ekLog
    check logEv.line == "a boot line"

    let exitEv = parseEvent(exitEvent(7))
    check exitEv.kind == ekExit
    check exitEv.code == 7

    let errEv = parseEvent(errorEvent("worker gone"))
    check errEv.kind == ekError
    check errEv.message == "worker gone"

  test "parseEvent rejects an unknown event type":
    expect ValueError:
      discard parseEvent($(%*{"v": ProtocolVersion, "type": "bogus"}))

  test "parseAddr splits host:port and rejects malformed input":
    let a = parseAddr("10.0.0.5:8873")
    check a.host == "10.0.0.5"
    check a.port == 8873
    expect ValueError:
      discard parseAddr("no-port")
    expect ValueError:
      discard parseAddr("host:notanumber")

  test "protocol paths are versioned under /v1":
    check PathInfo.startsWith("/v1/")
    check PathExec == "/v1/exec"
    check ApiPrefix == "/v" & ProtocolVersion

  test "chunkSizeHex preserves trailing zeros (multiples of 16)":
    # Regression: a size that is a multiple of 16 (hex ending in 0) must keep
    # its trailing zero. A bug that stripped trailing zeros too turned 0x40 into
    # "4", understating the chunk body and desyncing the NDJSON /v1/exec stream
    # ("malformed chunked encoding" on the reader). Every value here round-trips
    # back to the byte length via parseHexInt.
    check chunkSizeHex(64) == "40" # 0x40 — the exact byte length that broke it
    check chunkSizeHex(16) == "10"
    check chunkSizeHex(112) == "70"
    check chunkSizeHex(256) == "100"
    check chunkSizeHex(75) == "4b" # a non-multiple that always worked
    check chunkSizeHex(1) == "1"
    check chunkSizeHex(0) == "0"
    # Property: the emitted token parses back to the original length.
    for n in [1, 15, 16, 17, 32, 48, 64, 100, 112, 255, 256, 4096, 65536]:
      check parseHexInt(chunkSizeHex(n)) == n

  test "applyUserData materializes a 0600 seed file and appends --user-data":
    let dir = getTempDir() / "vmh-serve-userdata-test"
    let secret = "#!/bin/bash\n./config.sh --jitconfig TOKEN\n"
    let baseArgv = @["run", "--ephemeral", "--backend", "incus",
                     "--baseline", "job-1"]
    let (argv, path) = applyUserData(baseArgv, secret, dir)
    check path.len > 0
    defer:
      removeFile(path)
      try: removeDir(dir) except CatchableError: discard
    # The seed file exists and carries the EXACT bytes (nothing truncated).
    check fileExists(path)
    check readFile(path) == secret
    # --user-data <path> was appended, preserving the original argv order.
    check argv[0 ..< baseArgv.len] == baseArgv
    check argv[^2] == "--user-data"
    check argv[^1] == path
    when defined(posix):
      # Owner-only: the file carries a runner registration token.
      check getFilePermissions(path) == {fpUserRead, fpUserWrite}

  test "applyUserData is a no-op on empty user-data":
    let baseArgv = @["provision", "--backend", "noop"]
    let (argv, path) = applyUserData(baseArgv, "", getTempDir())
    check argv == baseArgv
    check path == ""

  test "applyUserData does not double-append when argv already has --user-data":
    let baseArgv = @["run", "--ephemeral", "--user-data", "/pinned/path"]
    let (argv, path) = applyUserData(baseArgv, "some bytes", getTempDir())
    check argv == baseArgv     # untouched — caller pinned its own file
    check path == ""           # nothing materialized ⇒ nothing to clean up
