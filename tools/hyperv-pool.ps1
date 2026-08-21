<#
.SYNOPSIS
  Construct and manage a Hyper-V warm pool (recycle-from-pool-per-task).

.DESCRIPTION
  The Hyper-V implementation of the algorithm selected for this backend in
  docs/pool-algorithms.md. Measured on win-ci-bare-001, 2026-08-21:

    clone-per-task    Import 28.67 + Restore 2.16 + Resume 5.08 = 35.9 s
    recycle-per-task              Restore 2.16 + Resume 5.08 =  7.2 s
    cold boot, for reference                                 = 36   s

  so cloning per task buys nothing over a cold boot, while recycling a warm
  member is ~5x better. Cloning is still needed -- but only to change
  CAPACITY, which is what -Construct does, once, with nobody waiting.

  WHY EACH MEMBER IS RENAMED AND CHECKPOINTED SEPARATELY.

  A hot checkpoint captures RAM, and RAM contains the machine name and the
  DHCP lease. Two guests restored from ONE shared checkpoint therefore come
  up identical -- measured: both answered to WIN-EDC8DG9PTDT on
  172.27.94.244, which breaks the outbound reachability a CI runner exists
  to use. So the pool is N DISTINCT warm states, not N copies of one: each
  member is renamed, rebooted so the rename takes, and only then
  checkpointed as its own baseline.

  Sysprep is deliberately NOT used. /generalize forces OOBE on first boot,
  so a generalized image can only ever be cold-booted -- which throws away
  the 36 s -> 5 s the warm path exists for.

.PARAMETER Construct
  Build the pool: export the source VM once, then import, rename and
  checkpoint each member.

.PARAMETER Status
  Show members, their baselines and their current state.

.PARAMETER Teardown
  Remove every member VM and its files. Leaves the source VM alone.
#>
[CmdletBinding()]
param(
    [switch]$Construct,
    [switch]$Status,
    [switch]$Teardown,
    [switch]$Rebaseline,
    # Operate on ONE member instead of all of them. Needed because members
    # fail independently: one can be mid-Windows-Update while another is
    # healthy, and a whole-pool operation would either block on the sick one
    # or refuse to touch the healthy one.
    [string]$Member = '',
    [string]$SourceVm = 'repro-golden-win11-x64',
    [string]$SourceCheckpoint = 'pool-source',
    [int]$Size = 2,
    [string]$MemberPrefix = 'repro-pool',
    [string]$PoolRoot = 'C:\hyperv\pool',
    [string]$ExportRoot = 'C:\hyperv\pool-export',
    [string]$GuestUser = 'admin',
    [string]$GuestPassword = 'repro-windows-x64',
    [string]$SwitchName = 'Default Switch',
    # First boot after an import is FAR slower than a normal cold boot:
    # Windows re-detects devices behind a new VM id and a new MAC. Measured
    # on this host: 293s for the first member, against a 36s cold boot. A
    # 300s default put the second member 7s outside the window and failed
    # the whole construction, so this is deliberately generous -- it is paid
    # once per member, at capacity-change time, with nobody waiting.
    [int]$ReadyTimeoutSec = 1200
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

function Log { param($m) Write-Host "hyperv-pool: $m" }

function Get-GuestCred {
    $pw = ConvertTo-SecureString $GuestPassword -AsPlainText -Force
    New-Object System.Management.Automation.PSCredential($GuestUser, $pw)
}

function Wait-GuestReady {
    param([string]$Vm, [int]$TimeoutSec)
    # PowerShell Direct, not SSH or a network probe: it reaches the guest
    # over VMBus, so readiness does not depend on the very DHCP lease that
    # member renaming is about to churn.
    $cred = Get-GuestCred
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try {
            Invoke-Command -VMName $Vm -Credential $cred -ScriptBlock { 1 } -ErrorAction Stop | Out-Null
            return [math]::Round($sw.Elapsed.TotalSeconds, 2)
        } catch { Start-Sleep -Seconds 2 }
    }
    throw "guest '$Vm' was not reachable over PowerShell Direct within ${TimeoutSec}s"
}

