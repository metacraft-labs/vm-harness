## Pure reprobuild graph for vm-harness.
##
## The default collection builds the shipping CLI and benchmark. The test
## collection builds and executes the deterministic, host-independent suite on
## every supported platform. POSIX host-backend tests which rely on shell
## scripts or process groups are added only on POSIX; live hypervisor
## lifecycles remain in the explicit host-test catalog.

import repro_project_dsl
import ct_test_nim_unittest

type
  VmHarnessTestSpec = object
    source: string
    binary: string

const portableTestSpecs: seq[VmHarnessTestSpec] = @[
  VmHarnessTestSpec(source: "tests/unit/t_output_envelope.nim",
    binary: "t_output_envelope"),
  VmHarnessTestSpec(source: "tests/unit/t_auto_selection.nim",
    binary: "t_auto_selection"),
  VmHarnessTestSpec(source: "tests/unit/t_guest_scripts.nim",
    binary: "t_guest_scripts"),
  VmHarnessTestSpec(source: "tests/unit/t_cli_probe.nim",
    binary: "t_cli_probe"),
  VmHarnessTestSpec(source: "tests/unit/t_cli_boot.nim",
    binary: "t_cli_boot"),
  VmHarnessTestSpec(source: "tests/unit/t_hyperv_parsers.nim",
    binary: "t_hyperv_parsers"),
  VmHarnessTestSpec(source: "tests/unit/t_wsl_parsers.nim",
    binary: "t_wsl_parsers"),
  VmHarnessTestSpec(source: "tests/unit/t_utm_parsers.nim",
    binary: "t_utm_parsers"),
  VmHarnessTestSpec(source: "tests/unit/t_tart_shared_dirs.nim",
    binary: "t_tart_shared_dirs"),
  VmHarnessTestSpec(source: "tests/integration/t_noop_lifecycle.nim",
    binary: "t_noop_lifecycle"),
  VmHarnessTestSpec(source: "tests/e2e/t_vm_harness_smoke.nim",
    binary: "t_vm_harness_smoke"),
  VmHarnessTestSpec(source: "tests/e2e/t_vm_harness_finally_cleanup_on_panic.nim",
    binary: "t_vm_harness_finally_cleanup_on_panic"),
  VmHarnessTestSpec(source: "tests/e2e/t_vm_harness_auto_backend_selection.nim",
    binary: "t_vm_harness_auto_backend_selection"),
  VmHarnessTestSpec(source: "tests/integration/t_libvirt_backend.nim",
    binary: "t_libvirt_backend"),
  VmHarnessTestSpec(source: "tests/integration/t_cli_libvirt_flags.nim",
    binary: "t_cli_libvirt_flags"),
]

const posixTestSpecs: seq[VmHarnessTestSpec] = @[
  VmHarnessTestSpec(source: "tests/unit/t_qemu_windows_arm_backend.nim",
    binary: "t_qemu_windows_arm_backend"),
  VmHarnessTestSpec(source: "tests/unit/t_tart_backend.nim",
    binary: "t_tart_backend"),
]

package vm_harness:
  defaultToolProvisioning "path"

  uses:
    "nim >=2.2 <3.0"
    when defined(macosx):
      "clang"
    else:
      "gcc >=12"

  library vm_harness

  executable vmHarness:
    name: "vm-harness"

  executable snapshotRevertBench:
    name: "vm-harness-bench-snapshot-revert"

  build:
    const exeSuffix = (when defined(windows): ".exe" else: "")
    const binDir = "build/bin/"
    const testBinDir = "build/test-bin/"

    let cliBuild = nim.c(
      source = "src/vm_harness/cli.nim",
      binary = binDir & "vm-harness" & exeSuffix,
      extraInputs = @["src", "guest-scripts", "guest-recipes"],
      actionId = "vm_harness.cli.build")
    let benchBuild = nim.c(
      source = "tools/bench/snapshot_revert_bench.nim",
      binary = binDir & "vm-harness-bench-snapshot-revert" & exeSuffix,
      extraInputs = @["src", "tools", "guest-scripts", "guest-recipes"],
      actionId = "vm_harness.snapshot_revert_bench.build")
    discard collect("default", @[cliBuild, benchBuild])

    var testBuildActions: seq[BuildActionDef] = @[]
    var testExecuteActions: seq[BuildActionDef] = @[]

    proc emitTestPair(spec: VmHarnessTestSpec;
                      buildActions, executeActions: var seq[BuildActionDef]) =
      let output = testBinDir & spec.binary & exeSuffix
      let edge = buildNimUnittest.build(
        source = spec.source,
        binary = output,
        extraInputs = @["src", "guest-scripts", "guest-recipes"],
        actionId = "vm_harness.test_build." & spec.binary)
      buildActions.add(edge.action)
      executeActions.add(edge.testBinary.run(
        actionId = "vm_harness.test_execute." & spec.binary,
        registerImplicitName = false))

    for spec in portableTestSpecs:
      emitTestPair(spec, testBuildActions, testExecuteActions)

    when defined(posix):
      for spec in posixTestSpecs:
        emitTestPair(spec, testBuildActions, testExecuteActions)

    discard collect("test-builds", testBuildActions)
    discard collect("test", testExecuteActions)
