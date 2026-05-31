## Guest-script embedding (design doc §12 choice #1: ``staticRead`` at
## compile time).
##
## Backends call ``writeGuestRunner`` from the host side to drop the
## right script onto disk (or pipe its content into the guest). The
## strings themselves are baked into the binary so the library has no
## runtime dependency on the source tree.

import std/strformat

const
  PosixRunner* = staticRead("../../guest-scripts/posix.sh")
    ## Contents of ``guest-scripts/posix.sh``. The Rust port (M17) embeds
    ## the same file via ``include_str!``.

  WindowsRunner* = staticRead("../../guest-scripts/windows.ps1")
    ## Contents of ``guest-scripts/windows.ps1``.

type
  GuestRunnerKind* = enum
    grPosix = "posix"
    grWindows = "windows"

proc guestRunnerContent*(kind: GuestRunnerKind): string =
  case kind
  of grPosix: PosixRunner
  of grWindows: WindowsRunner

proc writeGuestRunner*(kind: GuestRunnerKind, destPath: string) =
  ## Materialize the runner script to ``destPath``. Useful for backends
  ## that copy the script into the guest, and for the test fixtures.
  writeFile(destPath, guestRunnerContent(kind))

proc renderShimScript*(kind: GuestRunnerKind,
                      tracePath: string, realBinPath: string): string =
  ## Render a ready-to-install shim wrapper with the placeholders
  ## substituted. Returns the shim *body* (not the runner). Useful for
  ## backends that install shims directly without going through the
  ## guest-side ``install-trace-shim`` subcommand.
  case kind
  of grPosix:
    &"""#!/bin/sh
printf '%s\t%s\n' "$(date +%s%N 2>/dev/null || date +%s)" "$0 $*" >> "{tracePath}"
exec "{realBinPath}" "$@"
"""
  of grWindows:
    &"""
"$([DateTimeOffset]::Now.ToUnixTimeMilliseconds())`t$($MyInvocation.MyCommand.Path) $($args -join ' ')" |
    Out-File -FilePath "{tracePath}" -Append -Encoding utf8
& "{realBinPath}" @args
exit $LASTEXITCODE
"""
