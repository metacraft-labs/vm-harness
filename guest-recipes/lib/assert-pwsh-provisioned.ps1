# assert-pwsh-provisioned.ps1 -- HARD GATE: refuse to let a Windows golden be
# captured unless PowerShell 7 (`pwsh`) is actually usable by a SERVICE on
# every clone of it.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS (read this before "simplifying" it away)
# ---------------------------------------------------------------------------
# provision-pwsh.ps1 deliberately exits 0 even when it fails, because it runs
# from FirstLogonCommands where a non-zero exit can wedge the rest of the chain
# -- including the install-done sentinel and the shutdown that signals
# install-complete to virt-install. That trade-off is defensible ONLY if
# something downstream refuses to ship the resulting image.
#
# Without such a gate the original defect returns one layer up: the golden is
# captured with no pwsh, every clone boots without pwsh.exe, and nobody finds
# out until CI fails again with `pwsh: command not found` -- which is exactly
# the bug this change set exists to fix, and which went unnoticed for weeks
# precisely because nothing asserted it. A README section telling an operator
# to check a marker file is documentation, not enforcement.
#
# So this script is the enforcement. It is invoked by the golden-capture path
# (windows-x64-base/build-sysprep-golden.sh) BEFORE sysprep, and it exits
# non-zero -- loudly, naming the defect -- if the image would be shipped
# without a working PowerShell 7.
#
# ---------------------------------------------------------------------------
# WHAT IT ASSERTS, AND WHY EACH CHECK IS THE RIGHT ONE
# ---------------------------------------------------------------------------
# 1. No failure marker from provision-pwsh.ps1.
#
# 2. `pwsh.exe` exists at the install directory -- the cheap, unambiguous
#    check that separates "not installed" from "installed but broken", so the
#    failure message can say which.
#
# 3. `<InstallDir>` is present in the RAW machine PATH registry value. This --
#    not the current process's $env:Path -- is the thing that survives capture.
#    The GitHub Actions runner runs as a SERVICE, and services.exe builds the
#    environment block it hands to services once at boot from
#    HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment. A
#    process-scoped or user-scoped PATH would pass a naive `Get-Command pwsh`
#    check while leaving every clone's runner service without pwsh. Reading the
#    registry value directly is the only check that proves the property the
#    fleet actually depends on.
#
#    Read with DoNotExpandEnvironmentNames for the same reason
#    provision-pwsh.ps1 writes it that way: the value is REG_EXPAND_SZ and
#    contains %SystemRoot%-style tokens that must not be expanded here.
#
# 4. The value kind is still REG_EXPAND_SZ. If a careless write ever converted
#    it to REG_SZ, `%SystemRoot%\system32` would stop expanding and the image
#    would be subtly bricked for every process on the box.
#
# 5. The interpreter actually RUNS, and reports major version >= 7. An
#    unpacked-but-unstartable pwsh.exe (missing runtime, quarantined by
#    Defender after the fact, wrong architecture) is exactly as useless to CI
#    as no pwsh at all. The version floor is what stops a `pwsh` that somehow
#    resolved to the built-in Windows PowerShell 5.1 from passing: 5.1 would
#    satisfy "it ran" while leaving every `shell: pwsh` step broken.
#
# WHAT IT CANNOT ASSERT. Whether `pwsh -v` resolves for `NT AUTHORITY\SYSTEM`
# in session 0 depends on services.exe rebuilding its environment block at the
# NEXT boot, which by definition has not happened in the image being captured.
# Check 3 is the strongest statically available proxy: it verifies the exact
# registry value services.exe will read. The service-context proof has to be
# taken on a booted clone of the promoted artifact, and is not this gate's job.
#
# Exit codes: 0 = image is fit to capture. 1 = do not capture it.
#
# Usage:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File assert-pwsh-provisioned.ps1
#   ... -InstallDir C:\pwsh

