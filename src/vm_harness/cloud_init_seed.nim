## NoCloud cloud-init seed ISO9660 generator.
##
## cloud-init's NoCloud datasource auto-detects any block device whose
## filesystem label is "cidata" (case-insensitive) and reads
## ``user-data`` + ``meta-data`` from its root. The ISO9660 PVD's
## volume-identifier field doubles as the filesystem label that udev
## surfaces, so we set it to "CIDATA".
##
## This builder writes a minimal-but-compliant ISO9660 with two files in
## the root directory. No Joliet, no Rock Ridge — cloud-init reads the
## bytes by exact name and the Linux ISO9660 driver returns the file
## names as-stored when neither extension is present, so lowercase
## ``user-data`` + ``meta-data`` work as intended.
##
## Direct port of ``build_nocloud_iso`` from
## ``reprobuild/recipes/reproos-ref-iso/boot-test-hyperv.py``. Layout
## (one logical block = 2048 bytes):
##
##   LBA 0..15 = system area (reserved, all zeroes).
##   LBA 16   = Primary Volume Descriptor.
##   LBA 17   = Volume Descriptor Set Terminator.
##   LBA 18   = L-path Path Table.
##   LBA 19   = M-path Path Table.
##   LBA 20   = Root directory.
##   LBA 21.. = file extents.

import std/[times]

const LogicalBlockSize* = 2048

proc padTo(data: openArray[char], size: int): seq[byte] =
  if data.len > size:
    raise newException(ValueError, "data exceeds field size")
  result = newSeq[byte](size)
  for i, c in data: result[i] = byte(c)
  for i in data.len ..< size: result[i] = 0

