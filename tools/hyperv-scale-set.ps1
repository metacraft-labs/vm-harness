<#
.SYNOPSIS
  Run a GitHub Actions scale set on a Hyper-V warm pool.

.DESCRIPTION
  Drives the recycle-from-pool-per-task algorithm against the members built
  by hyperv-pool.ps1. Per member, forever:

    1. mint a fresh runner registration token on the HOST
    2. configure an --ephemeral runner inside the member (PowerShell Direct)
    3. run it; it accepts exactly ONE job and exits
    4. restore the member to ITS baseline and resume  <- the recycle
    5. repeat

  WHY THE RUNNER IS EPHEMERAL AND THE VM IS NOT.

  `--ephemeral` makes the runner process exit after a single job, which is
  what gives GitHub-side isolation (the registration is consumed, so no
  second job can land on dirty state). The VM is then restored, which gives
  filesystem isolation. Neither alone is enough: an ephemeral runner in a
  reused VM leaks the filesystem, and a restored VM with a long-lived runner
  can be handed a second job mid-restore.

  WHY THE TOKEN IS MINTED PER CYCLE.

  Because it EXPIRES (one hour), not because it is consumed. Registration
  tokens are reusable within their TTL -- verified on 2026-08-21 by
  registering two runners with one token, both succeeding -- so an earlier
  comment here claiming they are single-use was wrong.

  The distinction matters for how this daemon gets its token. Minting per
  cycle via `gh` needs an interactive login, which SYSTEM does not have at
  boot; but win-ci-bare-001 already receives a freshly minted token every 10
  minutes through the deploy-agent's sealed section, and one such token can
  register EVERY member of the pool for the hour it lives. That makes the
  existing channel sufficient for an unattended daemon, with no new secret
  on the box.

  What the TTL does rule out is baking a token into the baseline checkpoint,
  which is why the baseline is captured with the runner INSTALLED BUT
  UNCONFIGURED. Every cycle configures from clean.

  WHERE THE RECYCLE COST SITS. Step 4 runs after the job finishes, not
  before the next one starts, so a member is already warm when work arrives.
  Measured on this host: restore + resume is 12-19 s, against a 36 s cold
  boot -- but only if it happens off the critical path. That figure is
  variable and has been seen far higher on a long-uptime host; see
  docs/pool-algorithms.md before planning against a smaller one.

.PARAMETER Org
  GitHub org the runners register with.

.PARAMETER Labels
  Comma-separated runner labels. These decide which `runs-on` reaches this
  pool.

.PARAMETER Once
  Run a single job per member and stop, instead of looping. For proving the
  mechanism without leaving a daemon behind.
#>
[CmdletBinding()]
param(
    [string]$Org = 'metacraft-labs',
    [string]$Labels = 'self-hosted,Windows,X64,eph-win-x64-hv',
    [string]$MemberPrefix = 'repro-pool',
    [string]$GuestUser = 'admin',
    [string]$GuestPassword = 'repro-windows-x64',
    [string]$RunnerDir = 'C:\actions-runner',
    [int]$ReadyTimeoutSec = 300,
    [int]$JobTimeoutSec = 3600,
    # Serve ONE member. The parent invocation spawns one child process per
    # member with this set; without it the parent would enumerate members and
    # spawn children forever.
    [string]$Member = '',
    # A member that fails this many cycles in a row is parked rather than
    # retried forever. A wedged member that keeps re-registering looks like
    # capacity to GitHub while accepting jobs it cannot run, which is worse
    # than being one member short.
    [int]$MaxConsecutiveFailures = 3,
    [switch]$Once
)

# PSModulePath hygiene, FIRST, before any cmdlet that is not an autoloaded
# core builtin. A launcher -- Git Bash, a pwsh 7 shell, a scheduled task --
# can leak a PSModulePath that makes Windows PowerShell 5.1 resolve core
# modules to pwsh 7's copies, or fail to find them at all. Observed here as
# "The 'ConvertTo-SecureString' command was found in the module
# 'Microsoft.PowerShell.Security', but the module could not be loaded",
# mid-way through building a pool. Resetting to the machine value makes the
# script independent of however it was invoked.
$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath','Machine')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Log { param($m) Write-Host ("[{0:HH:mm:ss}] scale-set: {1}" -f (Get-Date), $m) }

function Get-GuestCred {
    $pw = ConvertTo-SecureString $GuestPassword -AsPlainText -Force
    New-Object System.Management.Automation.PSCredential($GuestUser, $pw)
}

