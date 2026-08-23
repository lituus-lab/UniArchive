# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Safe command-line interface for ZIP inspection, testing, and extraction.

import std/[os, strformat]
import UniArchive

proc usage() =
  stderr.writeLine "usage: uniarchive create [--store] ARCHIVE INPUT..."
  stderr.writeLine "usage: uniarchive list ARCHIVE"
  stderr.writeLine "       uniarchive inspect ARCHIVE"
  stderr.writeLine "       uniarchive test ARCHIVE"
  stderr.writeLine "       uniarchive cat ARCHIVE ENTRY"
  stderr.writeLine "       uniarchive extract ARCHIVE DESTINATION [ENTRY...]"

proc main(): int =
  if paramCount() < 1:
    usage()
    return 2
  try:
    let command = paramStr(1)
    case command
    of "create":
      var first = 2
      var codec = zmDeflate
      if paramCount() >= 2 and paramStr(2) == "--store":
        codec = zmStore
        first = 3
      if paramCount() < first + 1: usage(); return 2
      var inputs: seq[string]
      for index in first + 1 .. paramCount(): inputs.add paramStr(index)
      createZipFromPaths(paramStr(first), inputs, codec)
      echo &"created {paramStr(first)} from {inputs.len} input paths"
    of "list":
      if paramCount() != 2: usage(); return 2
      let archive = openArchive(paramStr(2))
      for entry in archive.entries:
        echo &"{entry.uncompressedSize}\t{entry.name}"
    of "inspect":
      if paramCount() != 2: usage(); return 2
      let archive = openArchive(paramStr(2))
      echo "format\tzip"
      echo &"entries\t{archive.entries.len}"
      if archive.comment.len > 0: echo &"comment\t{archive.comment}"
      for span in archive.spans:
        echo &"span\t{span.kind}\t{span.first}\t{span.pastLast}"
    of "test":
      if paramCount() != 2: usage(); return 2
      let archive = openArchive(paramStr(2))
      for entry in archive.entries: discard archive.readEntry(entry)
      echo &"verified {archive.entries.len} entries"
    of "cat":
      if paramCount() != 3: usage(); return 2
      let archive = openArchive(paramStr(2))
      let data = archive.readEntry(paramStr(3))
      if data.len > 0 and stdout.writeBuffer(unsafeAddr data[0], data.len) !=
          data.len:
        raise ArchiveException(kind: aeIo, msg: "short standard-output write")
    of "extract":
      if paramCount() < 3: usage(); return 2
      let archive = openArchive(paramStr(2))
      let report = if paramCount() == 3:
          archive.extractAll(paramStr(3))
        else:
          var selectors: seq[string]
          for index in 4 .. paramCount(): selectors.add paramStr(index)
          archive.extractSelected(paramStr(3), selectors)
      echo &"extracted {report.files} files, {report.bytesWritten} bytes"
    else:
      usage()
      return 2
    0
  except ArchiveException as error:
    stderr.writeLine &"uniarchive: {error.kind}: {error.msg}"
    case error.kind
    of aeUnsupported: 3
    of aeInvalidFormat, aeCorruptData: 4
    of aeUnsafeArchive, aeDuplicateEntry: 6
    of aeResourceLimit: 7
    of aeIo: 9
    else: 4
  except CatchableError as error:
    stderr.writeLine "uniarchive: ", error.msg
    9

quit(main())

