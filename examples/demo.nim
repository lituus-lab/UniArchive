# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/[os, tempfiles]
import UniArchive

let path = getTempDir() / "uniarchive_demo.zip"
writeZip(path, [archiveInput("hello.txt", "hello")])
let archive = openArchive(path)
doAssert archive.readTextEntry("hello.txt") == "hello"
removeFile(path)

