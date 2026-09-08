## External-tool fixtures exercise real process boundaries and the real CLI.
## They model lifecycle failures deterministically; they do not claim live VM coverage.
import std/[json, os, osproc, sequtils, strutils, tables, tempfiles, times,
            unittest, xmlparser, xmltree]
import vm_harness/[cli, instances, process_capture, ssh, types]

proc fixture(tool: string, args: seq[string]): int =
  let root = getEnv("VMH_FIXTURE_ROOT")
  let statePath = root / "hypervisor.json"
  var state = parseJson(readFile(statePath))
  state["calls"].add(%*{"tool": tool, "args": args})
  defer: writeFile(statePath, $state)
  proc option(name: string): string =
    let at = args.find(name)
    if at >= 0 and at + 1 < args.len: args[at + 1] else: ""
  proc diskPath(value: string): string =
    for field in value.split(','):
      if field.startsWith("path="): return field[5..^1]
  proc findDomain(id: string): string =
    for name, domain in state["domains"]:
      if name == id or domain["uuid"].getStr() == id: return name
  case tool
  of "qemu-img":
    if args[0] == "info":
      echo $(%*[{"filename": args[^1]}])
      return 0
    writeFile(args[^1], "owned-overlay")
    return 0
  of "virt-install":
    let name = option("--name")
    let id = if option("--uuid").len > 0: option("--uuid") else: newInstanceId()
    let disk = diskPath(option("--disk"))
    let serialOpt = option("--serial")
    var serial: string
    for field in serialOpt.split(','):
      if field.startsWith("path="): serial = field[5..^1]
      if field.startsWith("log.file="): serial = field[9..^1]
    let nvram = root / (id & ".vars.fd")
    writeFile(nvram, "firmware-identity")
    writeFile(root / (id & ".tpm"), "tpm-identity")
    let xml = "<domain><name>" & name & "</name><uuid>" & id &
      "</uuid><os><nvram>" & nvram & "</nvram></os><devices>" &
      "<disk device=\"disk\"><source file=\"" & disk &
      "\"/></disk></devices></domain>"
    state["domains"][name] = %*{"uuid": id, "state": "running", "disk": disk,
      "serial": serial, "xml": xml, "port": 0, "nvram": nvram}
    state["boots"] = %(state["boots"].getInt() + 1)
    if getEnv("VMH_FIXTURE_FAIL") == "create": return 1
    writeFile(serial, "READY\n")
    return 0
  of "ssh":
    writeFile(root / "ssh-argv.json", $(%args))
    if getEnv("VMH_FIXTURE_FAIL") == "ssh":
      stderr.writeLine("REMOTE HOST IDENTIFICATION HAS CHANGED")
      return 255
    if getEnv("VMH_FIXTURE_HOLD") == "yes":
      writeFile(root / "ssh-started", "")
      sleep(2000)
    if args[^1] == "hostname":
      echo "fixture-host"
      return 0
    if '@' in args[^1] and not args[^1].contains(' '):
      echo "interactive"
      return 0
    let r = captureCommand(@["/bin/sh", "-c", args[^1]], timeoutSec = 10,
                            mergeStderr = false)
    stdout.write(r.stdout)
    stderr.write(r.stderr)
    return r.exitCode
  of "virsh":
    if args == @["--version"]: echo "11.7"; return 0
    if args.len < 3: return 2
    let action = args[2]
    if getEnv("VMH_FIXTURE_FAIL") == "list" and action == "list": return 1
    if action == "list":
      for name, domain in state["domains"]:
        echo (if "--uuid" in args: domain["uuid"].getStr() else: name)
      return 0
    if action == "define":
      let xml = readFile(args[3])
      let document = parseXml(xml)
      let name = document.child("name").innerText
      let id = document.child("uuid").innerText
      let disk = document.child("devices").child("disk").child("source").attr("file")
      state["domains"][name] = %*{"uuid": id, "state": "shut off", "disk": disk,
        "xml": xml, "port": 0, "serial": parentDir(args[3]) / "serial.log",
        "nvram": document.child("os").child("nvram").innerText}
      return 0
    if args.len < 4: return 2
    let name = findDomain(if args[3] == "--nvram": args[4] else: args[3])
    if name.len == 0: return 1
    let domain = state["domains"][name]
    case action
    of "domuuid": echo domain["uuid"].getStr()
    of "domstate": echo domain["state"].getStr()
    of "dominfo": discard
    of "dumpxml":
      if getEnv("VMH_FIXTURE_FAIL") == "dumpxml": return 1
      echo domain["xml"].getStr()
    of "shutdown", "destroy":
      if getEnv("VMH_FIXTURE_FAIL") == "stop": return 1
      domain["state"] = %"shut off"
      domain["port"] = %0
    of "start":
      domain["state"] = %"running"
      var file = open(domain["serial"].getStr(), fmAppend)
      file.write("RESTART\n")
      file.close()
    of "undefine":
      if getEnv("VMH_FIXTURE_FAIL") == "undefine": return 1
      if "--nvram" in args: removeFile(domain["nvram"].getStr())
      if "--tpm" in args: removeFile(root / (domain["uuid"].getStr() & ".tpm"))
      state["domains"].delete(name)
    of "qemu-monitor-command":
      if args[^1] == "info usernet":
        if domain["port"].getInt() > 0:
          echo "TCP[HOST_FORWARD] 9 127.0.0.1 " & $domain["port"].getInt() & " 10.0.2.15 22"
      else:
        if getEnv("VMH_FIXTURE_FAIL") == "forward": echo "Could not set up host forwarding rule"; return 0
        let port = args[^1].split(':')[2].split('-')[0]
        domain["port"] = %parseInt(port)
    of "screenshot": writeFile(args[4], "fixture-png")
    else: return 2
    return 0
  else: return 2