proc padToBlock(data: seq[byte]): seq[byte] =
  let rem = (LogicalBlockSize - (data.len mod LogicalBlockSize)) mod LogicalBlockSize
  result = data
  for _ in 0 ..< rem: result.add(0'u8)

proc bothEndianU16(v: int): seq[byte] =
  let u = uint16(v)
  @[byte(u and 0xFF), byte((u shr 8) and 0xFF),
    byte((u shr 8) and 0xFF), byte(u and 0xFF)]

proc bothEndianU32(v: int): seq[byte] =
  let u = uint32(v)
  @[byte(u and 0xFF),
    byte((u shr 8) and 0xFF),
    byte((u shr 16) and 0xFF),
    byte((u shr 24) and 0xFF),
    byte((u shr 24) and 0xFF),
    byte((u shr 16) and 0xFF),
    byte((u shr 8) and 0xFF),
    byte(u and 0xFF)]

proc le32(v: int): seq[byte] =
  let u = uint32(v)
  @[byte(u and 0xFF),
    byte((u shr 8) and 0xFF),
    byte((u shr 16) and 0xFF),
    byte((u shr 24) and 0xFF)]

proc be32(v: int): seq[byte] =
  let u = uint32(v)
  @[byte((u shr 24) and 0xFF),
    byte((u shr 16) and 0xFF),
    byte((u shr 8) and 0xFF),
    byte(u and 0xFF)]

proc le16(v: int): seq[byte] =
  let u = uint16(v)
  @[byte(u and 0xFF), byte((u shr 8) and 0xFF)]

proc be16(v: int): seq[byte] =
  let u = uint16(v)
  @[byte((u shr 8) and 0xFF), byte(u and 0xFF)]

proc strA(s: string, size: int): seq[byte] =
  ## ISO9660 a-string field (subset of ASCII; pad with space, 0x20).
  result = newSeq[byte](size)
  let bytes = cast[seq[byte]](s)
  for i in 0 ..< min(bytes.len, size): result[i] = bytes[i]
  for i in bytes.len ..< size: result[i] = 0x20

proc strD(s: string, size: int): seq[byte] =
  ## ISO9660 d-string field (uppercase + digits + '_'); pad with space.
  result = newSeq[byte](size)
  var canonical = ""
  for c in s:
    if (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_':
      canonical.add(c)
    elif c >= 'a' and c <= 'z':
      canonical.add(chr(ord(c) - 32))
    else:
      canonical.add('_')
  let bytes = cast[seq[byte]](canonical)
  for i in 0 ..< min(bytes.len, size): result[i] = bytes[i]
  for i in bytes.len ..< size: result[i] = 0x20

proc isoDecDateTime(): seq[byte] =
  ## ISO9660 17-byte "yyyymmddHHMMSScc" + tz-offset-quarters volume timestamp.
  let now = utc(getTime())
  let s = format(now, "yyyyMMddHHmmss") & "00"
  result = newSeq[byte](17)
  let bytes = cast[seq[byte]](s)
  for i in 0 ..< min(bytes.len, 16): result[i] = bytes[i]
  result[16] = 0  # tz 0 (UTC)

proc isoDirDateTime(): seq[byte] =
  ## ISO9660 7-byte directory-entry timestamp.
  let now = utc(getTime())
  result = newSeq[byte](7)
  result[0] = byte(now.year - 1900)
  result[1] = byte(ord(now.month))
  result[2] = byte(now.monthday)
  result[3] = byte(now.hour)
  result[4] = byte(now.minute)
  result[5] = byte(now.second)
  result[6] = 0  # tz 0

proc dirRecord(name: seq[byte], extentLba: int, sizeBytes: int,
               isDir: bool): seq[byte] =
  ## Build one ISO9660 directory record. Pads to even length.
  if name.len == 0:
    raise newException(ValueError, "empty name")
  let fileFlags: byte = if isDir: 0x02 else: 0x00
  var recLen = 33 + name.len
  if (recLen mod 2) == 1: recLen += 1
  result = newSeq[byte](recLen)
  var i = 0
  result[i] = byte(recLen); inc i
  result[i] = 0; inc i  # extended attr length
  let be = bothEndianU32(extentLba)
  for b in be: result[i] = b; inc i
  let sz = bothEndianU32(sizeBytes)
  for b in sz: result[i] = b; inc i
  let ts = isoDirDateTime()
  for b in ts: result[i] = b; inc i
  result[i] = fileFlags; inc i
  result[i] = 0; inc i  # file unit size
  result[i] = 0; inc i  # interleave gap
  let seq2 = bothEndianU16(1)
  for b in seq2: result[i] = b; inc i
  result[i] = byte(name.len); inc i
  for b in name: result[i] = b; inc i
  while i < recLen: result[i] = 0; inc i

proc buildNoCloudIso*(userData, metaData: string,
                     volumeId: string = "CIDATA"): seq[byte] =
  ## Build a minimal NoCloud cloud-init seed ISO9660 image in memory.
  ## Returns the full bytes; caller writes to disk.
  proc bytesOf(s: string): seq[byte] =
    result = newSeq[byte](s.len)
    for i, c in s: result[i] = byte(c)

  let udBytes = bytesOf(userData)
  let mdBytes = bytesOf(metaData)
  let udPadded = padToBlock(udBytes)
  let mdPadded = padToBlock(mdBytes)

  let udataLba = 21
  let mdataLba = udataLba + (udPadded.len div LogicalBlockSize)
  let totalBlocks = mdataLba + (mdPadded.len div LogicalBlockSize)

  # Root directory: 4 records ('.', '..', user-data, meta-data).
  let dotName = @[byte(0)]
  let dotDotName = @[byte(1)]
  let udataName = bytesOf("user-data")
  let mdataName = bytesOf("meta-data")

  var rootRecs: seq[byte] = @[]
  rootRecs.add(dirRecord(dotName, 20, LogicalBlockSize, isDir = true))
  rootRecs.add(dirRecord(dotDotName, 20, LogicalBlockSize, isDir = true))
  rootRecs.add(dirRecord(udataName, udataLba, udBytes.len, isDir = false))
  rootRecs.add(dirRecord(mdataName, mdataLba, mdBytes.len, isDir = false))
  let rootBlock = padToBlock(rootRecs)

  # Path Table: one entry for root. L-path is little-endian, M-path big.
  proc pathTable(bigEndian: bool): seq[byte] =
    var rec: seq[byte] = @[]
    rec.add(1)  # dir id length
    rec.add(0)  # extended attr len
    if bigEndian:
      rec.add(be32(20))
      rec.add(be16(1))
    else:
      rec.add(le32(20))
      rec.add(le16(1))
    rec.add(0)  # dir id (root)
    rec.add(0)  # padding to even
    result = padToBlock(rec)

  let lpath = pathTable(bigEndian = false)
  let mpath = pathTable(bigEndian = true)

  # Root directory record (placed inside PVD).
  let rootDirRecord = dirRecord(dotName, 20, LogicalBlockSize, isDir = true)

  # Primary Volume Descriptor (LBA 16, 2048 bytes).
  var pvd: seq[byte] = @[]
  pvd.add(1)            # type = primary
  for b in cast[seq[byte]]("CD001"): pvd.add(b)
  pvd.add(1)            # version
  pvd.add(0)            # unused
  pvd.add(strA("", 32))            # system identifier
  pvd.add(strD(volumeId, 32))      # volume identifier
  for _ in 0 ..< 8: pvd.add(0)     # unused
  pvd.add(bothEndianU32(totalBlocks))
  for _ in 0 ..< 32: pvd.add(0)
  pvd.add(bothEndianU16(1))        # volume set size
  pvd.add(bothEndianU16(1))        # volume sequence number
  pvd.add(bothEndianU16(LogicalBlockSize))
  pvd.add(bothEndianU32(LogicalBlockSize))  # path table size
  pvd.add(le32(18))                # L-path location
  pvd.add(le32(0))                 # optional L-path
  pvd.add(be32(19))                # M-path location
  pvd.add(be32(0))                 # optional M-path
  pvd.add(rootDirRecord)           # 34-byte root dir record
  pvd.add(strD("", 128))           # volume set id
  pvd.add(strA("", 128))           # publisher id
  pvd.add(strA("", 128))           # data preparer id
  pvd.add(strA("", 128))           # application id
  pvd.add(strD("", 37))            # copyright file id
  pvd.add(strD("", 37))            # abstract file id
  pvd.add(strD("", 37))            # bibliographic file id
  pvd.add(isoDecDateTime())        # volume creation date
  pvd.add(isoDecDateTime())        # volume modification date
  for _ in 0 ..< 16: pvd.add(byte('0'))
  pvd.add(0)                       # volume expiration
  for _ in 0 ..< 16: pvd.add(byte('0'))
  pvd.add(0)                       # volume effective date
  pvd.add(1)                       # file structure version
  pvd.add(0)                       # unused
  for _ in 0 ..< 512: pvd.add(0)   # application use
  for _ in 0 ..< 653: pvd.add(0)   # reserved
  let pvdBlock = padToBlock(pvd)
  doAssert pvdBlock.len == LogicalBlockSize,
    "PVD len mismatch: " & $pvdBlock.len

  # Volume Descriptor Set Terminator (LBA 17).
  var vdst: seq[byte] = @[255'u8]
  for b in cast[seq[byte]]("CD001"): vdst.add(b)
  vdst.add(1)
  for _ in 0 ..< (LogicalBlockSize - 7): vdst.add(0)
  doAssert vdst.len == LogicalBlockSize

  # Assemble.
  var outBytes: seq[byte] = @[]
  for _ in 0 ..< (LogicalBlockSize * 16): outBytes.add(0)
  outBytes.add(pvdBlock)
  outBytes.add(vdst)
  outBytes.add(lpath)
  outBytes.add(mpath)
  outBytes.add(rootBlock)
  outBytes.add(udPadded)
  outBytes.add(mdPadded)
  doAssert outBytes.len == totalBlocks * LogicalBlockSize,
    "ISO len mismatch: " & $outBytes.len & " vs " &
    $(totalBlocks * LogicalBlockSize)
  result = outBytes

proc writeNoCloudIso*(path, userData, metaData: string;
                     volumeId: string = "CIDATA") =
  let blob = buildNoCloudIso(userData, metaData, volumeId)
  var f = open(path, fmWrite)
  defer: f.close()
  if blob.len > 0:
    discard f.writeBuffer(unsafeAddr blob[0], blob.len)
