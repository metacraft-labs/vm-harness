## Incus backend — ephemeral per-job Linux SYSTEM CONTAINERS.
##
## This is the container-based analog of the libvirt backend (which runs
## per-job Windows/Linux VMs on KVM). Incus system containers launch in
## well under a second and cost a fraction of a VM, so the ephemeral loop
## (fresh container per job → run one job → destroy) is far cheaper than
## the libvirt path and needs no ``/dev/kvm``.
##
## The backend is a thin adapter around the ``incus`` CLI. Command map
## (one CLI verb per VmBackend method):
##
##   probeAvailability        ``incus info``
##   provisionBaseline        ``incus image list <alias>`` (ensure present)
##   provisionEphemeralClone  ``incus launch <base> <name>`` (+ optional
##                            ``--ephemeral`` and cloud-init user-data
##                            injection via ``incus config set``)
##   startAndAwaitReady       poll ``incus exec <name> -- true`` until it
##                            succeeds (container Running + init up)
##   execInGuest              ``incus exec <name> -- <cmd>``
##   copyToGuest              ``incus file push <host> <name>/<guest>``
##   copyFromGuest            ``incus file pull <name>/<guest> <host>``
##   stopAndCleanup           ``incus delete --force <name>``  (no residue —
##                            the per-container storage volume goes with it)
##
## Snapshot methods map onto ``incus snapshot`` / ``incus restore`` /
## ``incus delete <name>/<snap>``.
##
## *Socket access:* the ``incus`` CLI talks to ``/var/lib/incus/unix.socket``,
## which is group ``incus-admin``. In production the service/runner user is
## in that group (declared in the host's NixOS config) so a plain ``incus``
## invocation works. When the current login session pre-dates the group
## grant (or in a sandbox), export ``VMH_INCUS_CMD="sudo -n incus"`` and the
## backend prefixes every call with it. The command vector is configurable
## via ``newIncusBackend(incusCmd = ...)`` for tests.
##
## *Compile-time portability:* like the other backends this module compiles
## on any host so the small unit tests can run anywhere; ``probeAvailability``
## returns false on non-Linux hosts / when ``incus`` is absent.

import std/[options, os, osproc, streams, strtabs,
            strutils, tables, times]
import ../types
import ../auto

# ---------------------------------------------------------------------------
# Backend type.

type
  IncusBackend* = ref object of VmBackend
    ## Adapter around the ``incus`` CLI.
    incusCmd*: seq[string]
      ## The command vector used to invoke incus, e.g. ``@["incus"]`` or
      ## ``@["sudo", "incus"]``. Defaults to ``@["incus"]``; overridden by
      ## the ``VMH_INCUS_CMD`` env var (space-split) when set.
    baseImage*: string
      ## Default base image alias/fingerprint used by
      ## ``provisionEphemeralClone`` when the spec doesn't override it.
      ## Defaults to ``vmh-base``.
    storagePool*: string
      ## Storage pool the ephemeral containers land in (used by the
      ## no-residual-volume assertion). Defaults to ``default``.
    execUser*: string
      ## User the in-guest ``incus exec`` runs as. Empty ⇒ incus default
      ## (root). Kept for parity with the SSH-user seam on other backends.
    readyTimeoutSec*: int
      ## How long ``startAndAwaitReady`` polls for ``incus exec -- true``.

  EphemeralIncusSpec* = object
    ## Inputs for one per-job ephemeral container.
    name*: string                ## container name (must be unique per job)
    baseImage*: string           ## base image alias/fingerprint to launch
                                 ## from; empty ⇒ backend default ``baseImage``
    ephemeral*: bool             ## pass ``--ephemeral`` to ``incus launch``
                                 ## so the daemon auto-removes the container
                                 ## on stop (defence in depth; explicit
                                 ## ``delete --force`` in stopAndCleanup is
                                 ## still the reliable teardown)
    profiles*: seq[string]       ## optional profiles (``--profile p``); empty
                                 ## ⇒ the ``default`` profile
    userData*: string            ## optional cloud-init user-data. When set it
                                 ## is injected via
                                 ## ``incus config set <name>
                                 ##   cloud-init.user-data <...>`` — the IM2
                                 ## JIT bootstrap-injection seam. Requires a
                                 ## cloud-init-enabled image to take effect.
    config*: Table[string, string]
                                 ## optional raw ``incus config set`` keys
                                 ## (e.g. ``security.nesting`` ,
                                 ## ``cloud-init.vendor-data``). Applied after
                                 ## launch (before start when ``--ephemeral``
                                 ## containers still need a config pass).

