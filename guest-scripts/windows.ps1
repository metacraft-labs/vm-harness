# vm-harness Tier-1 in-guest PowerShell runner.
#
# Generic primitives only — exec a command, install/uninstall an argv-trace
# shim, write rows to RESULT.txt, finalize with the DONE sentinel. Project-
# specific orchestration lives in the consumer's repo, NOT here.
#
# Used by the Hyper-V and UTM (Windows-on-ARM) backends.
#
# Subcommand surface (mirrors posix.sh):
#
#   -Subcommand exec -OutputDir <dir> [-Env @{...}] -Cmd <args>
#   -Subcommand install-trace-shim -RealBinary <name> -LogPath <path>
#   -Subcommand uninstall-trace-shim -RealBinary <name>
#   -Subcommand write-result -OutputDir <dir> -Step <name> -Status <ok|fail|skipped> [-ElapsedMs <int>]
#   -Subcommand finalize -OutputDir <dir> -Verdict <PASS|FAIL|ERROR|INCOMPLETE>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('exec','install-trace-shim','uninstall-trace-shim','write-result','finalize')]
    [string]$Subcommand,

    [string]$OutputDir,
    [hashtable]$Env,
    [string[]]$Cmd,

    [string]$RealBinary,
    [string]$LogPath,

    [string]$Step,
    [ValidateSet('ok','fail','skipped')]
    [string]$Status,
    [int]$ElapsedMs = -1,

    [ValidateSet('PASS','FAIL','ERROR','INCOMPLETE')]
    [string]$Verdict
)

$ErrorActionPreference = 'Stop'

$ShimTemplate = @'
"$([DateTimeOffset]::Now.ToUnixTimeMilliseconds())`t$($MyInvocation.MyCommand.Path) $($args -join ' ')" |
    Out-File -FilePath "@TRACE_LOG_PATH@" -Append -Encoding utf8
& "@REAL_BIN_PATH@" @args
exit $LASTEXITCODE
'@

function Get-SafeName {
    param([string]$s)
    if (-not $s) { return 'cmd' }
    $clean = ($s -replace '[^A-Za-z0-9_.-]', '_')
    if ($clean.Length -eq 0) { return 'cmd' }
    return $clean
}

function Resolve-RealBinary {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue |
           Where-Object { $_.Source -and -not (Test-Path "$($_.Source).real") } |
           Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-Exec {
    if (-not $OutputDir) { throw 'exec: -OutputDir is required' }
    if (-not $Cmd -or $Cmd.Count -lt 1) { throw 'exec: -Cmd is required' }
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $base = Get-SafeName ([System.IO.Path]::GetFileName($Cmd[0]))
    $outFile = Join-Path $OutputDir ("02-{0}-run.txt" -f $base)
    $n = 1
    while (Test-Path $outFile) {
        $outFile = Join-Path $OutputDir ("02-{0}-{1}-run.txt" -f $base, $n)
        $n++
    }
    "# cmd: $($Cmd -join ' ')" | Out-File -FilePath $outFile -Encoding utf8

    $tmpEnv = @{}
    if ($Env) {
        foreach ($k in $Env.Keys) {
            $tmpEnv[$k] = [Environment]::GetEnvironmentVariable($k)
            [Environment]::SetEnvironmentVariable($k, $Env[$k])
        }
    }
    $startTicks = [DateTime]::UtcNow.Ticks
    $exitCode = 0
    try {
        $output = & $Cmd[0] @($Cmd | Select-Object -Skip 1) 2>&1
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }
        $output | ForEach-Object { $_ | Out-String } | Add-Content -Path $outFile -Encoding utf8
    } catch {
        $_ | Out-String | Add-Content -Path $outFile -Encoding utf8
        $exitCode = 1
    } finally {
        if ($Env) {
            foreach ($k in $tmpEnv.Keys) {
                if ($null -eq $tmpEnv[$k]) {
                    [Environment]::SetEnvironmentVariable($k, $null)
                } else {
                    [Environment]::SetEnvironmentVariable($k, $tmpEnv[$k])
                }
            }
        }
    }
    $elapsedMs = [int](([DateTime]::UtcNow.Ticks - $startTicks) / 10000)
    "# exit_code: $exitCode" | Add-Content -Path $outFile -Encoding utf8
    "# elapsed_ms: $elapsedMs" | Add-Content -Path $outFile -Encoding utf8
    exit $exitCode
}

