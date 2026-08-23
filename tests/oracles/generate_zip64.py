# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import sys
import zipfile

# Force ZIP64 structures with a tiny payload so the parser path is testable.
zipfile.ZIP64_LIMIT = 1
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED,
                     allowZip64=True) as archive:
    archive.writestr("zip64.txt", b"zip64 payload")
