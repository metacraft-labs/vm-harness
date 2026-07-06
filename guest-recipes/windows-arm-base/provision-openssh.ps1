$ErrorActionPreference = 'Stop'

$log = 'C:\Windows\Temp\vmh-openssh-provision.log'
$fail = 'C:\Windows\Temp\vmh-openssh-provision-failed'
$done = 'C:\Windows\Temp\repro-install-done'
$script:provisionFailed = $false

Remove-Item -LiteralPath $fail, $done -Force -ErrorAction SilentlyContinue

function Log([string]$Message) {
  $line = '{0:o} {1}' -f (Get-Date), $Message
  Add-Content -LiteralPath $log -Value $line -Encoding UTF8
}

function LogError([string]$Step, [object]$Err) {
  $code = $global:LASTEXITCODE
  $hresult = '0x{0:X8}' -f $Err.Exception.HResult
  Log ('ERROR ' + $Step + ' LASTEXITCODE=' + $code + ' HRESULT=' + $hresult + ' MESSAGE=' + $Err.Exception.Message)
}

function Fail([string]$Message) {
  Log ('FAIL: ' + $Message)
  Set-Content -LiteralPath $fail -Value $Message -Encoding UTF8 -Force
  $script:provisionFailed = $true
}

function CapabilityState([string]$Label) {
  try {
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction Stop
    Log ($Label + ' capability state: ' + $cap.State)
    return $cap
  } catch {
    LogError ($Label + ' capability query') $_
    return $null
  }
}

Log 'BEGIN OpenSSH provisioning'
$capBefore = CapabilityState 'before'

try {
  Log 'BEGIN Add-WindowsCapability OpenSSH.Server~~~~0.0.1.0'
  Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction Stop |
    Out-String |
    ForEach-Object {
      if ($_.Trim()) {
        Log ($_.Trim())
      }
    }
  Log ('END Add-WindowsCapability LASTEXITCODE=' + $global:LASTEXITCODE)
} catch {
  LogError 'Add-WindowsCapability' $_
}

$capAfter = CapabilityState 'after'
if (($null -eq $capAfter) -or ($capAfter.State -ne 'Installed')) {
  Fail 'OpenSSH.Server capability is not installed'
}

if (-not $script:provisionFailed) {
  try {
    Set-Service -Name sshd -StartupType Automatic -ErrorAction Stop
    Start-Service -Name sshd -ErrorAction Stop
    New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force -ErrorAction Stop | Out-Null
    New-ItemProperty `
      -Path 'HKLM:\SOFTWARE\OpenSSH' `
      -Name DefaultShell `
      -Value (Get-Command powershell.exe).Source `
      -PropertyType String `
      -Force `
      -ErrorAction Stop | Out-Null

    if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
      New-NetFirewallRule `
        -Name 'OpenSSH-Server-In-TCP' `
        -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True `
        -Direction Inbound `
        -Protocol TCP `
        -Action Allow `
        -LocalPort 22 `
        -ErrorAction Stop | Out-Null
    }

    $svc = Get-Service -Name sshd -ErrorAction Stop
    $startMode = (Get-CimInstance Win32_Service -Filter "Name='sshd'" -ErrorAction Stop).StartMode
    Log ('service sshd status: ' + $svc.Status + '; startType: ' + $startMode)
    if ($svc.Status -ne 'Running') {
      Fail 'sshd service is not running'
    }
    if (-not $script:provisionFailed) {
      Log 'SUCCESS OpenSSH provisioning'
    }
  } catch {
    LogError 'sshd configuration' $_
    Fail 'sshd is unavailable'
  }
}

exit 0
