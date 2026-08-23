# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

import std/[options, os, strutils, tempfiles, times, unittest]
when not defined(release):
  import contracts
import UniArchive

proc input(name, data: string; compressionMethod = zmDeflate): ArchiveInput =
  result.name = name
  result.compressionMethod = compressionMethod
  for ch in data: result.data.add byte(ch)

proc text(data: seq[byte]): string =
  result = newString(data.len)
  for i, value in data: result[i] = char(value)

proc writeBytes(path: string; bytes: openArray[byte]) =
  var raw = newString(bytes.len)
  for i, value in bytes: raw[i] = char(value)
  writeFile(path, raw)

proc put32(bytes: var seq[byte]; at: int; value: uint32) =
  for i in 0 ..< 4: bytes[at + i] = byte(value shr (8 * i))

proc findSignature(bytes: openArray[byte]; signature: array[4, byte];
    start = 0): int =
  for i in start .. bytes.len - 4:
    if bytes[i] == signature[0] and bytes[i + 1] == signature[1] and
        bytes[i + 2] == signature[2] and bytes[i + 3] == signature[3]:
      return i
  -1

suite "ZIP reader and writer":
  test "stored and deflated entries round-trip":
    # Writing never replaces an existing path, so a fixed name turns one
    # failed run into a confusing failure in the next. Isolate per run.
    let work = createTempDir("uniarchive_roundtrip", "")
    defer: removeDir(work)
    let path = work / "roundtrip.zip"
    writeZip(path, [input("stored.txt", "stored", zmStore),
      input("deflated.txt", "deflated deflated deflated")])
    let archive = openArchive(path)
    check archive.entries.len == 2
    check archive.contains("stored.txt")
    check text(archive.readEntry("stored.txt")) == "stored"
    check text(archive.readEntry("deflated.txt")) ==
      "deflated deflated deflated"

  test "empty stored and deflated entries round-trip":
    let path = getTempDir() / "uniarchive_empty.zip"
    writeZip(path, [input("stored", "", zmStore),
      input("deflated", "", zmDeflate)])
    let archive = openArchive(path)
    check archive.readEntry("stored").len == 0
    check archive.readEntry("deflated").len == 0
    removeFile(path)

  test "forced ZIP64 writer round-trips entry and end records":
    let path = getTempDir() / "uniarchive_forced_zip64.zip"
    writeBytes(path, createZip([input("small.txt", "small payload")],
      forceZip64 = true))
    let archive = openArchive(path)
    check archive.entries.len == 1
    check text(archive.readEntry("small.txt")) == "small payload"
    check archive.spans.len == 5
    removeFile(path)

  test "generated writer requests each payload exactly once in order":
    var requested: seq[int]
    let bytes = createZipGenerated(3,
      proc(index: int): ArchiveInput =
      requested.add index
      input("entry-" & $index, "payload-" & $index))
    check requested == @[0, 1, 2]
    let path = getTempDir() / "uniarchive_generated.zip"
    requested.setLen(0)
    writeZipGenerated(path, 3,
      proc(index: int): ArchiveInput =
      requested.add index
      input("entry-" & $index, "payload-" & $index))
    check requested == @[0, 1, 2]
    check readFile(path) == text(bytes)
    check text(openArchive(path).readEntry("entry-2")) == "payload-2"
    removeFile(path)

  test "the portable name policy is one rule, shared by reader and writer":
    # The writer used to check only length and depth, so it could emit names
    # its own reader refuses. Both now go through inspectArchiveName.
    var parts: seq[string]
    const bytes = 4096'u64
    const depth = 64'u32
    check inspectArchiveName("dir/file.txt", bytes, depth, parts) == aniOk
    check inspectArchiveName("dir/", bytes, depth, parts) == aniOk
    check inspectArchiveName("", bytes, depth, parts) == aniOverlong
    check inspectArchiveName("a/b", 2'u64, depth, parts) == aniOverlong
    check inspectArchiveName("/abs", bytes, depth, parts) == aniPlatformSpecific
    check inspectArchiveName("a\\b", bytes, depth, parts) == aniPlatformSpecific
    check inspectArchiveName("C:/x", bytes, depth, parts) == aniPlatformSpecific
    check inspectArchiveName("a/b/c", bytes, 2'u32, parts) == aniDepth
    check inspectArchiveName("a/../b", bytes, depth, parts) == aniComponent
    check inspectArchiveName("trailing./x", bytes, depth, parts) ==
      aniAmbiguousSuffix
    check inspectArchiveName("bad\1name", bytes, depth, parts) == aniControlByte
    check inspectArchiveName("CON.txt", bytes, depth, parts) == aniReservedStem
    check inspectArchiveName("dir/NUL", bytes, depth, parts) == aniReservedStem

  test "creation refuses a path deeper than the policy allows":
    # The reader enforced maxPathDepth; the writer did not, so a deep tree
    # produced an archive this library would then refuse to open.
    let work = createTempDir("uniarchive_depth", "")
    defer: removeDir(work)
    var deep = work
    for level in 0 .. 8:
      deep = deep / "level"
      createDir(deep)
    writeFile(deep / "leaf.txt", "leaf")
    var narrow = defaultArchiveLimits()
    narrow.maxPathDepth = 4
    expect ArchiveException:
      createZipFromPaths(work / "deep.zip", [work / "level"],
        limits = narrow)

  test "streaming writer enforces output limit before publication":
    let path = getTempDir() / "uniarchive_writer_limit.zip"
    expect ArchiveException:
      writeZipGenerated(path, 1,
        proc(index: int): ArchiveInput = input("large", repeat('x', 4096)),
        maximumOutput = 64)
    check not fileExists(path)

  test "missing entry is explicit":
    let path = getTempDir() / "uniarchive_missing.zip"
    writeZip(path, [input("one", "1")])
    let archive = openArchive(path)
    expect ArchiveException:
      discard archive.readEntry("two")
    removeFile(path)

  test "CRC corruption is rejected":
    let path = getTempDir() / "uniarchive_crc.zip"
    var bytes = createZip([input("one", "payload", zmStore)])
    bytes[30 + 3] = bytes[30 + 3] xor 1
    var raw = newString(bytes.len)
    for i, value in bytes: raw[i] = char(value)
    writeFile(path, raw)
    let archive = openArchive(path)
    expect ArchiveException:
      discard archive.readEntry("one")
    removeFile(path)

  test "local and central names must agree":
    let path = getTempDir() / "uniarchive_local_name.zip"
    var bytes = createZip([input("one", "payload", zmStore)])
    bytes[30] = byte('x')
    var raw = newString(bytes.len)
    for i, value in bytes: raw[i] = char(value)
    writeFile(path, raw)
    expect ArchiveException:
      discard openArchive(path)
    removeFile(path)

  test "reserved general-purpose flags are rejected":
    let path = getTempDir() / "uniarchive_reserved_flag.zip"
    var bytes = createZip([input("one", "payload", zmStore)])
    let central = findSignature(bytes, [byte 0x50, 0x4B, 0x01, 0x02])
    bytes[6] = bytes[6] or 0x10
    bytes[central + 8] = bytes[central + 8] or 0x10
    writeBytes(path, bytes)
    expect ArchiveException:
      discard openArchive(path)
    removeFile(path)

  test "writer rejects names falsely marked as UTF-8":
    var invalid = input("valid", "payload")
    invalid.name = "bad" & char(0xFF)
    expect ArchiveException:
      discard createZip([invalid])

  test "legacy CP437 names decode while preserving raw bytes":
    let path = getTempDir() / "uniarchive_cp437.zip"
    var bytes = createZip([input("x", "payload", zmStore)])
    let central = findSignature(bytes, [byte 0x50, 0x4B, 0x01, 0x02])
    bytes[7] = bytes[7] and 0xF7
    bytes[30] = 0x82
    bytes[central + 9] = bytes[central + 9] and 0xF7
    bytes[central + 46] = 0x82
    writeBytes(path, bytes)
    let archive = openArchive(path)
    check archive.entries[0].name == "é"
    check archive.entries[0].rawNameBytes == @[0x82'u8]
    check text(archive.readEntry("é")) == "payload"
    removeFile(path)

  test "entry and archive comments round-trip":
    let path = getTempDir() / "uniarchive_comments.zip"
    var commented = input("commented.txt", "payload")
    commented.comment = "entrée commentée"
    writeBytes(path, createZip([commented], archiveComment = "archive comment"))
    let archive = openArchive(path)
    check archive.comment == "archive comment"
    check text(archive.rawCommentBytes) == "archive comment"
    check archive.entries[0].comment == "entrée commentée"
    check text(archive.readEntry("commented.txt")) == "payload"
    removeFile(path)

  test "stored sizes must agree before allocation":
    let path = getTempDir() / "uniarchive_store_sizes.zip"
    var bytes = createZip([input("one", "payload", zmStore)])
    let central = findSignature(bytes, [byte 0x50, 0x4B, 0x01, 0x02])
    bytes.put32(central + 20, 8)
    writeBytes(path, bytes)
    expect ArchiveException:
      discard openArchive(path)
    removeFile(path)

  test "overlapping physical records are rejected":
    let path = getTempDir() / "uniarchive_overlap.zip"
    var bytes = createZip([input("a", "1234", zmStore),
      input("b", "5678", zmStore)])
    let central = findSignature(bytes, [byte 0x50, 0x4B, 0x01, 0x02])
    bytes.put32(18, 39)
    bytes.put32(22, 39)
    bytes.put32(central + 20, 39)
    bytes.put32(central + 24, 39)
    writeBytes(path, bytes)
    expect ArchiveException:
      discard openArchive(path)
    removeFile(path)

  test "compression ratio policy is enforced":
    let path = getTempDir() / "uniarchive_ratio.zip"
    writeZip(path, [input("zeros", repeat('0', 4096))])
    var limits = defaultArchiveLimits()
    limits.maxCompressionRatio = 10
    expect ArchiveException:
      discard openArchive(path, limits)
    removeFile(path)

  test "transactional extraction publishes only safe paths":
    let archivePath = getTempDir() / "uniarchive_extract.zip"
    let destination = getTempDir() / "uniarchive_extract_result"
    if dirExists(destination): removeDir(destination)
    writeZip(archivePath, [input("dir/file.txt", "verified")])
    let report = extractAll(archivePath, destination)
    check report.files == 1
    check readFile(destination / "dir" / "file.txt") == "verified"
    removeDir(destination)
    removeFile(archivePath)

  test "transactional extraction rejects traversal without publishing":
    let archivePath = getTempDir() / "uniarchive_traversal.zip"
    let destination = getTempDir() / "uniarchive_traversal_result"
    if dirExists(destination): removeDir(destination)
    writeZip(archivePath, [input("../escape", "blocked")])
    expect ArchiveException:
      discard extractAll(archivePath, destination)
    check not dirExists(destination)
    removeFile(archivePath)

  test "transactional extraction rejects portable path ambiguities":
    let unsafeNames = ["/absolute", "C:/drive", "server\\share", "CON",
      "trailing. ", "a//b", "a/./b"]
    for index, name in unsafeNames:
      let archivePath = getTempDir() / ("uniarchive_unsafe_" & $index & ".zip")
      let destination = getTempDir() / ("uniarchive_unsafe_" & $index)
      if dirExists(destination): removeDir(destination)
      writeZip(archivePath, [input(name, "blocked")])
      expect ArchiveException:
        discard extractAll(archivePath, destination)
      check not dirExists(destination)
      removeFile(archivePath)

  test "transactional extraction rejects Unix symlinks":
    let archivePath = getTempDir() / "uniarchive_symlink.zip"
    let destination = getTempDir() / "uniarchive_symlink_result"
    var bytes = createZip([input("link", "target", zmStore)])
    let central = findSignature(bytes, [byte 0x50, 0x4B, 0x01, 0x02])
    bytes[central + 5] = 3
    bytes.put32(central + 38, 0xA000_0000'u32)
    writeBytes(archivePath, bytes)
    expect ArchiveException:
      discard extractAll(archivePath, destination)
    check not dirExists(destination)
    removeFile(archivePath)

  test "selective extraction unions files and directory subtrees":
    let archivePath = getTempDir() / "uniarchive_selected.zip"
    let destination = getTempDir() / "uniarchive_selected_result"
    writeZip(archivePath, [input("one.txt", "one"),
      input("dir/", "", zmStore), input("dir/a.txt", "a"),
      input("dir/nested/b.txt", "b"), input("skip.txt", "skip")])
    let report = extractSelected(archivePath, destination,
      ["one.txt", "dir"])
    check report.files == 3
    check fileExists(destination / "one.txt")
    check fileExists(destination / "dir" / "a.txt")
    check fileExists(destination / "dir" / "nested" / "b.txt")
    check not fileExists(destination / "skip.txt")
    removeDir(destination)
    removeFile(archivePath)

  test "missing selective target publishes nothing":
    let archivePath = getTempDir() / "uniarchive_selected_missing.zip"
    let destination = getTempDir() / "uniarchive_selected_missing_result"
    writeZip(archivePath, [input("one.txt", "one")])
    expect ArchiveException:
      discard extractSelected(archivePath, destination, ["absent"])
    check not dirExists(destination)
    removeFile(archivePath)

  test "declared total output limit is enforced while indexing":
    let path = getTempDir() / "uniarchive_total_limit.zip"
    writeZip(path, [input("one", "1234", zmStore),
      input("two", "5678", zmStore)])
    var limits = defaultArchiveLimits()
    limits.maxEntryOutput = 4
    limits.maxTotalOutput = 7
    expect ArchiveException:
      discard openArchive(path, limits)
    removeFile(path)

  test "single-byte corruptions never escape as defects":
    let path = getTempDir() / "uniarchive_mutation.zip"
    let canonical = createZip([input("entry", "mutation payload")])
    for index in 0 ..< canonical.len:
      var corrupted = canonical
      corrupted[index] = corrupted[index] xor 0xFF
      writeBytes(path, corrupted)
      try:
        let archive = openArchive(path)
        for entry in archive.entries: discard archive.readEntry(entry)
      except ArchiveException:
        discard
    removeFile(path)

  test "filesystem trees create and extract through the public API":
    let source = createTempDir("uar-create-source-", "")
    let output = source.parentDir / (source.lastPathPart & ".zip")
    let destination = source.parentDir / (source.lastPathPart & "-out")
    createDir(source / "nested")
    writeFile(source / "alpha.txt", "alpha")
    writeFile(source / "nested" / "beta.txt", "beta beta beta")
    setLastModificationTime(source / "alpha.txt", fromUnix(1_700_000_000))
    when not defined(windows):
      setFilePermissions(source / "alpha.txt", {fpUserRead, fpUserWrite})
    createZipFromPaths(output, [source])
    let archive = openArchive(output)
    check archive.entries.len == 4
    check archive.entryNames == @[source.lastPathPart & "/",
      source.lastPathPart & "/alpha.txt",
      source.lastPathPart & "/nested/",
      source.lastPathPart & "/nested/beta.txt"]
    let alpha = archive.findEntry(source.lastPathPart & "/alpha.txt").get
    check alpha.modifiedUnixSeconds == some(1_700_000_000'u32)
    check alpha.unixMode.isSome
    when not defined(windows):
      check (alpha.unixMode.get and 0x01FF'u16) == 0x0180'u16
    let report = extractAll(output, destination)
    check report.files == 2
    check report.directories == 2
    check readFile(destination / source.lastPathPart / "alpha.txt") == "alpha"
    check getLastModificationTime(destination / source.lastPathPart /
      "alpha.txt").toUnix == 1_700_000_000
    when not defined(windows):
      check getFilePermissions(destination / source.lastPathPart /
        "alpha.txt") == {fpUserRead, fpUserWrite}
    check readFile(destination / source.lastPathPart / "nested" / "beta.txt") ==
      "beta beta beta"
    removeDir(destination)
    removeFile(output)
    removeDir(source)

  test "ZIP creation never replaces an existing output":
    let source = createTempDir("uar-create-existing-", "")
    let output = source.parentDir / (source.lastPathPart & ".zip")
    writeFile(source / "file.txt", "payload")
    writeFile(output, "existing")
    expect ArchiveException:
      createZipFromPaths(output, [source])
    check readFile(output) == "existing"
    removeFile(output)
    removeDir(source)

  when not defined(windows):
    test "ZIP creation refuses symbolic links":
      let source = createTempDir("uar-create-link-", "")
      let output = source.parentDir / (source.lastPathPart & ".zip")
      writeFile(source / "target.txt", "target")
      createSymlink(source / "target.txt", source / "link.txt")
      expect ArchiveException:
        createZipFromPaths(output, [source])
      check not fileExists(output)
      removeFile(source / "link.txt")
      removeDir(source)

when not defined(release):
  suite "ZIP public contracts":
    test "archiveInput rejects an empty entry name":
      expect PreConditionDefect:
        discard archiveInput("", "payload")

    test "openArchive rejects an inconsistent limit policy":
      var limits = defaultArchiveLimits()
      limits.maxTotalOutput = limits.maxEntryOutput - 1
      expect PreConditionDefect:
        discard openArchive("unused.zip", limits)
else:
  suite "ZIP runtime policy validation":
    test "release rejects an inconsistent limit policy":
      var limits = defaultArchiveLimits()
      limits.maxTotalOutput = limits.maxEntryOutput - 1
      try:
        discard openArchive("unused.zip", limits)
        check false
      except ArchiveException as error:
        check error.kind == aeInvalidPolicy
