# provision-pwsh.ps1 -- install PowerShell 7 (`pwsh`) into a Windows golden
# image and put it on the MACHINE PATH.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# The Windows goldens ship only Windows PowerShell 5.1 (5.1.22621.x). Every
# ephemeral GARM runner cloned from them therefore has no `pwsh.exe`, and every
# GitHub Actions job that reaches a PowerShell 7 step dies with
#
#   ##[error]pwsh: command not found
#
# GitHub's hosted Windows images bundle PowerShell 7, so workflows written
# against the ecosystem's defaults assume it is there. Ours did not have it,
# and nothing ever installed it.
#
# ---------------------------------------------------------------------------
# WHY WINDOWS POWERSHELL 5.1 CANNOT SUBSTITUTE
# ---------------------------------------------------------------------------
# The obvious alternative -- rewrite every workflow step to `shell: powershell`
# -- does not remove the dependency, for three separate reasons:
#
#   1. The Actions runner dispatches a step's shell by EXECUTABLE NAME. A step
#      that says `shell: pwsh` is resolved with a PATH lookup for `pwsh`; how
#      5.1-compatible the script body happens to be is irrelevant.
#
#   2. Several things invoke `pwsh.exe` as a plain program, independently of
#      any step's `shell:` --
#        * metacraft-github-actions/setup-dev-env (the `reprobuild` flavor)
#          generates a `dev-exec.cmd` trampoline whose body is
#          `pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File ...`;
#        * codetracer's `windows-bootstrap-smoke` job runs `pwsh -File ...`
#          from inside steps that are themselves not pwsh; and
#        * codetracer-native-recorder's Justfile sets
#          `set windows-shell := ["pwsh.exe", ...]`, so every `just` recipe on
#          Windows shells out to it.
#      No amount of editing `shell:` keys reaches any of those.
#
#   3. 5.1 differs from 7 in ways that have already cost this project real
#      time. It does not escape double quotes embedded in an argument when it
#      builds a native command line (see the probe section below), and its `>>`
#      operator writes UTF-16LE where the runner parses `GITHUB_ENV` and
#      `GITHUB_OUTPUT` as UTF-8. Downgrading a working step body to 5.1 is a
#      change that has to be proven step by step, not assumed.
#
# So the binary has to be in the image. This is also the shape the fleet has
# already proven: the persistent (non-GARM) Windows runner installs the same
# pinned PowerShell 7 ZIP to the same `C:\pwsh` -- see
# infra/machines/server/_windows-runner-001/system_windows_runner.nim, whose
# comment records the motivating incident (codetracer-cairo-recorder
# `ci-windows-diy`, 2026-07-03, `pwsh: command not found`). The ephemeral fleet
# simply never got the same treatment.
#
# ---------------------------------------------------------------------------
# WHY THE **MACHINE** PATH IS THE LOAD-BEARING PART
# ---------------------------------------------------------------------------
# Identical to the reasoning in provision-git.ps1, and worth repeating because
# it is the part that is easy to get subtly wrong:
#
# The GitHub Actions runner runs as a Windows SERVICE. A service does not get a
# fresh environment per start: the Service Control Manager (services.exe)
# builds ONE environment block when it starts at boot, from
#
#   HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment
#
# and hands a copy to every service it launches. So an installer that edits the
# interactive user's PATH is invisible to the service forever, and even a
# correct machine-PATH edit is invisible to services already running in this
# boot. That is why this belongs in the GOLDEN IMAGE build rather than in the
# per-instance bootstrap: the golden is captured with the machine PATH already
# containing the install directory, so on every clone's *next boot* services.exe
# reads it from the registry and cloudbase-init -- plus the actions-runner
# process it launches -- inherit it. No ordering race, no reboot at job time.
#
# ---------------------------------------------------------------------------
# WHY THE STANDALONE ZIP AND WHY C:\pwsh
# ---------------------------------------------------------------------------
# The `PowerShell-<ver>-win-<arch>.zip` release asset is a self-contained
# binary tree: no MSI plumbing, no uninstall state, no reboot, and it
# side-installs cleanly next to the built-in Windows PowerShell instead of
# replacing it. `C:\pwsh` keeps the path short (long PATH entries are a real
# constraint here -- see the length guards below) and matches the persistent
# runner exactly, so both halves of the fleet resolve `pwsh` to the same place.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File provision-pwsh.ps1
#   ... -Arch arm64
#   ... -StagedArchive D:\pwsh\PowerShell-7.4.6-win-x64.zip
#
# With no -StagedArchive the script looks for the pinned archive under
# `<drive>:\pwsh\` on removable drives D..H (where build-autounattend-iso.sh
# stages it), then under C:\Windows\Temp\pwsh (where the arm64 recipe copies it
# during the specialize pass), and only if both fail does it download from the
# pinned GitHub release URL. Either way the SHA-256 below is enforced before
# anything is extracted.
#
# Idempotent: a matching install (same version marker + pwsh.exe present) is a
# no-op, and the PATH edit de-dupes.
#
# Diagnostics: C:\Windows\Temp\vmh-pwsh-provision.log
# Failure marker: C:\Windows\Temp\vmh-pwsh-provision-failed
# Success marker: C:\Windows\Temp\vmh-pwsh-provision-done (contains the version)
#
# ---------------------------------------------------------------------------
# FAILURE HANDLING -- AND THE GATE THAT MAKES IT SAFE
# ---------------------------------------------------------------------------
# This script exits 0 even on failure, because it runs from FirstLogonCommands
# where a non-zero exit can wedge the rest of the chain -- including the
# install-done sentinel and the shutdown that signals install-complete. On its
# own that would be dangerous: a golden could be captured with no pwsh and
# nobody would notice until CI failed again, which is the exact defect above
# one layer up.
#
# So the failure is ENFORCED, not merely logged:
# guest-recipes/lib/assert-pwsh-provisioned.ps1 re-verifies the marker, the raw
# machine PATH, its REG_EXPAND_SZ kind and a real `pwsh` execution, and
# windows-x64-base/build-sysprep-golden.sh runs it as a HARD GATE before
# sysprep. A pwsh-less image aborts the golden build.