function Wait-GuestSettled {
    param([string]$Vm, [int]$TimeoutSec = 600)
    # A baseline is only as good as the state it captures. Checkpointing a
    # guest that is still churning through post-boot work bakes that churn
    # into the baseline, so EVERY restore resumes into it and pays the cost
    # again -- measured: a baseline taken 10s after a reboot recycled to
    # ready in 40s, against 6.7s for a settled one, and the first PowerShell
    # Direct session after the restore broke outright.
    #
    # So wait for the guest to actually go quiet: host-side CPU low for
    # several consecutive samples AND a fast PowerShell Direct round trip.
    # CPU alone is not enough (it dips between bursts) and responsiveness
    # alone is not enough (it answers slowly while busy).
    $cred = Get-GuestCred
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $quiet = 0
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Seconds 10
        $cpu = (Get-VM -Name $Vm).CPUUsage
        $rt = [Diagnostics.Stopwatch]::StartNew()
        $responsive = $false
        try {
            Invoke-Command -VMName $Vm -Credential $cred -ScriptBlock { 1 } -ErrorAction Stop | Out-Null
            $responsive = $true
        } catch { }
        $rt.Stop()
        if ($cpu -le 5 -and $responsive -and $rt.Elapsed.TotalSeconds -lt 3) {
            $quiet++
            if ($quiet -ge 3) {
                Log "[$Vm] settled after $([math]::Round($sw.Elapsed.TotalSeconds,1))s (cpu=$cpu%, rtt=$([math]::Round($rt.Elapsed.TotalSeconds,2))s)"
                return
            }
        } else {
            $quiet = 0
        }
    }
    Log "[$Vm] WARNING: never went fully quiet in ${TimeoutSec}s; checkpointing anyway"
}

function Disable-GuestUpdateChurn {
    param([string]$Vm)
    # Windows Update is the enemy of a warm baseline, in two distinct ways.
    #
    # At construction: the golden had network while installing, so updates
    # were staged, and every member then applies them on FIRST BOOT --
    # observed on repro-pool-001, parked on "You are 1% there. Please keep
    # your computer on." past a 1200s timeout, while member 000 booted
    # minutes earlier and sailed through. That alone makes construction
    # non-deterministic.
    #
    # At run time it is worse: a member that decides to install updates
    # DURING a job burns CPU, can reboot the guest mid-run, and does it
    # differently on each member. An ephemeral CI runner does not want to be
    # patched; it wants to be identical to its baseline every single time.
    # Patching belongs to rebuilding the golden -- a deliberate, scheduled
    # act -- not to a runner mid-build.
    $cred = Get-GuestCred
    Invoke-Command -VMName $Vm -Credential $cred -ScriptBlock {
        $ErrorActionPreference = 'SilentlyContinue'
        foreach ($svc in 'wuauserv','UsoSvc','WaaSMedicSvc','DoSvc') {
            Stop-Service -Name $svc -Force
            Set-Service -Name $svc -StartupType Disabled
        }
        # Policy too, so the orchestrator cannot re-enable the services.
        $k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        New-Item -Path $k -Force | Out-Null
        Set-ItemProperty -Path $k -Name NoAutoUpdate -Value 1 -Type DWord
        Set-ItemProperty -Path $k -Name AUOptions    -Value 1 -Type DWord
        foreach ($tp in '\Microsoft\Windows\UpdateOrchestrator\',
                        '\Microsoft\Windows\WindowsUpdate\') {
            Get-ScheduledTask -TaskPath $tp | Disable-ScheduledTask | Out-Null
        }
    } | Out-Null
    Log "[$Vm] Windows Update disabled (services + policy + orchestrator tasks)"
}

function Get-PoolMembers {
    if ($Member) { return @(Get-VM -Name $Member -ErrorAction SilentlyContinue) }
    Get-VM | Where-Object { $_.Name -like "$MemberPrefix-*" } | Sort-Object Name
}

