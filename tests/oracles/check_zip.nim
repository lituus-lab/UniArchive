# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/os
import UniArchive

if paramCount() != 1: quit("usage: check_zip INPUT", 2)
let archive = openArchive(paramStr(1))
doAssert archive.readTextEntry("zip64.txt") == "zip64 payload"