[CmdletBinding()]
param(
  [ValidateSet('', 'x64', 'arm64')]
  [string] $Arch = '',
  [string] $StagedArchive = '',
  [string] $InstallDir = 'C:\pwsh'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# THE PIN. This is the single source of truth for the PowerShell 7 version used
# by every Windows golden in this repo. guest-recipes/lib/fetch-powershell.sh
# PARSES the three assignments below -- keep them on one line each, single-
# quoted, in this exact shape, or that script will refuse to run.
#
# 7.4.6 is the version the persistent Windows runner already ships, so the two
# halves of the fleet stay on one version.
#
# Both checksums are the ones the PowerShell project publishes in the release
# notes for v7.4.6, independently re-verified by downloading each asset and
# running sha256sum on it.
# ---------------------------------------------------------------------------
$PwshVersion = '7.4.6'
$PwshSha256X64 = 'ed49ce5adb2162cc4a835d740486be729ba904627cca71fcb6c2b95be11b993d'
$PwshSha256Arm64 = '875af8ae039abb583976129b8508c7cc39f0371ae790db096561e44019da0165'

$log = 'C:\Windows\Temp\vmh-pwsh-provision.log'
$failMarker = 'C:\Windows\Temp\vmh-pwsh-provision-failed'
$doneMarker = 'C:\Windows\Temp\vmh-pwsh-provision-done'

function Log([string] $Message) {
  $line = '{0:o} {1}' -f (Get-Date), $Message
  try { Add-Content -LiteralPath $log -Value $line -Encoding UTF8 } catch { }
  Write-Host $line
}

Remove-Item -LiteralPath $failMarker -Force -ErrorAction SilentlyContinue

try {
  Log 'BEGIN PowerShell 7 provisioning'

  if (-not $Arch) {
    $Arch = switch ($env:PROCESSOR_ARCHITECTURE) {
      'ARM64' { 'arm64' }
      'AMD64' { 'x64' }
      default { 'x64' }
    }
    Log ("auto-detected arch '$Arch' from PROCESSOR_ARCHITECTURE=" + $env:PROCESSOR_ARCHITECTURE)
  }

  if ($Arch -eq 'arm64') {
    $assetName = "PowerShell-$PwshVersion-win-arm64.zip"
    $wantSha = $PwshSha256Arm64
  } else {
    $assetName = "PowerShell-$PwshVersion-win-x64.zip"
    $wantSha = $PwshSha256X64
  }
  $assetUrl = "https://github.com/PowerShell/PowerShell/releases/download/v$PwshVersion/$assetName"

  $pwshExe = Join-Path $InstallDir 'pwsh.exe'

  # -- 1. Idempotency fast-path ---------------------------------------------
  $alreadyInstalled = $false
  if ((Test-Path -LiteralPath $pwshExe) -and (Test-Path -LiteralPath $doneMarker)) {
    $installedVersion = (Get-Content -LiteralPath $doneMarker -Raw).Trim()
    if ($installedVersion -eq $PwshVersion) {
      Log "PowerShell $PwshVersion already installed at $InstallDir; skipping download + extract"
      $alreadyInstalled = $true
    } else {
      Log "installed version '$installedVersion' != pinned '$PwshVersion'; reinstalling"
    }
  }

  # -- 2. Keep Defender from eating the payload -----------------------------
  # MsMpEng quarantines pwsh.exe as a `PUA:Win32/PowerShellCore` false
  # positive often enough that the persistent runner's recipe adds this
  # exclusion FIRST, before anything is written. Do the same.
  #
  # ONLY $InstallDir is excluded here, and permanently -- that is the path
  # whose contents keep tripping the false positive. The staging directory
  # gets its own exclusion in step 5, scoped to the extract, and REMOVED
  # again once the tree is moved into place. It used to be added here and
  # never removed, which meant the exclusion was captured into the golden:
  # a clone of the promoted image was found carrying
  #
  #     C:\Windows\Temp\vmh-pwsh-extract-6752
  #
  # in Get-MpPreference, naming a directory that stopped existing during the
  # build. Windows reuses PIDs freely, so any later process that draws 6752
  # recreates that exact path and inherits an UNSCANNED directory under
  # C:\Windows\Temp -- on machines whose entire job is running pull-request
  # code. An exclusion must not outlive the thing it was excluding.
  $staging = "C:\Windows\Temp\vmh-pwsh-extract-$PID"
  try {
    Add-MpPreference -ExclusionPath $InstallDir -ErrorAction Stop
    Log "added Defender exclusion for $InstallDir"
  } catch {
    Log ("Defender exclusion for $InstallDir not applied (non-fatal): " + $_.Exception.Message)
  }

  if (-not $alreadyInstalled) {
    # -- 3. Resolve the archive ---------------------------------------------
    $archive = ''
    # Whether WE fetched the file at $archive. Only then may a checksum
    # mismatch delete it, so a retry re-downloads instead of failing forever on
    # a poisoned cache. A caller-supplied path is not ours to clobber, and a
    # STAGED archive that fails the checksum means the autounattend ISO itself
    # is wrong -- leaving it in place keeps that defect reproducible rather
    # than silently papering over it with a download.
    $archiveIsOurs = $false

    if ($StagedArchive -and (Test-Path -LiteralPath $StagedArchive)) {
      $archive = $StagedArchive
      Log "using caller-supplied archive: $archive"
    }

    if (-not $archive) {
      # windows-arm-base copies the ISO's `pwsh\` directory to
      # C:\Windows\Temp\pwsh during the SPECIALIZE pass, because on that recipe
      # the install media is already detached by the time FirstLogonCommands
      # run. Check the local copy before the removable scan.
      $localStaged = "C:\Windows\Temp\pwsh\$assetName"
      if (Test-Path -LiteralPath $localStaged) {
        $archive = $localStaged
        Log "using locally staged archive: $archive"
      }
    }

    if (-not $archive) {
      # build-autounattend-iso.sh stages the pinned archive at `pwsh\<name>` on
      # the autounattend ISO. Drive letters under OOBE depend on device attach
      # order, so scan the usual removable range -- same reason the OpenSSH,
      # PortableGit and first-boot.ps1 staging steps do.
      foreach ($d in 'D', 'E', 'F', 'G', 'H') {
        $candidate = "${d}:\pwsh\$assetName"
        if (Test-Path -LiteralPath $candidate) {
          $archive = "C:\Windows\Temp\$assetName"
          Log "found staged archive on ${d}: -- copying to $archive"
          Copy-Item -LiteralPath $candidate -Destination $archive -Force
          $archiveIsOurs = $true
          break
        }
      }
    }

    if (-not $archive) {
      $archive = "C:\Windows\Temp\$assetName"
      $archiveIsOurs = $true
      if (Test-Path -LiteralPath $archive) {
        Log "reusing previously downloaded archive: $archive"
      } else {
        Log "no staged archive found; downloading $assetUrl"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $assetUrl -OutFile $archive -UseBasicParsing
      }
    }

    # -- 4. Enforce the pin BEFORE extracting anything ------------------------
    # These bytes become a shell that CI runs arbitrary build steps through, in
    # the golden the entire Windows fleet is cloned from. The checksum gate is
    # the only thing standing between a compromised or truncated download and
    # that outcome, so it runs before a single entry is written to disk.
    $actualSha = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower()
    if ($actualSha -ne $wantSha.ToLower()) {
      if ($archiveIsOurs) {
        # Drop our own bad copy so a retry re-downloads instead of failing on
        # the same poisoned cache forever.
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
      }
      throw "SHA-256 mismatch for $assetName ($archive)`n  expected: $wantSha`n  actual:   $actualSha"
    }
    Log "SHA-256 verified: $actualSha"

    # -- 5. Extract ----------------------------------------------------------
    # .NET's ZipFile rather than Expand-Archive: it is one managed call with no
    # native command line to quote (see the 5.1 note below), and it is roughly
    # an order of magnitude faster than 5.1's Expand-Archive on this ~110 MB,
    # ~1000-entry archive -- which matters because this runs inside an OOBE
    # chain that other steps are waiting on.
    #
    # Extract to a per-PID staging directory and rename into place, rather than
    # extracting over $InstallDir: the .NET Framework overload of
    # ExtractToDirectory refuses to overwrite existing entries, so extracting
    # onto a half-populated directory from an interrupted earlier run would
    # fail. Staging + rename is also atomic enough that a crash mid-extract
    # cannot leave a partial tree at $InstallDir that the idempotency check
    # above would later mistake for an install.
    Log "extracting to $staging"
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue

    # Scoped to the extract, and undone below. See the note in step 2: an
    # exclusion left behind here is captured into the golden and inherited by
    # every clone, naming a path that no longer exists.
    try {
      Add-MpPreference -ExclusionPath $staging -ErrorAction Stop
      Log "added temporary Defender exclusion for $staging"
    } catch {
      Log ("Defender exclusion for $staging not applied (non-fatal): " + $_.Exception.Message)
    }

    try {
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      [System.IO.Compression.ZipFile]::ExtractToDirectory($archive, $staging)

      $stagedExe = Join-Path $staging 'pwsh.exe'
      if (-not (Test-Path -LiteralPath $stagedExe)) {
        throw "PowerShell archive did not produce $stagedExe"
      }

      if (Test-Path -LiteralPath $InstallDir) {
        Log "removing previous install at $InstallDir"
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
      }
      # Same volume, so this is a rename rather than a copy.
      Move-Item -LiteralPath $staging -Destination $InstallDir -Force
    } finally {
      # `finally`, so a throw between here and the move cannot leave the rule
      # behind either -- that is the path the original defect took.
      try {
        Remove-MpPreference -ExclusionPath $staging -ErrorAction Stop
        Log "removed temporary Defender exclusion for $staging"
      } catch {
        Log ("could not remove Defender exclusion for $staging (non-fatal): " + $_.Exception.Message)
      }
    }

    if (-not (Test-Path -LiteralPath $pwshExe)) {
      throw "PowerShell install did not produce $pwshExe"
    }
    Log "extracted: pwsh.exe present at $pwshExe"
  }

  # -- 6. Machine PATH ------------------------------------------------------
  # Read/write the raw REG_EXPAND_SZ. `Get-ItemProperty` (and the managed
  # environment accessor for the 'Machine' target) EXPAND embedded
  # `%SystemRoot%`-style tokens; writing that expansion back would silently
  # bake this build machine's values into the golden's PATH for every clone.
  # DoNotExpandEnvironmentNames preserves them verbatim.
  $envKeyPath = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
  $envKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($envKeyPath, $true)
  if ($null -eq $envKey) {
    throw "could not open HKLM\$envKeyPath for writing (not elevated?)"
  }
  try {
    $currentPath = [string] $envKey.GetValue(
      'Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $segments = @($currentPath -split ';' | Where-Object { $_ -ne '' })

    # `-contains` is case-insensitive for strings, so an existing entry that
    # differs only in case is correctly treated as present.
    if ($segments -contains $InstallDir) {
      Log "machine PATH already contains $InstallDir"
    } else {
      $newPath = (($segments + $InstallDir) -join ';')
      # The 2047-char ceiling belongs to the legacy console tooling, not to the
      # registry: RegSetValueEx happily stores far larger values, which is
      # exactly why this writes through the registry API rather than shelling
      # out to a console helper that would TRUNCATE a long PATH and brick the
      # image. Still, a machine PATH past 2047 breaks a number of third-party
      # installers for everyone downstream, so record it rather than letting it
      # pass unseen.
      if ($newPath.Length -gt 2047) {
        Log ("WARNING: machine PATH will be $($newPath.Length) chars (>2047). " +
          'The registry write is safe, but some legacy tools and installers ' +
          'cannot round-trip a value this long.')
      }
      # A value this large indicates real corruption rather than a long PATH;
      # refuse instead of writing it into the golden.
      if ($newPath.Length -gt 32000) {
        throw ("refusing to write a $($newPath.Length)-char machine PATH " +
          '(>32000); the existing value looks corrupt: ' + $currentPath)
      }
      $envKey.SetValue('Path', $newPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)
      Log "added $InstallDir to the machine PATH ($($newPath.Length) chars, HKLM\$envKeyPath)"
    }

    # Preserving the value KIND matters as much as the value: PATH is
    # REG_EXPAND_SZ, and silently demoting it to REG_SZ would stop
    # %SystemRoot%-style tokens expanding for every process on the box.
    $kind = $envKey.GetValueKind('Path')
    if ($kind -ne [Microsoft.Win32.RegistryValueKind]::ExpandString) {
      throw "machine PATH value kind is $kind, expected ExpandString (REG_EXPAND_SZ)"
    }

    $verifyPath = [string] $envKey.GetValue(
      'Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if (@($verifyPath -split ';') -notcontains $InstallDir) {
      throw "machine PATH write did not stick; HKLM Path is still: $verifyPath"
    }
    Log 'machine PATH verified by read-back'
  } finally {
    $envKey.Close()
  }

  # Best-effort: tell already-running processes that respond to
  # WM_SETTINGCHANGE (Explorer, some shells) to re-read the environment. This
  # does NOT help the SCM -- services.exe only builds its block at boot -- but
  # it makes an interactive session on the build VM behave sanely.
  try {
    $sig = '[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'
    $native = Add-Type -MemberDefinition $sig -Name VmhWin32PwshSendMessageTimeout -Namespace VmhWin32Pwsh -PassThru
    $result = [UIntPtr]::Zero
    $null = $native::SendMessageTimeout([IntPtr]0xffff, 0x1a, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
    Log 'broadcast WM_SETTINGCHANGE'
  } catch {
    Log ('WM_SETTINGCHANGE broadcast failed (non-fatal): ' + $_.Exception.Message)
  }

  # Make the rest of THIS script (and anything it spawns) see the new PATH.
  $env:Path = $InstallDir + ';' + $env:Path

  # -- 7. Prove the interpreter actually runs -------------------------------
  # A `pwsh.exe` that unpacked but cannot start (missing runtime, quarantined
  # by Defender after the fact, wrong architecture) is exactly as useless to CI
  # as no pwsh at all, and would otherwise be discovered by a failing job.
  #
  # The probe is written to a FILE and run as `-File <path>`, never as
  # `-Command <string>`. THIS SCRIPT IS RUN BY `powershell.exe` -- Windows
  # PowerShell 5.1 in these goldens -- which does NOT escape double quotes
  # embedded in an argument when it builds a native command line, so the child
  # receives a mangled argv. That failure mode has already shipped once here:
  # the Git gate's `bash -c <string>` probe split at the first inner quote and
  # failed on every image while saying nothing about Git. A path has no spaces
  # and no quotes, so every argument-passing mode produces the same argv.
  #
  # The name carries $PID so two runs cannot truncate each other's probe, and
  # the file is deleted in a `finally` so it is never captured into the golden.
  $probeScript = "C:\Windows\Temp\vmh-pwsh-probe-$PID.ps1"
  $probe = @()
  try {
    $probeBody = @(
      'Write-Output ("PWSH_VERSION " + $PSVersionTable.PSVersion.ToString())'
      'Write-Output ("PWSH_EDITION " + $PSVersionTable.PSEdition)'
      'Write-Output ("PWSH_PATH " + [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
      $probeScript, $probeBody + "`n", (New-Object System.Text.ASCIIEncoding))

    # 5.1 turns ANY stderr line from a native command into a terminating
    # NativeCommandError while $ErrorActionPreference is 'Stop' and stderr is
    # redirected with 2>&1. We want stderr in the log, not an opaque abort --
    # the verdict below comes from the PWSH_VERSION line, so a genuinely broken
    # interpreter still fails, by name.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $probe = @(& $pwshExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $probeScript 2>&1)
    } finally {
      $ErrorActionPreference = $prevEap
    }
  } finally {
    Remove-Item -LiteralPath $probeScript -Force -ErrorAction SilentlyContinue
  }
  foreach ($line in $probe) { Log "pwsh probe: $line" }

  $versionLine = @($probe | Where-Object { $_ -match '^PWSH_VERSION\s+(\S+)$' })
  if ($versionLine.Count -eq 0) {
    throw ('pwsh probe: ' + $pwshExe + ' did not report a version' +
      "`n  probe output: " + ($probe -join ' | '))
  }
  $reported = ([regex]::Match([string] $versionLine[0], '^PWSH_VERSION\s+(\S+)$')).Groups[1].Value
  # Guard against an install that silently resolved to the built-in Windows
  # PowerShell: 5.1 would satisfy "it ran" while leaving `shell: pwsh` broken.
  if ([int] ($reported -split '\.')[0] -lt 7) {
    throw "pwsh probe: reported version $reported is not PowerShell 7 or newer"
  }
  if ($reported -ne $PwshVersion) {
    Log "WARNING: pwsh reports $reported but the pin is $PwshVersion"
  }
  Log "pwsh probe: interpreter runs and reports $reported"

  Set-Content -LiteralPath $doneMarker -Value $PwshVersion -Encoding ASCII -Force
  Log "SUCCESS PowerShell $PwshVersion provisioned ($InstallDir on the machine PATH)"
  exit 0
} catch {
  $message = $_.Exception.Message
  Log "FAIL $message"
  try {
    Set-Content -LiteralPath $failMarker -Value $message -Encoding UTF8 -Force
  } catch { }
  # Deliberately exit 0: this runs from FirstLogonCommands, where a non-zero
  # exit can wedge the remainder of the chain (including the install-done
  # sentinel and the shutdown that signals install-complete to virt-install).
  #
  # That trade-off is only defensible because the failure is ENFORCED
  # downstream rather than merely documented. guest-recipes/lib/
  # assert-pwsh-provisioned.ps1 reads this marker -- and independently
  # re-verifies the machine PATH and a real pwsh execution -- and
  # windows-x64-base/build-sysprep-golden.sh runs it as a hard gate before
  # sysprep, aborting the golden build rather than shipping an image whose
  # clones cannot run `shell: pwsh` steps. Without that gate, exiting 0 here
  # would silently reintroduce the very defect this script fixes.
  exit 0
}
