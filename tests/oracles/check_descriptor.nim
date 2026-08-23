# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/os
import UniArchive

if paramCount() != 1: quit("usage: check_descriptor INPUT", 2)
let archive = openArchive(paramStr(1))
doAssert archive.readTextEntry("descriptor.txt") == "descriptor payload"
doAssert archive.readTextEntry("descriptor64.txt") == "ZIP64 descriptor payload"
