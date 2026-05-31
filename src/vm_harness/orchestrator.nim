## Lifecycle orchestrator.
##
## ``runGate`` wraps the per-gate ``revert → exec → cleanup`` sequence in a
## ``try/finally`` that guarantees ``stopAndCleanup`` runs even if the
## gate raises, even on Ctrl-C (we install a SIGINT handler that flips a
## shared bool the orchestrator checks between phases). The output
## envelope is finalized with the right verdict regardless of which step
## failed.
##
## Consumers can either call ``runGate`` directly (simple case) or compose
## the lower-level primitives themselves (e.g. when running multiple gates
## back-to-back inside one session). The contract: whoever calls
## ``revertToBaseline`` is responsible for the matching
## ``stopAndCleanup``.

import std/[options, tables, times]
import ./types, ./output

when defined(posix):
  import std/[posix]

type
  GateSpec* = object
    name*: string                                 ## logical gate name
    baseline*: string                             ## baseline tag
    env*: Table[string, string]                   ## env passed to execInGuest
    cmd*: seq[string]                             ## command to exec in guest
    copyTo*: seq[tuple[host: string, guest: string]]
    copyFrom*: seq[tuple[guest: string, host: string]]
    shims*: seq[ArgvTraceShim]
    timeoutSec*: int

  GateResult* = object
    verdict*: Verdict
    exec*: Option[ExecResult]
    elapsedMs*: int

var sigIntFlag {.threadvar.}: bool

when defined(posix):
  proc onSigInt(sig: cint) {.noconv.} =
    sigIntFlag = true
elif defined(windows):
  # Minimal SIGINT handling on Windows; the CLI installs a console handler
  # if needed. For simplicity we just rely on the Nim runtime's
  # ``onUnhandledException`` to surface the interrupt — the ``finally``
  # block still runs.
  discard

proc installSigIntHandler*() =
  ## Idempotent. Installs a SIGINT handler that flips ``sigIntFlag`` so
  ## the orchestrator can break out between phases. The default Ctrl-C
  ## behavior (raising ``EOSError``) still triggers the ``finally``
  ## block, but installing this handler lets us write a clean
  ## ``INCOMPLETE`` verdict instead of leaking an uncaught exception.
  when defined(posix):
    var sa: Sigaction
    sa.sa_handler = onSigInt
    discard sigemptyset(sa.sa_mask)
    sa.sa_flags = 0
    discard sigaction(SIGINT, sa, nil)

proc checkInterrupted*() =
  if sigIntFlag:
    raise newException(IOError, "vm-harness interrupted (SIGINT)")

proc runGate*(backend: VmBackend, gate: GateSpec,
             envelope: OutputEnvelope): GateResult =
  ## Execute one gate end-to-end with guaranteed cleanup. The verdict is
  ## ``PASS`` when ``execInGuest`` returns exit-code 0, ``FAIL`` when it
  ## returns non-zero, ``ERROR`` for harness-internal exceptions, and
  ## ``INCOMPLETE`` on Ctrl-C.
  installSigIntHandler()
  let gateStart = epochTime()
  envelope.logProvision("gate: " & gate.name & " backend: " & $backend.id &
                        " baseline: " & gate.baseline)
  var vm: VmHandle = nil
  result.verdict = vError
  try:
    let revertStart = epochTime()
    vm = backend.revertToBaseline(gate.baseline)
    envelope.recordStep("revert", ssOk,
                       int((epochTime() - revertStart) * 1000))
    checkInterrupted()

    for c in gate.copyTo:
      let s = epochTime()
      backend.copyToGuest(vm, c.host, c.guest)
      envelope.recordStep("copy-to:" & c.guest, ssOk,
                         int((epochTime() - s) * 1000))
    checkInterrupted()

    for s in gate.shims:
      let t = epochTime()
      backend.installArgvTraceShim(vm, s)
      envelope.recordStep("install-shim:" & s.wrappedBinaryName, ssOk,
                         int((epochTime() - t) * 1000))
    checkInterrupted()

    let execStart = epochTime()
    let er = backend.execInGuest(vm, gate.env, gate.cmd,
                                 timeoutSec = (if gate.timeoutSec > 0:
                                                gate.timeoutSec else: 600))
    envelope.writeCommandRun(gate.cmd, er)
    envelope.recordStep("exec:" & gate.name,
                       (if er.exitCode == 0: ssOk else: ssFail),
                       int((epochTime() - execStart) * 1000))
    result.exec = some(er)
    result.verdict = (if er.exitCode == 0: vPass else: vFail)
    checkInterrupted()

    for c in gate.copyFrom:
      let s = epochTime()
      backend.copyFromGuest(vm, c.guest, c.host)
      envelope.recordStep("copy-from:" & c.guest, ssOk,
                         int((epochTime() - s) * 1000))
  except IOError as e:
    # SIGINT path or any other IO error mid-flight.
    envelope.logProvision("interrupted: " & e.msg)
    envelope.recordStep("interrupt", ssFail)
    result.verdict = vIncomplete
  except CatchableError as e:
    envelope.logProvision("error: " & e.msg)
    envelope.recordStep("error:" & $e.name, ssFail)
    result.verdict = vError
  finally:
    if vm != nil:
      let cleanupStart = epochTime()
      backend.stopAndCleanup(vm, deleteVm = true)
      envelope.recordStep("cleanup", ssOk,
                         int((epochTime() - cleanupStart) * 1000))
    result.elapsedMs = int((epochTime() - gateStart) * 1000)
    envelope.finalize(result.verdict)
