## `docs/design.md` § "Reprobuild adapter" must describe the resource types
## this repository actually declares.
##
## MOCK POLICY — nothing is mocked. The test reads the two real files in the
## working tree: `src/vm_harness/repro/resources.nim` and `docs/design.md`.
##
## WHY THIS EXISTS. The determinism table is documentation of a contract that
## lives in code — a class in the table that the source does not declare is
## not a typo, it is a false statement about which cached results reprobuild
## may reuse across machines. `resources.nim` had already drifted once: its
## module header said "three native providers" long after it declared six,
## and nothing noticed because nothing checked. Checking it by eye is exactly
## the mechanism that failed.
##
## WHAT IS AND IS NOT CHECKED. The source is the authority; the document is
## checked against it. Every `resourceType` block's typeId must appear in the
## table with the class the block declares. The reverse is deliberately NOT
## required: the table also carries rows for the two libvirt running-state
## operations, which are backend methods rather than `resourceType` blocks
## and so have no `determinism:` line to read. Those rows are checked for
## PRESENCE only — a mechanical class check there would be checking prose
## against prose.
##
## The class names differ by design between the two files: the Nim enum is
## `rdVolatile`/`rdHostBound`/`rdWeak`/`rdStrong`, the spec vocabulary is
## `volatile`/`host-bound`/`weak`/`strong`. The mapping is applied here and
## is the only place the two spellings meet.

import std/[os, strutils, tables, unittest]

const
  RepoRoot = currentSourcePath().parentDir.parentDir.parentDir
  ResourcesPath = RepoRoot / "src" / "vm_harness" / "repro" / "resources.nim"
  DesignPath = RepoRoot / "docs" / "design.md"
  SectionHeading = "## 14. Reprobuild adapter"
  # Backend methods, not `resourceType` blocks. Presence-checked only.
  BackendOperations = ["snapshotRunning", "restoreSnapshot"]

proc specClassOf(nimEnum: string): string =
  case nimEnum
  of "rdStrong": "strong"
  of "rdWeak": "weak"
  of "rdHostBound": "host-bound"
  of "rdVolatile": "volatile"
  else: raise newException(ValueError,
    "unknown determinism enum in resources.nim: " & nimEnum)

proc typeIdConstants(source: string): Table[string, string] =
  ## `TypeContainer* = "vm_harness.container"` → {"TypeContainer": "vm_harness.container"}
  result = initTable[string, string]()
  for rawLine in source.splitLines():
    let line = rawLine.strip()
    if not line.startsWith("Type"):
      continue
    let eq = line.find('=')
    if eq < 0:
      continue
    let name = line[0 ..< eq].strip().strip(chars = {'*'})
    let rest = line[eq + 1 .. ^1].strip()
    if rest.len >= 2 and rest[0] == '"' and rest[^1] == '"':
      result[name] = rest[1 ..< rest.len - 1]

proc declaredTypes(source: string): Table[string, string] =
  ## Every `resourceType <Const>:` block → {typeId: specClassName}, taking the
  ## class from the block's own `determinism:` line.
  let consts = typeIdConstants(source)
  result = initTable[string, string]()
  var pendingId = ""
  for rawLine in source.splitLines():
    let line = rawLine.strip()
    if line.startsWith("resourceType ") and line.endsWith(":"):
      let constName = line["resourceType ".len ..< line.len - 1].strip()
      doAssert consts.hasKey(constName),
        "resourceType block names an unknown constant: " & constName
      pendingId = consts[constName]
    elif pendingId.len > 0 and line.startsWith("determinism:"):
      let enumName = line["determinism:".len .. ^1].strip()
      result[pendingId] = specClassOf(enumName)
      pendingId = ""
  doAssert pendingId.len == 0,
    "a resourceType block declared no determinism: " & pendingId