# ---------------------------------------------------------------- status ---
if ($Status) {
    $members = @(Get-PoolMembers)
    if ($members.Count -eq 0) { Log "no members (prefix '$MemberPrefix-')"; return }
    $members | ForEach-Object {
        $snaps = (Get-VMSnapshot -VMName $_.Name | Select-Object -Expand Name) -join ','
        [pscustomobject]@{
            Member    = $_.Name
            State     = $_.State
            Uptime    = $_.Uptime
            Baselines = $snaps
        }
    } | Format-Table -AutoSize
    return
}

# -------------------------------------------------------------- teardown ---
if ($Teardown) {
    foreach ($m in Get-PoolMembers) {
        Log "removing $($m.Name)"
        Stop-VM -Name $m.Name -TurnOff -Force -ErrorAction SilentlyContinue
        Remove-VM -Name $m.Name -Force
    }
    if (Test-Path -LiteralPath $PoolRoot) {
        Remove-Item -LiteralPath $PoolRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Log "pool torn down"
    return
}

# ------------------------------------------------------------ rebaseline ---
# Recapture a member's baseline from its CURRENT state, without rebuilding
# it. Needed because a baseline can be bad without the member being bad --
# most commonly captured before the guest finished settling, which makes
# every subsequent restore slow. Rebuilding a member costs ~10 minutes;
# this costs seconds.
if ($Rebaseline) {
    foreach ($m in Get-PoolMembers) {
        $n = $m.Name
        if ((Get-VM -Name $n).State -ne 'Running') { Start-VM -Name $n }
        $readyIn = Wait-GuestReady -Vm $n -TimeoutSec $ReadyTimeoutSec
        Log "[$n] reachable in ${readyIn}s"
        Disable-GuestUpdateChurn -Vm $n
        Wait-GuestSettled -Vm $n
        $old = Get-VMSnapshot -VMName $n -Name 'baseline' -ErrorAction SilentlyContinue
        if ($old) { Remove-VMSnapshot -VMSnapshot $old }
        $d = (Get-Date).AddMinutes(20)
        while ((Get-Date) -lt $d) {
            Start-Sleep -Seconds 5
            if (-not ((Get-VM -Name $n).Status -match 'Merg') -and
                -not (Get-VMSnapshot -VMName $n -Name 'baseline' -ErrorAction SilentlyContinue)) { break }
        }
        $t = [Diagnostics.Stopwatch]::StartNew()
        Checkpoint-VM -Name $n -SnapshotName 'baseline'
        $t.Stop()
        Log "[$n] baseline recaptured in $([math]::Round($t.Elapsed.TotalSeconds,2))s"
    }
    return
}

if (-not $Construct) { Log "nothing to do; pass -Construct, -Status or -Teardown"; return }

# ------------------------------------------------------------- construct ---
if (-not (Get-VM -Name $SourceVm -ErrorAction SilentlyContinue)) {
    throw "source VM '$SourceVm' not found"
}
if (-not (Get-VMSnapshot -VMName $SourceVm -Name $SourceCheckpoint -ErrorAction SilentlyContinue)) {
    throw "source checkpoint '$SourceCheckpoint' not found on '$SourceVm'"
}

# Export once and import N times, rather than exporting per member: the
# export is the expensive half and its result is identical for every member.
Log "exporting '$SourceVm' once as the member source"
if (Test-Path -LiteralPath $ExportRoot) {
    Remove-Item -LiteralPath $ExportRoot -Recurse -Force
}
$null = New-Item -ItemType Directory -Force -Path $ExportRoot
$sw = [Diagnostics.Stopwatch]::StartNew()
Stop-VM -Name $SourceVm -TurnOff -Force -ErrorAction SilentlyContinue
Export-VM -Name $SourceVm -Path $ExportRoot
$sw.Stop()
Log "export took $([math]::Round($sw.Elapsed.TotalSeconds,1))s"

# The VM config lives under 'Virtual Machines'. Picking the first *.vmcx
# found by a recursive search grabs the one under 'Snapshots' instead, which
# imports a VM frozen at that checkpoint WITH NO SNAPSHOT TREE -- the very
# thing the recycle path needs. Cost an hour the first time.
$srcVmcx = Get-ChildItem -Path $ExportRoot -Recurse -Filter *.vmcx |
           Where-Object { $_.Directory.Name -eq 'Virtual Machines' } |
           Select-Object -First 1
if (-not $srcVmcx) { throw "no VM config found under $ExportRoot" }

$null = New-Item -ItemType Directory -Force -Path $PoolRoot
$made = @()

for ($i = 0; $i -lt $Size; $i++) {
    $name = "$MemberPrefix-{0:d3}" -f $i
    if (Get-VM -Name $name -ErrorAction SilentlyContinue) {
        Log "$name already exists; skipping"
        continue
    }
    $dest = Join-Path $PoolRoot $name
    # Clear anything a previous failed attempt left behind. Remove-VM deletes
    # the VM but NOT its disks, so a member that died mid-construction leaves
    # a vhd/ directory that makes the next Import-VM fail with "the file
    # ... already exists" -- which reads as a bug in the import rather than
    # as leftovers, and blocks every subsequent retry.
    if (Test-Path -LiteralPath $dest) {
        Log "[$name] clearing stale files from a previous attempt"
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
    Log "[$name] importing"
    $t = [Diagnostics.Stopwatch]::StartNew()
    $imp = Import-VM -Path $srcVmcx.FullName -Copy -GenerateNewId `
             -VhdDestinationPath   (Join-Path $dest 'vhd') `
             -VirtualMachinePath   (Join-Path $dest 'vm') `
             -SnapshotFilePath     (Join-Path $dest 'snap') `
             -SmartPagingFilePath  (Join-Path $dest 'sp')
    Rename-VM -VM $imp -NewName $name
    $t.Stop()
    Log "[$name] imported in $([math]::Round($t.Elapsed.TotalSeconds,1))s"

    # A distinct MAC per member. Two members sharing one would collide on the
    # switch; and the dynamic pool is unreliable on a freshly enabled host
    # ("No available MAC address" with a healthy-looking range), so assign
    # explicitly out of the host's own range.
    $mac = '00155D64F1{0:X2}' -f (0xB0 + $i)
    Get-VMNetworkAdapter -VMName $name | Set-VMNetworkAdapter -StaticMacAddress $mac
    Connect-VMNetworkAdapter -VMName $name -SwitchName $SwitchName -ErrorAction SilentlyContinue

    # The inherited checkpoint (the SOURCE's warm state, carrying the
    # source's name and lease) is dropped LATER -- after this member has its
    # own baseline. Deleting it here and booting immediately is a race:
    # Remove-VMSnapshot returns before the .avhdx merge begins, so a
    # `Status -match 'Merg'` poll sees "Operating normally", exits at once,
    # and the VM is started while its disk chain is still being rewritten.
    # Observed exactly that: the guest hung on the Hyper-V boot splash at 0%
    # CPU for seven minutes.
    Log "[$name] booting to give it its own identity"
    Start-VM -Name $name
    $readyIn = Wait-GuestReady -Vm $name -TimeoutSec $ReadyTimeoutSec
    Log "[$name] reachable in ${readyIn}s"

    $cred = Get-GuestCred
    $current = Invoke-Command -VMName $name -Credential $cred -ScriptBlock { $env:COMPUTERNAME }
    if ($current -ne $name.ToUpper()) {
        Log "[$name] renaming guest ($current -> $name) and rebooting"
        Invoke-Command -VMName $name -Credential $cred -ScriptBlock {
            param($n)
            Rename-Computer -NewName $n -Force -ErrorAction Stop
        } -ArgumentList $name
        # A rename only takes at boot; without this the member would keep the
        # source's NetBIOS name and collide with its siblings.
        Restart-VM -Name $name -Force
        Start-Sleep -Seconds 5
        $readyIn = Wait-GuestReady -Vm $name -TimeoutSec $ReadyTimeoutSec
        Log "[$name] back up in ${readyIn}s"
    }

    # Silence Windows Update BEFORE settling, or the settle loop simply
    # waits out one update cycle and the baseline captures a guest that is
    # about to start another.
    Disable-GuestUpdateChurn -Vm $name

    # Let it settle so the captured state is genuinely warm, then checkpoint
    # THIS member's own baseline. A fixed sleep is not enough -- see
    # Wait-GuestSettled for what a too-early capture costs on every restore.
    Wait-GuestSettled -Vm $name
    $t = [Diagnostics.Stopwatch]::StartNew()
    Checkpoint-VM -Name $name -SnapshotName 'baseline'
    $t.Stop()
    $ident = Invoke-Command -VMName $name -Credential $cred -ScriptBlock {
        [pscustomobject]@{ CN = $env:COMPUTERNAME
                           IP = (Get-NetIPAddress -AddressFamily IPv4 |
                                 Where-Object { $_.IPAddress -notlike '127.*' } |
                                 Select-Object -First 1 -Expand IPAddress) }
    }
    Log "[$name] baseline checkpointed in $([math]::Round($t.Elapsed.TotalSeconds,2))s (name=$($ident.CN) ip=$($ident.IP))"

    # NOW drop the inherited source checkpoint -- this member has its own
    # baseline, so the source's warm state is dead weight that would also
    # leave the member restorable to a shared identity. Merging online is
    # safe here because nothing boots until it completes, and the wait polls
    # for the .avhdx to actually disappear rather than trusting VM Status.
    $inherited = Get-VMSnapshot -VMName $name | Where-Object { $_.Name -ne 'baseline' }
    foreach ($s in $inherited) {
        Log "[$name] dropping inherited checkpoint '$($s.Name)'"
        Remove-VMSnapshot -VMSnapshot $s
    }
    if ($inherited) {
        $d = (Get-Date).AddMinutes(20)
        while ((Get-Date) -lt $d) {
            Start-Sleep -Seconds 5
            $merging = (Get-VM -Name $name).Status -match 'Merg'
            $snapsLeft = @(Get-VMSnapshot -VMName $name | Where-Object { $_.Name -ne 'baseline' }).Count
            if (-not $merging -and $snapsLeft -eq 0) { break }
        }
        Log "[$name] merge complete"
    }
    $made += [pscustomobject]@{ Member = $name; Name = $ident.CN; IP = $ident.IP }
}

Log "pool constructed:"
$made | Format-Table -AutoSize

# Identity distinctness is the property the whole design rests on, so assert
# it rather than trusting the rename to have worked.
#
# Checked across EVERY member, not just the ones this run created. A run that
# adds one member to an existing pool would otherwise "verify" a set of one
# and prove nothing -- and a collision between a new member and an existing
# one is exactly the case worth catching.
#
# Every count is wrapped in @(). Under Set-StrictMode, Select-Object -Unique
# over a single item returns a bare string, and .Count on it throws
# "The property 'Count' cannot be found on this object" -- which is how this
# assertion failed on the run that added member 001 to a pool of one.
$all = @()
foreach ($m in Get-PoolMembers) {
    if ((Get-VM -Name $m.Name).State -ne 'Running') { continue }
    try {
        $id = Invoke-Command -VMName $m.Name -Credential (Get-GuestCred) -ErrorAction Stop -ScriptBlock {
            [pscustomobject]@{ CN = $env:COMPUTERNAME
                               IP = (Get-NetIPAddress -AddressFamily IPv4 |
                                     Where-Object { $_.IPAddress -notlike '127.*' } |
                                     Select-Object -First 1 -Expand IPAddress) }
        }
        $all += [pscustomobject]@{ Member = $m.Name; Name = $id.CN; IP = $id.IP }
    } catch {
        Log "WARNING: could not read identity of $($m.Name); excluded from the distinctness check"
    }
}
$all | Format-Table -AutoSize
$names = @($all | Select-Object -Expand Name)
$ips   = @($all | Select-Object -Expand IP)
if ($names.Count -ne @($names | Select-Object -Unique).Count) {
    throw "members share a computer name: $($names -join ', ') -- renaming failed, and restoring these would collide"
}
if ($ips.Count -ne @($ips | Select-Object -Unique).Count) {
    throw "members share an IP: $($ips -join ', ') -- the DHCP leases did not diverge"
}
Log "verified: all $($all.Count) member(s) have distinct computer names and IPs"
