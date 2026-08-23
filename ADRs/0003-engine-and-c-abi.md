<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0003: Engine, C ABI and CLI

- Status: Accepted
- Date: 2026-08-23
- Scope: UniArchive

## Decision

The Nim library is the engine and the source of truth. A thin C ABI
(`src/UniArchive/c_api.nim`) built `--app:staticlib`/`--app:lib --noMain
--mm:arc -d:release` produces `libUniArchive.a` / `libUniArchive.so`, and the
hand-written `include/UniArchive.h` is kept in sync with it by hand.

`tests/c` links that header against the built library on every CI run, so a
renamed or retyped symbol fails to link rather than shipping. The generated
`--header:` output is deliberately not used: it tracks Nim's codegen rather
than the contract we mean to promise.

`--mm:arc` gives foreign callers a deterministic memory model with no cycle
collector; `--noMain` means C does not have to call `NimMain()`.

The CLI (`src/uniarchive_cli.nim`) is a front end over the same engine, not a
second implementation. It exists because inspecting and extracting an archive
is something one does from a shell, and because a hostile archive is easier to
reason about when the tool that opens it enforces the same ceilings the library
does.

## Call shape

Reading entry points are asked twice: once with a null output pointer, which
returns the number of bytes the result needs, then again with a buffer of that
size. A negative return means the archive was refused — a failed check, a
budget exceeded, a malformed record — and the caller is told nothing more,
because an exception must never unwind across the ABI boundary.

Writing never replaces an existing path. That is a property of the engine, not
of the CLI: a caller that wants replacement removes the file itself, so no
entry point can destroy data by default.
