$ErrorActionPreference = 'Stop'

$log = 'C:\Windows\Temp\vmh-openssh-provision.log'
$fail = 'C:\Windows\Temp\vmh-openssh-provision-failed'
$done = 'C:\Windows\Temp\repro-install-done'
$portableZip = 'C:\Windows\Temp\OpenSSH-ARM64.zip'
$netKvmDir = 'C:\Windows\Temp\virtio\NetKVM\w11\ARM64'
$installDir = 'C:\Program Files\OpenSSH'
$expandedDir = 'C:\Program Files\OpenSSH-ARM64'
$script:provisionFailed = $false
# Our own inbound allow rule for sshd, owned by this recipe rather than by
# whatever Add-WindowsCapability happens to install. See ConfigureOpenSsh.
$script:SshdFirewallRuleName = 'vmh-sshd-in-tcp22'

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

function LogPipeline([string]$Prefix, [scriptblock]$Block) {
  & $Block 2>&1 | ForEach-Object {
    $text = $_.ToString().Trim()
    if ($text) {
      Log ($Prefix + ': ' + $text)
    }
  }
}

function LogNetKvmDiagnostics([string]$Label) {
  Log ('BEGIN NetKVM diagnostics ' + $Label)
  try {
    LogPipeline ('pnputil enum net ' + $Label) { & pnputil.exe /enum-drivers /class Net }
  } catch {
    LogError ('pnputil enum net ' + $Label) $_
  }
  try {
    Get-PnpDevice -Class Net -ErrorAction Stop |
      Select-Object -Property Status, Class, FriendlyName, InstanceId |
      Format-List |
      Out-String |
      ForEach-Object {
        if ($_.Trim()) {
          Log (('pnp net {0}: ' -f $Label) + $_.Trim())
        }
      }
  } catch {
    LogError ('Get-PnpDevice Net ' + $Label) $_
  }
  Log ('END NetKVM diagnostics ' + $Label)
}

function InstallNetKvmDriver {
  $netKvmInf = Join-Path $netKvmDir 'netkvm.inf'
  if (-not (Test-Path -LiteralPath $netKvmDir)) {
    Log ('NetKVM ARM64 driver not staged at ' + $netKvmDir + '; skipping virtio-net driver install')
    return
  }
  if (-not (Test-Path -LiteralPath $netKvmInf)) {
    throw ('NetKVM ARM64 driver directory is staged but netkvm.inf is missing at ' + $netKvmInf)
  }

  Log ('BEGIN NetKVM ARM64 driver install from ' + $netKvmInf)
  LogNetKvmDiagnostics 'before'
  LogPipeline 'pnputil add NetKVM' { & pnputil.exe /add-driver $netKvmInf /install }
  $code = $global:LASTEXITCODE
  Log ('END pnputil add NetKVM LASTEXITCODE=' + $code)
  if ($code -ne 0) {
    throw ('pnputil failed to install NetKVM ARM64 driver from ' + $netKvmInf + ' with exit code ' + $code)
  }
  LogNetKvmDiagnostics 'after'
  Log 'SUCCESS NetKVM ARM64 driver install'
}

