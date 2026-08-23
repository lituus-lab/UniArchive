<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# UniArchive

Pure-Nim archive containers: ZIP and ZIP64, read and written under explicit
bounds, in Nim, with a hand-written C ABI, a Cython Python binding and a CLI.

Layer-3 in the `lituus-lab` `Uni*` family DAG: UniCompress and UniChecksum are
its only sibling dependencies — DEFLATE for the payloads, CRC-32 for the entry
checks. Outside the family it also needs NimContracts, which is verification
infra and compiles away under `-d:release`.

## Quick start

```nim
import UniArchive

writeZip("demo.zip", [archiveInput("notes.txt", "one\n"),
                      archiveInput("data/values.csv", "a,b\n1,2\n")])

let reader = openArchive("demo.zip")
echo reader.entryNames                   # @["notes.txt", "data/values.csv"]
echo reader.entries.len                  # 2
echo reader.readTextEntry("notes.txt")   # one
```

```c
#include "UniArchive.h"
int64_t n = uar_entry_count("demo.zip");   /* -1 if the reader refuses it */
```

```python
import uniarchive
uniarchive.names("demo.zip")
```

See `book/index.nim` (nimib, built into `book/index.html`) for the full
walkthrough, and `py/notebooks/quickstart.ipynb` for the Python side.

## What's inside

- **Reading** (`zip.nim`) — ZIP and ZIP64 with Store and Deflate, plus
  streaming data descriptors. Before exposing an entry it checks the local and
  central records, ZIP64 fields, metadata budgets, declared against actual
  sizes, CRC-32, compression ratios, duplicate names, and physical record
  overlaps. Unsupported general-purpose flags and invalid UTF-8 declarations
  are rejected. Legacy names without the UTF-8 flag decode as CP437 while their
  central-directory bytes stay reachable through `rawNameBytes`. The input is
  held as one immutable snapshot.
- **Writing** (`create.nim`) — canonical DOS dates, Unix creator attributes,
  optional Unix modification timestamps (`0x5455`), and ZIP64 extras when
  required. Creation walks directories in bytewise sorted order, refuses
  symbolic links and special files, observes the same ceilings as reading, and
  publishes atomically. Payloads are opened lazily and released entry by entry;
  encoded bytes flow through a 64 KiB sink, so only central-directory metadata
  stays resident until finalisation. The nine portable Unix rwx bits are
  preserved; setuid, setgid and sticky are neither recorded nor restored.
- **Extraction** (`extract.nim`) — `extractAll` rejects traversal, absolute and
  platform-ambiguous paths, links, special files and collisions. Every payload
  is verified in a private staging tree, and the destination is published only
  once the whole archive succeeds. `extractSelected` takes any number of exact
  files and directory subtrees, unions them, and keeps the same guarantees.

Entry comments are UTF-8 when written; archive comments are restricted to the
portable ASCII subset, because ZIP carries no archive-comment encoding flag.

## The CLI

`nimble cli` builds it. It never replaces an existing path.

```text
build/uniarchive create archive.zip path/to/file path/to/directory
build/uniarchive create --store archive.zip already-compressed.bin
build/uniarchive list archive.zip
build/uniarchive inspect archive.zip
build/uniarchive test archive.zip
build/uniarchive cat archive.zip path/inside/archive
build/uniarchive extract archive.zip destination
build/uniarchive extract archive.zip destination file.txt dir/subtree
```

## The Uni* family

