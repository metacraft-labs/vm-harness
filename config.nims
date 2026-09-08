# Workspace-wide Nim configuration.
#
# Ensure that ``nim r tests/...`` finds the library sources at ``src/``
# without requiring the consumer to ``nimble install`` first.

switch("path", "src")

# Graph metadata declares tools before any build tool can be selected.
# These modes do not compile the CLI or its PCRE-dependent serial matcher.
when defined(linux) and not (defined(reproInterfaceMode) or defined(reproProviderMode)):
  import std/[os, strutils]
  let pcreConfig = findExe("pcre-config")
  if pcreConfig.len == 0:
    raise newException(ValueError,
      "vm-harness Linux builds require pcre-config on the compile action PATH")
  # Check-only mode does not execute gorgeEx or link an executable.
  if getCommand() != "check":
    # Resolve only the declared PCRE dependency, never the caller's entire
    # LD_LIBRARY_PATH (which can belong to an incompatible guest closure).
    let probe = gorgeEx(quoteShell(pcreConfig) & " --libs")
    let flags = probe.output.strip()
    if probe.exitCode != 0 or flags.len == 0:
      raise newException(ValueError, "pcre-config --libs failed: " & probe.output)
    switch("passL", flags)
    for flag in parseCmdLine(flags):
      if flag.startsWith("-L"):
        switch("passL", "-Wl,-rpath," & quoteShell(flag[2..^1]))
