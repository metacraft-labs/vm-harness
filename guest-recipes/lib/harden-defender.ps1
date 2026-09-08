<#
.SYNOPSIS
  Apply the offline AV-hardening registry payload to a Windows image.

.DESCRIPTION
  Edits an offline .vhdx's registry hives while the image is NOT booted, so
  the live protections that block a running-guest approach (AMSI, tamper
  protection, the on-access filter) are simply not present to interfere.

  The payload itself lives in the sibling data files, NOT in this script:
    defender-off-system.reg    service/driver Start values ({{CS}} templated)
    defender-off-software.reg   feature + policy values
    defender-off.targets        the service list used for verification
  Keeping it out of the script text is deliberate -- see the README next to
  this file for the full rationale and the observations behind it.

.PARAMETER VhdxPath
  The .vhdx to service. It must NOT be attached to a running VM.

.PARAMETER Verify
  Read the values back after applying and throw if any did not take. Default
  on.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VhdxPath,
    [bool]$Verify = $true
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Log { param($m) Write-Host "harden-defender: $m" }

if (-not (Test-Path -LiteralPath $VhdxPath)) { throw "vhdx not found: $VhdxPath" }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sysTemplate = Join-Path $here 'defender-off-system.reg'
$softPayload = Join-Path $here 'defender-off-software.reg'
$targetsFile = Join-Path $here 'defender-off.targets'
foreach ($f in $sysTemplate, $softPayload, $targetsFile) {
    if (-not (Test-Path -LiteralPath $f)) { throw "payload file missing: $f" }
}
$targets = @(Get-Content -LiteralPath $targetsFile | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim() })

$mounted = $null
$loadedSys = $false
$loadedSoft = $false
$concreteSys = $null
$concreteSoft = $null

try {
    $mounted = Mount-VHD -Path $VhdxPath -Passthru | Get-Disk
    $vol = Get-Partition -DiskNumber $mounted.Number | Get-Volume |
        Where-Object { $_.DriveLetter } |
        Where-Object { Test-Path "$($_.DriveLetter):\Windows\System32\config\SYSTEM" } |
        Select-Object -First 1
    if (-not $vol) { throw "no Windows partition with a config hive on $VhdxPath" }
    $cfg = "$($vol.DriveLetter):\Windows\System32\config"
    Log "servicing hives under $cfg"

    & reg.exe load 'HKLM\HARDEN_SYS'  "$cfg\SYSTEM"   | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg load SYSTEM failed ($LASTEXITCODE)" }
    $loadedSys = $true
    & reg.exe load 'HKLM\HARDEN_SOFT' "$cfg\SOFTWARE" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg load SOFTWARE failed ($LASTEXITCODE)" }
    $loadedSoft = $true

    # The running control set of an installed image; Select\Current is
    # authoritative where a hardcoded ControlSet001 would only usually be
    # right.
    $cur = (Get-ItemProperty 'HKLM:\HARDEN_SYS\Select' -Name Current).Current
    $cs = 'ControlSet{0:D3}' -f $cur
    Log "current control set: $cs"

    # Both payloads are re-materialised to a temp file before import rather
    # than imported from the repo directly. reg.exe requires CRLF line
    # endings, and Set-Content supplies them regardless of how git checked the
    # file out (a .reg tracked with LF imports as "Error accessing the
    # registry", which names nothing useful). The system payload additionally
    # gets its {{CS}} placeholder resolved here.
    $concreteSys  = Join-Path $env:TEMP ("hd-sys-{0}.reg"  -f $PID)
    $concreteSoft = Join-Path $env:TEMP ("hd-soft-{0}.reg" -f $PID)
    ((Get-Content -Raw -LiteralPath $sysTemplate) -replace '\{\{CS\}\}', $cs) |
        Set-Content -LiteralPath $concreteSys -Encoding Ascii
    (Get-Content -Raw -LiteralPath $softPayload) |
        Set-Content -LiteralPath $concreteSoft -Encoding Ascii

    & reg.exe import $concreteSys | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg import (system) failed ($LASTEXITCODE)" }
    & reg.exe import $concreteSoft | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg import (software) failed ($LASTEXITCODE)" }

    if ($Verify) {
        $bad = @()
        foreach ($t in $targets) {
            $key = "HKLM\HARDEN_SYS\$cs\Services\$t"
            $q = & reg.exe query $key /v Start 2>&1
            if ($LASTEXITCODE -eq 0 -and ($q -join ' ') -notmatch '0x4\b') {
                $bad += "$t did not take"
            }
        }
        if ($bad) { throw "verification failed: $($bad -join '; ')" }
        Log "verified $($targets.Count) target(s) in $cs"
    }
} finally {
    # A GC before unload: reg.exe cannot unload a hive while .NET still holds a
    # handle opened by Get-ItemProperty above.
    [gc]::Collect(); [gc]::WaitForPendingFinalizers()
    if ($concreteSys -and (Test-Path -LiteralPath $concreteSys)) { [IO.File]::Delete($concreteSys) }
    if ($loadedSoft) { & reg.exe unload 'HKLM\HARDEN_SOFT' 2>&1 | Out-Null }
    if ($loadedSys)  { & reg.exe unload 'HKLM\HARDEN_SYS'  2>&1 | Out-Null }
    if ($mounted)    { Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue }
}

Log "done: $VhdxPath"