UniArchive is layer 3 of `lituus-lab`'s `Uni*` family: a set of Nim libraries,
each with a C ABI and a Python binding, unified by a shared dependency DAG and
documentation/testing conventions. See
[lituus-lab/.github](https://github.com/lituus-lab/.github) for the family's
purpose and philosophy. It builds on UniCompress for DEFLATE and UniChecksum
for CRC-32 rather than carrying either, so a bug in a codec is fixed once.

## Provenance & development

ZIP is specified by PKWARE's APPNOTE and its ZIP64 extensions; there is no
original format work here. `PROVENANCE.md` records, per area, which
specification was followed and which independent implementation served as an
oracle or a threat-modelling reference — none of them is bundled or
translated.

The writer's output is checked against Python's `zipfile` — including data
descriptors, forced ZIP64, and the automatic 65,536-entry transition — and
against libarchive. Security tests cover record
overlaps, expansion limits, inconsistent Store records and transactional path
confinement.

Development used LLM/agent assistance extensively, on the terms described below.
One visible consequence: this repo's git history is short and linear, with
commits landing close together in time — that reflects an LLM/agent writing pass
over an already-specified format, not the container being designed at that speed.

## Layout

```text
src/UniArchive.nim            umbrella module
src/UniArchive/zip.nim        reader, records and bounds (NimContracts)
src/UniArchive/create.nim     writer and filesystem walk
src/UniArchive/extract.nim    transactional extraction
src/UniArchive/c_api.nim      C ABI
src/uniarchive_cli.nim        command-line front end
include/UniArchive.h          hand-written C header
tests/                        Nim tests, oracles and fixtures
tests/c/                      C ABI test (links the header against the lib)
examples/                     Nim + C demos
py/                           Cython binding + pytest
ADRs/                         0001 sibling deps, 0002 license, 0003 engine & C ABI, 0004 public surfaces, 0005 hostile archives
.github/workflows/ci.yml      3-OS Nim matrix + C ABI + Python
```

## Build

```bash
nimble install -y
nimble test           # Nim, debug (contracts active)
nimble testRelease    # Nim, release (contracts compiled away)
nimble testAll        # debug + release + C ABI
nimble cli            # the command-line front end
nimble ctest          # C ABI: static lib + tests/c
nimble cexample       # C demo
nimble example        # Nim demo
nimble pyTest         # Cython + pytest
nimble oracle         # differential checks against Python zipfile and libarchive
nimble benchmark      # archive throughput
nimble lint           # nimpretty check
nimble checkVGraph    # import-direction check
nimble coverage       # gcov + lcov -> coverage/
nimble book           # nimib book -> book/index.html
nimble docs           # book + API reference -> pages/
```

## CI

`test`, `cabi` and `python` on ubuntu/macOS/Windows. `consume-cabi` and
`consume-wheel` rebuild against the published artifacts on a machine without Nim,
so what ships is what was tested. `coverage` and `docs` run on ubuntu.

`dco` blocks PRs missing a `Signed-off-by` trailer; `commitizen` blocks PRs whose
commits or title are not [Conventional Commits](https://www.conventionalcommits.org/)
(`CONTRIBUTING.md`).

The same gates run locally with pre-commit:
`pip install pre-commit && pre-commit install`
(`CONTRIBUTING.md`).

`docs` publishes to GitHub Pages — skipped on push to a fork or while the repo
is private, on by default once public on `main`.

## AI-assisted contributions

Assistance from AI/LLM tools is welcome on the same terms as any other
contribution.

- **Accountability.** The human contributor is the author and remains fully
  responsible for the change. The DCO sign-off (`Signed-off-by`) is the mechanism:
  by signing you certify the content is yours or properly licensed — this covers
  AI-assisted work, provided you can stand behind it.
- **No third-party contamination.** Ensure AI output introduces no code from a
  third party without a compatible license and attribution. If an LLM reproduced
  protected material, do not submit it.
- **Correctness is yours.** The gates (tests, `nimble lint`, conventional commits,
  pre-commit) catch a lot, but you own the result — review and verify what you
  commit.
- **Atomic commits.** Each commit is one logical change. A PR may stack
  several atomic commits (one per element, say) — one monolithic big-bang
  commit is not.
- **Disclosure.** State in the PR whether AI assistance was used (see the PR
  template). It is not a hard requirement — the DCO remains the gate.

## License

Apache-2.0 (`LICENSE`). DCO sign-off on every commit (`CONTRIBUTING.md`).
