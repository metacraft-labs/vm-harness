## vm-harness output envelope writer
##
## Implements the *mandatory envelope* defined in design doc §3.5:
##
## ::
##
##     <output-dir>/
##     ├── 00-provision.log    ← session-start log
##     ├── 02-<cmd>-run.txt    ← per execInGuest call
##     ├── RESULT.txt          ← per-step status + verdict
##     └── DONE                ← sentinel written last
##
## The ``OutputEnvelope`` is a thin wrapper around a directory; it owns no
## state besides the directory path and a couple of file handles. The
## ``DONE`` sentinel is borrowed from the existing PowerShell harnesses so
## downstream parsers can distinguish complete from interrupted runs.

import std/[os, times, strutils, strformat, locks]
import ./types

type
  StepStatus* = enum
    ssOk = "ok"
    ssFail = "fail"
    ssSkipped = "skipped"

  Verdict* = enum
    vPass = "PASS"
    vFail = "FAIL"
    vError = "ERROR"
    vIncomplete = "INCOMPLETE"

  OutputEnvelope* = ref object
    dir*: string
    started*: float
    resultLock: Lock
    finalized*: bool

proc newOutputEnvelope*(dir: string): OutputEnvelope =
  ## Create (or refresh) an output envelope rooted at ``dir``. The directory
  ## is created with intermediates; any stale ``DONE`` sentinel from a prior
  ## run is removed so consumers can't misread an interrupted re-run as
  ## complete.
  createDir(dir)
  removeFile(dir / "DONE")
  result = OutputEnvelope(dir: dir, started: epochTime(), finalized: false)
  initLock(result.resultLock)
  # Truncate the per-run files so re-runs start clean.
  writeFile(dir / "00-provision.log", "")
  writeFile(dir / "RESULT.txt", "")

proc logProvision*(env: OutputEnvelope, msg: string) =
  ## Append a line to ``00-provision.log`` with an ISO-8601 timestamp.
  let line = &"{now().utc().format(\"yyyy-MM-dd'T'HH:mm:ss'Z'\")} {msg}\n"
  let f = open(env.dir / "00-provision.log", fmAppend)
  defer: f.close()
  f.write(line)

proc safeName(s: string): string =
  ## Sanitize a command basename for use in a file name.
  result = newStringOfCap(s.len)
  for c in s:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}:
      result.add c
    else:
      result.add '_'
  if result.len == 0:
    result = "cmd"

proc writeCommandRun*(env: OutputEnvelope, cmd: seq[string],
                     r: ExecResult) =
  ## Write the per-command artifact ``02-<basename>-run.txt`` capturing the
  ## full argv, exit code, elapsed time, stdout, and stderr. If multiple
  ## commands share a basename, subsequent ones get a numeric suffix.
  let base = if cmd.len == 0: "cmd" else: safeName(extractFilename(cmd[0]))
  var path = env.dir / &"02-{base}-run.txt"
  var n = 1
  while fileExists(path):
    path = env.dir / &"02-{base}-{n}-run.txt"
    inc n
  var content = ""
  content &= &"# cmd: {cmd.join(\" \")}\n"
  content &= &"# exit_code: {r.exitCode}\n"
  content &= &"# elapsed_ms: {r.elapsedMs}\n"
  content &= "# --- stdout ---\n"
  content &= r.stdout
  if not r.stdout.endsWith("\n"):
    content &= "\n"
  content &= "# --- stderr ---\n"
  content &= r.stderr
  if not r.stderr.endsWith("\n"):
    content &= "\n"
  writeFile(path, content)

proc recordStep*(env: OutputEnvelope, step: string, status: StepStatus,
                elapsedMs: int = -1) =
  ## Append a single step row to ``RESULT.txt`` in the canonical format
  ## ``step: <name>  status: <ok|fail|skipped>  elapsed_ms: <int>``.
  withLock env.resultLock:
    let f = open(env.dir / "RESULT.txt", fmAppend)
    defer: f.close()
    if elapsedMs >= 0:
      f.writeLine(&"step: {step}  status: {status}  elapsed_ms: {elapsedMs}")
    else:
      f.writeLine(&"step: {step}  status: {status}")

proc finalize*(env: OutputEnvelope, verdict: Verdict) =
  ## Write the final ``verdict:`` row to ``RESULT.txt`` and create the
  ## ``DONE`` sentinel last. Safe to call multiple times — only the first
  ## call writes the sentinel.
  withLock env.resultLock:
    if env.finalized:
      return
    let f = open(env.dir / "RESULT.txt", fmAppend)
    f.writeLine(&"verdict: {verdict}")
    f.close()
    writeFile(env.dir / "DONE", $verdict & "\n")
    env.finalized = true

proc isComplete*(env: OutputEnvelope): bool =
  ## Returns true when the ``DONE`` sentinel is present.
  fileExists(env.dir / "DONE")
