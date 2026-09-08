## Durable media ownership. Operation locks are not lifetime leases; the caller
## (for example Reprobuild) owns retention and scheduling.
import std/[json, options, os, osproc, strutils, sysrand, tables, times,
            xmlparser, xmltree]
import ./types, ./orchestrator, ./process_capture
import ./backends/libvirt
when defined(linux):
  import std/posix
  proc flock(fd, operation: cint): cint {.importc, header: "<sys/file.h>".}
  proc atomicRename(oldPath, newPath: cstring): cint {.importc: "rename", header: "<stdio.h>".}
  var noFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
  var directoryFlag {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint

type
  InstanceLock* = ref object
    fd: int
  DurableInstance* = ref object
    receipt*: JsonNode
    receiptPath*: string
    backend*: LibvirtBackend
    operationLock: InstanceLock

proc validateInstanceName*(name: string) =
  if name.len == 0 or name.len > 64 or name[0] notin {'a'..'z', 'A'..'Z', '0'..'9'}:
    raise newException(ValueError, "instance name must start with an alphanumeric character (max 64)")
  for c in name:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}:
      raise newException(ValueError, "invalid instance name")

proc validateInstanceId*(id: string) =
  if id.len != 36: raise newException(ValueError, "instance ID must be a UUID")
  for i, c in id:
    if i in [8, 13, 18, 23]:
      if c != '-': raise newException(ValueError, "instance ID must be a UUID")
    elif c notin {'0'..'9', 'a'..'f'}:
      raise newException(ValueError, "instance UUID must be lowercase hexadecimal")

proc newInstanceId*(): string =
  var bytes: array[16, byte]
  if not urandom(bytes): raise newException(IOError, "cannot generate instance UUID")
  bytes[6] = (bytes[6] and 0x0f) or 0x40
  bytes[8] = (bytes[8] and 0x3f) or 0x80
  for i, b in bytes:
    if i in [4, 6, 8, 10]: result.add('-')
    result.add(toHex(b, 2).toLowerAscii())

proc ensureDirectory(path: string) =
  if symlinkExists(path) or fileExists(path):
    raise newException(IOError, "state directory must not be a symlink or file: " & path)
  createDir(path)

proc instanceDirectory*(root, name: string): string =
  validateInstanceName(name)
  if root.len == 0: raise newException(ValueError, "--state-dir is required")
  absolutePath(root) / "instances" / name

proc acquireInstanceOperationLock*(root, name: string, timeoutSec = 10,
                                   registry = false): InstanceLock =
  when defined(linux):
    validateInstanceName(name)
    if root.len == 0: raise newException(ValueError, "--state-dir is required")
    ensureDirectory(absolutePath(root))
    let locks = absolutePath(root) / "locks"
    ensureDirectory(locks)
    let path = locks / ((if registry: "registry." else: "instance.") & name & ".lock")
    let fd = posix.open(path.cstring, O_CREAT or O_RDWR or noFollow or O_CLOEXEC,
                        Mode(0o600))
    if fd < 0: raiseOSError(osLastError(), path)
    let deadline = epochTime() + float(timeoutSec)
    while flock(fd, 2 or 4) != 0:
      if errno notin [EAGAIN, EINTR]:
        let error = osLastError()
        discard posix.close(fd)
        raiseOSError(error, path)
      if epochTime() >= deadline:
        discard posix.close(fd)
        raise newException(TimeoutError, "instance operation is busy: " & name)
      sleep(25)
    InstanceLock(fd: int(fd))
  else:
    raise newException(BackendUnavailableError, "durable media requires Linux/libvirt")

proc release*(lock: InstanceLock) =
  when defined(linux):
    if lock != nil and lock.fd >= 0:
      discard flock(cint(lock.fd), 8)
      discard posix.close(cint(lock.fd))
      lock.fd = -1

proc close*(instance: DurableInstance) =
  if instance != nil: instance.operationLock.release()

proc requireExclusive(instance: DurableInstance) =
  if instance.operationLock == nil or instance.operationLock.fd < 0:
    raise newException(VmHarnessError, "instance operation requires an exclusive lock")