function Wait-GuestReady {
    param([string]$Vm, [int]$TimeoutSec)
    $cred = Get-GuestCred
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try {
            Invoke-Command -VMName $Vm -Credential $cred -ScriptBlock { 1 } -ErrorAction Stop | Out-Null
            return [math]::Round($sw.Elapsed.TotalSeconds, 2)
        } catch { Start-Sleep -Seconds 2 }
    }
    throw "guest '$Vm' not reachable within ${TimeoutSec}s"
}

function New-RegistrationToken {
    # Minted on the HOST: the guest has no credentials and should not. Fetched
    # per cycle because the token expires in an hour -- not because it is
    # consumed; it is reusable within that hour (see the header).
    $t = (& gh api -X POST "/orgs/$Org/actions/runners/registration-token" --jq '.token' 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not $t -or $t.Length -lt 20) {
        throw "could not mint a registration token: $t"
    }
    "$t".Trim()
}

function Restore-Member {
    param([string]$Vm)
    # THE RECYCLE. Everything the job wrote is discarded here, and the member
    # comes back as itself -- its own computer name and its own DHCP lease --
    # because the baseline was captured per member.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $snap = Get-VMSnapshot -VMName $Vm -Name 'baseline' -ErrorAction Stop
    Restore-VMCheckpoint -VMSnapshot $snap -Confirm:$false
    if ((Get-VM -Name $Vm).State -ne 'Running') { Start-VM -Name $Vm }
    $readyIn = Wait-GuestReady -Vm $Vm -TimeoutSec $ReadyTimeoutSec
    $sw.Stop()
    Log "[$Vm] recycled in $([math]::Round($sw.Elapsed.TotalSeconds,2))s (ready $readyIn s)"
}

function Invoke-OneJobCycle {
    param([string]$Vm)
    $cred = Get-GuestCred
    $token = New-RegistrationToken
    $runnerName = "$Vm-$((Get-Date).ToString('HHmmss'))"

    Log "[$Vm] configuring ephemeral runner '$runnerName'"
    Invoke-Command -VMName $Vm -Credential $cred -ScriptBlock {
        param($dir, $url, $tok, $name, $labels)
        $ErrorActionPreference = 'Stop'
        Set-Location $dir
        # --ephemeral: accept exactly one job then exit. --replace so a
        # stale registration with the same name cannot block config.
        & "$dir\config.cmd" --unattended --ephemeral --replace `
            --url $url --token $tok --name $name --labels $labels `
            --work '_work' 2>&1 | Out-String
    } -ArgumentList $RunnerDir, "https://github.com/$Org", $token, $runnerName, $Labels | Out-Null

    Log "[$Vm] runner online, waiting for a job (timeout ${JobTimeoutSec}s)"
    # run.cmd blocks until the single job completes, then exits. Its exit is
    # the signal that the task is done -- but it is NOT proof that a job ever
    # ran. A runner whose registration is rejected exits just as promptly, so
    # both the exit code and the transcript are checked below.
    $r = Invoke-Command -VMName $Vm -Credential $cred -ScriptBlock {
        param($dir)
        Set-Location $dir
        $text = & "$dir\run.cmd" 2>&1 | Out-String
        [pscustomobject]@{ Out = $text; ExitCode = $LASTEXITCODE }
    } -ArgumentList $RunnerDir
    Log "[$Vm] runner exited"
    $out = $r.Out
    if ($out) {
        ($out -split "`n" | Select-Object -Last 6) | ForEach-Object { Log "[$Vm]   $($_.Trim())" }
    }

    # DID A JOB ACTUALLY RUN? The runner prints this line exactly once per job
    # it executes, carrying that job's own conclusion. Treating "run.cmd
    # exited" as "job finished" was wrong: a listener that comes up, fails to
    # create a session and leaves looks identical, so the loop would recycle
    # and immediately re-register -- spinning through registration tokens
    # while the log reported finished jobs and the pool served nothing. That
    # is precisely the false-green this campaign keeps hitting, so an
    # unserved cycle must raise and count toward the parking threshold.
    $m = [regex]::Match($out, 'completed with result:\s*(\w+)')
    if (-not $m.Success) {
        $tail = ($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1) -replace '\s+', ' '
        throw "runner exited WITHOUT serving a job (exit code $($r.ExitCode)); last line: $tail"
    }

    # A job that FAILED is a legitimate outcome of somebody's workflow, not a
    # sick member -- it must not count toward parking. Only "no job at all"
    # indicts the member.
    Log "[$Vm] job completed with result: $($m.Groups[1].Value) (runner exit $($r.ExitCode))"
}

# ------------------------------------------------------------------ main ---