const
  DefaultIncusBaseImage* = "vmh-base"
  DefaultIncusStoragePool* = "default"
  DefaultIncusReadyTimeoutSec* = 60

proc resolveIncusCmd(incusCmd: seq[string]): seq[string] =
  ## Honour the ``VMH_INCUS_CMD`` env var (space-split) when the caller
  ## left the default. Lets the gate run under ``sudo incus`` in a session
  ## that pre-dates the ``incus-admin`` group grant without changing the
  ## production registration (plain ``incus``).
  if incusCmd != @["incus"]:
    return incusCmd
  let envCmd = getEnv("VMH_INCUS_CMD")
  if envCmd.len > 0:
    return envCmd.splitWhitespace()
  return incusCmd

proc newIncusBackend*(incusCmd: seq[string] = @["incus"],
                      baseImage: string = DefaultIncusBaseImage,
                      storagePool: string = DefaultIncusStoragePool,
                      execUser: string = "",
                      readyTimeoutSec: int =
                        DefaultIncusReadyTimeoutSec): IncusBackend =
  ## Construct an IncusBackend. Defaults match the host layout: the
  ## ``vmh-base`` Debian image, the ``default`` storage pool, ``incus`` on
  ## PATH (overridable via ``VMH_INCUS_CMD``).
  result = IncusBackend(
    id: biIncus,
    hostPlatform: detectHostPlatform(),
    supportedGuests: {goLinux},
    incusCmd: resolveIncusCmd(incusCmd),
    baseImage: baseImage,
    storagePool: storagePool,
    execUser: execUser,
    readyTimeoutSec: readyTimeoutSec)

# ---------------------------------------------------------------------------
# Process invocation helper. Mirrors ``runProcessCapture`` in the other
# backend modules (standalone so this slice doesn't drag their deps).

proc runProcessCapture(cmd: seq[string], cwd: string = "",
                       timeoutSec: int = 0,
                       env: Table[string, string] = initTable[string, string](),
                       stdinData: string = ""): ExecResult =
  if cmd.len == 0:
    raise newException(ValueError, "runProcessCapture: empty cmd")
  let start = epochTime()
  var procEnv: StringTableRef = nil
  if env.len > 0:
    procEnv = newStringTable(modeStyleInsensitive)
    for k, v in env:
      procEnv[k] = v
  var p = startProcess(cmd[0], workingDir = cwd, args = cmd[1 .. ^1],
                       env = procEnv,
                       options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  if stdinData.len > 0:
    try:
      let s = p.inputStream
      if s != nil:
        s.write(stdinData)
        s.close()
    except CatchableError: discard
  let outStream = p.outputStream
  var stdout = ""
  let deadline = if timeoutSec > 0: epochTime() + timeoutSec.float else: 0.0
  while true:
    var chunk = newString(4096)
    let n = outStream.readData(addr chunk[0], chunk.len)
    if n > 0:
      chunk.setLen(n)
      stdout.add(chunk)
    elif n == 0:
      if not p.running:
        break
      if timeoutSec > 0 and epochTime() > deadline:
        p.terminate()
        return ExecResult(
          exitCode: -1,
          stdout: stdout,
          stderr: "vm-harness: process timed out after " & $timeoutSec & "s",
          elapsedMs: int((epochTime() - start) * 1000))
      sleep(50)
  let code = p.waitForExit(timeout = -1)
  ExecResult(
    exitCode: code,
    stdout: stdout,
    stderr: "",
    elapsedMs: int((epochTime() - start) * 1000))

# ---------------------------------------------------------------------------
# incus CLI primitives.

proc incusArgs(b: IncusBackend, sub: openArray[string]): seq[string] =
  ## Build a full ``<incusCmd...> <sub...>`` invocation.
  result = b.incusCmd
  for s in sub: result.add(s)

proc runIncus*(b: IncusBackend, sub: openArray[string],
               timeoutSec: int = 120,
               env: Table[string, string] = initTable[string, string](),
               stdinData: string = ""): ExecResult =
  runProcessCapture(b.incusArgs(sub), timeoutSec = timeoutSec,
                    env = env, stdinData = stdinData)

proc containerExists*(b: IncusBackend, name: string): bool =
  ## ``incus info <name>`` exits 0 iff the container is defined.
  let r = b.runIncus(@["info", name], timeoutSec = 30)
  r.exitCode == 0

proc listContainerNames*(b: IncusBackend): seq[string] =
  ## ``incus list --format csv -c n`` — every container the daemon knows
  ## about (running or stopped). Used by the ephemeral gate to assert NO
  ## residual per-job container survives teardown. Returns an empty seq on
  ## error. NOTE: this lists ALL containers on the host — callers assert
  ## only on their OWN job names, never on unrelated production containers.
  let r = b.runIncus(@["list", "--format", "csv", "-c", "n"], timeoutSec = 30)
  if r.exitCode != 0:
    return @[]
  for line in r.stdout.splitLines():
    let s = line.strip()
    if s.len > 0:
      result.add(s)

proc containerState*(b: IncusBackend, name: string): string =
  ## ``incus list <name> --format csv -c s`` — the RUNNING/STOPPED status
  ## string, or "" when the container doesn't exist.
  let r = b.runIncus(@["list", name, "--format", "csv", "-c", "s"],
                     timeoutSec = 30)
  if r.exitCode != 0:
    return ""
  result = r.stdout.strip()

proc storageVolumeExists*(b: IncusBackend, name: string): bool =
  ## Whether a ``container/<name>`` storage volume still exists on the
  ## backend's pool. After ``incus delete --force`` the per-container
  ## volume must be gone — the ephemeral gate's no-residue assertion.
  let r = b.runIncus(@["storage", "volume", "list", b.storagePool,
                       "--format", "csv"], timeoutSec = 30)
  if r.exitCode != 0:
    return false
  for line in r.stdout.splitLines():
    let cols = line.split(',')
    # Rows look like: ``container,<name>,,filesystem,<usedby>``.
    if cols.len >= 2 and cols[0].strip() == "container" and
       cols[1].strip() == name:
      return true
  false

proc deleteContainer*(b: IncusBackend, name: string): ExecResult =
  ## ``incus delete --force <name>`` — force-stop + delete in one shot.
  ## Idempotent-ish: incus returns non-zero for a missing container, which
  ## the caller treats as already-clean.
  b.runIncus(@["delete", "--force", name], timeoutSec = 60)

# ---------------------------------------------------------------------------
# provisionEphemeralClone + teardown (the per-job core).

proc applyConfig(b: IncusBackend, name: string, spec: EphemeralIncusSpec) =
  ## Inject cloud-init user-data (the IM2 JIT seam) + any raw config keys.
  if spec.userData.len > 0:
    let r = b.runIncus(@["config", "set", name,
                         "cloud-init.user-data", spec.userData], timeoutSec = 30)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "incus config set cloud-init.user-data failed (exit " &
        $r.exitCode & "): " & r.stdout)
  for k, v in spec.config:
    let r = b.runIncus(@["config", "set", name, k, v], timeoutSec = 30)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "incus config set " & k & " failed (exit " & $r.exitCode & "): " &
        r.stdout)

