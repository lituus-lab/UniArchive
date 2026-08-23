# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import sys
import zipfile

expect_comments = len(sys.argv) == 3 and sys.argv[2] == "comments"

with zipfile.ZipFile(sys.argv[1]) as archive:
    assert archive.comment == (b"archive comment" if expect_comments else b"")
    assert archive.namelist() == ["stored.txt", "deflated.txt"]
    assert archive.read("stored.txt") == b"stored"
    assert archive.read("deflated.txt") == b"deflated deflated deflated"
    assert archive.getinfo("stored.txt").comment == (
        b"stored comment" if expect_comments else b"")
    assert all(info.create_system == 3 for info in archive.infolist())
    assert all((info.external_attr >> 16) & 0o170000 == 0o100000
               for info in archive.infolist())
