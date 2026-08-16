# assert-git-provisioned.ps1 -- HARD GATE: refuse to let a Windows golden be
# captured unless Git for Windows is actually usable by a SERVICE on every
# clone of it.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS (read this before "simplifying" it away)
# ---------------------------------------------------------------------------
# provision-git.ps1 deliberately exits 0 even when it fails, because it runs
# from FirstLogonCommands where a non-zero exit can wedge the rest of the
# chain -- including the install-done sentinel and the shutdown that signals
# install-complete to virt-install. That trade-off is defensible ONLY if
# something downstream refuses to ship the resulting image.
#
# Without such a gate the original defect returns one layer up: the golden is
# captured with no Git, every clone boots without bash.exe, and nobody finds
# out until CI fails again -- which is exactly the bug this whole change set
# exists to fix. A README section telling an operator to check a marker file
# is documentation, not enforcement.
#
# So this script is the enforcement. It is invoked by the golden-capture path
# (windows-x64-base/build-sysprep-golden.sh) BEFORE sysprep, and it exits
# non-zero -- loudly, naming the defect -- if the image would be shipped
# without a working Git.
#
# ---------------------------------------------------------------------------
# WHAT IT ASSERTS, AND WHY EACH CHECK IS THE RIGHT ONE
# ---------------------------------------------------------------------------
# 1. No failure marker from provision-git.ps1.
#
# 2. `<InstallDir>\bin` is present in the RAW machine PATH registry value.
#    This -- not the current process's $env:Path -- is the thing that survives
#    capture. The GitHub Actions runner runs as a SERVICE, and services.exe
#    builds the environment block it hands to services once at boot from
#    HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment. A
#    process-scoped or user-scoped PATH would pass a naive `Get-Command bash`
#    check while leaving every clone's runner service without bash. Reading
#    the registry value directly is the only check that proves the property
#    the fleet actually depends on.
#
#    Read with DoNotExpandEnvironmentNames for the same reason
#    provision-git.ps1 writes it that way: the value is REG_EXPAND_SZ and
#    contains %SystemRoot%-style tokens that must not be expanded here.
#
# 3. The value kind is still REG_EXPAND_SZ. If a careless write ever converted
#    it to REG_SZ, `%SystemRoot%\system32` would stop expanding and the image
#    would be subtly bricked for every process on the box.
#
# 4. Every tool a `shell: bash` step relies on actually resolves THROUGH
#    bin\bash.exe. Only `<InstallDir>\bin` is on the machine PATH; the MSYS
#    coreutils live in `usr\bin` and `mingw64\bin` (`clangarm64\bin` on arm64)
#    and are reachable only because the bin\bash.exe shim prepends them inside
#    the spawned process. That indirection is load-bearing, so it is proved by
#    execution rather than assumed -- and each tool is checked individually,
#    because a probe that merely greps the combined output for "bash" passes
#    even when everything else is missing.
#
# Exit codes: 0 = image is fit to capture. 1 = do not capture it.
#
# Usage:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File assert-git-provisioned.ps1
#   ... -InstallDir C:\PortableGit

