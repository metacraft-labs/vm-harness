# Workspace-wide Nim configuration.
#
# Ensure that ``nim r tests/...`` finds the library sources at ``src/``
# without requiring the consumer to ``nimble install`` first.

switch("path", "src")

when defined(linux):
  import std/[os, strutils]
  let pcreConfig = findExe("pcre-config")
  if pcreConfig.len > 0:
    # Resolve only the declared PCRE dependency, never the caller's entire
    # LD_LIBRARY_PATH (which can belong to an incompatible guest closure).
    let flags = gorge(quoteShell(pcreConfig) & " --libs").strip()
    switch("passL", flags)
    for flag in parseCmdLine(flags):
      if flag.startsWith("-L"):
        switch("passL", "-Wl,-rpath," & quoteShell(flag[2..^1]))