[CmdletBinding()]
param(
  [string] $InstallDir = 'C:\pwsh',
  # The floor, not the pin. A newer PowerShell 7.x in the image is fine; the
  # pin itself is enforced by provision-pwsh.ps1's checksum, which is where a
  # version claim can actually be tied to bytes.
  [int] $MinimumMajorVersion = 7
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$problems = New-Object System.Collections.Generic.List[string]
function Bad([string] $m) { $problems.Add($m); Write-Host "  [FAIL] $m" }
function Good([string] $m) { Write-Host "  [ ok ] $m" }

$pwshExe = Join-Path $InstallDir 'pwsh.exe'

Write-Host 'assert-pwsh-provisioned: verifying the golden is fit to capture'

# -- 1. provisioning failure marker ------------------------------------------
$failMarker = 'C:\Windows\Temp\vmh-pwsh-provision-failed'
if (Test-Path -LiteralPath $failMarker) {
  $why = ''
  try { $why = (Get-Content -LiteralPath $failMarker -Raw).Trim() } catch { }
  Bad "provision-pwsh.ps1 recorded a failure: $why"
  $logPath = 'C:\Windows\Temp\vmh-pwsh-provision.log'
  if (Test-Path -LiteralPath $logPath) {
    Write-Host '  ---- tail of vmh-pwsh-provision.log ----'
    Get-Content -LiteralPath $logPath -Tail 25 | ForEach-Object { Write-Host "  | $_" }
  }
} else {
  Good 'no provision-pwsh failure marker'
}

# -- 2. the binary is there --------------------------------------------------
$haveExe = Test-Path -LiteralPath $pwshExe
if ($haveExe) {
  Good "pwsh.exe present at $pwshExe"
} else {
  Bad "missing $pwshExe -- PowerShell 7 was never installed in this image"
}

# -- 3/4. the machine PATH (the property that survives capture) ---------------
$envKeyPath = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$envKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($envKeyPath, $false)
if ($null -eq $envKey) {
  Bad "could not open HKLM\$envKeyPath"
} else {
  try {
    $raw = [string] $envKey.GetValue(
      'Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $kind = $envKey.GetValueKind('Path')

    if (@($raw -split ';' | Where-Object { $_ -ne '' }) -contains $InstallDir) {
      Good "machine PATH contains $InstallDir"
    } else {
      Bad ("machine PATH does NOT contain $InstallDir -- every clone's runner " +
           "SERVICE will boot without pwsh.exe. Raw value: $raw")
    }

    if ($kind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) {
      Good 'machine PATH is still REG_EXPAND_SZ'
    } else {
      Bad ("machine PATH value kind is $kind, expected ExpandString (REG_EXPAND_SZ). " +
           "%SystemRoot%-style tokens in PATH will no longer expand for any process.")
    }

    # Not fatal, but a PATH near the legacy 2047-char ceiling breaks a number
    # of installers, so say so while someone is still looking.
    if ($raw.Length -gt 2047) {
      Write-Host ("  [warn] machine PATH is $($raw.Length) chars (>2047): " +
                  'legacy tooling cannot round-trip a value this long.')
    } else {
      Good "machine PATH length $($raw.Length) chars (legacy limit 2047)"
    }
  } finally {
    $envKey.Close()
  }
}

# -- 5. prove the interpreter runs, and is really 7+ -------------------------
if (-not $haveExe) {
  Bad 'skipping the execution probe: there is no pwsh.exe to run'
} else {
  # Run the probe from a FILE, not `-Command <string>`. This gate is executed
  # by `powershell.exe` (Windows PowerShell 5.1 in these goldens), which does
  # not escape the double quotes embedded in an inline script when building the
  # native command line, so the child receives a mangled argv. That is not
  # hypothetical: the Git gate shipped exactly that bug once and then failed
  # every image -- including correct ones -- while its output said nothing
  # whatsoever about Git. A script path has no spaces and no quotes, so every
  # argument-passing mode produces the same argv.
  #
  # Named with $PID so concurrent runs cannot truncate each other's probe, and
  # removed in a `finally` so the gate leaves no residue in an image about to
  # be captured for the whole fleet.
  $probeScript = "C:\Windows\Temp\vmh-pwsh-gate-probe-$PID.ps1"
  $probe = @()
  try {
    $probeBody = @(
      'Write-Output ("PWSH_VERSION " + $PSVersionTable.PSVersion.ToString())'
      'Write-Output ("PWSH_EDITION " + $PSVersionTable.PSEdition)'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
      $probeScript, $probeBody + "`n", (New-Object System.Text.ASCIIEncoding))

    # 5.1 turns ANY stderr line from a native command into a terminating
    # NativeCommandError while $ErrorActionPreference is 'Stop' and stderr is
    # redirected with 2>&1. Unhandled, that aborts this script with a
    # PowerShell exception instead of the verdict below -- the exact "fails
    # without saying anything about its subject" shape this gate must not have.
    # Relax the preference across the call only; the verdict comes from the
    # PWSH_VERSION line, so a pwsh that cannot run still fails the gate.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $probe = @(& $pwshExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $probeScript 2>&1)
    } finally {
      $ErrorActionPreference = $prevEap
    }
  } catch {
    # Fail closed AND say why: an unwritable or unrunnable probe leaves the
    # interpreter unproven, and unproven is not shippable.
    Bad ('could not run the pwsh probe (' + $_.Exception.Message +
         ') -- PowerShell 7 remains unproven on this image')
  } finally {
    Remove-Item -LiteralPath $probeScript -Force -ErrorAction SilentlyContinue
  }
  foreach ($line in $probe) { Write-Host "  | $line" }

  $versionLine = @($probe | Where-Object { $_ -match '^PWSH_VERSION\s+(\S+)$' })
  if ($versionLine.Count -eq 0) {
    Bad ("$pwshExe did not report a version -- it is present but does not run. " +
         'Probe output: ' + ($probe -join ' | '))
  } else {
    $reported = ([regex]::Match([string] $versionLine[0], '^PWSH_VERSION\s+(\S+)$')).Groups[1].Value
    $major = 0
    try { $major = [int] ($reported -split '\.')[0] } catch { }
    if ($major -ge $MinimumMajorVersion) {
      Good "pwsh runs and reports $reported"
    } else {
      Bad ("pwsh reports version $reported, which is below the required major " +
           "$MinimumMajorVersion. Windows PowerShell 5.1 cannot serve a " +
           '`shell: pwsh` step.')
    }
  }
}

Write-Host ''
if ($problems.Count -gt 0) {
  Write-Host "assert-pwsh-provisioned: FAILED with $($problems.Count) problem(s):"
  foreach ($p in $problems) { Write-Host "  * $p" }
  Write-Host ''
  Write-Host 'DO NOT capture this image. Clones of it will run GitHub Actions jobs,'
  Write-Host 'and without PowerShell 7 on the MACHINE PATH every `shell: pwsh` step'
  Write-Host 'fails with "pwsh: command not found" -- as does every step that shells'
  Write-Host 'out to pwsh.exe directly, such as the dev-exec.cmd trampoline that'
  Write-Host 'setup-dev-env generates. Re-run guest-recipes/lib/provision-pwsh.ps1 in'
  Write-Host 'the guest (elevated) and inspect C:\Windows\Temp\vmh-pwsh-provision.log.'
  exit 1
}

Write-Host 'assert-pwsh-provisioned: OK -- PowerShell 7 is on the machine PATH and the'
Write-Host 'interpreter runs. This image is fit to capture.'
exit 0