proc atomicStateWrite*(path, content: string) =
  when defined(linux):
    if symlinkExists(path): raise newException(IOError, "refusing state symlink: " & path)
    let tmp = path & ".tmp-" & newInstanceId()
    let fd = posix.open(tmp.cstring, O_CREAT or O_EXCL or O_WRONLY or O_CLOEXEC,
                       Mode(0o600))
    if fd < 0: raiseOSError(osLastError(), tmp)
    try:
      var offset = 0
      while offset < content.len:
        let n = posix.write(fd, unsafeAddr content[offset], content.len - offset)
        if n < 0:
          if errno == EINTR: continue
          raiseOSError(osLastError())
        offset += int(n)
      if fsync(fd) != 0: raiseOSError(osLastError())
      if atomicRename(tmp.cstring, path.cstring) != 0: raiseOSError(osLastError())
      let dirFd = posix.open(parentDir(path).cstring, O_RDONLY or directoryFlag)
      if dirFd < 0: raiseOSError(osLastError())
      try:
        if fsync(dirFd) != 0: raiseOSError(osLastError())
      finally: discard posix.close(dirFd)
    finally:
      discard posix.close(fd)
      if fileExists(tmp): removeFile(tmp)
  else:
    raise newException(BackendUnavailableError, "durable media requires Linux/libvirt")

proc save*(instance: DurableInstance, phase: string, error = "") =
  instance.requireExclusive()
  instance.receipt["phase"] = %phase
  instance.receipt["last_error"] = %error
  instance.receipt["updated_at"] = %int64(epochTime())
  atomicStateWrite(instance.receiptPath, pretty(instance.receipt) & "\n")

proc field(instance: DurableInstance, key: string): string =
  instance.receipt[key].getStr()

proc observe*(instance: DurableInstance): LibvirtDomainObservation =
  instance.backend.requireDomainOwner(instance.field("domain_name"),
                                      instance.field("instance_id"))

proc preserveDomainXml*(instance: DurableInstance) =
  instance.requireExclusive()
  if instance.observe().present:
    let xml = instance.backend.checkedVirsh([
      "dumpxml", instance.field("instance_id"), "--inactive"])
    if xml.len == 0: raise newException(VmHarnessError, "empty domain XML")
    let document = parseXml(xml)
    let osNode = document.child("os")
    let nvram = if osNode == nil: nil else: osNode.child("nvram")
    let nvramPath = if nvram == nil: "" else: nvram.innerText
    if instance.field("phase") == "creating" or not fileExists(instance.field("domain_xml")):
      instance.receipt["nvram_path"] = %nvramPath
    elif nvramPath != instance.field("nvram_path"):
      raise newException(VmHarnessError, "domain firmware path differs from receipt")
    atomicStateWrite(instance.field("domain_xml"), xml & "\n")
    instance.save(instance.field("phase"), instance.field("last_error"))

proc beginDurableBoot*(root, name, requestedId: string, b: LibvirtBackend,
                       spec: var BootMediaSpec, lockTimeoutSec = 10): DurableInstance =
  let lock = acquireInstanceOperationLock(root, name, lockTimeoutSec)
  try:
    let registryLock = acquireInstanceOperationLock(root, "index", lockTimeoutSec, true)
    defer: registryLock.release()
    let dir = instanceDirectory(root, name)
    ensureDirectory(parentDir(dir))
    # A failed or destroyed receipt remains reserved until explicitly recovered.
    if dirExists(dir) or fileExists(dir) or symlinkExists(dir):
      raise newException(VmHarnessError, "instance state already exists: " & dir)
    let id = if requestedId.len > 0: requestedId else: newInstanceId()
    validateInstanceId(id)
    let domainName = "vmh-media-" & id
    if b.inspectDomain(domainName).present or
        id in b.checkedVirsh(["list", "--all", "--uuid"]).splitLines():
      raise newException(VmHarnessError, "instance UUID is already registered in libvirt")
    ensureDirectory(dir)
    b.imagePoolDir = dir
    let ownKnownHosts = b.sshKnownHostsPath.len == 0
    if b.sshKnownHostsPath.len == 0: b.sshKnownHostsPath = dir / "known_hosts"
    if b.sshHostKeyAlias.len == 0: b.sshHostKeyAlias = "vmh-" & id
    createDir(parentDir(b.sshKnownHostsPath))
    spec.name = domainName
    spec.instanceId = id
    spec.serialLogPath = dir / "serial.log"
    let now = int64(epochTime())
    result = DurableInstance(backend: b, operationLock: lock,
      receiptPath: dir / "instance.json", receipt: %*{
        "schema_version": 1, "name": name, "instance_id": id,
        "backend": "libvirt", "libvirt_uri": b.libvirtUri,
        "domain_name": domainName, "phase": "creating",
        "source_image": absolutePath(spec.mediaPath),
        "active_disk": b.domainDiskPath(domainName),
        "domain_xml": dir / "domain.xml", "serial_log": spec.serialLogPath,
        "nvram_path": "", "owns_known_hosts": ownKnownHosts,
        "ssh": {"host": "127.0.0.1", "port": b.sshPort, "user": b.sshUser,
          "private_key": b.sshKeyPath, "known_hosts": b.sshKnownHostsPath,
          "host_key_alias": b.sshHostKeyAlias, "guest_os": "linux"},
        "created_at": now, "updated_at": now, "last_error": ""})
    result.save("creating")
  except:
    lock.release()
    raise

