## unit_vm_harness_utm_parsers (M3 supplemental).
##
## Pure parser unit tests for the ``utmctl`` output formats consumed by
## ``UtmBackend``. Both ``utmctl list`` and ``utmctl ip-address`` emit
## occasional warning lines on stderr (``Error from event: …``,
## ``NOTE: utmctl does not work from SSH sessions …``) — the backend
## merges stderr into stdout so the parser must be tolerant of those
## warnings interleaved with real rows.

import std/[os, times, unittest]
import vm_harness

suite "utm output parsers":
  test "parseUtmListOutput: empty input -> no rows":
    check parseUtmListOutput("").len == 0
    check parseUtmListOutput("\n\n").len == 0

  test "parseUtmListOutput: header-only -> no rows":
    let raw = "UUID                                 Status   Name\n"
    check parseUtmListOutput(raw).len == 0

  test "parseUtmListOutput: real row parses cleanly":
    let raw = """UUID                                 Status   Name
00112233-4455-6677-8899-aabbccddeeff stopped  repro-windows-arm-base
12345678-1234-1234-1234-123456789abc started  repro-vm-utm-windows-1700000000-42
"""
    let rows = parseUtmListOutput(raw)
    check rows.len == 2
    check rows[0].uuid == "00112233-4455-6677-8899-aabbccddeeff"
    check rows[0].status == "stopped"
    check rows[0].name == "repro-windows-arm-base"
    check rows[1].uuid == "12345678-1234-1234-1234-123456789abc"
    check rows[1].status == "started"
    check rows[1].name == "repro-vm-utm-windows-1700000000-42"

  test "parseUtmListOutput: tolerates Error from event noise":
    let raw = """Error from event: The operation couldn’t be completed. (OSStatus error -1743.)
NOTE: utmctl does not work from SSH sessions or before logging in.
Error from event: The operation couldn’t be completed. (OSStatus error -1743.)
UUID                                 Status   Name
00112233-4455-6677-8899-aabbccddeeff stopped  repro-windows-arm-base
"""
    let rows = parseUtmListOutput(raw)
    check rows.len == 1
    check rows[0].name == "repro-windows-arm-base"

  test "parseUtmListOutput: rejects malformed first-token (non-UUID)":
    # Defensive against any unrelated stderr line that survives the
    # warning-prefix skip — it must still not be misparsed as a VM row.
    let raw = """UUID                                 Status   Name
weird-line-that-is-not-a-uuid stopped  something
00112233-4455-6677-8899-aabbccddeeff stopped  legit
"""
    let rows = parseUtmListOutput(raw)
    check rows.len == 1
    check rows[0].name == "legit"

  test "parseUtmListOutput: name with spaces survives":
    let raw = """UUID                                 Status   Name
00112233-4455-6677-8899-aabbccddeeff stopped  My Test Windows VM
"""
    let rows = parseUtmListOutput(raw)
    check rows.len == 1
    check rows[0].name == "My Test Windows VM"

  test "parseIpAddressOutput: empty -> no IPs":
    check parseIpAddressOutput("").len == 0

  test "parseIpAddressOutput: single IPv4 line":
    check parseIpAddressOutput("192.168.64.42\n") == @["192.168.64.42"]

  test "parseIpAddressOutput: multiple IPs across lines":
    let raw = """192.168.64.42
fe80::1234:5678:9abc:def0
"""
    let ips = parseIpAddressOutput(raw)
    check ips.len == 2
    check ips[0] == "192.168.64.42"
    check ips[1] == "fe80::1234:5678:9abc:def0"

  test "parseIpAddressOutput: skips warnings":
    let raw = """Error from event: ...
NOTE: utmctl does not work ...
192.168.64.42
"""
    check parseIpAddressOutput(raw) == @["192.168.64.42"]

  test "parseIpAddressOutput: tolerates interface-name annotation":
    # Some utmctl builds emit ``192.168.64.42 (en0)`` style annotated
    # output. We take the first whitespace-separated token.
    let raw = "192.168.64.42 en0\nfe80::1 en0\n"
    let ips = parseIpAddressOutput(raw)
    check ips.len == 2
    check ips[0] == "192.168.64.42"

  test "probeAvailability: silent hung utmctl returns false promptly":
    when defined(macosx):
      let script = getTempDir() / "vmh-utmctl-hang-" &
                   $getCurrentProcessId() & ".sh"
      writeFile(script, "#!/bin/sh\nexec /bin/sleep 5\n")
      try:
        setFilePermissions(script, {fpUserRead, fpUserWrite, fpUserExec})
        let b = newUtmBackend(utmctlCmd = script, probeTimeoutSec = 1)
        let started = epochTime()
        check not b.probeAvailability()
        check epochTime() - started < 3.0
      finally:
        try: removeFile(script)
        except CatchableError: discard
    else:
      skip()
