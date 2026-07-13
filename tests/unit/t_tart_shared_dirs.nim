import std/[os, unittest]
import vm_harness/backends/tart
import vm_harness/types

proc restoreEnv(name: string, existed: bool, value: string) =
  if existed:
    putEnv(name, value)
  else:
    delEnv(name)

suite "Tart shared directories":
  test "macOS excludes the raw Nix store but keeps the reprobuild store":
    let
      nixName = "MCL_RUNNER_SHARED_NIX_STORE"
      reproName = "MCL_RUNNER_SHARED_REPRO_STORE"
      hadNix = existsEnv(nixName)
      hadRepro = existsEnv(reproName)
      oldNix = getEnv(nixName)
      oldRepro = getEnv(reproName)
      sharedPath = getCurrentDir()
    defer:
      restoreEnv(nixName, hadNix, oldNix)
      restoreEnv(reproName, hadRepro, oldRepro)

    putEnv(nixName, sharedPath)
    putEnv(reproName, sharedPath)

    check newTartBackend(goMacos).sharedDirs.len == 1
    check newTartBackend(goLinux).sharedDirs.len == 2
