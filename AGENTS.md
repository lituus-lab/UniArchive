<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# AGENTS.md — UniArchive

## Build & gates

```bash
nimble install -y
nimble testAll    # Nim debug + release + C ABI
nimble pyTest     # build shared library, Cython extension, then run pytest
nimble example
nimble coverage   # gcov + lcov -> coverage/ (needs lcov; linux/macOS)
nimble docs       # nimib book + API reference -> pages/ (needs nimib)
```

Use the choosenim toolchain. `nimble docs` needs its complete Nim distribution
because `--project` builds the bundled `dochack` tool.

CI: three-OS Nim, C ABI, Python and artifact-consumption matrices.

## Conventions

- English comments, terse, describe what is done. No "deprecated".
- NimContracts `{.contractual.}` + `require:`/`ensure:`/`body:`, compiled away
  under `-d:release`. Exceptions never cross the C ABI.
- A postcondition is cheaper than the body: never re-derives the result by
  calling the function itself.
- C ABI: hand-written `include/UniArchive.h` kept in sync with
  `src/UniArchive/c_api.nim`; `tests/c` links the header against the lib.
  Built `--app:staticlib`/`--app:lib --noMain --mm:arc -d:release`.
- C symbols use `uar_`; lib `libUniArchive`; header `UniArchive.h`.
- `book/index.nim` is nimib: its code blocks are compiled and run at docs build,
  so prose that outlives its API breaks the build. `py/notebooks/quickstart.ipynb`
  plays the same role for Python and renders natively on GitHub.
- End covered sources with a blank line. Nim maps a trailing statement one line
  past EOF; without that line lcov aborts on `range`/`unmapped`, and `nimble
  coverage` deliberately suppresses no error so the failure stays visible.

## Scope

Public archive engine. The current scope is ZIP and ZIP64 Store/Deflate reading
and writing. Apache-2.0, DCO.
