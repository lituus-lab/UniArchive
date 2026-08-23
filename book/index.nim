# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import nimib
import std/[os, strutils]

nbInit
nb.title = "UniArchive"

nbText: """
# UniArchive

A ZIP file is a container, not a codec. It frames entries with local headers,
records them again in a central directory at the end, and leaves the actual
squeezing to DEFLATE. UniArchive owns the framing and nothing else: the payload
codec is UniCompress, the entry checksum is UniChecksum. That separation is
what lets a bug in either be fixed once, for every format that uses them.

This page is a nimib book: every Nim block below is compiled and run when the
book is built, and the output shown is what the code actually produced.

## Writing an archive

`createZip` returns the bytes; `writeZip` puts them on disk. Both take entries
as `(name, data)` pairs.
"""

nbCode:
  import UniArchive

  let encoded = createZip([archiveInput("notes.txt", "one\n"),
                           archiveInput("data/values.csv", "a,b\n1,2\n")])
  echo "archive: ", encoded.len, " bytes"
  echo "signature: ", encoded[0].toHex(2), encoded[1].toHex(2),
       encoded[2].toHex(2), encoded[3].toHex(2)

nbText: """
`504B0304` is the local file header signature every ZIP starts with — the
"PK" of Phil Katz, followed by the record type.

## Reading it back

A reader takes one immutable snapshot of the source and validates before it
exposes anything: local against central records, ZIP64 fields, declared against
actual sizes, CRC-32, duplicate names, and whether two records physically
overlap.
"""

nbCode:
  # Reading is path-based: one immutable snapshot of a file on disk.
  removeFile("book-demo.zip")
  writeFile("book-demo.zip", cast[string](encoded))
  let reader = openArchive("book-demo.zip")
  echo "entries: ", reader.entryNames
  echo "notes.txt -> ", reader.readTextEntry("notes.txt").strip()
  echo "present? ", "data/values.csv" in reader

nbText: """
## Refusing what does not add up

The checks are not advisory. Corrupting a single byte of a payload breaks its
CRC-32, and the reader refuses the entry rather than handing back damaged data.
"""

nbCode:
  var damaged = encoded
  # Land inside the first entry's payload, past the 30-byte local header.
  damaged[40] = damaged[40] xor 0xFF'u8
  removeFile("book-damaged.zip")
  writeFile("book-damaged.zip", cast[string](damaged))
  try:
    discard openArchive("book-damaged.zip").readTextEntry("notes.txt")
    echo "accepted — this line should not print"
  except ArchiveException as e:
    echo "refused: ", e.kind
  removeFile("book-demo.zip")
  removeFile("book-damaged.zip")

nbText: """
Extraction adds path confinement on top: `extractAll` rejects traversal,
absolute and platform-ambiguous names, links, special files and collisions,
verifies every payload in a private staging tree, and publishes the destination
only once the whole archive has succeeded. `extractSelected` applies the same
guarantees to any union of exact files and directory subtrees, and aborts if a
selector matches nothing.

Writing never replaces an existing path — a caller that wants replacement
removes the file itself, so no entry point can destroy data by default.

## References

- [.ZIP File Format Specification](https://support.pkware.com/pkzip/appnote)
  — PKWARE's APPNOTE: the record layout, the general-purpose bit flags, and the
  ZIP64 extensions.
- [RFC 1951](https://www.rfc-editor.org/rfc/rfc1951) — the DEFLATE bitstream a
  compressed entry carries, implemented in UniCompress.
- [Info-ZIP](https://infozip.sourceforge.net/) — the reference implementations
  whose behaviour set most of the de-facto conventions APPNOTE leaves open.
- [libarchive](https://www.libarchive.org/) — one of the two independent
  readers this repo's differential tests check its output against.
- [Python `zipfile`](https://docs.python.org/3/library/zipfile.html) — the
  other, including data descriptors and the automatic ZIP64 transition.
"""

nbSave
