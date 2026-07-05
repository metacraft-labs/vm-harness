## Unit tests for CLI probe backend filtering.

import std/unittest
import vm_harness/cli
import vm_harness/types

suite "cli probe backend selection":
  test "probe without --backend keeps the all-registered behavior":
    let opts = parseCliOpts(@["probe"])
    check probeBackendIds(opts).len > 1

  test "probe --backend narrows to exactly that backend":
    let opts = parseCliOpts(@["probe", "--backend", "tart-macos"])
    check probeBackendIds(opts) == @[biTartMacos]
