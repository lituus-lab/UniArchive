# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/os
import UniArchive

if paramCount() != 1:
  quit("usage: generate_zip OUTPUT", 2)
var stored = archiveInput("stored.txt", "stored", zmStore)
stored.comment = "stored comment"
writeZip(paramStr(1), [stored,
  archiveInput("deflated.txt", "deflated deflated deflated")],
  archiveComment = "archive comment")