proc provisionEphemeralClone*(b: IncusBackend,
                              spec: EphemeralIncusSpec): VmHandle =
  ## Materialise ONE fresh per-job container from the base image.
  ##
  ## Steps (exact commands):
  ##   1. ``incus launch <base> <name> [--ephemeral] [--profile p ...]``
  ##      — a brand-new container whose rootfs is a fresh copy of the base
  ##      image. Nothing from a prior job can bleed in.
  ##   2. optional ``incus config set <name> cloud-init.user-data <...>``
  ##      / raw config keys — the IM2 JIT bootstrap-injection seam.
  ##
  ## The returned handle is marked ``ephemeral=true`` so ``stopAndCleanup``
  ## (the DeleteInstance path) force-deletes the container AND its storage
  ## volume, leaving no residue.
  if spec.name.len == 0:
    raise newException(ValueError,
      "provisionEphemeralClone: spec.name is empty")
  let base = if spec.baseImage.len > 0: spec.baseImage else: b.baseImage
  if base.len == 0:
    raise newException(ValueError,
      "provisionEphemeralClone: no base image (spec.baseImage empty and " &
      "backend baseImage unset)")
  if b.containerExists(spec.name):
    raise newVmHarnessError($b.id, lpProvisioning,
      "provisionEphemeralClone: container '" & spec.name &
      "' already exists; per-job clones require a fresh name")

  var launchArgs = @["launch", base, spec.name]
  if spec.ephemeral:
    launchArgs.add("--ephemeral")
  for p in spec.profiles:
    launchArgs.add("--profile")
    launchArgs.add(p)
  let launchRes = b.runIncus(launchArgs, timeoutSec = 120)
  if launchRes.exitCode != 0:
    # Best-effort teardown of any half-built container.
    discard b.deleteContainer(spec.name)
    raise newVmHarnessError($b.id, lpProvisioning,
      "incus launch " & base & " " & spec.name & " failed (exit " &
      $launchRes.exitCode & "): " & launchRes.stdout)

  try:
    b.applyConfig(spec.name, spec)
  except CatchableError as e:
    discard b.deleteContainer(spec.name)
    raise e

  var extra = initTable[string, string]()
  extra["container"] = spec.name
  extra["ephemeral"] = "true"
  extra["baseImage"] = base
  extra["storagePool"] = b.storagePool
  result = VmHandle(
    backend: b,
    name: spec.name,
    baseline: base,
    ipAddress: none(string),
    sshPort: 0,
    sshUser: b.execUser,
    sshAuth: SshAuth(kind: saNone),
    extra: extra)

