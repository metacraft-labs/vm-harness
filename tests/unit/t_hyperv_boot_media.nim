## Unit tests for the Hyper-V boot-media PowerShell builder.
##
## These assert on the PowerShell text `buildNewBootVmCommand` emits, so
## they run on any host — no Hyper-V role, no VM, no elevation. That
## matters here: the Hyper-V role is a reboot to enable and is absent
## from both the dev boxes and the Linux CI runners, so an
## assert-on-emitted-script test is the only coverage these code paths
## can get before they run for real on win-ci-bare-001.
##
## The behaviour under test is what Windows 11 Setup requires of the VM
## it is installing into. Getting any of it wrong does not produce an
## error we can catch — Setup stops at a graphical "This PC can't run
## Windows 11" dialog, which from the harness side is indistinguishable
## from a slow install until the timeout fires.

import std/[strutils, unittest]
import vm_harness

proc win11Spec(): BootMediaSpec =
  ## A spec shaped like the Windows 11 golden build: install ISO as the
  ## boot media, autounattend ISO as the seed, and the three Win11
  ## hardware gates satisfied.
  BootMediaSpec(
    name: BootVmNamePrefix & "win11",
    kind: bmkIso,
    mediaPath: "C:\\iso\\win11.iso",
    secondaryIsoPath: "C:\\iso\\autounattend.iso",
    cpus: 4,
    memoryMB: 8192,
    generation: 2,
    secureBootEnabled: true,
    tpmEnabled: true,
    diskGB: 80)

proc render(spec: BootMediaSpec): string =
  ## The emitted script with its `#` comment lines removed.
  ##
  ## Stripping matters for the ordering assertions below: the script
  ## carries prose explaining the Set-VMKeyProtector/Enable-VMTPM
  ## ordering, and that prose names both cmdlets. Searching the raw text
  ## finds the comment before the command and reports the order
  ## backwards. Asserting on executable lines only is also the more
  ## honest test — a comment cannot break an install.
  let b = newHyperVBackend()
  let raw = b.buildNewBootVmCommand(spec, spec.name, "testpipe",
                                    "C:\\scratch\\boot.vhdx")
  var kept: seq[string] = @[]
  for line in raw.splitLines():
    if not line.strip().startsWith("#"):
      kept.add(line)
  kept.join("\n")

suite "buildNewBootVmCommand: Windows 11 hardware gates":
  test "vTPM is enabled, and the key protector is created FIRST":
    let ps = render(win11Spec())
    check "Set-VMKeyProtector" in ps
    check "-NewLocalKeyProtector" in ps
    check "Enable-VMTPM" in ps
    # Ordering is not cosmetic: Enable-VMTPM fails outright on a VM that
    # has no key protector yet, so an emitted script with these two
    # reversed would create a TPM-less VM and hang Setup.
    check ps.find("Set-VMKeyProtector") < ps.find("Enable-VMTPM")

  test "the vTPM is attached before the VM is ever started":
    # Hyper-V rejects Enable-VMTPM on a running VM. This builder is
    # supposed to leave the VM Off, but assert it so a future edit that
    # folds Start-VM in here trips the test rather than the install.
    let ps = render(win11Spec())
    let startIdx = ps.find("Start-VM")
    if startIdx >= 0:
      check ps.find("Enable-VMTPM") < startIdx

  test "the scratch boot disk honours diskGB, not the 8GB Linux default":
    # Win11 Setup's partitioning step fails on < 64 GB.
    let ps = render(win11Spec())
    check "$diskGB  = 80" in ps
    check "[int64]$diskGB * 1GB" in ps
    check "-SizeBytes 8GB" notin ps

  test "Secure Boot stays ON for Windows guests":
    # Unlike the libvirt path — which disables secure boot because the
    # nixpkgs OVMF has no MS-key-enrolled vars template — Hyper-V ships
    # the MicrosoftWindows template, so there is no reason to weaken it.
    let ps = render(win11Spec())
    check "-EnableSecureBoot $secureBoot" in ps
    check "$secureBoot = 'On'" in ps

suite "buildNewBootVmCommand: vTPM is opt-in and generation-aware":
  test "no TPM cmdlets are emitted when tpmEnabled is false":
    var spec = win11Spec()
    spec.tpmEnabled = false
    let ps = render(spec)
    check "$wantTpm = $false" in ps
    # The cmdlets may appear inside the guarded block; what must not
    # happen is the guard being unconditionally true.
    check "$wantTpm = $true" notin ps

  test "a TPM request on Generation 1 is refused, not silently emitted":
    # Gen 1 has no UEFI and therefore no vTPM. Emitting Enable-VMTPM
    # anyway would throw at runtime on the box; the builder resolves it
    # at build time instead.
    var spec = win11Spec()
    spec.generation = 1
    spec.tpmEnabled = true
    let ps = render(spec)
    check "$wantTpm = $false" in ps

  test "defaults stay Linux-friendly when the Win11 fields are unset":
    # Guard against making every existing reproos boot test pay for
    # Windows' requirements.
    let spec = BootMediaSpec(
      name: BootVmNamePrefix & "linux",
      kind: bmkIso,
      mediaPath: "C:\\iso\\repro.iso")
    let ps = render(spec)
    check "$wantTpm = $false" in ps
    check "$diskGB  = 8" in ps

suite "buildNewBootVmCommand: caller-owned installation disk":
  test "an explicit target disk is created and attached without reuse":
    var spec = win11Spec()
    spec.targetDiskPath = "C:\\images\\reproos-installed.vhdx"
    let ps = render(spec)
    check "$targetVhdx = 'C:\\images\\reproos-installed.vhdx'" in ps
    check "$bootVhdx = if ($kind -eq 'vhdx')" in ps
    check "target boot disk already exists" in ps
    check "New-VHD -Path $bootVhdx" in ps