function Invoke-InstallTraceShim {
    if (-not $RealBinary) { throw 'install-trace-shim: -RealBinary is required' }
    if (-not $LogPath) { throw 'install-trace-shim: -LogPath is required' }
    $real = Resolve-RealBinary -Name $RealBinary
    if (-not $real) { throw "install-trace-shim: cannot find $RealBinary on PATH" }
    $backup = "$real.real"
    if (-not (Test-Path $backup)) {
        Copy-Item -LiteralPath $real -Destination $backup -Force
    }
    $shim = $ShimTemplate.Replace('@TRACE_LOG_PATH@', $LogPath).Replace('@REAL_BIN_PATH@', $backup)
    # If the wrapped binary is an .exe, install the shim as a sibling .ps1 with
    # the same stem (callers in PowerShell will resolve to either form). For
    # ergonomics we also rewrite the .exe as a tiny launcher that exec's
    # PowerShell with the .ps1 — simpler is to just drop the .ps1 and rely on
    # PowerShell auto-extension lookup. Backends are expected to install
    # their guest tools so the wrapped name resolves to PowerShell scripts.
    $shimPath = [System.IO.Path]::ChangeExtension($real, '.ps1')
    Set-Content -LiteralPath $shimPath -Value $shim -Encoding utf8
    if (-not (Test-Path $LogPath)) {
        New-Item -ItemType File -Force -Path $LogPath | Out-Null
    }
}

function Invoke-UninstallTraceShim {
    if (-not $RealBinary) { throw 'uninstall-trace-shim: -RealBinary is required' }
    $real = Get-Command $RealBinary -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty Source
    if (-not $real) { return }
    $backup = "$real.real"
    if (Test-Path $backup) {
        Copy-Item -LiteralPath $backup -Destination $real -Force
        Remove-Item -LiteralPath $backup -Force
    }
}

function Invoke-WriteResult {
    if (-not $OutputDir) { throw 'write-result: -OutputDir is required' }
    if (-not $Step) { throw 'write-result: -Step is required' }
    if (-not $Status) { throw 'write-result: -Status is required' }
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $resultFile = Join-Path $OutputDir 'RESULT.txt'
    if ($ElapsedMs -ge 0) {
        Add-Content -LiteralPath $resultFile -Encoding utf8 -Value ("step: {0}  status: {1}  elapsed_ms: {2}" -f $Step, $Status, $ElapsedMs)
    } else {
        Add-Content -LiteralPath $resultFile -Encoding utf8 -Value ("step: {0}  status: {1}" -f $Step, $Status)
    }
}

function Invoke-Finalize {
    if (-not $OutputDir) { throw 'finalize: -OutputDir is required' }
    if (-not $Verdict) { throw 'finalize: -Verdict is required' }
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    Add-Content -LiteralPath (Join-Path $OutputDir 'RESULT.txt') -Encoding utf8 -Value ("verdict: {0}" -f $Verdict)
    Set-Content -LiteralPath (Join-Path $OutputDir 'DONE') -Encoding utf8 -Value $Verdict
}

switch ($Subcommand) {
    'exec'                 { Invoke-Exec }
    'install-trace-shim'   { Invoke-InstallTraceShim }
    'uninstall-trace-shim' { Invoke-UninstallTraceShim }
    'write-result'         { Invoke-WriteResult }
    'finalize'             { Invoke-Finalize }
}
