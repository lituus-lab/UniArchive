# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

import std/os
import UniArchive

if paramCount() != 1:
  quit("usage: generate_forced_zip64 OUTPUT", 2)
let bytes = createZip([archiveInput("stored.txt", "stored", zmStore),
  archiveInput("deflated.txt", "deflated deflated deflated")],
  forceZip64 = true)
var raw = newString(bytes.len)
for index, value in bytes: raw[index] = char(value)
writeFile(paramStr(1), raw)
