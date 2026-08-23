# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/[monotimes, os, strformat, strutils, times]
import UniArchive

let payload = "archive benchmark payload\n".repeat(500_000)
let started = getMonoTime()
let encoded = createZip([archiveInput("payload.txt", payload)])
let elapsed = (getMonoTime() - started).inNanoseconds.float / 1e9
echo &"ZIP create: {payload.len.float / elapsed / 1e6:.2f} MB/s ({encoded.len} bytes)"

let streamPath = getTempDir() / "uniarchive-stream-benchmark.zip"
let streamStarted = getMonoTime()
writeZipGenerated(streamPath, 1,
  proc(index: int): ArchiveInput = archiveInput("payload.txt", payload))
let streamElapsed = (getMonoTime() - streamStarted).inNanoseconds.float / 1e9
echo &"ZIP stream: {payload.len.float / streamElapsed / 1e6:.2f} MB/s " &
  &"({getFileSize(streamPath)} bytes)"
removeFile(streamPath)

var entries: seq[ArchiveInput]
for i in 0 ..< 1_000:
  entries.add archiveInput(&"entry-{i:04}.txt", "guard payload")
let archiveBytes = createZip(entries)
let path = getTempDir() / "uniarchive-guard-benchmark.zip"
var raw = newString(archiveBytes.len)
for i, value in archiveBytes: raw[i] = char(value)
writeFile(path, raw)
let guardStarted = getMonoTime()
let archive = openArchive(path)
let guardElapsed = (getMonoTime() - guardStarted).inNanoseconds
doAssert archive.entries.len == entries.len
echo &"ZIP guard: {entries.len} entries in {guardElapsed} ns"
removeFile(path)