[CmdletBinding()]
param(
  [string] $InstallDir = 'C:\PortableGit',
  # The tools a GitHub Actions `shell: bash` step and the reprobuild release
  # workflow actually invoke. curl and tar live in mingw64\bin / usr\bin
  # respectively, so they exercise both directories the shim prepends.
  [string[]] $RequiredTools = @('bash', 'git', 'sha256sum', 'awk', 'unzip', 'tar', 'curl')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$problems = New-Object System.Collections.Generic.List[string]
function Bad([string] $m) { $problems.Add($m); Write-Host "  [FAIL] $m" }
function Good([string] $m) { Write-Host "  [ ok ] $m" }

$binDir = Join-Path $InstallDir 'bin'
$bashExe = Join-Path $binDir 'bash.exe'
$gitExe = Join-Path $binDir 'git.exe'

Write-Host 'assert-git-provisioned: verifying the golden is fit to capture'

# -- 1. provisioning failure marker ------------------------------------------
$failMarker = 'C:\Windows\Temp\vmh-git-provision-failed'
if (Test-Path -LiteralPath $failMarker) {
  $why = ''
  try { $why = (Get-Content -LiteralPath $failMarker -Raw).Trim() } catch { }
  Bad "provision-git.ps1 recorded a failure: $why"
  $logPath = 'C:\Windows\Temp\vmh-git-provision.log'
  if (Test-Path -LiteralPath $logPath) {
    Write-Host '  ---- tail of vmh-git-provision.log ----'
    Get-Content -LiteralPath $logPath -Tail 25 | ForEach-Object { Write-Host "  | $_" }
  }
} else {
  Good 'no provision-git failure marker'
}

# -- 2/3. the machine PATH (the property that survives capture) ---------------
$envKeyPath = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$envKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($envKeyPath, $false)
if ($null -eq $envKey) {
  Bad "could not open HKLM\$envKeyPath"
} else {
  try {
    $raw = [string] $envKey.GetValue(
      'Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $kind = $envKey.GetValueKind('Path')

    if (@($raw -split ';' | Where-Object { $_ -ne '' }) -contains $binDir) {
      Good "machine PATH contains $binDir"
    } else {
      Bad ("machine PATH does NOT contain $binDir -- every clone's runner " +
           "SERVICE will boot without bash.exe. Raw value: $raw")
    }

    if ($kind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) {
      Good 'machine PATH is still REG_EXPAND_SZ'
    } else {
      Bad ("machine PATH value kind is $kind, expected ExpandString (REG_EXPAND_SZ). " +
           "%SystemRoot%-style tokens in PATH will no longer expand for any process.")
    }

    # Not fatal, but a PATH near the legacy 2047-char ceiling breaks setx and a
    # number of installers, so say so while someone is still looking.
    if ($raw.Length -gt 2047) {
      Write-Host ("  [warn] machine PATH is $($raw.Length) chars (>2047): " +
                  'legacy tools such as setx.exe cannot round-trip this value.')
    } else {
      Good "machine PATH length $($raw.Length) chars (legacy limit 2047)"
    }
  } finally {
    $envKey.Close()
  }
}

# -- 4. prove the toolchain resolves through the bin\bash.exe shim ------------
if (-not (Test-Path -LiteralPath $bashExe)) {
  Bad "missing $bashExe"
} elseif (-not (Test-Path -LiteralPath $gitExe)) {
  Bad "missing $gitExe"
} else {
  # One `command -v` per tool, each tagged, so a missing tool is unambiguous.
  # `command -v` prints nothing and returns non-zero when a tool is absent, so
  # a combined one-liner would silently under-report.
  $inner = 'for t in ' + ($RequiredTools -join ' ') +
           '; do p="$(command -v "$t" 2>/dev/null)"; ' +
           'if [ -n "$p" ]; then echo "TOOL $t $p"; else echo "TOOL $t -"; fi; done'
  $probe = @(& $bashExe -c $inner 2>&1)
  foreach ($line in $probe) { Write-Host "  | $line" }

  foreach ($tool in $RequiredTools) {
    $hit = $probe | Where-Object { $_ -match ("^TOOL\s+" + [regex]::Escape($tool) + "\s+(.+)$") }
    if ($hit -and ($hit -notmatch ("^TOOL\s+" + [regex]::Escape($tool) + "\s+-$"))) {
      Good "bash resolves $tool"
    } else {
      Bad ("bash cannot resolve '$tool' -- a `shell: bash` step that uses it " +
           'will fail on every clone of this golden')
    }
  }

  try {
    $v = (& $gitExe --version) -join ' '
    if ($v -match 'git version') { Good "git reports: $v" } else { Bad "unexpected git --version output: $v" }
  } catch {
    Bad ('git --version failed: ' + $_.Exception.Message)
  }
}

Write-Host ''
if ($problems.Count -gt 0) {
  Write-Host "assert-git-provisioned: FAILED with $($problems.Count) problem(s):"
  foreach ($p in $problems) { Write-Host "  * $p" }
  Write-Host ''
  Write-Host 'DO NOT capture this image. Clones of it will run GitHub Actions jobs,'
  Write-Host 'and without Git on the MACHINE PATH every `shell: bash` step fails with'
  Write-Host '"bash: command not found" while actions/checkout degrades to the REST-API'
  Write-Host 'tarball. Re-run guest-recipes/lib/provision-git.ps1 in the guest (elevated)'
  Write-Host 'and inspect C:\Windows\Temp\vmh-git-provision.log.'
  exit 1
}

Write-Host 'assert-git-provisioned: OK -- Git for Windows is on the machine PATH and the'
Write-Host 'MSYS toolchain resolves through bin\bash.exe. This image is fit to capture.'
exit 0