proc loadInstance*(root, name, expectedId: string, lockTimeoutSec = 10,
                   readOnly = false): DurableInstance =
  let lock = if readOnly: nil else: acquireInstanceOperationLock(root, name, lockTimeoutSec)
  try:
    let dir = instanceDirectory(root, name)
    if symlinkExists(absolutePath(root)) or symlinkExists(parentDir(dir)) or symlinkExists(dir):
      raise newException(IOError, "instance state must not be a symlink")
    let path = dir / "instance.json"
    if symlinkExists(path): raise newException(IOError, "receipt must not be a symlink")
    let data = parseJson(readFile(path))
    if data["schema_version"].getInt() != 1 or data["backend"].getStr() != "libvirt":
      raise newException(ValueError, "unsupported instance receipt")
    let id = data["instance_id"].getStr()
    validateInstanceId(id)
    if data["name"].getStr() != name or
        data["domain_name"].getStr() != "vmh-media-" & id:
      raise newException(ValueError, "receipt identity does not match its name")
    if expectedId.len > 0:
      validateInstanceId(expectedId)
      if expectedId != id:
        raise newException(VmHarnessError, "instance ID precondition failed")
    for (key, expected) in [("active_disk", dir / ("vmh-media-" & id & ".qcow2")),
                            ("domain_xml", dir / "domain.xml"),
                            ("serial_log", dir / "serial.log")]:
      if data[key].getStr() != expected:
        raise newException(ValueError, "invalid receipt path: " & key)
    let ssh = data["ssh"]
    if data["phase"].getStr() notin ["creating", "starting", "running", "stopping",
        "stopped", "destroying", "destroyed", "failed"] or
        data["owns_known_hosts"].kind != JBool or
        (data["owns_known_hosts"].getBool() and
          ssh["known_hosts"].getStr() != dir / "known_hosts"):
      raise newException(ValueError, "invalid instance receipt phase or artifact ownership")
    if ssh["guest_os"].getStr() != "linux" or ssh["host"].getStr() != "127.0.0.1" or
        ssh["port"].getInt() notin 1..65535:
      raise newException(ValueError, "unsupported receipt SSH endpoint")
    let b = newLibvirtBackend(sshPassword = "", sshGuestOs = goLinux,
      sshUser = ssh["user"].getStr(), sshPort = ssh["port"].getInt(),
      sshKeyPath = ssh["private_key"].getStr(),
      sshKnownHostsPath = ssh["known_hosts"].getStr(),
      sshHostKeyAlias = ssh["host_key_alias"].getStr(), imagePoolDir = dir)
    # Do not re-resolve the recorded system URI through a changed environment.
    b.libvirtUri = data["libvirt_uri"].getStr()
    if b.libvirtUri.len == 0 or b.sshUser.len == 0 or b.sshKeyPath.len == 0 or
        b.sshKnownHostsPath.len == 0 or b.sshHostKeyAlias.len == 0:
      raise newException(ValueError, "incomplete instance receipt")
    result = DurableInstance(receipt: data, receiptPath: path,
                              backend: b, operationLock: lock)
  except:
    lock.release()
    raise

