<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# Provenance

UniArchive is an independent pure-Nim implementation. No implementation listed
below is copied or linked into the distributed library.

| Area | Primary specification | Independent oracle or design reference |
| --- | --- | --- |
| ZIP and ZIP64 | PKWARE APPNOTE 6.3.10 | Python `zipfile`, libarchive |
| Deflate | RFC 1951 | Python `zlib` |
| CRC-32 | ZIP APPNOTE, RFC 1952 | Python `zlib` |
| Physical record overlap | ZIP record layout | Mark Adler's `beagle.py` algorithm and Info-ZIP work |
| Extraction policy | Platform filesystem semantics | SafeZip security model and OWASP archive guidance |

Mark Adler's published detector and SafeZip were studied for threat modelling.
Their source code is not bundled or translated. The overlap sweep in
UniArchive is implemented independently over the APPNOTE record structures.
