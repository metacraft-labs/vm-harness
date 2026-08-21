<#
.SYNOPSIS
  Build the Windows-x64 golden image on Hyper-V, unattended.

.DESCRIPTION
  The Hyper-V counterpart of build-sysprep-golden.sh, which is libvirt-only
  (qcow2, OVMF fd paths, virsh, qemu-img, virtio). This drives the same
  autounattend.xml -- built with `--target hyperv`, so the virtio
  driver-injection component is stripped -- against a Gen 2 VM.

  THREE THINGS WINDOWS 11 SETUP REFUSES WITHOUT, all of which fail the same
  unhelpful way (Setup stops at a graphical dialog, which from out here is
  indistinguishable from a slow install until the timeout fires):

    * TPM 2.0. Created via Set-VMKeyProtector THEN Enable-VMTPM -- that order
      is mandatory, because Enable-VMTPM fails on a VM with no key protector.
      The local key protector binds the VM's saved state to THIS host, which
      is fine for a runner pool that never leaves one box but means a vTPM
      guest cannot be migrated without re-keying.
    * >= 64 GB system disk. Setup's partitioning step fails on less.
    * Generation 2 / UEFI. Secure Boot stays ON with the MicrosoftWindows
      template, which Hyper-V selects by default -- unlike the libvirt path,
      which has to disable it because the nixpkgs OVMF ships no
      MS-key-enrolled vars template.

  COMPLETION SIGNAL. The autounattend's last FirstLogonCommand shuts the
  guest down. libvirt reads that through `virt-install --wait`; here it is
  simply the VM reaching State=Off after having been Running. That is the
  only in-band signal available without networking into the guest, so it is
  what this script waits on. A guest that is still Running at the deadline
  is a FAILURE, not a slow success -- Setup sitting on a dialog looks exactly
  like this.

  A NIC IS REQUIRED, unlike the transient boot-probe VMs the backend makes.
  The autounattend's FirstLogonCommands download OpenSSH and PortableGit, so
  the guest needs a route out. Default Switch (NAT) suffices.

.PARAMETER WindowsIso
  Path to the Windows 11 x64 install ISO (multi-edition; the unattend
  selects "Windows 11 Pro" by /IMAGE/NAME).

.PARAMETER AutounattendIso
  Path to the seed ISO from `build-autounattend-iso.sh --target hyperv`.

.PARAMETER VmName
  Name of the transient build VM. Removed on success unless -KeepVm.

.PARAMETER OutputVhdx
  Where the finished golden disk is left.

.PARAMETER TimeoutMinutes
  How long to wait for the unattended install. The libvirt recipe documents
  25-50 minutes wall-clock for OOBE; the default here is deliberately well
  clear of that.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WindowsIso,
    [Parameter(Mandatory = $true)][string]$AutounattendIso,
    [string]$VmName = 'repro-golden-win11-x64',
    [string]$OutputVhdx = 'C:\hyperv\golden\win11-x64-golden.vhdx',
    [int]$MemoryMB = 8192,
    [int]$Cpus = 4,
    [int]$DiskGB = 80,
    [string]$SwitchName = 'Default Switch',
    [string]$StaticMacAddress = '00155D64F1A0',
    # Must match the LocalAccount/AutoLogon credentials baked into
    # autounattend.xml; PowerShell Direct authenticates with them.
    [string]$GuestUser = 'admin',
    [string]$GuestPassword = 'repro-windows-x64',
    [int]$TimeoutMinutes = 90,
    [switch]$KeepVm
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Log { param($m) Write-Host "build-golden-hyperv: $m" }

foreach ($p in @($WindowsIso, $AutounattendIso)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "not found: $p" }
}
if ($DiskGB -lt 64) {
    throw "DiskGB=$DiskGB is below Windows 11 Setup's 64 GB floor; it will fail at partitioning."
}

$outDir = Split-Path -Parent $OutputVhdx
$null = New-Item -ItemType Directory -Force -Path $outDir
$workDir = Join-Path $outDir "build-$VmName"
$null = New-Item -ItemType Directory -Force -Path $workDir
$vhd = Join-Path $workDir "$VmName.vhdx"

# --- clean slate -----------------------------------------------------------
if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
    Log "removing pre-existing VM $VmName"
    Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
    Remove-VM -Name $VmName -Force
}
if (Test-Path -LiteralPath $vhd) { Remove-Item -LiteralPath $vhd -Force }

