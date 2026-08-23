# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Generate a streaming ZIP that uses a data descriptor."""

import io
import pathlib
import sys
import zipfile


class Unseekable(io.BytesIO):
    def seekable(self):
        return False

    def seek(self, *args, **kwargs):
        raise io.UnsupportedOperation("stream is not seekable")


target = pathlib.Path(sys.argv[1])
stream = Unseekable()
with zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED) as archive:
    archive.writestr("descriptor.txt", b"descriptor payload")
    with archive.open("descriptor64.txt", "w", force_zip64=True) as member:
        member.write(b"ZIP64 descriptor payload")
target.write_bytes(stream.getvalue())
