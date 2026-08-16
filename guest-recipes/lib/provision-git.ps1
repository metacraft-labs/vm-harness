# provision-git.ps1 -- install Git for Windows (PortableGit) into a Windows
# golden image and put it on the MACHINE PATH.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# Git for Windows is what supplies `bash.exe` on Windows. Without it:
#
#   * every GitHub Actions step with `shell: bash` dies with
#     `##[error]bash: command not found` -- including the FIRST step of
#     metacraft-labs/metacraft-github-actions/setup-dev-env, so a job aborts
#     before any repo-specific work runs; and
#   * `actions/checkout` degrades to the REST-API tarball path and logs
#     "To create a local Git repository instead, add Git 2.18 or higher to the
#     PATH", leaving no `.git` for anything downstream.
#
# Both symptoms are the same missing dependency. The Windows goldens produced
# by guest-recipes/windows-x64-base and guest-recipes/windows-arm-base did not
# install Git at any stage, so every ephemeral GARM Windows runner cloned from
# them was born without it.
#
# ---------------------------------------------------------------------------
# WHY THE **MACHINE** PATH IS THE LOAD-BEARING PART
# ---------------------------------------------------------------------------
# The GitHub Actions runner runs as a Windows SERVICE. A service does not get
# a fresh environment per start from the registry: the Service Control Manager
# (services.exe) builds ONE environment block when it starts at boot, from
#
#   HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment
#
# and hands a copy of that block to every service it launches. So:
#
#   * An installer that only edits the interactive user's PATH (HKCU\Environment)
#     is invisible to the service. Forever.
#   * A `setx PATH ...` in a per-user logon script is likewise invisible.
#   * Even a correct HKLM edit is invisible to services ALREADY RUNNING, and to
#     services started later in the same boot from the SCM's cached block.
#
# That last point is why this script belongs in the GOLDEN IMAGE build and not
# in the per-instance bootstrap: the golden is captured with the machine PATH
# already containing the Git bin directory, so on every clone's *next boot*
# services.exe reads it from the registry, and cloudbase-init (a service) plus
# the actions-runner process it launches both inherit it. No ordering race, no
# reboot needed at job time.
#
# ---------------------------------------------------------------------------
# WHY PortableGit AND WHY ONLY `<InstallDir>\bin` GOES ON PATH
# ---------------------------------------------------------------------------
# PortableGit is the self-contained 7-Zip self-extractor Git for Windows ships
# alongside the Inno Setup installer. It needs no MSI/Inno plumbing, leaves no
# uninstall state, and lets us decide exactly which directories reach PATH.
# It is also what the persistent (non-GARM) runner already uses -- see
# infra/machines/server/_win-ci-vm-001/system_windows_runner.nim -- so this is
# the fleet's proven shape, not a new one.
#
# `<InstallDir>\bin` contains only three files: bash.exe, sh.exe and git.exe,
# and they are NOT the real binaries -- they are Git for Windows' ~46-47 KB
# wrapper shim (bin\bash.exe and bin\sh.exe are byte-identical; the PDB path
# in the binary names it `compat-bash`). The shim sets MSYSTEM and PREPENDS
# the MSYS directories to PATH before exec'ing `..\usr\bin\bash.exe`.
#
# Verified by inspecting the shim's embedded UTF-16 strings, which contain the
# literal search-path template `cmd;` `usr\bin;` `bin;` `mingw\bin;`, plus
# `MSYSTEM` and the target `@@EXEPATH@@\..\usr\bin\bash.exe`. The `mingw`
# token is substituted per MSYSTEM, so the second directory is:
#
#   x64    -> `mingw64\bin`     (shim also embeds the string MINGW64)
#   arm64  -> `clangarm64\bin`  (shim also embeds the string CLANGARM64)
#
# -- which is why this script never hardcodes `mingw64`: the arm64 asset has
# no such directory. Confirmed by execution, not just by reading strings: with
# ONLY `<InstallDir>\bin` on PATH, `bin\bash.exe -c 'command -v ...'` reports
# PATH=/mingw64/bin:/usr/bin:... inside the process and resolves bash, git,
# sha256sum, awk, unzip, tar and curl.
#
# Consequence: putting ONLY `<InstallDir>\bin` on the machine PATH is enough for
# `shell: bash` steps to also find sha256sum, awk, unzip, tar and the rest of
# the MSYS coreutils -- the wrapper hands them over inside the bash process --
# WITHOUT shadowing the Windows `find.exe` and `sort.exe` machine-wide, which
# is what adding `usr\bin` to the machine PATH (the installer's
# `/o:PathOption=CmdTools`) would do to every process on the box.
#
# MinGit was evaluated and REJECTED: MinGit-2.55.0.4-64-bit.zip ships
# `usr/bin/sh.exe` and `usr/bin/dash.exe` but NO `bash.exe` at all, and no
# sha256sum/unzip/tar/curl. It cannot satisfy `shell: bash`.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File provision-git.ps1
#   ... -Arch arm64
#   ... -StagedArchive D:\git\PortableGit-2.55.0.4-64-bit.7z.exe
#
# With no -StagedArchive the script looks for the pinned archive under
# `<drive>:\git\` on removable drives D..H (where build-autounattend-iso.sh
# stages it), and only if that fails does it download from the pinned GitHub
# release URL. Either way the SHA-256 below is enforced before extraction.
#
# Idempotent: a matching install (same version marker + bash.exe present) is a
# no-op, and the PATH edit de-dupes.
#
# Diagnostics: C:\Windows\Temp\vmh-git-provision.log
# Failure marker: C:\Windows\Temp\vmh-git-provision-failed
# Success marker: C:\Windows\Temp\vmh-git-provision-done (contains the version)
#
# ---------------------------------------------------------------------------
# FAILURE HANDLING -- AND THE GATE THAT MAKES IT SAFE
# ---------------------------------------------------------------------------
# This script exits 0 even on failure, because it runs from FirstLogonCommands
# where a non-zero exit can wedge the rest of the chain. On its own that would
# be dangerous: a golden could be captured with no Git and nobody would notice
# until CI failed again -- the exact defect above, one layer up.
#
# So the failure is ENFORCED, not merely logged:
# guest-recipes/lib/assert-git-provisioned.ps1 re-verifies the marker, the raw
# machine PATH, its REG_EXPAND_SZ kind, and the whole bash toolchain, and
# windows-x64-base/build-sysprep-golden.sh runs it as a HARD GATE before
# sysprep. A Git-less image aborts the golden build.

