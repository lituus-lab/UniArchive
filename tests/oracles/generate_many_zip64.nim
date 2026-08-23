# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

import std/[os, strformat]
import UniArchive

const EntryCount = 65_536

if paramCount() != 1:
  quit("usage: generate_many_zip64 OUTPUT", 2)

writeZipGenerated(paramStr(1), EntryCount,
  proc(index: int): ArchiveInput =
  ArchiveInput(name: &"entry-{index:05}.txt", compressionMethod: zmStore),
  maximumOutput = 32'u64 shl 20)

var limits = defaultArchiveLimits()
limits.maxEntries = EntryCount
let archive = openArchive(paramStr(1), limits)
doAssert archive.entries.len == EntryCount
doAssert archive.entries[0].name == "entry-00000.txt"
doAssert archive.entries[^1].name == "entry-65535.txt"