function InstallPortableOpenSsh {
  if (Test-Path -LiteralPath (Join-Path $installDir 'sshd.exe')) {
    Log ('portable OpenSSH already present at ' + $installDir)
    return
  }
  if (-not (Test-Path -LiteralPath $portableZip)) {
    throw ('portable OpenSSH fallback zip not found at ' + $portableZip)
  }

  Log ('BEGIN portable OpenSSH fallback from ' + $portableZip)
  Stop-Service -Name sshd -Force -ErrorAction SilentlyContinue
  Stop-Service -Name ssh-agent -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $expandedDir -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue

  Expand-Archive -LiteralPath $portableZip -DestinationPath 'C:\Program Files' -Force
  if (Test-Path -LiteralPath $expandedDir) {
    Move-Item -LiteralPath $expandedDir -Destination $installDir -Force
  }

  if (-not (Test-Path -LiteralPath (Join-Path $installDir 'sshd.exe'))) {
    $candidate = Get-ChildItem -LiteralPath 'C:\Program Files' -Directory -Filter 'OpenSSH*' -ErrorAction SilentlyContinue |
      Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'sshd.exe') } |
      Select-Object -First 1
    if ($null -ne $candidate) {
      Move-Item -LiteralPath $candidate.FullName -Destination $installDir -Force
    }
  }

  $sshdExe = Join-Path $installDir 'sshd.exe'
  if (-not (Test-Path -LiteralPath $sshdExe)) {
    throw ('portable OpenSSH expanded without sshd.exe under ' + $installDir)
  }

  $installScript = Join-Path $installDir 'install-sshd.ps1'
  if (Test-Path -LiteralPath $installScript) {
    Log ('BEGIN bundled install-sshd.ps1 at ' + $installScript)
    LogPipeline 'install-sshd.ps1' { & $installScript -Confirm:$false }
    Log ('END bundled install-sshd.ps1 LASTEXITCODE=' + $global:LASTEXITCODE)
  } else {
    Log 'bundled install-sshd.ps1 not found; registering sshd service manually'
    $programDataSsh = Join-Path $env:ProgramData 'ssh'
    New-Item -ItemType Directory -Path $programDataSsh -Force -ErrorAction Stop | Out-Null
    $defaultConfig = Join-Path $installDir 'sshd_config_default'
    $config = Join-Path $programDataSsh 'sshd_config'
    if ((Test-Path -LiteralPath $defaultConfig) -and (-not (Test-Path -LiteralPath $config))) {
      Copy-Item -LiteralPath $defaultConfig -Destination $config -Force -ErrorAction Stop
    }
    $sshKeygen = Join-Path $installDir 'ssh-keygen.exe'
    if (Test-Path -LiteralPath $sshKeygen) {
      LogPipeline 'ssh-keygen -A' { & $sshKeygen -A }
    }
    if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
      New-Service `
        -Name sshd `
        -DisplayName 'OpenSSH SSH Server' `
        -BinaryPathName ('"{0}"' -f $sshdExe) `
        -StartupType Manual `
        -ErrorAction Stop | Out-Null
    }
  }

  Log 'END portable OpenSSH fallback'
}

function ConfigureOpenSsh {
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

  # The inbound allow rule for TCP 22, on EVERY firewall profile.
  #
  # MEASURED on m3 2026-09-15, and it is what stalled the first headless
  # golden build for an entire deadline with a perfectly provisioned guest:
  # `Add-WindowsCapability OpenSSH.Server` installs its own rule named
  # OpenSSH-Server-In-TCP scoped to the **Private** profile only. QEMU's
  # user-mode network is unidentified, so Windows classifies it **Public**,
  # whose policy is BlockInbound. The result reads like nothing is wrong
  # anywhere: sshd Running, `netstat` showing 0.0.0.0:22 LISTENING, the NIC
  # up on 10.0.2.15 — and not one banner byte reaching the host through the
  # forwarded port, because the SYN is dropped inside the guest.
  #
  # The old code only created a rule when NONE existed, so the capability's
  # Private-only rule made this a no-op on exactly the path that needs it.
  # Widen what is there, and only create when there is nothing to widen.
  # Widen the capability's own rule when it is there, by whatever name it
  # carries. Logged either way, because its profile scoping is the fact that
  # cost a whole build deadline.
  foreach ($existing in @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -eq 'OpenSSH-Server-In-TCP' -or
                     $_.DisplayName -like '*OpenSSH*Server*' })) {
    Log ('existing sshd firewall rule name=' + $existing.Name +
         ' display=' + $existing.DisplayName +
         ' profiles=' + $existing.Profile + ' enabled=' + $existing.Enabled)
    try {
      Set-NetFirewallRule -Name $existing.Name -Enabled True -Profile Any `
        -ErrorAction Stop
    } catch {
      LogError ('widen firewall rule ' + $existing.Name) $_
    }
  }

  # And own a rule outright, so reachability does not depend on a rule
  # Microsoft ships and may rename, rescope or stop shipping.
  Get-NetFirewallRule -Name $script:SshdFirewallRuleName -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
  New-NetFirewallRule `
    -Name $script:SshdFirewallRuleName `
    -DisplayName 'vm-harness OpenSSH Server (sshd) any-profile' `
    -Enabled True `
    -Direction Inbound `
    -Protocol TCP `
    -Action Allow `
    -LocalPort 22 `
    -Profile Any `
    -ErrorAction Stop | Out-Null

  # Assert it, rather than assume it took. A golden whose sshd is firewalled
  # off is indistinguishable from a golden that never finished installing,
  # and the harness cannot read this log without the very SSH that is blocked.
  $sshdRule = Get-NetFirewallRule -Name $script:SshdFirewallRuleName -ErrorAction Stop
  Log ('firewall rule ' + $sshdRule.Name + ' profiles=' + $sshdRule.Profile +
       ' enabled=' + $sshdRule.Enabled + ' action=' + $sshdRule.Action +
       ' direction=' + $sshdRule.Direction)
  if (("$($sshdRule.Profile)" -ne 'Any') -or
      ("$($sshdRule.Enabled)" -ne 'True') -or
      ("$($sshdRule.Action)" -ne 'Allow') -or
      ("$($sshdRule.Direction)" -ne 'Inbound')) {
    Fail ('inbound firewall rule for sshd is not an Any-profile allow: profiles=' +
          $sshdRule.Profile + ' enabled=' + $sshdRule.Enabled +
          ' action=' + $sshdRule.Action + ' direction=' + $sshdRule.Direction)
  }

  $svc = Get-Service -Name sshd -ErrorAction Stop
  $startMode = (Get-CimInstance Win32_Service -Filter "Name='sshd'" -ErrorAction Stop).StartMode
  Log ('service sshd status: ' + $svc.Status + '; startType: ' + $startMode)
  if ($svc.Status -ne 'Running') {
    Fail 'sshd service is not running'
  }
}

Log 'BEGIN Windows ARM provisioning'

try {
  InstallNetKvmDriver
} catch {
  LogError 'NetKVM ARM64 driver install' $_
  Fail ('staged NetKVM ARM64 driver install failed: ' + $_.Exception.Message)
}

if (-not $script:provisionFailed) {
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
    Log 'OpenSSH.Server capability is not installed; trying portable OpenSSH ARM64 fallback'
    try {
      InstallPortableOpenSsh
    } catch {
      LogError 'portable OpenSSH fallback' $_
      Fail ('OpenSSH.Server capability is not installed and portable fallback failed: ' + $_.Exception.Message)
    }
  }
}

if (-not $script:provisionFailed) {
  try {
    ConfigureOpenSsh
    if (-not $script:provisionFailed) {
      Log 'SUCCESS OpenSSH provisioning'
    }
  } catch {
    LogError 'sshd configuration' $_
    Fail 'sshd is unavailable'
  }
}

exit 0
