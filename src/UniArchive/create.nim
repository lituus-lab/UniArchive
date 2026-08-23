# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Deterministic and bounded filesystem collection for ZIP creation.

import std/[algorithm, options, os, strutils, times]
import contracts
import ./zip

proc creationError(kind: ArchiveErrorKind; message: string) {.noreturn.} =
  raise ArchiveException(kind: kind, msg: message)

proc checkNameLimits(entryName: string; limits: ArchiveLimits) =
  ## Same portable-name policy the reader applies, enforced on the way out: an
  ## archive this writer produces must be one this library will agree to open.
  var components: seq[string]
  let issue = inspectArchiveName(entryName, limits.maxPathBytes,
    limits.maxPathDepth, components)
  case issue
  of aniOk: discard
  of aniOverlong, aniDepth:
    creationError(aeResourceLimit, issue.reason & ": " & entryName)
  else:
    creationError(aeUnsafeArchive, issue.reason & ": " & entryName)

func archiveName(path: string): string =
  result = path.replace('\\', '/')
  while result.len > 0 and result[0] == '/': result = result[1 .. ^1]
  if result.len == 0 or result == "." or result.startsWith("../") or
      "/../" in result or result.endsWith("/.."):
    creationError(aeUnsafeArchive, "unsafe ZIP creation name: " & path)

proc readRegularFile(path: string; maximum: uint64): seq[byte] =
  var file: File
  if not open(file, path, fmRead):
    creationError(aeIo, "input file could not be opened: " & path)
  defer: file.close()
  let info = getFileInfo(file)
  if info.kind != pcFile or info.isSpecial:
    creationError(aeUnsafeArchive, "input is not a regular file: " & path)
  if info.size < 0 or uint64(info.size) > maximum or
      uint64(info.size) > uint64(high(int)):
    creationError(aeResourceLimit, "input file exceeds creation limit: " & path)
  result = newSeq[byte](int(info.size))
  if result.len > 0 and file.readBuffer(addr result[0], result.len) != result.len:
    creationError(aeIo, "input file changed or was truncated: " & path)
  var extra: byte
  if file.readBuffer(addr extra, 1) != 0:
    creationError(aeResourceLimit, "input file grew beyond its validated size: " & path)

type CollectedInput = object
  path, name: string
  compressionMethod: ZipMethod
  modifiedUnixSeconds: Option[uint32]
  unixMode: Option[uint16]
  directory: bool