proc handle*(instance: DurableInstance): VmHandle =
  let b = instance.backend
  VmHandle(backend: b, name: instance.field("instance_id"),
    baseline: "<durable-media>", ipAddress: some("127.0.0.1"),
    sshPort: b.sshPort, sshUser: b.sshUser,
    sshAuth: SshAuth(kind: saKeyFile, keyPath: b.sshKeyPath),
    extra: {"serialLogPath": instance.field("serial_log")}.toTable())

proc failBoot*(instance: DurableInstance, message: string) =
  instance.requireExclusive()
  var failures: seq[string]
  try: instance.save("failed", message)
  except CatchableError as error: failures.add(error.msg)
  try: instance.preserveDomainXml()
  except CatchableError as error: failures.add(error.msg)
  # Failure to save recovery XML must not skip the checked owned shutdown.
  try:
    instance.backend.stopOwnedDomain(instance.field("domain_name"),
      instance.field("instance_id"), force = true)
  except CatchableError as error: failures.add(error.msg)
  if failures.len > 0:
    let detail = message & "; recovery required: " & failures.join("; ")
    instance.save("failed", detail)
    raise newException(VmHarnessError, detail)

proc status*(instance: DurableInstance): JsonNode =
  let observed = instance.backend.inspectDomain(instance.field("domain_name"))
  result = instance.receipt.copy()
  result["receipt_path"] = %instance.receiptPath
  result["receipt_exists"] = %true
  result["present"] = %observed.present
  result["backend_state"] = %observed.state
  result["state"] = %(if instance.field("phase") == "failed": "failed"
    elif instance.field("phase") in ["creating", "starting"]: "creating"
    elif not observed.present: "destroyed"
    elif observed.state == "shut off": "stopped"
    elif observed.state == "running": "running"
    else: "failed")
  result["observed_instance_id"] = %observed.uuid
  result["ownership"] = %(if not observed.present: "absent"
    elif observed.uuid == instance.field("instance_id"): "matched" else: "mismatch")

proc absentInstanceStatus*(root, name: string): JsonNode =
  let path = instanceDirectory(root, name) / "instance.json"
  %*{"schema_version": 1, "name": name, "instance_id": "", "backend": "libvirt",
    "libvirt_uri": "", "domain_name": "", "phase": "absent", "source_image": "",
    "active_disk": "", "domain_xml": "", "serial_log": "",
    "nvram_path": "", "owns_known_hosts": false,
    "ssh": {"host": "", "port": 0, "user": "", "private_key": "",
      "known_hosts": "", "host_key_alias": "", "guest_os": "linux"},
    "created_at": 0, "updated_at": 0, "last_error": "", "receipt_path": path,
    "receipt_exists": false, "present": false, "state": "absent",
    "backend_state": "", "ownership": "absent", "observed_instance_id": ""}

proc restoreDefinition(instance: DurableInstance, requireDisk = true) =
  let path = instance.field("domain_xml")
  if symlinkExists(path): raise newException(IOError, "recovery XML must not be a symlink")
  let xml = parseXml(readFile(path))
  if xml.tag != "domain" or xml.child("uuid") == nil or xml.child("name") == nil or
      xml.child("uuid").innerText != instance.field("instance_id") or
      xml.child("name").innerText != instance.field("domain_name"):
    raise newException(VmHarnessError, "recovery XML does not match instance ownership")
  let osNode = xml.child("os")
  let nvram = if osNode == nil: nil else: osNode.child("nvram")
  if (if nvram == nil: "" else: nvram.innerText) != instance.field("nvram_path"):
    raise newException(VmHarnessError, "recovery firmware path differs from receipt")
  var foundDisk = false
  let devices = xml.child("devices")
  if devices != nil:
    for node in devices.items:
      if node.kind == xnElement and node.tag == "disk" and node.attr("device") == "disk":
        let source = node.child("source")
        if source != nil and source.attr("file") == instance.field("active_disk"):
          foundDisk = true
        else:
          raise newException(VmHarnessError, "recovery XML contains an unowned writable disk")
  if not foundDisk or (requireDisk and not fileExists(instance.field("active_disk"))):
    raise newException(VmHarnessError, "recovery disk is missing or differs from receipt")
  if instance.field("instance_id") in instance.backend.checkedVirsh(
      ["list", "--all", "--uuid"]).splitLines():
    raise newException(VmHarnessError, "instance UUID is registered under a different name")
  discard instance.backend.checkedVirsh(["define", path])
  if not instance.observe().present:
      raise newException(VmHarnessError, "restored domain is absent")

