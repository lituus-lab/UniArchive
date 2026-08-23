# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    assert len(archive.infolist()) == 65_536
    assert archive.infolist()[0].filename == "entry-00000.txt"
    assert archive.infolist()[-1].filename == "entry-65535.txt"