function Invoke-ServeLoop {
    param([string]$Vm)
    # The per-member loop. Each pass serves exactly one job and then recycles,
    # so isolation holds at both layers: --ephemeral consumes the GitHub-side
    # registration, and the restore discards everything written to disk.
    if (-not (Get-VMSnapshot -VMName $Vm -Name 'baseline' -ErrorAction SilentlyContinue)) {
        throw "member '$Vm' has no 'baseline' checkpoint; run hyperv-pool.ps1 -Construct"
    }
    $fails = 0
    $cycle = 0
    while ($true) {
        $cycle++
        try {
            if ((Get-VM -Name $Vm).State -ne 'Running') { Start-VM -Name $Vm }
            Wait-GuestReady -Vm $Vm -TimeoutSec $ReadyTimeoutSec | Out-Null
            Invoke-OneJobCycle -Vm $Vm
            Restore-Member -Vm $Vm
            $fails = 0
        } catch {
            $fails++
            Log "[$Vm] cycle $cycle failed ($fails/$MaxConsecutiveFailures): $($_.Exception.Message)"
            if ($fails -ge $MaxConsecutiveFailures) {
                Log "[$Vm] PARKED after $fails consecutive failures. It is NOT serving."
                Log "[$Vm] capture the console before assuming it is slow:"
                Log "[$Vm]   tools/hyperv-console-shot.ps1 -VmName $Vm"
                Log "[$Vm] then rebuild it: tools/hyperv-pool.ps1 -Rebaseline -Member $Vm"
                return
            }
            # Try to get back to a known state before the next attempt. A
            # member left mid-cycle has a half-configured runner, which makes
            # the next config.cmd fail too and turns one bad cycle into a
            # permanent one.
            try { Restore-Member -Vm $Vm } catch { Log "[$Vm] recovery restore also failed: $($_.Exception.Message)" }
        }
        if ($Once) { Log "[$Vm] -Once: stopping after one cycle"; return }
    }
}

if ($Member) {
    Log "serving member $Member (labels: $Labels)"
    Invoke-ServeLoop -Vm $Member
    return
}

$members = @(Get-VM | Where-Object { $_.Name -like "$MemberPrefix-*" } | Sort-Object Name)
if ($members.Count -eq 0) {
    throw "no pool members found (prefix '$MemberPrefix-'); run hyperv-pool.ps1 -Construct"
}
foreach ($m in $members) {
    if (-not (Get-VMSnapshot -VMName $m.Name -Name 'baseline' -ErrorAction SilentlyContinue)) {
        throw "member '$($m.Name)' has no 'baseline' checkpoint; run hyperv-pool.ps1 -Construct"
    }
}
Log "pool has $($members.Count) member(s): $(($members | Select-Object -Expand Name) -join ', ')"
Log "labels: $Labels"

# One CHILD PROCESS per member, each with -Member so it serves exactly one.
# Separate processes rather than Start-Job: a job shares the parent runspace,
# and PowerShell Direct sessions from inside a job are unreliable, which
# matters because every guest interaction here goes through one.
$procs = @()
foreach ($m in $members) {
    $args = @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
        '-File', $PSCommandPath,
        '-Member', $m.Name,
        '-Org', $Org, '-Labels', $Labels,
        '-GuestUser', $GuestUser, '-GuestPassword', $GuestPassword,
        '-RunnerDir', $RunnerDir,
        '-ReadyTimeoutSec', $ReadyTimeoutSec,
        '-JobTimeoutSec', $JobTimeoutSec,
        '-MaxConsecutiveFailures', $MaxConsecutiveFailures
    )
    if ($Once) { $args += '-Once' }
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -PassThru -NoNewWindow
    $procs += [pscustomobject]@{ Member = $m.Name; Process = $p }
    Log "[$($m.Name)] worker pid $($p.Id)"
}

Log "started $($procs.Count) worker(s); Ctrl-C to stop"
try {
    while ($true) {
        Start-Sleep -Seconds 15
        $alive = @($procs | Where-Object { -not $_.Process.HasExited })
        if ($alive.Count -eq 0) { Log "all workers exited"; break }
        foreach ($x in $procs) {
            if ($x.Process.HasExited -and -not $x.PSObject.Properties['Reported']) {
                Add-Member -InputObject $x -NotePropertyName Reported -NotePropertyValue $true
                # WaitForExit() returns immediately (the process is already
                # gone), but it is what makes ExitCode readable: with
                # Start-Process -PassThru the property stays empty until the
                # handle is reaped, so this line used to log "code )" and tell
                # an operator nothing about whether the worker finished its
                # -Once cycle or died.
                $x.Process.WaitForExit()
                Log "[$($x.Member)] worker exited (code $($x.Process.ExitCode)) -- that member is no longer serving"
            }
        }
    }
} finally {
    foreach ($x in $procs) {
        if (-not $x.Process.HasExited) {
            Log "[$($x.Member)] stopping worker pid $($x.Process.Id)"
            Stop-Process -Id $x.Process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
