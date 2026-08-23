# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Bounded ZIP/ZIP64 reader and deterministic ZIP writer.

import std/[algorithm, options, os, sets, strutils, tempfiles, unicode]
import contracts
import UniChecksum
import UniCompress

const
  SigLocal = 0x0403_4B50'u32
  SigCentral = 0x0201_4B50'u32
  SigEocd = 0x0605_4B50'u32
  SigZip64Eocd = 0x0606_4B50'u32
  SigZip64Locator = 0x0706_4B50'u32
  SigDescriptor = 0x0807_4B50'u32
  MaxEocdSearch = 65_557

type
  ArchiveErrorKind* = enum
    ## Stable error categories emitted for archive operations.
    aeIo, aeInvalidPolicy, aeInvalidFormat, aeUnsupported, aeCorruptData,
    aeResourceLimit, aeUnsafeArchive, aeMissingEntry, aeDuplicateEntry

  ArchiveException* = ref object of CatchableError
    ## Error raised for invalid, unsupported, unsafe, or unavailable archives.
    kind*: ArchiveErrorKind

  ArchiveLimits* = object
    ## Runtime-enforced ceilings for parsing and decompression.
    maxArchiveBytes*: uint64
    maxEntries*: uint64
    maxEntryOutput*: uint64
    maxTotalOutput*: uint64
    maxTotalCompressedBytes*: uint64
    maxMetadataBytes*: uint64
    maxPathBytes*: uint64
    maxPathDepth*: uint32
    maxCompressionRatio*: uint64
    maxEntryDecodeWork*: uint64

  ZipMethod* = enum
    ## ZIP compression methods emitted by the writer.
    zmStore = 0
    zmDeflate = 8

  ArchiveEntryKind* = enum
    ## Filesystem interpretation of one ZIP entry.
    aekFile, aekDirectory, aekSymlink, aekSpecial

  ArchiveEntry* = object
    ## Immutable central-directory metadata for one ZIP entry.
    name*: string
    compressionMethod*: uint16
    crc32*: uint32
    compressedSize*: uint64
    uncompressedSize*: uint64
    localOffset*: uint64
    modifiedUnixSeconds*: Option[uint32]
    unixMode*: Option[uint16]
    comment*: string
    rawName: string
    rawComment: string
    flags: uint16
    hostSystem: uint8
    externalAttributes: uint32
    zip64Sizes: bool
    dataStart, dataStop: uint64

  ZipSpanKind* = enum
    ## Physical ZIP record kinds checked for overlap.
    zskLocalEntry, zskCentralDirectory, zskZip64End, zskZip64Locator,
    zskEndOfCentralDirectory

  ZipSpan* = object
    ## Half-open physical interval occupied by a ZIP record.
    first*, pastLast*: uint64
    kind*: ZipSpanKind

  ArchiveReader* = object
    ## Validated in-memory snapshot. Construct with `openArchive`.
    data: seq[byte]
    indexedEntries: seq[ArchiveEntry]
    physicalSpans: seq[ZipSpan]
    limits: ArchiveLimits
    archiveComment, rawArchiveComment: string

  ArchiveInput* = object
    ## One input entry accepted by the deterministic ZIP writer.
    name*: string
    data*: seq[byte]
    compressionMethod*: ZipMethod
    modifiedUnixSeconds*: Option[uint32]
    unixMode*: Option[uint16]
    comment*: string

  ArchiveInputProvider* = proc(index: int): ArchiveInput {.closure.}
    ## Lazily provide one entry to a sequential ZIP writer.

func coherent(limits: ArchiveLimits): bool =
  limits.maxArchiveBytes > 0 and limits.maxEntries > 0 and
    limits.maxEntryOutput > 0 and
    limits.maxTotalOutput >= limits.maxEntryOutput and
    limits.maxTotalOutput <= uint64(high(int64)) and
    limits.maxTotalCompressedBytes > 0 and limits.maxMetadataBytes > 0 and
    limits.maxPathBytes > 0 and limits.maxPathBytes <= uint64(high(uint16)) and
    limits.maxPathDepth > 0 and
    limits.maxCompressionRatio > 0 and limits.maxEntryDecodeWork > 0 and
    limits.maxEntryDecodeWork <= uint64(high(int64))

