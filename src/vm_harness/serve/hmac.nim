## vm-harness serve — pure-Nim SHA-256 + HMAC-SHA256 (RA6).
##
## Self-contained, dependency-free hashing used by the enrollment/identity
## signatures (``enrollment.nim``). vm-harness is deliberately dependency-light
## (``vm_harness.nimble`` requires only ``nim``); Nim's stdlib ships ``std/sha1``
## but no SHA-256 / HMAC and no asymmetric primitive. Rather than pull in
## ``nimcrypto`` or link OpenSSL for what is a *capability-advertisement*
## signature (the confidential, endpoint-authenticated transport is already
## provided by bearer-over-NetBird — campaign non-negotiable pattern (a)), we
## carry a small, auditable, fully test-vectored SHA-256 + HMAC here.
##
## Everything is pure value logic: deterministic, host-independent, and unit
## tested against the standard NIST SHA-256 and RFC 4231 HMAC vectors
## (``tests/unit/t_serve_enrollment.nim``).

const
  K: array[64, uint32] = [
    0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
    0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
    0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
    0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
    0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
    0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
    0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
    0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
    0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
    0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
    0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
    0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
    0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
    0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
    0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
    0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

const BlockSize = 64   ## SHA-256 block size in bytes (also the HMAC block size).

proc rotr(x: uint32, n: int): uint32 {.inline.} =
  (x shr n) or (x shl (32 - n))

proc sha256Bytes*(msg: openArray[byte]): array[32, byte] =
  ## Raw SHA-256 digest of ``msg`` (32 bytes).
  var h: array[8, uint32] = [
    0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]

  # Padding: append 0x80, then zeros, then the 64-bit big-endian bit length.
  let ml = msg.len
  var data = newSeq[byte](ml)
  for i in 0 ..< ml: data[i] = msg[i]
  data.add(0x80'u8)
  while data.len mod BlockSize != 56:
    data.add(0x00'u8)
  let bitLen = uint64(ml) * 8'u64
  for i in countdown(7, 0):
    data.add(byte((bitLen shr (i * 8)) and 0xff'u64))

  var w: array[64, uint32]
  var blk = 0
  while blk < data.len:
    for t in 0 ..< 16:
      let o = blk + t * 4
      w[t] = (uint32(data[o]) shl 24) or (uint32(data[o + 1]) shl 16) or
             (uint32(data[o + 2]) shl 8) or uint32(data[o + 3])
    for t in 16 ..< 64:
      let s0 = rotr(w[t - 15], 7) xor rotr(w[t - 15], 18) xor (w[t - 15] shr 3)
      let s1 = rotr(w[t - 2], 17) xor rotr(w[t - 2], 19) xor (w[t - 2] shr 10)
      w[t] = w[t - 16] + s0 + w[t - 7] + s1

    var a = h[0]; var b = h[1]; var c = h[2]; var d = h[3]
    var e = h[4]; var f = h[5]; var g = h[6]; var hh = h[7]
    for t in 0 ..< 64:
      let s1 = rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)
      let ch = (e and f) xor ((not e) and g)
      let t1 = hh + s1 + ch + K[t] + w[t]
      let s0 = rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)
      let maj = (a and b) xor (a and c) xor (b and c)
      let t2 = s0 + maj
      hh = g; g = f; f = e; e = d + t1
      d = c; c = b; b = a; a = t1 + t2
    h[0] += a; h[1] += b; h[2] += c; h[3] += d
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh
    blk += BlockSize

  for i in 0 ..< 8:
    result[i * 4] = byte((h[i] shr 24) and 0xff)
    result[i * 4 + 1] = byte((h[i] shr 16) and 0xff)
    result[i * 4 + 2] = byte((h[i] shr 8) and 0xff)
    result[i * 4 + 3] = byte(h[i] and 0xff)

proc toHex*(b: openArray[byte]): string =
  ## Lower-case hex encoding.
  const digits = "0123456789abcdef"
  result = newStringOfCap(b.len * 2)
  for x in b:
    result.add(digits[int(x shr 4)])
    result.add(digits[int(x and 0x0f)])

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len: result[i] = byte(s[i])

proc sha256Hex*(s: string): string =
  ## SHA-256 of a string, lower-case hex.
  toHex(sha256Bytes(toBytes(s)))

proc hmacSha256Bytes*(key, msg: openArray[byte]): array[32, byte] =
  ## HMAC-SHA256 (RFC 2104) of ``msg`` under ``key``.
  var k = newSeq[byte](BlockSize)
  if key.len > BlockSize:
    let kh = sha256Bytes(key)
    for i in 0 ..< 32: k[i] = kh[i]
  else:
    for i in 0 ..< key.len: k[i] = key[i]
  var iPad = newSeq[byte](BlockSize)
  var oPad = newSeq[byte](BlockSize)
  for i in 0 ..< BlockSize:
    iPad[i] = k[i] xor 0x36'u8
    oPad[i] = k[i] xor 0x5c'u8
  var inner = iPad
  for x in msg: inner.add(x)
  let innerHash = sha256Bytes(inner)
  var outer = oPad
  for x in innerHash: outer.add(x)
  sha256Bytes(outer)

proc hmacSha256Hex*(key, msg: string): string =
  ## HMAC-SHA256 of string ``msg`` under string ``key``, lower-case hex.
  toHex(hmacSha256Bytes(toBytes(key), toBytes(msg)))

proc constantTimeHexEq*(a, b: string): bool =
  ## Data-independent comparison of two equal-purpose hex strings (signature
  ## verification). Mirrors ``protocol.constantTimeEq`` but kept local so the
  ## crypto module has no dependency on the wire-protocol module.
  var diff = a.len xor b.len
  for i in 0 ..< a.len:
    let bc = if b.len > 0: b[i mod b.len] else: '\0'
    diff = diff or (int(a[i]) xor int(bc))
  diff == 0