# --- create ----------------------------------------------------------------
Log "creating $VmName (gen 2, ${Cpus} vCPU, ${MemoryMB} MB, ${DiskGB} GB)"
New-VHD -Path $vhd -SizeBytes ([int64]$DiskGB * 1GB) -Dynamic | Out-Null
New-VM -Name $VmName -Generation 2 -MemoryStartupBytes ([int64]$MemoryMB * 1MB) `
       -VHDPath $vhd -Path $workDir | Out-Null
Set-VMProcessor -VMName $VmName -Count $Cpus
# Fixed memory: dynamic memory during Setup causes needless ballooning work
# and the box has RAM to spare.
Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false
# Setup reboots several times; without this the VM stops at the first one.
# AutomaticCheckpointsEnabled, NOT CheckpointType Disabled. The goal is only
# to stop Hyper-V taking an automatic checkpoint every time the VM starts;
# `-CheckpointType Disabled` also forbids taking them MANUALLY, which breaks
# the primitive this whole image exists to feed -- Checkpoint-VM is the
# per-job reset for the ephemeral-runner pool. Setting it here cost a
# "Checkpoint operation failed / Checkpoints have been disabled" at capture
# time, on the golden, after a successful hour-long install.
Set-VM -Name $VmName -AutomaticStopAction ShutDown `
       -CheckpointType Standard -AutomaticCheckpointsEnabled $false

if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue) {
    Connect-VMNetworkAdapter -VMName $VmName -SwitchName $SwitchName
    # STATIC MAC, not the dynamic pool. On win-ci-bare-001 (Hyper-V freshly
    # enabled, 2026-08-20) Start-VM failed with
    #   "No available MAC address for Network Adapter"
    #   Synthetic Ethernet Port ... 'Attempt to access invalid address.' (0x800701E7)
    # even though Get-VMHost reported a healthy 256-address pool
    # (00155D64F100-F1FF) with a single adapter using it. Assigning a static
    # address out of that same range starts the VM immediately, so the pool
    # allocator -- not the range -- is what is broken on a newly enabled host.
    # A build VM wants a deterministic MAC anyway.
    if ($StaticMacAddress) {
        Set-VMNetworkAdapter -VMName $VmName -StaticMacAddress $StaticMacAddress
        Log "connected to switch '$SwitchName' (static MAC $StaticMacAddress)"
    } else {
        Log "connected to switch '$SwitchName' (dynamic MAC -- see the note above if Start-VM fails)"
    }
} else {
    Log "WARNING: switch '$SwitchName' not found -- the guest will have NO network."
    Log "         FirstLogonCommands that fetch OpenSSH/PortableGit will fail."
}

Set-VMFirmware -VMName $VmName -EnableSecureBoot On
Set-VMKeyProtector -VMName $VmName -NewLocalKeyProtector
Enable-VMTPM -VMName $VmName
Log "vTPM enabled, Secure Boot on ($((Get-VMFirmware -VMName $VmName).SecureBootTemplate))"

Add-VMDvdDrive -VMName $VmName -Path $WindowsIso
Add-VMDvdDrive -VMName $VmName -Path $AutounattendIso
$dvd = Get-VMDvdDrive -VMName $VmName | Where-Object { $_.Path -eq $WindowsIso }
Set-VMFirmware -VMName $VmName -FirstBootDevice $dvd
Log "install media attached; booting from DVD"

# --- run -------------------------------------------------------------------
Start-VM -Name $VmName
$startedAt = Get-Date