# ---------------------------------------------------------------------------
# VmBackend method overrides.

method probeAvailability*(b: IncusBackend): bool =
  ## ``incus info`` succeeds ⇒ the daemon is reachable through our command
  ## vector. Never raises (the auto-selector treats a raise as "no").
  when defined(linux):
    try:
      let r = b.runIncus(@["info"], timeoutSec = 30)
      return r.exitCode == 0
    except CatchableError:
      return false
  else:
    return false

method provisionBaseline*(b: IncusBackend, spec: BaselineSpec) =
  ## Ensure the base image exists. ``spec.sourceImage`` (when set) names the
  ## image alias/fingerprint to check; otherwise the backend default
  ## ``baseImage``. Idempotent — no-op when the image is already present.
  ## Provisioning a *new* image (pulling from a remote) is a host-init
  ## concern (IM0) done out-of-band; this method only verifies presence so
  ## the per-job path fails fast with a clear message.
  when defined(linux):
    let alias = if spec.sourceImage.len > 0: spec.sourceImage else: b.baseImage
    if alias.len == 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "provisionBaseline: no image alias (spec.sourceImage empty and " &
        "backend baseImage unset)")
    let r = b.runIncus(@["image", "list", alias, "--format", "csv", "-c", "l"],
                       timeoutSec = 30)
    if r.exitCode != 0 or r.stdout.strip().len == 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "provisionBaseline: base image '" & alias & "' not found in the " &
        "local image store. Pull it first (e.g. `incus image copy " &
        "images:debian/12 local: --alias " & alias & "`).")
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.provisionBaseline requires a Linux host")

method startAndAwaitReady*(b: IncusBackend, vm: VmHandle,
                          timeoutSec: int = 120) =
  ## Wait until the container is Running and its init is far enough along
  ## that ``incus exec -- true`` succeeds. Containers reach this in well
  ## under a second, but a short poll makes the contract robust.
  when defined(linux):
    let budget = if timeoutSec > 0: timeoutSec else: b.readyTimeoutSec
    let deadline = epochTime() + budget.float
    while epochTime() < deadline:
      if b.containerState(vm.name) == "RUNNING":
        let r = b.runIncus(@["exec", vm.name, "--", "true"], timeoutSec = 15)
        if r.exitCode == 0:
          return
      sleep(200)
    raise (ref GuestBootFailureError)(
      backend: $b.id, phase: lpStartup,
      msg: "IncusBackend.startAndAwaitReady: container '" & vm.name &
           "' did not become exec-ready within " & $budget & "s",
      cause: nil)
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.startAndAwaitReady requires a Linux host")

method execInGuest*(b: IncusBackend, vm: VmHandle,
                   env: Table[string, string],
                   cmd: seq[string],
                   stdin: string = "",
                   timeoutSec: int = 600): ExecResult =
  ## ``incus exec <name> [--env K=V ...] [--user <uid?>] -- <cmd...>``.
  ## The argv is passed through verbatim after ``--`` (no shell quoting
  ## games — incus exec forwards the vector directly to execvp in the
  ## container), which is cleaner than the SSH backends' cmd-line joining.
  when defined(linux):
    if cmd.len == 0:
      raise newException(ValueError, "execInGuest: empty cmd")
    var sub = @["exec", vm.name]
    for k, v in env:
      sub.add("--env")
      sub.add(k & "=" & v)
    if b.execUser.len > 0:
      sub.add("--user")
      sub.add(b.execUser)
    sub.add("--")
    for a in cmd:
      sub.add(a)
    return b.runIncus(sub, timeoutSec = timeoutSec, stdinData = stdin)
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.execInGuest requires a Linux host")

method copyToGuest*(b: IncusBackend, vm: VmHandle,
                   hostPath: string, guestPath: string) =
  ## ``incus file push [-r] <host> <name><guest>``.
  when defined(linux):
    if not fileExists(hostPath) and not dirExists(hostPath):
      raise newVmHarnessError($b.id, lpCopy,
        "IncusBackend.copyToGuest: source not found: " & hostPath)
    var sub = @["file", "push"]
    if dirExists(hostPath):
      sub.add("-r")
    sub.add(hostPath)
    sub.add(vm.name & guestPath)
    let r = b.runIncus(sub, timeoutSec = 300)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpCopy,
        "incus file push failed (exit " & $r.exitCode & "): " & r.stdout)
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.copyToGuest requires a Linux host")

