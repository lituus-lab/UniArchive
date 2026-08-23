# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Transactional ZIP extraction with portable path confinement.

import std/[options, os, sets, strutils, tempfiles, times, unicode]
import contracts
import ./zip

type
  ExtractionReport* = object
    ## Counts committed only after every entry has been verified.
    files*, directories*: uint64
    bytesWritten*: uint64

proc unsafe(message: string) {.noreturn.} =
  raise ArchiveException(kind: aeUnsafeArchive, msg: message)

func safeRelativePath(name: string; maxBytes: uint64;
    maxDepth: uint32): string =
  var components: seq[string]
  let issue = inspectArchiveName(name, maxBytes, maxDepth, components)
  if issue != aniOk: unsafe(issue.reason & ": " & name)
  result = components.join($DirSep)

template asIo(body: untyped) =
  ## A failing filesystem call here is an I/O condition — permissions, a full
  ## disk, a busy destination — not evidence of a hostile archive. Surface it
  ## as ArchiveException like every other failure this module reports, instead
  ## of letting a raw OSError escape a proc documented to raise ArchiveException.
  try: body
  except OSError as error:
    raise ArchiveException(kind: aeIo,
      msg: "extraction filesystem error: " & error.msg)

proc writeVerified(path: string; data: openArray[byte]) =
  var temporary: tuple[cfile: File; path: string]
  asIo: temporary = createTempFile(".uar-entry-", ".partial", path.parentDir)
  var file = temporary.cfile
  var committed = false
  try:
    if data.len > 0 and file.writeBuffer(unsafeAddr data[0], data.len) != data.len:
      raise ArchiveException(kind: aeIo, msg: "short extraction write")
    file.close()
    file = nil
    if fileExists(path) or dirExists(path):
      unsafe("extraction path collision: " & path)
    asIo: moveFile(temporary.path, path)
    committed = true
  finally:
    if file != nil: file.close()
    if not committed and fileExists(temporary.path): removeFile(temporary.path)

proc restoreModifiedTime(path: string; value: Option[uint32]) =
  if value.isSome:
    try:
      setLastModificationTime(path, fromUnix(int64(value.get)))
    except OSError as error:
      raise ArchiveException(kind: aeIo,
        msg: "could not restore modification time: " & error.msg)

