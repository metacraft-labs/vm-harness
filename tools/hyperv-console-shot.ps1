<#
.SYNOPSIS
  Capture a Hyper-V guest's console to a PNG.

.DESCRIPTION
  The single most valuable diagnostic when bringing up Windows guests on
  Hyper-V, because the failures that matter are invisible from the host.
  Every one of these looked identical from `Get-VM` -- State=Running, low
  CPU -- and was obvious the moment the screen was captured:

    * "Press any key to boot from CD or DVD"   (unattended install never starts)
    * Hyper-V boot summary, "The boot loader failed"
    * Hyper-V boot splash, hung mid-merge after a snapshot delete
    * "You're 1% there. Please keep your computer on."  (Windows Update)

  A guest sitting at 0% CPU is not necessarily idle and is not necessarily
  slow; it may be waiting for a keystroke nobody will send. Look before
  theorising.

  Uses Msvm_VirtualSystemManagementService.GetVirtualSystemThumbnailImage,
  which returns RGB565 and needs no guest cooperation -- it works on a guest
  that has no network, no credentials, and no OS.

.PARAMETER VmName
  Guest to capture. Accepts a wildcard to capture several at once.

.PARAMETER OutputDir
  Where PNGs are written. Defaults to the current directory.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VmName,
    [string]$OutputDir = '.',
    [int]$Width = 1024,
    [int]$Height = 768
)

$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath','Machine')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$null = New-Item -ItemType Directory -Force -Path $OutputDir

$svc = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService

foreach ($vm in @(Get-VM -Name $VmName)) {
    $n = $vm.Name
    try {
        $vmc = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$n'"
        $vs = Get-CimAssociatedInstance -InputObject $vmc -ResultClassName Msvm_VirtualSystemSettingData |
              Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' }
        $r = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage `
               -Arguments @{ TargetSystem = $vs
                             WidthPixels  = [uint16]$Width
                             HeightPixels = [uint16]$Height }
        if ($r.ReturnValue -ne 0) { throw "GetVirtualSystemThumbnailImage returned $($r.ReturnValue)" }

        # RGB565 -> 24bpp. SetPixel is slow but a console thumbnail is tiny
        # and this keeps the script dependency-free.
        $bytes = $r.ImageData
        $bmp = New-Object Drawing.Bitmap($Width, $Height)
        for ($y = 0; $y -lt $Height; $y++) {
            for ($x = 0; $x -lt $Width; $x++) {
                $i = ($y * $Width + $x) * 2
                $px = [BitConverter]::ToUInt16($bytes, $i)
                $bmp.SetPixel($x, $y, [Drawing.Color]::FromArgb(
                    [int]((($px -shr 11) -band 0x1F) * 255 / 31),
                    [int]((($px -shr 5)  -band 0x3F) * 255 / 63),
                    [int](( $px          -band 0x1F) * 255 / 31)))
            }
        }
        $out = Join-Path $OutputDir "$n.png"
        $bmp.Save($out, [Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        "{0,-24} state={1,-8} cpu={2,3}% uptime={3}  -> {4}" -f `
            $n, $vm.State, $vm.CPUUsage, $vm.Uptime, $out
    } catch {
        "{0,-24} capture failed: {1}" -f $n, $_.Exception.Message
    }
}