func defaultArchiveLimits*(): ArchiveLimits {.contractual.} =
  ## Return the conservative policy used unless callers override it.
  ensure:
    coherent(result)
  body:
    ArchiveLimits(maxArchiveBytes: 1'u64 shl 30, maxEntries: 10_000,
      maxEntryOutput: 256'u64 shl 20, maxTotalOutput: 1'u64 shl 30,
      maxTotalCompressedBytes: 1'u64 shl 30,
      maxMetadataBytes: 64'u64 shl 20, maxPathBytes: 4'u64 shl 10,
      maxPathDepth: 64,
      maxCompressionRatio: 200, maxEntryDecodeWork: 3_000_000_000'u64)

proc fail(kind: ArchiveErrorKind; message: string) {.noreturn.} =
  raise ArchiveException(kind: kind, msg: message)

const WindowsReserved* = ["CON", "PRN", "AUX", "NUL", "COM1", "COM2",
  "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1",
  "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"]

type
  ArchiveNameIssue* = enum
    ## Why a portable archive name is not acceptable. Shared so the writer
    ## refuses to produce a name the reader would refuse to open.
    aniOk, aniOverlong, aniNotUtf8, aniPlatformSpecific, aniDepth,
    aniComponent, aniAmbiguousSuffix, aniControlByte, aniReservedStem

func reason*(issue: ArchiveNameIssue): string =
  case issue
  of aniOk: ""
  of aniOverlong: "empty or overlong archive path"
  of aniNotUtf8: "archive path is not valid UTF-8"
  of aniPlatformSpecific: "absolute or platform-specific archive path"
  of aniDepth: "archive path depth exceeds policy"
  of aniComponent: "unsafe archive path component"
  of aniAmbiguousSuffix: "archive path has a platform-ambiguous suffix"
  of aniControlByte: "archive path contains a control byte"
  of aniReservedStem: "archive path uses a reserved Windows name"

func inspectArchiveName*(name: string; maxBytes: uint64; maxDepth: uint32;
    components: var seq[string]): ArchiveNameIssue =
  ## Portable-name policy, applied identically on the way in and on the way
  ## out. A trailing empty component (a directory's "/") is not counted.
  if name.len == 0 or uint64(name.len) > maxBytes: return aniOverlong
  if validateUtf8(name) != -1: return aniNotUtf8
  if name[0] in {'/', '\\'} or '\\' in name or ':' in name or '\0' in name:
    return aniPlatformSpecific
  components = name.split('/')
  if components.len > 0 and components[^1].len == 0:
    components.setLen(components.len - 1)
  if components.len == 0 or uint32(components.len) > maxDepth: return aniDepth
  for component in components:
    if component.len == 0 or component == "." or component == "..":
      return aniComponent
    if component[^1] in {'.', ' '}: return aniAmbiguousSuffix
    for ch in component:
      if ord(ch) < 32 or ord(ch) == 127: return aniControlByte
    if component.split('.')[0].toUpperAscii() in WindowsReserved:
      return aniReservedStem
  aniOk

func checkedAdd(a, b: uint64; what: string): uint64 =
  if b > high(uint64) - a: fail(aeResourceLimit, what & " overflows uint64")
  a + b

func checkedStop(dataLen: int; offset, length: uint64; what: string): int =
  if offset > uint64(dataLen) or length > uint64(dataLen) - offset:
    fail(aeCorruptData, what & " exceeds archive bounds")
  if offset + length > uint64(high(int)):
    fail(aeResourceLimit, what & " exceeds platform index range")
  int(offset + length)

func ratioExceeded(output, input, ratio: uint64): bool =
  if output == 0: return false
  if input == 0: return true
  if input > high(uint64) div ratio: return false
  output > input * ratio

func u16(data: openArray[byte]; at: int): uint16 =
  if at < 0 or at > data.len - 2: fail(aeCorruptData, "truncated uint16")
  uint16(data[at]) or (uint16(data[at + 1]) shl 8)

func u32(data: openArray[byte]; at: int): uint32 =
  if at < 0 or at > data.len - 4: fail(aeCorruptData, "truncated uint32")
  uint32(data[at]) or (uint32(data[at + 1]) shl 8) or
    (uint32(data[at + 2]) shl 16) or (uint32(data[at + 3]) shl 24)

func u64(data: openArray[byte]; at: int): uint64 =
  if at < 0 or at > data.len - 8: fail(aeCorruptData, "truncated uint64")
  uint64(u32(data, at)) or (uint64(u32(data, at + 4)) shl 32)

const Cp437High = [
  0x00C7'u16, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7,
  0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
  0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9,
  0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
  0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA,
  0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
  0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
  0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
  0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F,
  0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
  0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B,
  0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
  0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4,
  0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
  0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248,
  0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0]

func decodeCp437(raw: string): string =
  for value in raw:
    let octet = uint8(value)
    if octet < 0x80: result.add char(octet)
    else: result.add Rune(Cp437High[int(octet) - 0x80])

proc add16(dst: var seq[byte]; value: uint16) =
  dst.add byte(value and 0xFF)
  dst.add byte(value shr 8)

proc add32(dst: var seq[byte]; value: uint32) =
  dst.add16 uint16(value and 0xFFFF)
  dst.add16 uint16(value shr 16)

proc add64(dst: var seq[byte]; value: uint64) =
  dst.add32 uint32(value and 0xFFFF_FFFF'u64)
  dst.add32 uint32(value shr 32)

proc addString(dst: var seq[byte]; value: string) =
  for ch in value: dst.add byte(ch)

type FileZipSink = object
  file: File
  buffer: seq[byte]
  position: uint64
  maximum: uint64

func len(sink: FileZipSink): uint64 = sink.position

proc flush(sink: var FileZipSink) =
  if sink.buffer.len > 0:
    if sink.file.writeBuffer(addr sink.buffer[0], sink.buffer.len) !=
        sink.buffer.len:
      fail(aeIo, "short ZIP output write")
    sink.buffer.setLen(0)

proc add(sink: var FileZipSink; value: byte) =
  if sink.position >= sink.maximum:
    fail(aeResourceLimit, "ZIP output exceeds creation limit")
  sink.buffer.add value
  inc sink.position
  if sink.buffer.len == 64 * 1024: sink.flush()

proc add(sink: var FileZipSink; data: openArray[byte]) =
  if data.len == 0: return
  if uint64(data.len) > sink.maximum - sink.position:
    fail(aeResourceLimit, "ZIP output exceeds creation limit")
  if data.len >= 64 * 1024:
    sink.flush()
    if sink.file.writeBuffer(unsafeAddr data[0], data.len) != data.len:
      fail(aeIo, "short ZIP output write")
  else:
    sink.buffer.add data
    if sink.buffer.len >= 64 * 1024: sink.flush()
  sink.position = checkedAdd(sink.position, uint64(data.len), "ZIP output size")

proc add16(dst: var FileZipSink; value: uint16) =
  dst.add byte(value and 0xFF)
  dst.add byte(value shr 8)

proc add32(dst: var FileZipSink; value: uint32) =
  dst.add16 uint16(value and 0xFFFF)
  dst.add16 uint16(value shr 16)

proc add64(dst: var FileZipSink; value: uint64) =
  dst.add32 uint32(value and 0xFFFF_FFFF'u64)
  dst.add32 uint32(value shr 32)

proc addString(dst: var FileZipSink; value: string) =
  if value.len > 0:
    dst.add value.toOpenArrayByte(0, value.high)

func findEocd(data: openArray[byte]): int =
  if data.len < 22: fail(aeInvalidFormat, "ZIP end record is missing")
  let first = max(0, data.len - MaxEocdSearch)
  for at in countdown(data.len - 22, first):
    if u32(data, at) == SigEocd and
        at + 22 + int(u16(data, at + 20)) == data.len:
      return at
  fail(aeInvalidFormat, "ZIP end record is missing or malformed")

proc applyZip64Extra(data: openArray[byte]; start, length: int;
    unpacked, packed, offset: var uint64; needDisk: bool) =
  var pos = start
  let stop = checkedStop(data.len, uint64(start), uint64(length), "extra field")
  var found = false
  while pos < stop:
    if pos + 4 > stop: fail(aeCorruptData, "truncated ZIP extra field")
    let kind = u16(data, pos)
    let size = int(u16(data, pos + 2))
    pos += 4
    if pos + size > stop: fail(aeCorruptData, "ZIP extra field overruns record")
    if kind == 1:
      if found: fail(aeCorruptData, "duplicate ZIP64 extra field")
      found = true
      var cursor = pos
      if unpacked == uint64(high(uint32)):
        if cursor + 8 > pos + size: fail(aeCorruptData, "missing ZIP64 unpacked size")
        unpacked = u64(data, cursor); cursor += 8
      if packed == uint64(high(uint32)):
        if cursor + 8 > pos + size: fail(aeCorruptData, "missing ZIP64 packed size")
        packed = u64(data, cursor); cursor += 8
      if offset == uint64(high(uint32)):
        if cursor + 8 > pos + size: fail(aeCorruptData, "missing ZIP64 local offset")
        offset = u64(data, cursor); cursor += 8
      if needDisk:
        if cursor + 4 > pos + size: fail(aeCorruptData, "missing ZIP64 disk number")
        if u32(data, cursor) != 0: fail(aeUnsupported, "multi-disk ZIP64 entry")
        cursor += 4
      if cursor != pos + size:
        fail(aeCorruptData, "unexpected ZIP64 extra field size")
    pos += size

proc extendedTimestamp(data: openArray[byte]; start, length: int): Option[uint32] =
  var pos = start
  let stop = checkedStop(data.len, uint64(start), uint64(length), "extra field")
  var found = false
  while pos < stop:
    if pos + 4 > stop: fail(aeCorruptData, "truncated ZIP extra field")
    let kind = u16(data, pos)
    let size = int(u16(data, pos + 2))
    pos += 4
    if pos + size > stop: fail(aeCorruptData, "ZIP extra field overruns record")
    if kind == 0x5455:
      if found: fail(aeCorruptData, "duplicate extended timestamp field")
      found = true
      if size < 1: fail(aeCorruptData, "empty extended timestamp field")
      if (data[pos] and 1) != 0:
        if size < 5: fail(aeCorruptData, "truncated extended modification time")
        result = some(u32(data, pos + 1))
    pos += size

proc descriptorStop(data: openArray[byte]; start: int;
    entry: ArchiveEntry): int =
  template match32(at: int): bool =
    u32(data, at) == entry.crc32 and
      uint64(u32(data, at + 4)) == entry.compressedSize and
      uint64(u32(data, at + 8)) == entry.uncompressedSize
  template match64(at: int): bool =
    u32(data, at) == entry.crc32 and u64(data, at + 4) ==
        entry.compressedSize and
      u64(data, at + 12) == entry.uncompressedSize
  if entry.zip64Sizes:
    if start + 24 <= data.len and u32(data, start) == SigDescriptor and
        match64(start + 4): return start + 24
    if start + 20 <= data.len and match64(start): return start + 20
  else:
    if start + 16 <= data.len and u32(data, start) == SigDescriptor and
        match32(start + 4): return start + 16
    if start + 12 <= data.len and match32(start): return start + 12
  fail(aeCorruptData, "missing or inconsistent ZIP data descriptor")

proc validateSpans(spans: var seq[ZipSpan]) =
  spans.sort(proc(a, b: ZipSpan): int =
    result = cmp(a.first, b.first)
    if result == 0: result = cmp(a.pastLast, b.pastLast))
  for i in 1 ..< spans.len:
    if spans[i - 1].pastLast > spans[i].first:
      fail(aeUnsafeArchive, "overlapping ZIP records")

proc validateFlags(flags, compressionMethod: uint16) =
  var allowed = 0x0808'u16 # UTF-8 and data descriptor.
  if compressionMethod == uint16(zmDeflate):
    allowed = allowed or 0x0006'u16 # Deflate compression options.
  if (flags and not allowed) != 0:
    fail(aeUnsupported, "unsupported ZIP general-purpose flags")

proc loadSnapshot(path: string; maximum: uint64): seq[byte] =
  var file: File
  if not open(file, path, fmRead): fail(aeIo, "archive could not be opened")
  defer: file.close()
  let size = getFileSize(file)
  if size < 0 or uint64(size) > maximum or uint64(size) > uint64(high(int)):
    fail(aeResourceLimit, "archive exceeds input limit")
  result = newSeq[byte](int(size))
  if result.len > 0 and file.readBuffer(addr result[0], result.len) != result.len:
    fail(aeIo, "archive changed or was truncated while reading")
  var extra: byte
  if file.readBuffer(addr extra, 1) != 0:
    fail(aeResourceLimit, "archive grew beyond the validated snapshot")

proc indexLocalRecord(reader: var ArchiveReader; entryIndex: int): ZipSpan =
  var entry = reader.indexedEntries[entryIndex]
  discard checkedStop(reader.data.len, entry.localOffset, 30, "local header")
  let local = int(entry.localOffset)
  if u32(reader.data, local) != SigLocal:
    fail(aeCorruptData, "invalid local header: " & entry.name)
  let localFlags = u16(reader.data, local + 6)
  if localFlags != entry.flags: fail(aeCorruptData, "local flags mismatch: " & entry.name)
  validateFlags(localFlags, entry.compressionMethod)
  if u16(reader.data, local + 8) != entry.compressionMethod:
    fail(aeCorruptData, "local compression method mismatch: " & entry.name)
  let nameLen = int(u16(reader.data, local + 26))
  let extraLen = int(u16(reader.data, local + 28))
  discard checkedStop(reader.data.len, uint64(local + 30),
    uint64(nameLen + extraLen), "local name and extra fields")
  if nameLen != entry.rawName.len:
    fail(aeCorruptData, "local entry name length mismatch: " & entry.name)
  for i in 0 ..< nameLen:
    if reader.data[local + 30 + i] != byte(entry.rawName[i]):
      fail(aeCorruptData, "local entry name mismatch: " & entry.name)
  var localPacked = uint64(u32(reader.data, local + 18))
  var localUnpacked = uint64(u32(reader.data, local + 22))
  entry.zip64Sizes = entry.zip64Sizes or
    localPacked == uint64(high(uint32)) or
    localUnpacked == uint64(high(uint32))
  var unusedOffset = 0'u64
  applyZip64Extra(reader.data, local + 30 + nameLen, extraLen,
    localUnpacked, localPacked, unusedOffset, false)
  let localModified = extendedTimestamp(reader.data, local + 30 + nameLen,
    extraLen)
  if localModified.isSome and entry.modifiedUnixSeconds.isSome and
      localModified.get != entry.modifiedUnixSeconds.get:
    fail(aeCorruptData, "local modification time mismatch: " & entry.name)
  if (localFlags and 8) == 0 and
      (u32(reader.data, local + 14) != entry.crc32 or
      localPacked != entry.compressedSize or
      localUnpacked != entry.uncompressedSize):
    fail(aeCorruptData, "local sizes or CRC mismatch: " & entry.name)
  let dataStart = local + 30 + nameLen + extraLen
  let dataStop = checkedStop(reader.data.len, uint64(dataStart),
    entry.compressedSize, "entry data")
  let recordStop = if (localFlags and 8) != 0:
      descriptorStop(reader.data, dataStop, entry)
    else: dataStop
  entry.dataStart = uint64(dataStart)
  entry.dataStop = uint64(dataStop)
  reader.indexedEntries[entryIndex] = entry
  ZipSpan(first: entry.localOffset, pastLast: uint64(recordStop),
    kind: zskLocalEntry)

proc openArchive*(path: string;
    limits = defaultArchiveLimits()): ArchiveReader {.contractual.} =
  ## Open one immutable ZIP snapshot after structural and resource validation.
  require:
    path.len > 0
    coherent(limits)
  ensure:
    uint64(result.indexedEntries.len) <= limits.maxEntries
  body:
    if path.len == 0: fail(aeInvalidPolicy, "archive path is empty")
    if not coherent(limits): fail(aeInvalidPolicy, "incoherent archive limits")
    result.data = loadSnapshot(path, limits.maxArchiveBytes)
    result.limits = limits
    let eocd = findEocd(result.data)
    let archiveCommentLength = int(u16(result.data, eocd + 20))
    result.rawArchiveComment = newString(archiveCommentLength)
    for index in 0 ..< archiveCommentLength:
      result.rawArchiveComment[index] = char(result.data[eocd + 22 + index])
    result.archiveComment = decodeCp437(result.rawArchiveComment)
    if u16(result.data, eocd + 4) != 0 or u16(result.data, eocd + 6) != 0:
      fail(aeUnsupported, "multi-disk ZIP is unsupported")
    var count = uint64(u16(result.data, eocd + 10))
    var centralSize = uint64(u32(result.data, eocd + 12))
    var centralOffset = uint64(u32(result.data, eocd + 16))
    var zip64Offset, zip64Stop: uint64
    var hasZip64 = false
    if count == uint64(high(uint16)) or centralSize == uint64(high(uint32)) or
        centralOffset == uint64(high(uint32)):
      hasZip64 = true
      if eocd < 20 or u32(result.data, eocd - 20) != SigZip64Locator:
        fail(aeCorruptData, "ZIP64 locator is missing")
      if u32(result.data, eocd - 16) != 0 or u32(result.data, eocd - 4) != 1:
        fail(aeUnsupported, "multi-disk ZIP64 is unsupported")
      zip64Offset = u64(result.data, eocd - 12)
      discard checkedStop(result.data.len, zip64Offset, 56, "ZIP64 end record")
      let zip64 = int(zip64Offset)
      if u32(result.data, zip64) != SigZip64Eocd:
        fail(aeCorruptData, "ZIP64 end record is missing")
      let recordSize = u64(result.data, zip64 + 4)
      if recordSize < 44: fail(aeCorruptData, "short ZIP64 end record")
      zip64Stop = checkedAdd(zip64Offset,
        checkedAdd(12, recordSize, "ZIP64 end size"), "ZIP64 end offset")
      discard checkedStop(result.data.len, zip64Offset,
        zip64Stop - zip64Offset, "ZIP64 end record")
      if u32(result.data, zip64 + 16) != 0 or u32(result.data, zip64 + 20) != 0:
        fail(aeUnsupported, "multi-disk ZIP64 is unsupported")
      if u64(result.data, zip64 + 24) != u64(result.data, zip64 + 32):
        fail(aeUnsupported, "multi-disk ZIP64 entry count")
      count = u64(result.data, zip64 + 32)
      centralSize = u64(result.data, zip64 + 40)
      centralOffset = u64(result.data, zip64 + 48)
    if count > limits.maxEntries: fail(aeResourceLimit, "too many ZIP entries")
    let centralStop = checkedStop(result.data.len, centralOffset, centralSize,
      "central directory")
    var spans = @[ZipSpan(first: centralOffset,
      pastLast: uint64(centralStop), kind: zskCentralDirectory),
      ZipSpan(first: uint64(eocd), pastLast: uint64(result.data.len),
        kind: zskEndOfCentralDirectory)]
    if hasZip64:
      spans.add ZipSpan(first: zip64Offset, pastLast: zip64Stop,
        kind: zskZip64End)
      spans.add ZipSpan(first: uint64(eocd - 20), pastLast: uint64(eocd),
        kind: zskZip64Locator)
    var pos = int(centralOffset)
    var declaredOutput, declaredCompressed, metadataBytes: uint64
    var names = initHashSet[string]()
    for _ in 0'u64 ..< count:
      if pos + 46 > centralStop or u32(result.data, pos) != SigCentral:
        fail(aeCorruptData, "invalid central directory record")
      let flags = u16(result.data, pos + 8)
      let compressionMethod = u16(result.data, pos + 10)
      validateFlags(flags, compressionMethod)
      let nameLen = int(u16(result.data, pos + 28))
      let extraLen = int(u16(result.data, pos + 30))
      let commentLen = int(u16(result.data, pos + 32))
      if uint64(nameLen) > limits.maxPathBytes:
        fail(aeResourceLimit, "ZIP entry name exceeds path limit")
      let recordLength = uint64(46 + nameLen + extraLen + commentLen)
      let recordStop = checkedStop(result.data.len, uint64(pos), recordLength,
        "central record")
      if recordStop > centralStop:
        fail(aeCorruptData, "central record exceeds central directory")
      metadataBytes = checkedAdd(metadataBytes,
        uint64(nameLen + extraLen + commentLen), "metadata size")
      if metadataBytes > limits.maxMetadataBytes:
        fail(aeResourceLimit, "ZIP metadata exceeds limit")
      var packed = uint64(u32(result.data, pos + 20))
      var unpacked = uint64(u32(result.data, pos + 24))
      let zip64Sizes = packed == uint64(high(uint32)) or
        unpacked == uint64(high(uint32))
      var localOffset = uint64(u32(result.data, pos + 42))
      let disk = u16(result.data, pos + 34)
      if disk != 0 and disk != high(uint16): fail(aeUnsupported, "multi-disk ZIP entry")
      applyZip64Extra(result.data, pos + 46 + nameLen, extraLen,
        unpacked, packed, localOffset, disk == high(uint16))
      if unpacked > limits.maxEntryOutput:
        fail(aeResourceLimit, "entry exceeds declared output limit")
      if unpacked > limits.maxTotalOutput - declaredOutput:
        fail(aeResourceLimit, "archive exceeds declared total output limit")
      if packed > limits.maxTotalCompressedBytes - declaredCompressed:
        fail(aeResourceLimit, "archive exceeds compressed-data limit")
      if ratioExceeded(unpacked, packed, limits.maxCompressionRatio):
        fail(aeResourceLimit, "entry exceeds compression-ratio limit")
      if compressionMethod == uint16(zmStore) and packed != unpacked:
        fail(aeCorruptData, "stored entry has inconsistent sizes")
      declaredOutput += unpacked
      declaredCompressed += packed
      var rawName = newString(nameLen)
      for i in 0 ..< nameLen: rawName[i] = char(result.data[pos + 46 + i])
      if '\0' in rawName: fail(aeUnsafeArchive, "NUL in ZIP entry name")
      if (flags and 0x0800'u16) != 0 and validateUtf8(rawName) != -1:
        fail(aeCorruptData, "invalid UTF-8 ZIP entry name")
      let name = if (flags and 0x0800'u16) != 0: rawName
        else: decodeCp437(rawName)
      let commentStart = pos + 46 + nameLen + extraLen
      var rawComment = newString(commentLen)
      for index in 0 ..< commentLen:
        rawComment[index] = char(result.data[commentStart + index])
      if (flags and 0x0800'u16) != 0 and validateUtf8(rawComment) != -1:
        fail(aeCorruptData, "invalid UTF-8 ZIP entry comment")
      let comment = if (flags and 0x0800'u16) != 0: rawComment
        else: decodeCp437(rawComment)
      if name in names: fail(aeDuplicateEntry, "duplicate ZIP entry: " & name)
      names.incl name
      result.indexedEntries.add ArchiveEntry(name: name,
        compressionMethod: compressionMethod, crc32: u32(result.data, pos + 16),
        compressedSize: packed, uncompressedSize: unpacked,
        localOffset: localOffset, flags: flags,
        modifiedUnixSeconds: extendedTimestamp(result.data,
          pos + 46 + nameLen, extraLen),
        unixMode: (if uint8(u16(result.data, pos + 4) shr 8) == 3:
        some(uint16(u32(result.data, pos + 38) shr 16)) else: none(uint16)),
        rawName: rawName,
        comment: comment, rawComment: rawComment,
        hostSystem: uint8(u16(result.data, pos + 4) shr 8),
        externalAttributes: u32(result.data, pos + 38),
        zip64Sizes: zip64Sizes)
      pos = recordStop
    if pos != centralStop: fail(aeCorruptData, "central directory size mismatch")
    if ratioExceeded(declaredOutput, declaredCompressed,
        limits.maxCompressionRatio):
      fail(aeResourceLimit, "archive exceeds total compression-ratio limit")
    for i in 0 ..< result.indexedEntries.len:
      spans.add result.indexLocalRecord(i)
    validateSpans(spans)
    result.physicalSpans = spans

func entries*(reader: ArchiveReader): seq[ArchiveEntry] =
  ## Return an immutable copy of the validated central-directory index.
  reader.indexedEntries

func rawNameBytes*(entry: ArchiveEntry): seq[byte] =
  ## Return the exact filename bytes stored in the central directory.
  result = newSeq[byte](entry.rawName.len)
  for index, value in entry.rawName: result[index] = byte(value)

func rawCommentBytes*(entry: ArchiveEntry): seq[byte] =
  ## Return the exact entry-comment bytes stored in the central directory.
  result = newSeq[byte](entry.rawComment.len)
  for index, value in entry.rawComment: result[index] = byte(value)

func comment*(reader: ArchiveReader): string =
  ## Return the archive comment decoded as CP437.
  reader.archiveComment

func rawCommentBytes*(reader: ArchiveReader): seq[byte] =
  ## Return the exact archive-comment bytes stored in the end record.
  result = newSeq[byte](reader.rawArchiveComment.len)
  for index, value in reader.rawArchiveComment: result[index] = byte(value)

func kind*(entry: ArchiveEntry): ArchiveEntryKind =
  ## Classify an entry without following or materialising archive links.
  if entry.hostSystem == 3:
    let unixType = (entry.externalAttributes shr 16) and 0xF000'u32
    case unixType
    of 0xA000'u32: return aekSymlink
    of 0x4000'u32: return aekDirectory
    of 0'u32, 0x8000'u32: discard
    else: return aekSpecial
  if entry.name.len > 0 and entry.name[^1] == '/': aekDirectory
  else: aekFile

func spans*(reader: ArchiveReader): seq[ZipSpan] =
  ## Return the sorted, non-overlapping physical record map.
  reader.physicalSpans

func policy*(reader: ArchiveReader): ArchiveLimits =
  ## Return the immutable resource policy attached to this snapshot.
  reader.limits

func entryNames*(reader: ArchiveReader): seq[string] =
  ## Return entry names in central-directory order.
  for entry in reader.indexedEntries: result.add entry.name

func findEntry*(reader: ArchiveReader; name: string): Option[ArchiveEntry] =
  ## Find one entry by its exact byte-preserving name.
  for entry in reader.indexedEntries:
    if entry.name == name: return some(entry)

func contains*(reader: ArchiveReader; name: string): bool =
  ## Return whether the validated archive contains `name`.
  reader.findEntry(name).isSome

func trustedEntry(reader: ArchiveReader;
    candidate: ArchiveEntry): ArchiveEntry =
  for entry in reader.indexedEntries:
    let sameIdentity = entry.name == candidate.name and
      entry.localOffset == candidate.localOffset and
      entry.compressedSize == candidate.compressedSize and
      entry.uncompressedSize == candidate.uncompressedSize and
      entry.crc32 == candidate.crc32
    if sameIdentity:
      return entry
  fail(aeCorruptData, "entry does not belong to this archive snapshot")

proc readEntry*(reader: ArchiveReader; candidate: ArchiveEntry): seq[byte] =
  ## Decode and verify one indexed entry under the reader's policy.
  let entry = reader.trustedEntry(candidate)
  let start = int(entry.dataStart)
  let stop = int(entry.dataStop)
  case entry.compressionMethod
  of uint16(zmStore):
    result = newSeq[byte](int(entry.uncompressedSize))
    for i in 0 ..< result.len: result[i] = reader.data[start + i]
  of uint16(zmDeflate):
    if start == stop: fail(aeCorruptData, "empty Deflate payload: " & entry.name)
    try:
      let decoded = inflateWithConsumed(reader.data.toOpenArray(start, stop - 1),
        maxOutput = max(1'i64, int64(entry.uncompressedSize)),
        maxWork = int64(reader.limits.maxEntryDecodeWork))
      if decoded.next != stop - start:
        fail(aeCorruptData, "unconsumed Deflate payload bytes: " & entry.name)
      result = decoded.data
    except UniCompressException as error:
      let kind = if error.code == ucResourceLimit: aeResourceLimit
        elif error.code == ucUnsupported: aeUnsupported
        else: aeCorruptData
      fail(kind, error.msg)
  else:
    fail(aeUnsupported, "unsupported ZIP compression method: " &
      $entry.compressionMethod)
  if uint64(result.len) != entry.uncompressedSize:
    fail(aeCorruptData, "uncompressed size mismatch: " & entry.name)
  if crc32(result) != entry.crc32:
    fail(aeCorruptData, "CRC-32 mismatch: " & entry.name)

proc readEntry*(reader: ArchiveReader; name: string): seq[byte] =
  ## Read and verify one uniquely named entry.
  let entry = reader.findEntry(name)
  if entry.isNone: fail(aeMissingEntry, "entry not found: " & name)
  reader.readEntry(entry.get)

proc readTextEntry*(reader: ArchiveReader; name: string): string =
  ## Read verified entry bytes into a binary-safe Nim string.
  let data = reader.readEntry(name)
  result = newString(data.len)
  for i, value in data: result[i] = char(value)

proc archiveInput*(name, data: string;
    compressionMethod = zmDeflate): ArchiveInput {.contractual.} =
  ## Construct one textual or binary-string entry for the writer.
  require:
    name.len > 0
    name.len <= int(high(uint16))
    '\0' notin name
  ensure:
    result.name == name
    result.data.len == data.len
    result.compressionMethod == compressionMethod
  body:
    result.name = name
    result.compressionMethod = compressionMethod
    result.data = newSeq[byte](data.len)
    for i, value in data: result.data[i] = byte(value)

proc emitZip[Sink](result: var Sink; count: int;
    provider: ArchiveInputProvider; forceZip64: bool; archiveComment: string) =
  type Central = object
    name: string
    compressionMethod: ZipMethod
    modifiedUnixSeconds: Option[uint32]
    unixMode: Option[uint16]
    comment: string
    crc: uint32
    packedSize, unpackedSize: uint64
    offset: uint64
    zip64Sizes: bool
  var central: seq[Central]
  var names = initHashSet[string]()
  if count < 0 or provider == nil:
    fail(aeInvalidPolicy, "invalid ZIP input provider")
  if archiveComment.len > int(high(uint16)):
    fail(aeInvalidFormat, "ZIP archive comment is too long")
  for value in archiveComment:
    if ord(value) > 0x7F:
      fail(aeInvalidFormat, "ZIP archive comment must be ASCII")
  for index in 0 ..< count:
    let input = provider(index)
    if input.name.len == 0 or input.name.len > int(high(uint16)):
      fail(aeInvalidFormat, "invalid ZIP entry name length")
    if '\0' in input.name: fail(aeInvalidFormat, "NUL in ZIP entry name")
    if validateUtf8(input.name) != -1:
      fail(aeInvalidFormat, "ZIP writer entry name is not valid UTF-8")
    if input.comment.len > int(high(uint16)) or validateUtf8(input.comment) != -1:
      fail(aeInvalidFormat, "invalid UTF-8 ZIP entry comment")
    if input.name in names: fail(aeDuplicateEntry, "duplicate ZIP entry")
    names.incl input.name
    let packed = case input.compressionMethod
      of zmStore: input.data
      of zmDeflate: compress(input.data)
    let zip64Sizes = forceZip64 or uint64(input.data.len) > uint64(high(
        uint32)) or
      uint64(packed.len) > uint64(high(uint32))
    let item = Central(name: input.name,
      compressionMethod: input.compressionMethod,
      modifiedUnixSeconds: input.modifiedUnixSeconds,
      unixMode: input.unixMode, comment: input.comment, crc: crc32(input.data),
      packedSize: uint64(packed.len), unpackedSize: uint64(input.data.len),
      offset: uint64(result.len), zip64Sizes: zip64Sizes)
    let localExtraLength = (if zip64Sizes: 20 else: 0) +
      (if input.modifiedUnixSeconds.isSome: 9 else: 0)
    result.add32 SigLocal
    result.add16(if zip64Sizes: 45 else: 20)
    result.add16 0x0800
    result.add16 uint16(input.compressionMethod)
    result.add16 0; result.add16 0x0021
    result.add32 item.crc
    result.add32(if zip64Sizes: high(uint32) else: uint32(packed.len))
    result.add32(if zip64Sizes: high(uint32) else: uint32(input.data.len))
    result.add16 uint16(input.name.len)
    result.add16 uint16(localExtraLength)
    result.addString input.name
    if zip64Sizes:
      result.add16 1
      result.add16 16
      result.add64 uint64(input.data.len)
      result.add64 uint64(packed.len)
    if input.modifiedUnixSeconds.isSome:
      result.add16 0x5455
      result.add16 5
      result.add byte(1)
      result.add32 input.modifiedUnixSeconds.get
    result.add packed
    central.add item
  let centralStart = uint64(result.len)
  for item in central:
    let zip64Offset = forceZip64 or item.offset > uint64(high(uint32))
    let zip64ExtraSize = (if item.zip64Sizes: 16 else: 0) +
      (if zip64Offset: 8 else: 0)
    let centralExtraLength = (if zip64ExtraSize > 0: 4 +
        zip64ExtraSize else: 0) +
      (if item.modifiedUnixSeconds.isSome: 9 else: 0)
    let needsZip64 = item.zip64Sizes or zip64Offset
    result.add32 SigCentral
    result.add16(uint16(3 shl 8) or uint16(if needsZip64: 45 else: 20))
    result.add16(if needsZip64: 45 else: 20)
    result.add16 0x0800
    result.add16 uint16(item.compressionMethod)
    result.add16 0; result.add16 0x0021
    result.add32 item.crc
    result.add32(if item.zip64Sizes: high(uint32) else: uint32(item.packedSize))
    result.add32(if item.zip64Sizes: high(uint32) else: uint32(
        item.unpackedSize))
    result.add16 uint16(item.name.len)
    result.add16 uint16(centralExtraLength)
    result.add16 uint16(item.comment.len)
    result.add16 0; result.add16 0
    let defaultMode = if item.name.endsWith("/"): 0x41ED'u32
      else: 0x81A4'u32
    let mode = if item.unixMode.isSome:
        uint32(item.unixMode.get)
      else: defaultMode
    let external = (mode shl 16) or
      (if item.name.endsWith("/"): 0x10'u32 else: 0'u32)
    result.add32 external
    result.add32(if zip64Offset: high(uint32) else: uint32(item.offset))
    result.addString item.name
    if zip64ExtraSize > 0:
      result.add16 1
      result.add16 uint16(zip64ExtraSize)
      if item.zip64Sizes:
        result.add64 item.unpackedSize
        result.add64 item.packedSize
      if zip64Offset: result.add64 item.offset
    if item.modifiedUnixSeconds.isSome:
      result.add16 0x5455
      result.add16 5
      result.add byte(1)
      result.add32 item.modifiedUnixSeconds.get
    result.addString item.comment
  let centralSize = uint64(result.len) - centralStart
  let needsZip64End = forceZip64 or central.len > int(high(uint16)) or
    centralStart > uint64(high(uint32)) or centralSize > uint64(high(uint32))
  if needsZip64End:
    let zip64EndOffset = uint64(result.len)
    result.add32 SigZip64Eocd
    result.add64 44
    result.add16 45; result.add16 45
    result.add32 0; result.add32 0
    result.add64 uint64(central.len); result.add64 uint64(central.len)
    result.add64 centralSize
    result.add64 centralStart
    result.add32 SigZip64Locator
    result.add32 0
    result.add64 zip64EndOffset
    result.add32 1
  result.add32 SigEocd
  result.add16 0; result.add16 0
  result.add16(if needsZip64End: high(uint16) else: uint16(central.len))
  result.add16(if needsZip64End: high(uint16) else: uint16(central.len))
  result.add32(if needsZip64End: high(uint32) else: uint32(centralSize))
  result.add32(if needsZip64End: high(uint32) else: uint32(centralStart))
  result.add16 uint16(archiveComment.len)
  result.addString archiveComment

proc createZipGenerated*(count: int; provider: ArchiveInputProvider;
    forceZip64 = false; archiveComment = ""): seq[byte] =
  ## Create ZIP/ZIP64 while retaining at most one provided payload at a time.
  emitZip(result, count, provider, forceZip64, archiveComment)

proc createZip*(inputs: openArray[ArchiveInput];
    forceZip64 = false; archiveComment = ""): seq[byte] =
  ## Create a deterministic ZIP/ZIP64 archive from in-memory entries.
  let stableInputs = @inputs
  createZipGenerated(stableInputs.len,
    proc(index: int): ArchiveInput = stableInputs[index], forceZip64,
    archiveComment)

proc writeZipGenerated*(path: string; count: int;
    provider: ArchiveInputProvider; forceZip64 = false;
    maximumOutput = high(uint64); archiveComment = "") {.contractual.} =
  ## Atomically write entries supplied sequentially by `provider`.
  require:
    path.len > 0
    count >= 0
    maximumOutput != 0'u64
  body:
    let parent = path.parentDir
    if parent.len > 0 and not dirExists(parent):
      fail(aeIo, "ZIP output parent does not exist")
    if fileExists(path) or dirExists(path) or symlinkExists(path):
      fail(aeUnsafeArchive, "ZIP output already exists")
    let temporary = createTempFile(".uar-create-", ".partial",
      if parent.len > 0: parent else: getCurrentDir())
    var sink = FileZipSink(file: temporary.cfile, maximum: maximumOutput)
    var committed = false
    try:
      emitZip(sink, count, provider, forceZip64, archiveComment)
      sink.flush()
      sink.file.close()
      sink.file = nil
      if fileExists(path) or dirExists(path) or symlinkExists(path):
        fail(aeUnsafeArchive, "ZIP output appeared during creation")
      moveFile(temporary.path, path)
      committed = true
    except OSError as error:
      fail(aeIo, "ZIP output failed: " & error.msg)
    finally:
      if sink.file != nil: sink.file.close()
      if not committed and fileExists(temporary.path): removeFile(temporary.path)

proc writeZip*(path: string; inputs: openArray[ArchiveInput];
    archiveComment = "") {.contractual.} =
  ## Atomically create a new ZIP without replacing an existing path.
  require:
    path.len > 0
  body:
    let stableInputs = @inputs
    writeZipGenerated(path, stableInputs.len,
      proc(index: int): ArchiveInput = stableInputs[index],
      archiveComment = archiveComment)

