## Unit tests for the Hyper-V per-job EPHEMERAL clone PowerShell builder
## (`buildEphemeralCloneCommand`) — the host-lifecycle primitive RA4's
## `t_vmharness_serve_win_hyperv` gate drives on win-ci-bare-001.
##
## Like `t_hyperv_boot_media`, these assert on the emitted PowerShell text,
## so they run on any host with no Hyper-V role, no VM, no elevation — the
## only coverage the New-VHD/New-VM/Enable-VMTPM host-lifecycle paths can get
## before they run for real on the bare-metal Windows host. Mock policy: NO
## mocks — the function under test is pure (spec → PowerShell string).
##
## The behaviour under test is the Hyper-V analog of libvirt's CoW-overlay
## ephemeral clone: a per-job disk derived from a golden VHDX (differencing
## overlay or ReFS block-clone copy), a fresh Gen-2 VM around it, and safety
## guards that make teardown unable to touch a long-lived VM or the golden.

import std/[strutils, unittest]
import vm_harness

proc win11Spec(): HyperVEphemeralCloneSpec =
  ## A spec shaped like a per-job clone of the Windows 11 Hyper-V golden.
  HyperVEphemeralCloneSpec(
    name: EphemeralVmNamePrefix & "job-42",
    goldenVhdx: "D:\\golden\\win11-golden.vhdx",
    useDifferencing: true,
    cpus: 4,
    memoryMB: 8192,
    generation: 2,
    secureBootEnabled: true,
    tpmEnabled: true,
    switchName: "NAT-Switch",
    configDriveIso: "D:\\jit\\job-42.config-drive.iso")

proc render(spec: HyperVEphemeralCloneSpec): string =
  ## The emitted script with its `#` comment lines removed (so ordering
  ## assertions do not match prose that names a cmdlet before it runs).
  let b = newHyperVBackend()
  let raw = b.buildEphemeralCloneCommand(spec, ephemeralClonePathFor(spec))
  var kept: seq[string] = @[]
  for line in raw.splitLines():
    if not line.strip().startsWith("#"):
      kept.add(line)
  kept.join("\n")

suite "buildEphemeralCloneCommand: host-lifecycle ops (New-VHD/New-VM/Remove)":
  test "the golden is CoW-cloned and a fresh VM is created on the clone":
    let ps = render(win11Spec())
    # The differencing overlay keeps the golden read-only (never written).
    check "New-VHD -Path $clone -ParentPath $golden -Differencing" in ps
    check "New-VM -Name $vmName -Generation $gen" in ps
    check "-VHDPath $clone" in ps
    # New-VM binds the CLONE, never the golden directly.
    check "-VHDPath $golden" notin ps

  test "clone-path defaults next to the golden and is namespaced by VM name":
    let spec = win11Spec()
    let p = ephemeralClonePathFor(spec)
    check p == "D:\\golden\\" & EphemeralVmNamePrefix & "job-42.vhdx"

  test "an explicit clonePath is honoured verbatim":
    var spec = win11Spec()
    spec.clonePath = "E:\\scratch\\my-clone.vhdx"
    check ephemeralClonePathFor(spec) == "E:\\scratch\\my-clone.vhdx"

  test "a full-copy clone is emitted when differencing is disabled (ReFS)":
    var spec = win11Spec()
    spec.useDifferencing = false
    let ps = render(spec)
    check "$useDiff = $false" in ps
    check "Copy-Item -LiteralPath $golden -Destination $clone" in ps

suite "buildEphemeralCloneCommand: safety guards make teardown/golden safe":
  test "refuses a VM name outside the ephemeral namespace":
    var spec = win11Spec()
    spec.name = "some-long-lived-vm"
    # A name outside the prefix is refused by the guard AND by the builder's
    # emitted check.
    let b = newHyperVBackend()
    let ps = b.buildEphemeralCloneCommand(spec, "D:\\x.vhdx")
    check "SAFETY: refusing to create ephemeral VM" in ps
    check EphemeralVmNamePrefix in ps

  test "refuses to clobber an existing VM or an existing clone disk":
    let ps = render(win11Spec())
    check "already exists; per-job clones require a fresh name" in ps
    check "per-job clone disk already exists (refusing to clobber)" in ps

  test "aborts when the golden VHDX is missing (never creates a stray VM)":
    let ps = render(win11Spec())
    check "golden VHDX not found" in ps

suite "buildEphemeralCloneCommand: Windows 11 hardware gates":
  test "vTPM is enabled with the key protector created FIRST":
    let ps = render(win11Spec())
    check "Set-VMKeyProtector" in ps
    check "-NewLocalKeyProtector" in ps
    check "Enable-VMTPM" in ps
    check ps.find("Set-VMKeyProtector") < ps.find("Enable-VMTPM")

  test "Secure Boot stays On for the Windows golden":
    let ps = render(win11Spec())
    check "$secureBoot = 'On'" in ps
    check "-EnableSecureBoot $secureBoot" in ps

  test "a TPM request on Generation 1 is refused, not silently emitted":
    var spec = win11Spec()
    spec.generation = 1
    spec.tpmEnabled = true
    let ps = render(spec)
    check "$wantTpm = $false" in ps

  test "defaults: 2 vCPU / 4096 MB / Gen 2 when the fields are unset":
    let spec = HyperVEphemeralCloneSpec(
      name: EphemeralVmNamePrefix & "bare",
      goldenVhdx: "D:\\g\\golden.vhdx",
      useDifferencing: true)
    let ps = render(spec)
    check "$gen     = 2" in ps
    check "$memMB   = 4096" in ps
    check "$cpus    = 2" in ps

suite "buildEphemeralCloneCommand: JIT bootstrap + networking seams":
  test "a vSwitch NIC is connected for the metadata endpoint when requested":
    let ps = render(win11Spec())
    check "Connect-VMNetworkAdapter" in ps
    check "-SwitchName $switch" in ps

  test "the guest is network-isolated when no switch is given":
    var spec = win11Spec()
    spec.switchName = ""
    let ps = render(spec)
    check "Remove-VMNetworkAdapter" in ps

  test "a cloudbase-init ConfigDrive ISO is attached read-only when set":
    let ps = render(win11Spec())
    check "Add-VMDvdDrive -VMName $vmName -Path $configDrive" in ps
    check "configDriveIso not found" in ps