if paramCount() > 0:
  case paramStr(1)
  of "fixture": quit(fixture(paramStr(2), commandLineParams()[2..^1]))
  of "cli":
    try: quit(runCli(commandLineParams()[1..^1]))
    except CatchableError as error:
      stderr.writeLine(error.msg)
      quit(2)
  of "argv":
    echo $(%commandLineParams()[1..^1])
    quit(0)
  else: discard

type Fixture = object
  root: string
  env: Table[string, string]

proc setup(): Fixture =
  result.root = createTempDir("vmh-durable-", "")
  let bin = result.root / "bin"
  createDir(bin)
  for tool in ["virsh", "virt-install", "qemu-img", "ssh"]:
    let path = bin / tool
    writeFile(path, "#!/bin/sh\nexec " & quotePosixShellArg(getAppFilename()) &
      " fixture " & tool & " \"$@\"\n")
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
  writeFile(result.root / "hypervisor.json", $(%*{"domains": {}, "calls": [], "boots": 0}))
  writeFile(result.root / "source.qcow2", "caller-owned-installed-disk")
  writeFile(result.root / "id_ed25519", "caller-owned-key")
  writeFile(result.root / "known_hosts", "caller-owned-trust")
  result.env = {"VMH_FIXTURE_ROOT": result.root,
    "HOME": result.root, "PATH": bin & ":" & getEnv("PATH"),
    "LIBVIRT_DEFAULT_URI": "qemu:///session"}.toTable()

proc run(f: Fixture, args: seq[string], extra = initTable[string, string]()): ExecResult =
  var env = f.env
  for k, v in extra: env[k] = v
  captureCommand(@[getAppFilename(), "cli"] & args, env = env,
                  timeoutSec = 20, mergeStderr = false)

proc bootArgs(f: Fixture): seq[string] =
  @["boot", "--keep", "--name", "dev", "--state-dir", f.root / "harness",
    "--backend", "libvirt", "--source-image", f.root / "source.qcow2",
    "--guest", "linux", "--generation", "1", "--ssh-forward-port", "22022",
    "--ssh-user", "repro", "--ssh-private-key", f.root / "id_ed25519",
    "--ssh-known-hosts", f.root / "known_hosts", "--ssh-host-key-alias", "stable-host",
    "--ssh-ready-timeout-sec", "1", "--log-format", "json"]

proc action(f: Fixture, verb: string, suffix: seq[string] = @[]): seq[string] =
  @["instance", verb, "dev", "--state-dir", f.root / "harness",
    "--log-format", "json"] & suffix

proc receipt(f: Fixture): JsonNode =
  parseJson(readFile(f.root / "harness/instances/dev/instance.json"))

