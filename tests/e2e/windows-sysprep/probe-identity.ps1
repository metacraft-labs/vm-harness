$ErrorActionPreference = "Continue"
# Emit the clone's machine identity for the distinct-identity gate. Pipe-free
# (the Windows sshd default shell routes through cmd.exe, which eats `|`), so
# we materialise the account array and index it rather than piping.
Write-Output ("HOSTNAME=" + $env:COMPUTERNAME)
$accts = @(Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True")
$sid = $accts[0].SID
$machineSid = $sid -replace '-\d+$',''
Write-Output ("MACHINE_SID=" + $machineSid)
if (Test-Path C:\cloudbase-ran.txt) {
  Write-Output ("CLOUDBASE_MARKER=" + (Get-Content -Raw C:\cloudbase-ran.txt).Trim())
} else {
  Write-Output "CLOUDBASE_MARKER=ABSENT"
}