proc restorePermissions(path: string; value: Option[uint16]) =
  if value.isNone: return
  let mode = value.get
  var permissions: set[FilePermission]
  const mappings = [
    (fpUserRead, 0x0100'u16), (fpUserWrite, 0x0080'u16),
    (fpUserExec, 0x0040'u16), (fpGroupRead, 0x0020'u16),
    (fpGroupWrite, 0x0010'u16), (fpGroupExec, 0x0008'u16),
    (fpOthersRead, 0x0004'u16), (fpOthersWrite, 0x0002'u16),
    (fpOthersExec, 0x0001'u16)]
  for mapping in mappings:
    if (mode and mapping[1]) != 0: permissions.incl mapping[0]
  try:
    setFilePermissions(path, permissions)
  except OSError as error:
    raise ArchiveException(kind: aeIo,
      msg: "could not restore permissions: " & error.msg)

proc extractChosen(reader: ArchiveReader; destination: string;
    chosen: openArray[bool]): ExtractionReport =
  if chosen.len != reader.entries.len:
    raise ArchiveException(kind: aeInvalidPolicy,
      msg: "entry selection does not match archive index")
  block:
    let limits = reader.policy
    if destination.len == 0:
      raise ArchiveException(kind: aeInvalidPolicy,
          msg: "empty extraction destination")
    if fileExists(destination) or dirExists(destination):
      unsafe("extraction destination already exists")
    let parent = destination.parentDir
    if parent.len > 0:
      asIo: createDir(parent)
    let stagingParent = if parent.len > 0: parent else: getCurrentDir()
    var staging: string
    asIo: staging = createTempDir(".uar-stage-", ".partial", stagingParent)
    var published = false
    var collisionKeys = initHashSet[string]()
    var directoryMetadata: seq[tuple[path: string;
      time: Option[uint32]; mode: Option[uint16]]]
    try:
      for entryIndex, entry in reader.entries:
        if not chosen[entryIndex]: continue
        let relative = safeRelativePath(entry.name, limits.maxPathBytes,
          limits.maxPathDepth)
        let collisionKey = relative.toLowerAscii()
        if collisionKey in collisionKeys:
          unsafe("case-insensitive extraction collision: " & entry.name)
        collisionKeys.incl collisionKey
        let target = staging / relative
        case entry.kind
        of aekDirectory:
          if entry.compressedSize != 0 or entry.uncompressedSize != 0:
            unsafe("directory entry carries a payload: " & entry.name)
          if fileExists(target): unsafe("file/directory extraction collision")
          asIo: createDir(target)
          directoryMetadata.add (target, entry.modifiedUnixSeconds,
            entry.unixMode)
          inc result.directories
        of aekFile:
          asIo: createDir(target.parentDir)
          let data = reader.readEntry(entry)
          if uint64(data.len) > limits.maxTotalOutput - result.bytesWritten:
            raise ArchiveException(kind: aeResourceLimit,
              msg: "actual extraction output exceeds policy")
          writeVerified(target, data)
          restorePermissions(target, entry.unixMode)
          restoreModifiedTime(target, entry.modifiedUnixSeconds)
          result.bytesWritten += uint64(data.len)
          inc result.files
        of aekSymlink, aekSpecial:
          unsafe("links and special files are disabled")
      if directoryMetadata.len > 0:
        for index in countdown(directoryMetadata.high, 0):
          restorePermissions(directoryMetadata[index].path,
            directoryMetadata[index].mode)
          restoreModifiedTime(directoryMetadata[index].path,
            directoryMetadata[index].time)
      asIo: moveDir(staging, destination)
      published = true
    finally:
      if not published and dirExists(staging): removeDir(staging)

proc extractAll*(reader: ArchiveReader;
    destination: string): ExtractionReport {.contractual.} =
  ## Verify all payloads into a private staging tree, then publish the tree.
  require:
    destination.len > 0
  ensure:
    result.bytesWritten <= reader.policy.maxTotalOutput
  body:
    var chosen = newSeq[bool](reader.entries.len)
    for value in chosen.mitems: value = true
    result = extractChosen(reader, destination, chosen)

proc extractSelected*(reader: ArchiveReader; destination: string;
    selectors: openArray[string]): ExtractionReport {.contractual.} =
  ## Transactionally extract the union of exact files and directory subtrees.
  require:
    destination.len > 0
    selectors.len > 0
  body:
    if selectors.len == 0:
      raise ArchiveException(kind: aeInvalidPolicy,
          msg: "empty entry selection")
    let entries = reader.entries
    var chosen = newSeq[bool](entries.len)
    for selector in selectors:
      if selector.len == 0 or '\0' in selector:
        raise ArchiveException(kind: aeInvalidPolicy,
          msg: "invalid empty or NUL entry selector")
      let directoryName = if selector.endsWith("/"): selector else: selector & "/"
      var exactFile = false
      for entry in entries:
        if entry.name == selector and entry.kind != aekDirectory:
          exactFile = true
          break
      var matched = false
      for index, entry in entries:
        let selected = if exactFile: entry.name == selector
          else: entry.name == selector or entry.name == directoryName or
            entry.name.startsWith(directoryName)
        if selected:
          chosen[index] = true
          matched = true
      if not matched:
        raise ArchiveException(kind: aeMissingEntry,
          msg: "entry selector not found: " & selector)
    result = extractChosen(reader, destination, chosen)

proc extractSelected*(archivePath, destination: string;
    selectors: openArray[string];
    limits = defaultArchiveLimits()): ExtractionReport =
  ## Open and transactionally extract selected files or directory subtrees.
  openArchive(archivePath, limits).extractSelected(destination, selectors)

proc extractAll*(archivePath, destination: string;
    limits = defaultArchiveLimits()): ExtractionReport =
  ## Open, validate, and transactionally extract one ZIP archive.
  openArchive(archivePath, limits).extractAll(destination)

