# assert-defender-exclusions-sane.ps1 -- HARD GATE: refuse to let a Windows
# golden be captured while it carries a Defender exclusion that names a path
# which does not exist.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS (read this before "simplifying" it away)
# ---------------------------------------------------------------------------
# provision-pwsh.ps1 used to add its own PID-named extraction staging
# directory as a PERMANENT Defender exclusion and never remove it:
#
#     Get-MpPreference -> ExclusionPath:
#       C:\pwsh                                  <- deliberate, still there
#       C:\Windows\Temp\vmh-pwsh-extract-6752    <- the defect
#
# The staging directory stopped existing the moment the extracted tree was
# moved into place, but the exclusion outlived it and was CAPTURED into the
# promoted golden. Every `eph-win-x64` clone then inherited a rule exempting a
# directory that is not there.
#
# That is not untidy, it is an antivirus hole with a lottery number for an
# address. Windows reuses PIDs freely, so any later process that happens to
# draw 6752 recreates `C:\Windows\Temp\vmh-pwsh-extract-6752` and everything
# written into it is UNSCANNED -- on machines whose entire job is executing
# pull-request code from forks.
#
# ---------------------------------------------------------------------------
# WHY A RECIPE FIX WAS NOT ENOUGH, AND WHY THIS GATE IS THE MISSING HALF
# ---------------------------------------------------------------------------
# provision-pwsh.ps1 is fixed: the staging exclusion is now scoped to the
# extract and removed in a `finally`. But a recipe fix only reaches the fleet
# when a golden is next BUILT or RETROFITTED. The already-promoted image kept
# the stale rule, and nothing anywhere refused to ship it -- which is exactly
# how it survived promotion in the first place.
#
# The general defect class is "an exclusion outlived the thing it was
# excluding". So this gate does not look for `vmh-pwsh-extract-6752`, or for
# any hard-coded name. It asserts the INVARIANT:
#
#     every Defender path exclusion must name a path that exists
#
# A stale rule for a deleted directory fails it whatever the directory was
# called, including the next golden's different PID, and including staging
# paths left by recipes that do not exist yet.
#
# ---------------------------------------------------------------------------
# WHY IT DOES NOT SIMPLY CLEAR THE EXCLUSION LIST
# ---------------------------------------------------------------------------
# `C:\pwsh` is a DELIBERATE, load-bearing exclusion: MsMpEng quarantines
# pwsh.exe as a `PUA:Win32/PowerShellCore` false positive, which would brick
# every `shell: pwsh` step. A gate that demanded an empty list, or a remedy
# that flushed the list, would trade this defect for a worse one. The
# invariant above keeps `C:\pwsh` (it exists) and rejects the stale rule (it
# does not) without either being named here.
#
# ---------------------------------------------------------------------------
# NON-VACUITY
# ---------------------------------------------------------------------------
# The dangerous failure mode for a checker like this is passing because it
# found NOTHING -- a broken Get-MpPreference, a Defender-less SKU, or a typo
# in a property name all produce an empty list, and "no bad exclusions" then
# reads identically to "no exclusions were examined". So the gate first proves
# it is actually looking at Defender (the cmdlet resolves, the call returns an
# object) and reports the count it examined. It refuses to report success on a
# list it could not read.
#
# Note it does NOT require the list to be non-empty: an image legitimately
# carrying zero exclusions is fine. What it requires is having successfully
# READ the list.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File assert-defender-exclusions-sane.ps1
#
# Exit 0 = every path exclusion names something that exists.
# Exit 1 = at least one stale rule, or the list could not be read.

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Fail {
  param([string]$Message)
  Write-Output "DEFENDER-GATE: FAIL - $Message"
  exit 1
}

function Info {
  param([string]$Message)
  Write-Output "DEFENDER-GATE: $Message"
}

Info ("running under PowerShell " + $PSVersionTable.PSVersion.ToString() +
      " (" + $PSVersionTable.PSEdition + ") as " + (whoami))

# --- non-vacuity: prove we can actually interrogate Defender ---------------
$cmd = Get-Command Get-MpPreference -ErrorAction SilentlyContinue
if ($null -eq $cmd) {
  Fail "Get-MpPreference is not available - cannot verify Defender exclusions. Refusing to report success on a check that did not run."
}

$prefs = $null
try {
  $prefs = Get-MpPreference
} catch {
  Fail ("Get-MpPreference threw: " + $_.Exception.Message +
        " - cannot verify Defender exclusions. Refusing to report success on a check that did not run.")
}
if ($null -eq $prefs) {
  Fail "Get-MpPreference returned nothing - cannot verify Defender exclusions."
}

# @() so a single string does not enumerate per-character and a $null does not
# blow up .Count under Set-StrictMode.
$paths = @()
if ($null -ne $prefs.ExclusionPath) {
  $paths = @($prefs.ExclusionPath | Where-Object { $_ -ne $null -and $_.ToString().Trim() -ne "" })
}

Info ("examined " + $paths.Count + " Defender path exclusion(s)")
foreach ($p in $paths) { Info ("  exclusion: " + $p) }

# --- the invariant --------------------------------------------------------
$stale = @()
foreach ($p in $paths) {
  $exists = $false
  try {
    $exists = Test-Path -LiteralPath $p
  } catch {
    # An exclusion whose path cannot even be evaluated is not a path this
    # image should be exempting either.
    $exists = $false
  }
  Info ("  exists=" + $exists + "  " + $p)
  if (-not $exists) { $stale += $p }
}

if ($stale.Count -gt 0) {
  Write-Output ""
  foreach ($p in $stale) {
    Write-Output ("DEFENDER-GATE: stale exclusion names a path that does not exist: " + $p)
  }
  Write-Output ""
  Fail ("" + $stale.Count + " Defender path exclusion(s) name paths that do not exist. " +
        "Windows reuses PIDs, so such a rule is an unscanned directory waiting for a " +
        "process to recreate it - on a machine that runs pull-request code. Remove them with " +
        "Remove-MpPreference -ExclusionPath '<path>' and re-capture. Do NOT clear the whole " +
        "list: exclusions naming paths that DO exist (C:\pwsh) are deliberate.")
}

Info ("PASS - all " + $paths.Count + " path exclusion(s) name paths that exist")
exit 0