proc ensurePurgeUnreferenced(instance: DurableInstance) =
  let disk = instance.field("active_disk")
  let source = instance.field("source_image")
  proc samePath(a, b: string): bool =
    if a.len == 0 or b.len == 0: return false
    let left = if fileExists(a): expandFilename(a) else: absolutePath(a)
    let right = if fileExists(b): expandFilename(b) else: absolutePath(b)
    left == right
  proc checkReference(path, owner: string) =
    if path.len == 0: return
    if samePath(path, disk):
      raise newException(VmHarnessError, "purge disk is referenced by " & owner)
    let info = captureCommand(@[instance.backend.qemuImgCmd, "info", "--force-share",
      "--backing-chain", "--output=json", path], timeoutSec = 30, mergeStderr = false)
    if info.exitCode != 0:
      raise newException(VmHarnessError, "cannot check purge references for " & owner &
        ": " & info.stderr)
    let chain = parseJson(info.stdout)
    if chain.kind != JArray or chain.len == 0:
      raise newException(VmHarnessError, "invalid backing chain for " & owner)
    for image in chain:
      if not image.hasKey("filename") or image["filename"].getStr().len == 0:
        raise newException(VmHarnessError, "missing backing filename for " & owner)
      if samePath(image["filename"].getStr(), disk):
        raise newException(VmHarnessError, "purge disk is referenced by " & owner)
  let listed = instance.backend.tryListAllDomainNames()
  if not listed.ok: raise newException(VmHarnessError, listed.message)
  for name in listed.names:
    if name == instance.field("domain_name"): continue
    let document = parseXml(instance.backend.checkedVirsh(["dumpxml", name]))
    let devices = document.child("devices")
    if devices == nil: continue
    for node in devices.items:
      if node.kind != xnElement or node.tag != "disk": continue
      let src = node.child("source")
      if src == nil: continue
      let path = src.attr("file")
      checkReference(path, "domain " & name)
  let instancesDir = parentDir(parentDir(instance.receiptPath))
  for kind, dir in walkDir(instancesDir):
    if kind notin {pcDir, pcLinkToDir} or dir == parentDir(instance.receiptPath): continue
    if kind == pcLinkToDir: raise newException(IOError, "cannot inspect linked instance state")
    let receipt = dir / "instance.json"
    if not fileExists(receipt):
      raise newException(IOError, "cannot inspect instance without receipt: " & dir)
    let data = parseJson(readFile(receipt))
    for key in ["source_image", "active_disk"]:
      checkReference(data[key].getStr(), dir)
  if samePath(disk, source) or symlinkExists(disk):
    raise newException(VmHarnessError, "refusing to purge a caller-owned or linked disk")

proc start*(instance: DurableInstance, timeoutSec = 120) =
  instance.requireExclusive()
  let observed = instance.observe()
  try:
    instance.save("starting")
    if not observed.present: instance.restoreDefinition()
    if not observed.present or observed.state == "shut off":
      discard instance.backend.checkedVirsh(["start", instance.field("instance_id")])
    elif observed.state != "running":
      raise newException(VmHarnessError, "cannot start domain in state " & observed.state)
    instance.backend.ensureSshForward(instance.field("instance_id"), instance.backend.sshPort)
    instance.backend.startAndAwaitReady(instance.handle(), timeoutSec)
    instance.preserveDomainXml()
    instance.save("running")
  except CatchableError as error:
    if not observed.present or observed.state == "shut off": instance.failBoot(error.msg)
    else: instance.save("failed", error.msg)
    raise

proc stop*(instance: DurableInstance, timeoutSec = 60, force = false) =
  instance.requireExclusive()
  discard instance.observe()
  try:
    instance.save("stopping")
    instance.backend.stopOwnedDomain(instance.field("domain_name"),
      instance.field("instance_id"), timeoutSec, force)
    instance.save("stopped")
  except CatchableError as error:
    instance.save("failed", error.msg)
    raise