proc adapterSection(doc: string): string =
  let start = doc.find(SectionHeading)
  doAssert start >= 0,
    DesignPath & " has no '" & SectionHeading & "' section"
  let rest = doc[start + SectionHeading.len .. ^1]
  # The section runs to the next top-level heading, or to the end of file.
  let nextTop = rest.find("\n## ")
  if nextTop < 0: rest else: rest[0 ..< nextTop]

proc rowFor(section: string; typeId: string): string =
  ## The table row mentioning `typeId`, backtick-quoted as the table writes
  ## it. Empty when there is none.
  for line in section.splitLines():
    if not line.startsWith("|"):
      continue
    if ("`" & typeId & "`") in line:
      return line
  ""

suite "docs/design.md Reprobuild adapter section":

  let source = readFile(ResourcesPath)
  let doc = readFile(DesignPath)
  let section = adapterSection(doc)
  let declaredClasses = declaredTypes(source)

  test "the source declares the six resource types this check expects":
    ## A guard on the CHECKER. If the parse above silently found nothing,
    ## every assertion below would pass vacuously against an empty table.
    check declaredClasses.len == 6
    for typeId in ["vm_harness.container", "vm_harness.exec",
                   "vm_harness.snapshot", "vm_harness.network",
                   "vm_harness.nic", "vm_harness.check"]:
      check declaredClasses.hasKey(typeId)

  test "every declared resource type appears with the class the source declares":
    for typeId, specClass in declaredClasses:
      let row = rowFor(section, typeId)
      checkpoint(typeId & " -> " & specClass & " | row: " & row)
      check row.len > 0
      # The class must appear backtick-quoted in its own row, so a row that
      # merely mentions the word in prose does not satisfy it.
      check ("`" & specClass & "`") in row

  test "no declared type is documented with the WRONG class":
    ## The negative control. The check above would pass if a row carried both
    ## `volatile` and `host-bound`; this refuses any class token in a row
    ## other than the one the source declares.
    for typeId, specClass in declaredClasses:
      let row = rowFor(section, typeId)
      for other in ["strong", "weak", "host-bound", "volatile"]:
        if other == specClass:
          continue
        # `host-bound` contains neither `weak` nor `strong`, and no class
        # name is a substring of another, so a plain containment test is
        # exact here.
        checkpoint(typeId & " must not claim `" & other & "`: " & row)
        check ("`" & other & "`") notin row

  test "every volatile row carries a cacheRetention clause (§2.2)":
    ## §2.2 makes a `volatile` type without a retention clause an error. A
    ## table that omitted one would be documenting an invalid declaration.
    const RetentionClauses = ["max-age", "no-cache", "no-store", "this-build",
                              "stale-while-revalidate"]
    for typeId, specClass in declaredClasses:
      if specClass != "volatile":
        continue
      let row = rowFor(section, typeId)
      var found = false
      for clause in RetentionClauses:
        if ("`" & clause) in row:
          found = true
      checkpoint(typeId & " row: " & row)
      check found

  test "the two libvirt running-state operations are present":
    ## Presence only — these are backend methods, not `resourceType` blocks,
    ## so there is no `determinism:` line to check a class against.
    for op in BackendOperations:
      check ("`" & op & "`") in section

  test "the section points at the normative spec and names the wrapper home":
    check "Edge-Determinism-And-Soft-Rebuild.md" in section
    check "package vm_harness:" in section
    # §1.4 composition and §3's substitution rule are the two properties a
    # reader of the table most needs in order not to misread it.
    check "strictest" in section
    check "substitut" in section

  test "the module header agrees with the source about how many types there are":
    ## The drift that motivated this file: the header said "three native
    ## providers" while the module declared six.
    let header = source[0 ..< max(0, source.find("\nimport "))]
    check "six native providers" in header
    for typeId, specClass in declaredClasses:
      let short = typeId.split('.')[^1]
      checkpoint("header must document " & short)
      check (short & " — `") in header or (short & " —") in header