# DISMISS "Press any key to boot from CD or DVD".
#
# This is the single thing that stops an unattended Hyper-V Windows install
# dead, and it is invisible unless you look at the console: the firmware's
# boot summary reports
#     1. SCSI DVD (0,1)   The boot loader failed.
# for the install ISO, while the seed ISO on the next slot reports the
# different message "did not load an operating system". That asymmetry is
# the tell -- the Windows loader RAN, printed its prompt, got no key, and
# returned; the seed ISO simply has no loader. The VM then sits at the boot
# summary at 0% CPU, which is easily mistaken for a slow install.
#
# The libvirt path never hits this because virt-install boots the ISO
# directly. Remastering the media with efisys_noprompt.bin would also fix
# it, but that needs oscdimg from the ADK -- the very dependency make-iso.ps1
# exists to avoid. Typing a key costs nothing and needs no extra tooling.
#
# The keyboard device only exists while the VM is running, so it is acquired
# AFTER Start-VM, with a short retry.
$kbd = $null
for ($i = 0; $i -lt 20 -and -not $kbd; $i++) {
    Start-Sleep -Milliseconds 250
    $vmc = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem `
             -Filter "ElementName='$VmName'" -ErrorAction SilentlyContinue
    if ($vmc) {
        $kbd = Get-CimAssociatedInstance -InputObject $vmc -ResultClassName Msvm_Keyboard -ErrorAction SilentlyContinue
    }
}
if ($kbd) {
    # Spam rather than time it: the prompt appears a few seconds in and lasts
    # only about five, and a missed window costs a whole boot cycle.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $sent = 0
    while ($sw.Elapsed.TotalSeconds -lt 30) {
        try {
            Invoke-CimMethod -InputObject $kbd -MethodName TypeKey -Arguments @{ keyCode = [uint32]0x0D } | Out-Null
            $sent++
        } catch { }
        Start-Sleep -Milliseconds 400
    }
    Log "sent $sent keypresses to clear the boot prompt"
} else {
    Log "WARNING: no Msvm_Keyboard; if the guest never boots, it is parked on"
    Log "         'Press any key to boot from CD or DVD' at 0% CPU."
}
Log "started at $startedAt; polling for the install-done sentinel over PowerShell Direct"

# COMPLETION SIGNAL: poll the guest, do not wait for it to power itself off.
#
# The autounattend's last FirstLogonCommand is `shutdown /s /t 5`, which is
# how the libvirt path signals completion (`virt-install --wait` watches the
# domain go down). Measured here 2026-08-20: that step DOES NOT fire on
# Hyper-V. The sentinel one command earlier was written at 22:22:57, and an
# hour later the guest was still Running with no 1074 shutdown event in its
# System log at all. Waiting on power-off therefore hangs forever on a guest
# that finished installing in ~10 minutes.
#
# Hyper-V has a better signal available that libvirt does not: PowerShell
# Direct reaches the guest over VMBus with no networking, no SSH, no
# credentials plumbed through a config drive. So ask the guest directly
# whether it is done, which also distinguishes "still installing" from
# "finished but did not shut down" -- states that are indistinguishable from
# outside the VM.
$sentinel = 'C:\Windows\Temp\repro-install-done'
$deadline = $startedAt.AddMinutes($TimeoutMinutes)
$done = $false
$pw = ConvertTo-SecureString $GuestPassword -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($GuestUser, $pw)

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 20
    # Before the guest finishes installing, PowerShell Direct simply refuses
    # to connect -- that is the expected state, not an error worth logging.
    try {
        $ok = Invoke-Command -VMName $VmName -Credential $cred -ErrorAction Stop `
                -ScriptBlock { param($p) Test-Path $p } -ArgumentList $sentinel
        if ($ok) {
            $mins = [math]::Round(((Get-Date) - $startedAt).TotalMinutes, 1)
            Log "sentinel present after $mins min -- unattended install complete"
            $done = $true
            break
        }
    } catch { }
}

if (-not $done) {
    Log "TIMEOUT after $TimeoutMinutes min (state=$((Get-VM -Name $VmName).State))."
    Log "Capture the console before assuming it is slow -- every stall seen so far"
    Log "was visible on screen and invisible from the VM's state:"
    Log "  'Press any key to boot from CD or DVD'  -> 0% CPU, 4 MB disk, looks hung"
    Log "  Setup error dialog                      -> Running forever"
    Log "Thumbnail: Msvm_VirtualSystemManagementService.GetVirtualSystemThumbnailImage"
    Log "or attach interactively: vmconnect.exe localhost $VmName"
    Log "The VM and its disk are left in place for diagnosis: $vhd"
    exit 1
}

# Shut the guest down ourselves, since it will not do it. Stop-VM is a
# graceful ACPI shutdown; -TurnOff would be a power cut and risks an unclean
# image, which is the one thing a golden must not be.
Log "shutting the guest down cleanly"
Stop-VM -Name $VmName -Force
$offDeadline = (Get-Date).AddMinutes(10)
while ((Get-VM -Name $VmName).State -ne 'Off' -and (Get-Date) -lt $offDeadline) {
    Start-Sleep -Seconds 10
}
if ((Get-VM -Name $VmName).State -ne 'Off') {
    Log "guest did not stop within 10 min; forcing it off"
    Stop-VM -Name $VmName -TurnOff -Force
}