method copyFromGuest*(b: IncusBackend, vm: VmHandle,
                     guestPath: string, hostPath: string) =
  ## ``incus file pull [-r] <name><guest> <host>``.
  when defined(linux):
    createDir(parentDir(hostPath))
    var sub = @["file", "pull", "-r", vm.name & guestPath, hostPath]
    let r = b.runIncus(sub, timeoutSec = 300)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpCopy,
        "incus file pull failed (exit " & $r.exitCode & "): " & r.stdout)
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.copyFromGuest requires a Linux host")

method installArgvTraceShim*(b: IncusBackend, vm: VmHandle,
                            shim: ArgvTraceShim) =
  ## Not implemented for the Incus slice (the ephemeral runner path does
  ## not need the argv shim). A future slice can port the ``.real``-rename
  ## wrapper the hyperv backend uses, driven through ``incus exec``.
  raise newException(BackendUnavailableError,
    "IncusBackend.installArgvTraceShim is not implemented for the " &
    "ephemeral-container slice")

method uninstallArgvTraceShim*(b: IncusBackend, vm: VmHandle,
                              wrappedBinaryName: string) =
  ## No-op: nothing installed. A per-job container is destroyed wholesale.
  discard

method stopAndCleanup*(b: IncusBackend, vm: VmHandle, deleteVm: bool = true) =
  ## Safe from ``finally`` blocks: NEVER raises. When ``deleteVm`` is true
  ## the container is force-deleted (``incus delete --force``) which stops
  ## it and removes its per-container storage volume in one shot — no
  ## residue. When false the container is only stopped (kept for a later
  ## job / inspection). Idempotent: deleting a missing container is fine.
  when defined(linux):
    try:
      if deleteVm:
        discard b.deleteContainer(vm.name)
      else:
        discard b.runIncus(@["stop", "--force", vm.name], timeoutSec = 60)
    except CatchableError:
      discard
  else:
    discard

# ---------------------------------------------------------------------------
# Snapshot primitives — ``incus snapshot`` / ``incus restore`` /
# ``incus delete <name>/<snap>``. The per-job ephemeral path does not need
# these (each job gets a brand-new container from the base image), but they
# are implemented for parity so consumers that snapshot a longer-lived
# container work.

method snapshot*(b: IncusBackend, vmName: string, snapshotName: string): string =
  when defined(linux):
    let r = b.runIncus(@["snapshot", vmName, snapshotName], timeoutSec = 60)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "incus snapshot " & vmName & " " & snapshotName & " failed (exit " &
        $r.exitCode & "): " & r.stdout)
    return snapshotName
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.snapshot requires a Linux host")

method snapshotRunning*(b: IncusBackend, vmName,
                        snapshotName: string): string =
  ## Incus snapshots capture the container state regardless of run status
  ## (a stateful snapshot needs CRIU; the default is a filesystem snapshot,
  ## which is what the per-gate reset model wants). Behaves as ``snapshot``.
  b.snapshot(vmName, snapshotName)

method restoreSnapshot*(b: IncusBackend, vmName, snapshotName: string) =
  when defined(linux):
    let r = b.runIncus(@["restore", vmName, snapshotName], timeoutSec = 60)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpRevert,
        "incus restore " & vmName & " " & snapshotName & " failed (exit " &
        $r.exitCode & "): " & r.stdout)
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.restoreSnapshot requires a Linux host")

method listSnapshots*(b: IncusBackend, vmName: string): seq[string] =
  when defined(linux):
    let r = b.runIncus(@["snapshot", "list", vmName, "--format", "csv"],
                       timeoutSec = 30)
    if r.exitCode != 0:
      return @[]
    for line in r.stdout.splitLines():
      let cols = line.split(',')
      if cols.len >= 1 and cols[0].strip().len > 0:
        result.add(cols[0].strip())
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.listSnapshots requires a Linux host")

method removeSnapshot*(b: IncusBackend, vmName, snapshotName: string) =
  ## Idempotent: removing a missing snapshot is a no-op, not an error.
  when defined(linux):
    discard b.runIncus(@["delete", vmName & "/" & snapshotName],
                       timeoutSec = 60)
  else:
    discard

# ---------------------------------------------------------------------------
# Backend registration. Importing this module is enough to make
# ``--backend incus`` and ``vm-harness probe`` see the backend.

registerBackend(biIncus,
  proc(): VmBackend = newIncusBackend())
