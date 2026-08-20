<#
.SYNOPSIS
  Write a directory tree to an ISO9660+Joliet image on a Windows host.

.DESCRIPTION
  The Linux side of this recipe reaches for genisoimage/mkisofs/xorriso.
  None of those exist on Windows, and the Microsoft-blessed alternative
  (oscdimg) ships only in the Windows ADK — a separate multi-hundred-MB
  install we would then have to declare and converge on every build host.

  So: use oscdimg when it happens to be on PATH, and otherwise fall back
  to IMAPI2 (`IMAPI2FS.MsftFileSystemImage`), the CD-mastering COM
  service that has been in-box since Windows Vista. That makes seed-ISO
  creation a zero-dependency operation on any Windows host, which is what
  lets `build-golden.ps1` run on a freshly-imaged box.

  This writes a DATA ISO only — no El Torito boot record. That is all the
  autounattend seed needs (Windows Setup scans attached media for
  autounattend.xml at the root); do not reuse this to remaster a bootable
  Windows install ISO.

.PARAMETER SourceDir
  Directory whose *contents* become the ISO root.

.PARAMETER OutputPath
  Destination .iso path. Overwritten if it exists.

.PARAMETER VolumeName
  Volume label. Must be <= 32 chars for Joliet. Windows Setup does not
  care about the label, but AUTOUNATTEND makes it obvious in Disk
  Management which CD is which when debugging an install by hand.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [string]$VolumeName = 'AUTOUNATTEND'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
    throw "make-iso: source directory not found: $SourceDir"
}
if ($VolumeName.Length -gt 32) {
    throw "make-iso: volume name '$VolumeName' exceeds the 32-char Joliet limit"
}

$SourceDir = (Resolve-Path -LiteralPath $SourceDir).Path
$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}
if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }

# --- Path 1: oscdimg, when the ADK is already present -----------------------
$oscdimg = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
if ($oscdimg) {
    Write-Host "make-iso: using oscdimg ($($oscdimg.Source))"
    # -j1 = Joliet + ISO9660 in one image, matching the -J -r the Linux
    # branch passes to genisoimage. -u1 keeps long names readable.
    & $oscdimg.Source -j1 -u1 "-l$VolumeName" $SourceDir $OutputPath
    if ($LASTEXITCODE -ne 0) { throw "make-iso: oscdimg failed with exit code $LASTEXITCODE" }
    Write-Host "make-iso: wrote $OutputPath"
    return
}

# --- Path 2: IMAPI2, always available ---------------------------------------
Write-Host 'make-iso: oscdimg not on PATH; using in-box IMAPI2'

# IMAPI2 hands back the finished image as a COM IStream. .NET has no
# built-in "spool an IStream to disk", so add the smallest possible
# shim. Deliberately written without `unsafe` (the widely-copied
# New-ISOFile snippet takes the address of a local, which needs
# -CompilerParameters and an unsafe block); Marshal.AllocHGlobal does the
# same job in safe code and compiles under the in-box csc.
if (-not ('VmHarness.IsoStreamWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace VmHarness {
  public static class IsoStreamWriter {
    public static void Write(string path, object comStream, int blockSize, int totalBlocks) {
      IStream stream = (IStream)comStream;
      byte[] buffer = new byte[blockSize];
      IntPtr bytesRead = Marshal.AllocHGlobal(sizeof(int));
      try {
        using (FileStream fs = File.Create(path)) {
          for (int i = 0; i < totalBlocks; i++) {
            stream.Read(buffer, blockSize, bytesRead);
            int n = Marshal.ReadInt32(bytesRead);
            if (n <= 0) break;
            fs.Write(buffer, 0, n);
          }
          fs.Flush();
        }
      } finally {
        Marshal.FreeHGlobal(bytesRead);
        Marshal.ReleaseComObject(stream);
      }
    }
  }
}
'@
}

$fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
try {
    # 1 = ISO9660, 2 = Joliet, 4 = UDF. ISO9660|Joliet mirrors the
    # `-J -r` the Linux branch uses: 8.3 names for Setup's own parser,
    # long names for humans.
    $fsi.FileSystemsToCreate = 3
    $fsi.VolumeName = $VolumeName

    # $false = add the contents of SourceDir at the image root, rather
    # than nesting a directory named after it. Windows Setup only finds
    # autounattend.xml at the ROOT, so this flag is load-bearing.
    $fsi.Root.AddTree($SourceDir, $false)

    $img = $fsi.CreateResultImage()
    [VmHarness.IsoStreamWriter]::Write(
        $OutputPath, $img.ImageStream, $img.BlockSize, $img.TotalBlocks)
} finally {
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($fsi)
}

if (-not (Test-Path -LiteralPath $OutputPath)) {
    throw "make-iso: IMAPI2 reported success but produced no file at $OutputPath"
}
Write-Host ("make-iso: wrote {0} ({1:N0} bytes)" -f $OutputPath, (Get-Item -LiteralPath $OutputPath).Length)