# --- harden the image before capture ----------------------------------------
#
# Two properties that are part of the ALGORITHM, not setup taste. Both were
# learned by shipping a golden without them.
#
# 1. WINDOWS UPDATE OFF. The install has network for ~an hour, so updates get
#    staged into the image. Every guest cloned from it then applies them on
#    FIRST BOOT -- one pool member sat at "You're 1% there. Please keep your
#    computer on." for over an hour -- and, worse, would apply them MID-JOB,
#    burning CPU and potentially rebooting under a build. An ephemeral runner
#    wants to be identical to its baseline every cycle; patching belongs to
#    rebuilding this image, which is a deliberate scheduled act.
#    Measured effect on a pool member: settle time 280s -> 33s, checkpoint
#    92.78s -> 7.9s.
#
# 2. POWERSHELL 7. The first real job dispatched at this pool failed with
#    "pwsh: command not found" -- the image shipped Windows PowerShell 5.1
#    only, and a great many workflows use `shell: pwsh`. A registration-only
#    smoke test would have gone green on a runner that fails every real job.
$pwHard = ConvertTo-SecureString $GuestPassword -AsPlainText -Force
$credHard = New-Object System.Management.Automation.PSCredential($GuestUser, $pwHard)

Log "disabling Windows Update in the image"
Invoke-Command -VMName $VmName -Credential $credHard -ScriptBlock {
    $ErrorActionPreference = 'SilentlyContinue'
    foreach ($s in 'wuauserv','UsoSvc','WaaSMedicSvc','DoSvc') {
        Stop-Service -Name $s -Force
        Set-Service -Name $s -StartupType Disabled
    }
    $k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    New-Item -Path $k -Force | Out-Null
    Set-ItemProperty -Path $k -Name NoAutoUpdate -Value 1 -Type DWord
    Set-ItemProperty -Path $k -Name AUOptions    -Value 1 -Type DWord
    foreach ($tp in '\Microsoft\Windows\UpdateOrchestrator\',
                    '\Microsoft\Windows\WindowsUpdate\') {
        Get-ScheduledTask -TaskPath $tp | Disable-ScheduledTask | Out-Null
    }
} | Out-Null

$pwshProvisioner = Join-Path $PSScriptRoot '..\lib\provision-pwsh.ps1'
if (Test-Path -LiteralPath $pwshProvisioner) {
    Log "installing PowerShell 7 (pinned by ../lib/provision-pwsh.ps1)"
    $body = Get-Content -Raw -LiteralPath $pwshProvisioner
    Invoke-Command -VMName $VmName -Credential $credHard -ScriptBlock {
        param($b)
        Set-Content -LiteralPath 'C:\Windows\Temp\provision-pwsh.ps1' -Value $b -Encoding UTF8
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Windows\Temp\provision-pwsh.ps1' 2>&1 | Out-String
    } -ArgumentList $body | Out-Null
    $hasPwsh = Invoke-Command -VMName $VmName -Credential $credHard -ScriptBlock { Test-Path 'C:\pwsh\pwsh.exe' }
    if (-not $hasPwsh) { throw "PowerShell 7 provisioning did not produce C:\pwsh\pwsh.exe" }
    Log "PowerShell 7 present"
} else {
    Log "WARNING: ../lib/provision-pwsh.ps1 not found; image will ship WITHOUT pwsh"
    Log "         and any workflow using 'shell: pwsh' will fail on it."
}

# --- capture ---------------------------------------------------------------
Log "detaching install media"
Get-VMDvdDrive -VMName $VmName | Remove-VMDvdDrive

if (Test-Path -LiteralPath $OutputVhdx) { Remove-Item -LiteralPath $OutputVhdx -Force }
Log "capturing golden disk to $OutputVhdx"
# Move rather than copy: the build VHDX is already exactly the artifact, and
# an 80 GB copy is pure wall-clock. Remove the VM first so nothing holds it.
if (-not $KeepVm) {
    Remove-VM -Name $VmName -Force
    Move-Item -LiteralPath $vhd -Destination $OutputVhdx
    Log "build VM removed"
} else {
    Copy-Item -LiteralPath $vhd -Destination $OutputVhdx
    Log "build VM kept as $VmName (-KeepVm)"
}

$g = Get-Item -LiteralPath $OutputVhdx
Log "golden ready: $OutputVhdx ($([math]::Round($g.Length/1GB,2)) GB on disk)"
Log "next: sysprep/generalize, then checkpoint for the per-job clone path"