proc destroy*(instance: DurableInstance, timeoutSec = 60, force = false,
              purge = false) =
  instance.requireExclusive()
  var observed = instance.observe()
  let root = parentDir(parentDir(parentDir(instance.receiptPath)))
  let registryLock = if purge: acquireInstanceOperationLock(root, "index", 10, true) else: nil
  defer: registryLock.release()
  try:
    if purge:
      instance.ensurePurgeUnreferenced()
      if not observed.present and fileExists(instance.field("domain_xml")):
        instance.restoreDefinition(requireDisk = false)
        observed = instance.observe()
    instance.save("destroying")
    if observed.present:
      instance.backend.stopOwnedDomain(instance.field("domain_name"),
        instance.field("instance_id"), timeoutSec, force)
      instance.preserveDomainXml()
      let flags = if purge: @["--nvram", "--tpm"] else: @["--keep-nvram", "--keep-tpm"]
      discard instance.backend.checkedVirsh(@["undefine", instance.field("instance_id")] & flags)
    if instance.observe().present:
      raise newException(VmHarnessError, "domain remains after destroy")
    instance.save("destroyed")
    if purge:
      # Explicit files only. Inputs (including supplied SSH trust) are never removed.
      for key in ["active_disk", "domain_xml", "serial_log"]:
        let path = instance.field(key)
        if symlinkExists(path): raise newException(IOError, "refusing linked owned artifact")
        if fileExists(path): removeFile(path)
      if instance.receipt["owns_known_hosts"].getBool():
        let path = parentDir(instance.receiptPath) / "known_hosts"
        if fileExists(path): removeFile(path)
      removeFile(instance.receiptPath)
      # Do not recursively remove unexpected contents.
      when defined(linux):
        if posix.rmdir(parentDir(instance.receiptPath).cstring) != 0:
          raiseOSError(osLastError(), "instance directory is not empty after purge")
  except CatchableError as error:
    instance.save("failed", error.msg)
    raise

proc requireRunning(instance: DurableInstance) =
  instance.requireExclusive()
  let observed = instance.observe()
  if not observed.present or observed.state != "running":
    raise newException(VmHarnessError, "instance is not running; use instance start")

proc exec*(instance: DurableInstance, command: seq[string],
           env: Table[string, string], timeoutSec = 120): ExecResult =
  instance.requireRunning()
  if command.len == 0: raise newException(ValueError, "exec requires a command after --")
  let payload = formatSshEnvironment(env, goLinux) & formatSshCommand(command, goLinux)
  let argv = instance.backend.sshBaseArgs("127.0.0.1")
  captureCommand(argv & @[payload], timeoutSec = timeoutSec, mergeStderr = false)

proc ssh*(instance: DurableInstance): int =
  instance.requireRunning()
  let argv = instance.backend.sshBaseArgs("127.0.0.1")
  let p = startProcess(argv[0], args = @["-t"] & argv[1..^1],
                       options = {poUsePath, poParentStreams})
  defer:
    if p.running:
      p.kill()
      discard p.waitForExit()
    p.close()
  p.waitForExit()

proc screenshot*(instance: DurableInstance, path: string, delaySec = 0) =
  instance.requireRunning()
  if path.len == 0: raise newException(ValueError, "screenshot requires --screenshot PATH")
  if delaySec < 0 or delaySec > 300:
    raise newException(ValueError, "screenshot delay must be between 0 and 300 seconds")
  let destination = absolutePath(path)
  if symlinkExists(destination):
    raise newException(ValueError, "screenshot destination must not be a symlink")
  for reserved in [instance.receiptPath, instance.field("active_disk"),
      instance.field("source_image"), instance.field("domain_xml"),
      instance.field("serial_log"), instance.field("nvram_path"),
      instance.backend.sshKeyPath, instance.backend.sshKnownHostsPath]:
    if reserved.len > 0 and destination == absolutePath(reserved):
      raise newException(ValueError, "screenshot would overwrite instance data")
  sleep(delaySec * 1000)
  instance.backend.captureScreenshot(instance.handle(), destination)

proc logs*(instance: DurableInstance, follow = false) =
  discard instance.observe()
  let path = instance.field("serial_log")
  # Following output must not block a concurrent stop/destroy callback.
  instance.close()
  var offset: int64
  while true:
    checkInterrupted()
    if fileExists(path):
      var f = open(path, fmRead)
      try:
        if getFileSize(path) < offset: offset = 0
        setFilePos(f, offset)
        let chunk = f.readAll()
        offset += int64(chunk.len)
        stdout.write(chunk)
        stdout.flushFile()
      finally: f.close()
    if not follow: return
    sleep(100)