suite "durable libvirt CLI (fresh process fixtures)":
  test "absent status is JSON; malformed receipts and backend errors are failures":
    when defined(linux):
      let f = setup()
      defer: removeDir(f.root)
      let absent = f.run(f.action("status"))
      check absent.exitCode == 0
      let data = parseJson(absent.stdout)
      check data["state"].getStr() == "absent"
      check not data["receipt_exists"].getBool()
      let boot = f.run(f.bootArgs())
      check boot.exitCode == 0
      check f.run(f.action("status"), {"VMH_FIXTURE_FAIL": "list"}.toTable()).exitCode != 0
      writeFile(f.root / "harness/instances/dev/instance.json", "broken")
      check f.run(f.action("status")).exitCode != 0

  test "stop, start, destroy and recreate retain UUID, writable disk and trust":
    when defined(linux):
      let f = setup()
      defer: removeDir(f.root)
      let boot = f.run(f.bootArgs())
      checkpoint boot.stderr
      require boot.exitCode == 0
      let original = parseJson(boot.stdout)
      let id = original["instance_id"].getStr()
      writeFile(original["active_disk"].getStr(), "guest-writes-and-host-identity")
      for verb in ["stop", "start", "destroy", "start"]:
        let r = f.run(f.action(verb, @["--instance-id", id]))
        checkpoint r.stderr
        require r.exitCode == 0
        let current = parseJson(r.stdout)
        check current["instance_id"] == original["instance_id"]
        check current["ssh"] == original["ssh"]
        check readFile(current["active_disk"].getStr()) == "guest-writes-and-host-identity"
        check readFile(f.root / (id & ".tpm")) == "tpm-identity"
        check readFile(current["nvram_path"].getStr()) == "firmware-identity"
      check parseJson(readFile(f.root / "hypervisor.json"))["boots"].getInt() == 1
      check readFile(f.root / "known_hosts") == "caller-owned-trust"
      check f.run(f.action("logs")).stdout == "READY\nRESTART\nRESTART\n"
      let image = f.root / "frame.png"
      check f.run(f.action("screenshot", @["--screenshot", image])).exitCode == 0
      check readFile(image) == "fixture-png"

  test "exec preserves argv and environment; SSH has no remote command":
    when defined(linux):
      let f = setup()
      defer: removeDir(f.root)
      require f.run(f.bootArgs()).exitCode == 0
      let wanted = @["", "two words", "O'Brien", "$HOME; false", "line\nnext"]
      let r = f.run(f.action("exec", @["--", getAppFilename(), "argv"] & wanted))
      checkpoint r.stderr
      require r.exitCode == 0
      check parseJson(r.stdout) == %wanted
      let env = f.run(f.action("exec", @["--env", "VALUE=a b'&$HOME",
        "--", "sh", "-c", "printf '%s' \"$VALUE\"; printf error >&2; exit 7"]))
      check env.exitCode == 7
      check env.stdout == "a b'&$HOME"
      check env.stderr == "error"
      let interactive = f.run(f.action("ssh"))
      check interactive.exitCode == 0
      check interactive.stdout == "interactive\n"
      let args = parseJson(readFile(f.root / "ssh-argv.json"))
      check args[0].getStr() == "-t"
      check args[^1].getStr() == "repro@127.0.0.1"

  test "ordinary failed keep cleans up and named failed keep retains recoverable stopped state":
    when defined(linux):
      let f = setup()
      defer: removeDir(f.root)
      let args = f.bootArgs()
      var ordinary: seq[string]
      var i = 0
      while i < args.len:
        if args[i] in ["--name", "--state-dir"]: i += 2
        else: ordinary.add(args[i]); inc i
      ordinary.add(@["--", "hostname"])
      let failed = f.run(ordinary, {"VMH_FIXTURE_FAIL": "ssh"}.toTable())
      check failed.exitCode != 0
      check parseJson(readFile(f.root / "hypervisor.json"))["domains"].len == 0
      let named = f.run(f.bootArgs(), {"VMH_FIXTURE_FAIL": "ssh"}.toTable())
      check named.exitCode != 0
      check f.receipt()["phase"].getStr() == "failed"
      let status = f.run(f.action("status"))
      check parseJson(status.stdout)["backend_state"].getStr() == "shut off"
      check parseJson(status.stdout)["state"].getStr() == "failed"
      check f.run(f.action("start")).exitCode == 0

  test "partial creation and failed forwarding leave owned recovery receipts":
    when defined(linux):
      for failure in ["create", "forward"]:
        let f = setup()
        defer: removeDir(f.root)
        check f.run(f.bootArgs(), {"VMH_FIXTURE_FAIL": failure}.toTable()).exitCode != 0
        check f.receipt()["phase"].getStr() == "failed"
        let data = parseJson(f.run(f.action("status")).stdout)
        check data["backend_state"].getStr() == "shut off"
        check data["state"].getStr() == "failed"
        check f.run(f.action("start")).exitCode == 0

  test "failed recovery XML capture still stops the owned domain":
    when defined(linux):
      let f = setup()
      defer: removeDir(f.root)
      check f.run(f.bootArgs(), {"VMH_FIXTURE_FAIL": "dumpxml"}.toTable()).exitCode != 0
      let data = parseJson(f.run(f.action("status")).stdout)
      check data["state"].getStr() == "failed"
      check data["backend_state"].getStr() == "shut off"

  test "existing names, altered recovery XML and screenshot overwrites are refused":
    when defined(linux):
      let f = setup()
      defer: removeDir(f.root)
      require f.run(f.bootArgs()).exitCode == 0
      let data = f.receipt()
      check f.run(f.bootArgs()).exitCode != 0
      check f.receipt()["instance_id"] == data["instance_id"]
      check f.run(f.action("screenshot", @["--screenshot", data["active_disk"].getStr()])).exitCode != 0
      require f.run(f.action("destroy")).exitCode == 0
      let path = data["domain_xml"].getStr()
      writeFile(path, readFile(path).replace(data["nvram_path"].getStr(), f.root / "caller-firmware"))
      check f.run(f.action("start")).exitCode != 0
      check f.run(f.action("destroy", @["--purge", "--instance-id", data["instance_id"].getStr()])).exitCode != 0
      check fileExists(data["active_disk"].getStr())

  test "purge refuses an owned disk referenced by another registered domain":
    when defined(linux):
      let f = setup()
      defer: removeDir(f.root)
      require f.run(f.bootArgs()).exitCode == 0
      let data = f.receipt()
      let path = f.root / "hypervisor.json"
      var state = parseJson(readFile(path))
      state["domains"]["foreign"] = state["domains"][data["domain_name"].getStr()].copy()
      state["domains"]["foreign"]["uuid"] = %newInstanceId()
      writeFile(path, $state)
      let purge = f.run(f.action("destroy", @["--purge", "--instance-id", data["instance_id"].getStr()]))
      check purge.exitCode != 0
      check "referenced" in purge.stderr
      check fileExists(data["active_disk"].getStr())

  test "UUID mismatch and stale callback cannot stop a replacement":
    when defined(linux):
      let f = setup()
      defer: removeDir(f.root)
      require f.run(f.bootArgs()).exitCode == 0
      check f.run(f.action("stop", @["--instance-id", newInstanceId()])).exitCode != 0
      let data = f.receipt()
      let path = f.root / "hypervisor.json"
      var state = parseJson(readFile(path))
      state["domains"][data["domain_name"].getStr()]["uuid"] = %newInstanceId()
      writeFile(path, $state)
      check f.run(f.action("destroy")).exitCode != 0
      let status = f.run(f.action("status"))
      check status.exitCode == 3
      check parseJson(status.stdout)["ownership"].getStr() == "mismatch"

  test "stop and destroy failures propagate without deleting data":
    when defined(linux):
      let f = setup()
      defer: removeDir(f.root)
      require f.run(f.bootArgs()).exitCode == 0
      check f.run(f.action("stop"), {"VMH_FIXTURE_FAIL": "stop"}.toTable()).exitCode != 0
      check f.run(f.action("destroy"), {"VMH_FIXTURE_FAIL": "undefine"}.toTable()).exitCode != 0
      check fileExists(f.receipt()["active_disk"].getStr())
      check f.receipt()["phase"].getStr() == "failed"

  test "explicit purge removes owned state only, including after default destroy":
    when defined(linux):
      let f = setup()
      defer: removeDir(f.root)
      require f.run(f.bootArgs()).exitCode == 0
      let data = f.receipt()
      require f.run(f.action("destroy")).exitCode == 0
      check f.run(f.action("destroy", @["--purge"])).exitCode != 0
      let purge = f.run(f.action("destroy", @["--purge", "--instance-id", data["instance_id"].getStr()]))
      checkpoint purge.stderr
      require purge.exitCode == 0
      check not fileExists(data["active_disk"].getStr())
      check not fileExists(data["nvram_path"].getStr())
      check not fileExists(f.root / (data["instance_id"].getStr() & ".tpm"))
      check readFile(f.root / "source.qcow2") == "caller-owned-installed-disk"
      check readFile(f.root / "id_ed25519") == "caller-owned-key"
      check readFile(f.root / "known_hosts") == "caller-owned-trust"
      check parseJson(f.run(f.action("status")).stdout)["state"].getStr() == "absent"
      check f.run(f.bootArgs()).exitCode == 0

  test "operation lock is bounded and retained through exec and interactive SSH":
    when defined(linux):
      let f = setup()
      defer: removeDir(f.root)
      require f.run(f.bootArgs()).exitCode == 0
      for verb in ["exec", "ssh"]:
        if fileExists(f.root / "ssh-started"): removeFile(f.root / "ssh-started")
        let arguments = f.action(verb, (if verb == "exec": @["--", "true"] else: @[]))
        # env(1) launches the real dispatcher in a separate process.
        let envArgs = f.env.pairs.toSeq().mapIt(it[0] & "=" & it[1]) & @["VMH_FIXTURE_HOLD=yes"]
        let p = startProcess("env", args = envArgs & @[getAppFilename(), "cli"] & arguments,
                             options = {poUsePath, poStdErrToStdOut})
        defer: p.close()
        let deadline = epochTime() + 5
        while not fileExists(f.root / "ssh-started") and epochTime() < deadline: sleep(10)
        require fileExists(f.root / "ssh-started")
        let busy = f.run(f.action("stop", @["--lock-timeout-sec", "0"]))
        check busy.exitCode != 0
        check "busy" in busy.stderr
        check p.waitForExit(5000) == 0