[CmdletBinding()]
param(
  [ValidateSet('', 'x64', 'arm64')]
  [string] $Arch = '',
  [string] $StagedArchive = '',
  [string] $InstallDir = 'C:\PortableGit'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# THE PIN. This is the single source of truth for the Git for Windows version
# used by every Windows golden in this repo. guest-recipes/lib/fetch-portable-git.sh
# PARSES the four assignments below -- keep them on one line each, single-quoted,
# in this exact shape, or that script will refuse to run.
#
# Checksums are the ones git-for-windows publishes in the release notes for
# v2.55.0.windows.4, independently re-verified by downloading each asset and
# running sha256sum on it.
# ---------------------------------------------------------------------------
$GitVersion = '2.55.0.4'
$GitTag = 'v2.55.0.windows.4'
$GitSha256X64 = '016e84230a3767f0c6b3788e79ba0c58a17377086801719d46700fca4f7b36b5'
$GitSha256Arm64 = 'd69d0c6a3c5445553565ef74f1d9e22a9869f57c246111db347dd96c252b4da5'

$log = 'C:\Windows\Temp\vmh-git-provision.log'
$failMarker = 'C:\Windows\Temp\vmh-git-provision-failed'
$doneMarker = 'C:\Windows\Temp\vmh-git-provision-done'

function Log([string] $Message) {
  $line = '{0:o} {1}' -f (Get-Date), $Message
  try { Add-Content -LiteralPath $log -Value $line -Encoding UTF8 } catch { }
  Write-Host $line
}

Remove-Item -LiteralPath $failMarker -Force -ErrorAction SilentlyContinue

try {
  Log 'BEGIN Git for Windows provisioning'

  if (-not $Arch) {
    $Arch = switch ($env:PROCESSOR_ARCHITECTURE) {
      'ARM64' { 'arm64' }
      'AMD64' { 'x64' }
      default { 'x64' }
    }
    Log ("auto-detected arch '$Arch' from PROCESSOR_ARCHITECTURE=" + $env:PROCESSOR_ARCHITECTURE)
  }

  if ($Arch -eq 'arm64') {
    $assetName = "PortableGit-$GitVersion-arm64.7z.exe"
    $wantSha = $GitSha256Arm64
  } else {
    $assetName = "PortableGit-$GitVersion-64-bit.7z.exe"
    $wantSha = $GitSha256X64
  }
  $assetUrl = "https://github.com/git-for-windows/git/releases/download/$GitTag/$assetName"

  $binDir = Join-Path $InstallDir 'bin'
  $bashExe = Join-Path $binDir 'bash.exe'
  $gitExe = Join-Path $binDir 'git.exe'

  # -- 1. Idempotency fast-path ---------------------------------------------
  $alreadyInstalled = $false
  if ((Test-Path -LiteralPath $bashExe) -and (Test-Path -LiteralPath $doneMarker)) {
    $installedVersion = (Get-Content -LiteralPath $doneMarker -Raw).Trim()
    if ($installedVersion -eq $GitVersion) {
      Log "PortableGit $GitVersion already installed at $InstallDir; skipping download + extract"
      $alreadyInstalled = $true
    } else {
      Log "installed version '$installedVersion' != pinned '$GitVersion'; reinstalling"
    }
  }

  if (-not $alreadyInstalled) {
    # -- 2. Resolve the archive ---------------------------------------------
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
      # windows-arm-base copies the ISO's `git\` directory to
      # C:\Windows\Temp\git during the SPECIALIZE pass, because on that recipe
      # the install media is already detached by the time FirstLogonCommands
      # run. Check the local copy before the removable scan.
      $localStaged = "C:\Windows\Temp\git\$assetName"
      if (Test-Path -LiteralPath $localStaged) {
        $archive = $localStaged
        Log "using locally staged archive: $archive"
      }
    }

    if (-not $archive) {
      # build-autounattend-iso.sh stages the pinned archive at `git\<name>` on
      # the autounattend ISO. Drive letters under OOBE depend on device attach
      # order, so scan the usual removable range -- same reason the OpenSSH and
      # first-boot.ps1 staging steps do. windows-x64-base relies on this path:
      # its FirstLogonCommands run while the ISOs are still attached.
      foreach ($d in 'D', 'E', 'F', 'G', 'H') {
        $candidate = "${d}:\git\$assetName"
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

    # -- 3. Enforce the pin BEFORE executing anything -------------------------
    # This archive is a self-extracting executable: it is about to be RUN. The
    # checksum gate is the only thing standing between a compromised or
    # truncated download and arbitrary code executing as SYSTEM inside the
    # golden that the whole Windows fleet is cloned from.
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

    # -- 4. Extract ----------------------------------------------------------
    # 7-Zip self-extractor convention: `-y` accepts all prompts, `-o<dir>` must
    # have NO space between the flag and the path.
    Log "extracting to $InstallDir"
    $null = New-Item -ItemType Directory -Force -Path $InstallDir
    Start-Process -FilePath $archive -ArgumentList '-y', "-o$InstallDir" -Wait -NoNewWindow

    if (-not (Test-Path -LiteralPath $bashExe)) {
      throw "PortableGit extraction did not produce $bashExe"
    }
    if (-not (Test-Path -LiteralPath $gitExe)) {
      throw "PortableGit extraction did not produce $gitExe"
    }
    Log "extracted: bash.exe and git.exe present under $binDir"
  }

  # -- 5. Machine PATH ------------------------------------------------------
  # Read/write the raw REG_EXPAND_SZ. `Get-ItemProperty` (and
  # [Environment]::GetEnvironmentVariable(..., 'Machine')) EXPAND embedded
  # `%SystemRoot%`-style tokens; writing that expansion back would silently
  # bake this machine's values into the golden's PATH for every clone.
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
    if ($segments -contains $binDir) {
      Log "machine PATH already contains $binDir"
    } else {
      $newPath = (($segments + $binDir) -join ';')
      # The 2047-char ceiling is a `setx.exe` limitation, not a registry one:
      # RegSetValueEx happily stores far larger values, which is exactly why
      # this writes through the registry API instead of shelling out to setx
      # (setx would TRUNCATE a long PATH and brick the image). Still, a machine
      # PATH past 2047 breaks setx and a number of third-party installers for
      # everyone downstream, so record it rather than letting it pass unseen.
      if ($newPath.Length -gt 2047) {
        Log ("WARNING: machine PATH will be $($newPath.Length) chars (>2047). " +
             'The registry write is safe, but setx.exe and some installers ' +
             'cannot round-trip a value this long.')
      }
      # A value this large indicates real corruption rather than a long PATH;
      # refuse instead of writing it into the golden.
      if ($newPath.Length -gt 32000) {
        throw ("refusing to write a $($newPath.Length)-char machine PATH " +
               '(>32000); the existing value looks corrupt: ' + $currentPath)
      }
      $envKey.SetValue('Path', $newPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)
      Log "added $binDir to the machine PATH ($($newPath.Length) chars, HKLM\$envKeyPath)"
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
    if (@($verifyPath -split ';') -notcontains $binDir) {
      throw "machine PATH write did not stick; HKLM Path is still: $verifyPath"
    }
    Log "machine PATH verified by read-back"
  } finally {
    $envKey.Close()
  }

  # Best-effort: tell already-running processes that respond to
  # WM_SETTINGCHANGE (Explorer, some shells) to re-read the environment. This
  # does NOT help the SCM -- services.exe only builds its block at boot -- but
  # it makes an interactive session on the build VM behave sanely.
  try {
    $sig = '[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'
    $native = Add-Type -MemberDefinition $sig -Name VmhWin32SendMessageTimeout -Namespace VmhWin32 -PassThru
    $result = [UIntPtr]::Zero
    $null = $native::SendMessageTimeout([IntPtr]0xffff, 0x1a, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
    Log 'broadcast WM_SETTINGCHANGE'
  } catch {
    Log ('WM_SETTINGCHANGE broadcast failed (non-fatal): ' + $_.Exception.Message)
  }

  # Make the rest of THIS script (and anything it spawns) see the new PATH.
  $env:Path = $binDir + ';' + $env:Path

  # -- 6. Neutralise the interactive credential helper ----------------------
  # Git for Windows ships `etc\gitconfig` with `credential.helper =
  # helper-selector`, which pops an INTERACTIVE chooser on any credential
  # operation. Inside a runner service there is no interactive session, so the
  # selector reads a closed stdin and hangs until the 6h job timeout. This was
  # observed on the persistent runner (codetracer-cairo-recorder ci-windows-diy,
  # 2026-07-03) and the same golden feeds the ephemeral fleet, so disable it
  # here too. Per gitcredentials(7) an empty first helper entry cancels all
  # subsequent helpers. CI auth flows via token-in-URL, so nothing needs to be
  # stored.
  try {
    & $gitExe config --system --replace-all credential.helper ''
    # `--unset-all` exits 5 when the key is absent; that is not an error here.
    & $gitExe config --system --unset-all credential.helperSelector.selected 2>$null
    Log 'disabled the interactive credential helper in the system gitconfig'
  } catch {
    Log ('credential-helper neutralisation failed (non-fatal): ' + $_.Exception.Message)
  }

  # -- 7. Prove the toolchain actually resolves -----------------------------
  # Running through bin\bash.exe (the shim) is the real test: it proves the
  # shim's PATH augmentation makes the MSYS coreutils visible to a
  # `shell: bash` step, which is the thing this whole script exists to fix.
  #
  # Each tool is checked INDIVIDUALLY and tagged. An earlier version ran one
  # combined `command -v a; command -v b; ...` and then asserted only that the
  # combined output matched 'bash'. That assertion passes when every tool
  # except bash is missing -- `command -v` prints nothing for an absent tool,
  # and `/usr/bin/bash` satisfies the match on its own -- so it proved nothing
  # about the coreutils it claimed to cover. tar and curl are included because
  # `shell: bash` steps use them and they live in different directories
  # (usr\bin and mingw64\bin / clangarm64\bin), so between them they exercise
  # both paths the shim prepends.
  $requiredTools = @('bash', 'git', 'sha256sum', 'awk', 'unzip', 'tar', 'curl')
  $inner = 'for t in ' + ($requiredTools -join ' ') +
           '; do p="$(command -v "$t" 2>/dev/null)"; ' +
           'if [ -n "$p" ]; then echo "TOOL $t $p"; else echo "TOOL $t -"; fi; done'
  $probe = @(& $bashExe -c $inner 2>&1)
  foreach ($line in $probe) { Log "bash probe: $line" }
  $missingTools = @()
  foreach ($tool in $requiredTools) {
    $pattern = '^TOOL\s+' + [regex]::Escape($tool) + '\s+(.+)$'
    $hit = @($probe | Where-Object { $_ -match $pattern })
    if ($hit.Count -eq 0 -or ($hit -match ('^TOOL\s+' + [regex]::Escape($tool) + '\s+-$'))) {
      $missingTools += $tool
    }
  }
  if ($missingTools.Count -gt 0) {
    throw ("bash shim probe: these tools do not resolve through $bashExe -- " +
           ($missingTools -join ', ') + "`n  probe output: " + ($probe -join ' | '))
  }
  Log ("bash probe: all required tools resolve (" + ($requiredTools -join ', ') + ')')

  $gitVersionOut = (& $gitExe --version) -join ' '
  Log "git reports: $gitVersionOut"

  Set-Content -LiteralPath $doneMarker -Value $GitVersion -Encoding ASCII -Force
  Log "SUCCESS Git for Windows $GitVersion provisioned ($binDir on the machine PATH)"
  exit 0
} catch {
  $message = $_.Exception.Message
  Log "FAIL $message"
  try {
    Set-Content -LiteralPath $failMarker -Value $message -Encoding UTF8 -Force
  } catch { }
  # Deliberately exit 0: this runs from FirstLogonCommands, where a non-zero
  # exit can wedge the remainder of the chain (including the install-done
  # sentinel and the shutdown that signals virt-install).
  #
  # That trade-off is only defensible because the failure is ENFORCED
  # downstream rather than merely documented. guest-recipes/lib/
  # assert-git-provisioned.ps1 reads this marker -- and independently
  # re-verifies the machine PATH and the bash toolchain -- and
  # windows-x64-base/build-sysprep-golden.sh runs it as a hard gate before
  # sysprep, aborting the golden build rather than shipping an image whose
  # clones cannot run `shell: bash` steps. Without that gate, exiting 0 here
  # would silently reintroduce the very defect this script fixes.
  exit 0
}