func portableMode(info: FileInfo; directory: bool): Option[uint16] =
  var mode = if directory: 0x4000'u16 else: 0x8000'u16
  const mappings = [
    (fpUserRead, 0x0100'u16), (fpUserWrite, 0x0080'u16),
    (fpUserExec, 0x0040'u16), (fpGroupRead, 0x0020'u16),
    (fpGroupWrite, 0x0010'u16), (fpGroupExec, 0x0008'u16),
    (fpOthersRead, 0x0004'u16), (fpOthersWrite, 0x0002'u16),
    (fpOthersExec, 0x0001'u16)]
  for mapping in mappings:
    if mapping[0] in info.permissions: mode = mode or mapping[1]
  some(mode)

proc collectPath(path, name: string; codec: ZipMethod; limits: ArchiveLimits;
    result: var seq[CollectedInput]; total: var uint64) =
  let info = try:
      getFileInfo(path, followSymlink = false)
    except OSError as error:
      creationError(aeIo, "input could not be inspected: " & path & ": " & error.msg)
  if info.kind in {pcLinkToFile, pcLinkToDir}:
    creationError(aeUnsafeArchive, "symbolic links are disabled: " & path)
  if info.isSpecial:
    creationError(aeUnsafeArchive, "special files are disabled: " & path)
  let unixTime = info.lastWriteTime.toUnix
  let modified = if unixTime >= 0 and uint64(unixTime) <= uint64(high(uint32)):
      some(uint32(unixTime))
    else: none(uint32)
  case info.kind
  of pcFile:
    if info.size < 0 or uint64(info.size) > limits.maxEntryOutput:
      creationError(aeResourceLimit, "input file exceeds creation limit: " & path)
    if uint64(info.size) > limits.maxTotalOutput - total:
      creationError(aeResourceLimit, "creation inputs exceed total output limit")
    total += uint64(info.size)
    checkNameLimits(archiveName(name), limits)
    result.add CollectedInput(path: path, name: archiveName(name),
      compressionMethod: codec, modifiedUnixSeconds: modified,
      unixMode: portableMode(info, false))
  of pcDir:
    # Checked before recursing, so descent cannot pass the depth limit.
    checkNameLimits(archiveName(name) & "/", limits)
    result.add CollectedInput(path: path, name: archiveName(name) & "/",
      compressionMethod: zmStore, modifiedUnixSeconds: modified,
      unixMode: portableMode(info, true), directory: true)
    var children: seq[string]
    for _, child in walkDir(path, relative = false): children.add child
    children.sort(system.cmp[string])
    for child in children:
      collectPath(child, name & "/" & child.lastPathPart, codec, limits,
        result, total)
  else:
    creationError(aeUnsafeArchive, "unsupported filesystem object: " & path)
  if uint64(result.len) > limits.maxEntries:
    creationError(aeResourceLimit, "too many creation inputs")

proc collectArchiveInputs*(paths: openArray[string];
    compressionMethod = zmDeflate;
    limits = defaultArchiveLimits()): seq[ArchiveInput] {.contractual.} =
  ## Collect regular files and directory trees without following links.
  require:
    paths.len > 0
  ensure:
    result.len > 0
    uint64(result.len) <= limits.maxEntries
  body:
    if paths.len == 0:
      creationError(aeInvalidPolicy, "ZIP creation needs at least one input")
    var total = 0'u64
    var collected: seq[CollectedInput]
    for path in paths:
      if path.len == 0:
        creationError(aeInvalidPolicy, "empty ZIP creation path")
      let absolute = absolutePath(path)
      collectPath(absolute, absolute.lastPathPart, compressionMethod, limits,
        collected, total)
    # collectPath capped the declared sizes; cap what is actually read too, as
    # createZipFromPaths does. A file that grows between stat and read would
    # otherwise pass here and fail there.
    var actualTotal = 0'u64
    for item in collected:
      var data: seq[byte]
      if not item.directory:
        data = readRegularFile(item.path, limits.maxEntryOutput)
        if uint64(data.len) > limits.maxTotalOutput - actualTotal:
          creationError(aeResourceLimit,
            "creation inputs exceed actual total output limit")
        actualTotal += uint64(data.len)
      result.add ArchiveInput(name: item.name, data: data,
        compressionMethod: item.compressionMethod,
        modifiedUnixSeconds: item.modifiedUnixSeconds,
        unixMode: item.unixMode)

proc createZipFromPaths*(output: string; paths: openArray[string];
    compressionMethod = zmDeflate;
    limits = defaultArchiveLimits()) {.contractual.} =
  ## Collect `paths` and atomically create a new ZIP at `output`.
  require:
    output.len > 0
    paths.len > 0
  body:
    if paths.len == 0:
      creationError(aeInvalidPolicy, "ZIP creation needs at least one input")
    var declaredTotal = 0'u64
    var collected: seq[CollectedInput]
    for path in paths:
      if path.len == 0:
        creationError(aeInvalidPolicy, "empty ZIP creation path")
      let absolute = absolutePath(path)
      collectPath(absolute, absolute.lastPathPart, compressionMethod, limits,
        collected, declaredTotal)
    var actualTotal = 0'u64
    let provider: ArchiveInputProvider = proc(index: int): ArchiveInput =
      let item = collected[index]
      result = ArchiveInput(name: item.name,
        compressionMethod: item.compressionMethod,
        modifiedUnixSeconds: item.modifiedUnixSeconds,
        unixMode: item.unixMode)
      if not item.directory:
        result.data = readRegularFile(item.path, limits.maxEntryOutput)
        if uint64(result.data.len) > limits.maxTotalOutput - actualTotal:
          creationError(aeResourceLimit,
            "creation inputs exceed actual total output limit")
        actualTotal += uint64(result.data.len)
    writeZipGenerated(output, collected.len, provider,
      maximumOutput = limits.maxArchiveBytes)

