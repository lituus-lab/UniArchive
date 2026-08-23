<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# Security Policy

Report vulnerabilities privately, not via a public issue: use GitHub's private
vulnerability reporting (Security → Report a vulnerability on this repository),
or email <lbartoletti@lituus-lab.com>. Include: description + impact, minimal
reproducer, affected version (`uar_version()`).

Only the latest released line is supported. The `0.1.x` C ABI is not yet frozen.

## Surface

- C callers must provide non-null path and entry-name pointers; every entry
  point rejects a null one rather than dereferencing it.
- Failure is reported in the return type: `uar_open` yields `nil`, the
  integer-status entry points (`uar_extract`, `uar_create_zip`, the read and
  count calls) yield `-1`. No exception crosses the ABI.
- The Python binding translates an ABI failure into `ValueError`.
- Reentrant. A static build initializes the Nim runtime once, through the
  platform's one-time-initialization primitive, so concurrent first calls are
  safe; a shared build is initialized before any call reaches it.

## ZIP invariants

- Limits are validated at runtime in release builds as well as by contracts in
  debug builds.
- Store entries require equal packed and unpacked sizes before allocation.
- Local headers, central records, ZIP64 fields and data descriptors must agree.
- Every physical record is represented as a half-open interval; any overlap is
  rejected as an unsafe archive before decompression.
- Duplicate names, encrypted entries, patching, masked headers, reserved
  general-purpose flags and multi-disk archives are rejected. Names carrying
  the ZIP UTF-8 flag must contain valid UTF-8.
- Declared per-entry and cumulative output, compressed input, metadata, path
  length, compression ratios and Deflate decode work are bounded. Actual
  decoded sizes and CRC-32 are checked before bytes are returned or published.
- Extended timestamps are structurally bounded and local/central modification
  times must agree when both records provide them.

## Extraction

`extractAll` is transactional. It refuses an existing destination and stages
all regular files under a private sibling directory. Absolute paths, `..`,
backslashes, drive/ADS colons, control bytes, reserved Windows names, trailing
dots/spaces, case-insensitive collisions, symlinks and special files are
rejected. A failed extraction removes the staging tree and publishes nothing.

Automatic nested-archive extraction is not implemented and therefore cannot
silently reset the parent archive's limits.

## Creation

Filesystem creation accepts only regular files and directories. It does not
follow symbolic links, rejects special files, sorts each directory before
descent, and applies entry, per-file, and cumulative size ceilings. The output
is written beside its destination and moved into place only when complete. An
existing file, directory, or symbolic link is never replaced.

Filesystem payloads are supplied sequentially to the writer and actual bytes
are counted again after opening, so a file changing after discovery cannot
bypass the cumulative output ceiling. Encoded bytes are written through a
64 KiB buffer to a private temporary file under a separate archive-size ceiling;
only bounded per-entry data and central-directory metadata remain resident.
Only the portable rwx permission bits are restored, after file verification and
after all children for directories. Privileged and sticky mode bits are always
discarded.

The current reader snapshots a bounded archive in memory and returns bounded
entry buffers. A future streaming API may reduce resident memory further; it
must preserve the same runtime limits and verification-before-publication rule.
