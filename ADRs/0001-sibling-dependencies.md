<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0001: Two sibling dependencies, and nothing above them

- Status: Accepted
- Date: 2026-08-23
- Scope: UniArchive

## Decision

UniArchive depends on exactly two libraries of the family: UniCompress for the
DEFLATE payloads a ZIP entry carries, and UniChecksum for the CRC-32 every
entry is verified against. Nothing else is admitted.

Both sit below this repo, and neither knows what an archive is. Depending on a
consumer — anything that reads archives to get at their contents — would close
a cycle. `vgraph.cfg` lists those two as the only allowed engines, and
`nimble checkVGraph` fails the build on any other `requires` line naming a
`Uni*` package.

## Consequences

Reading and writing are expressed over byte spans, paths and integers. A codec
belongs in UniCompress, an integrity primitive in UniChecksum; neither is
reimplemented here, so a bug in either is fixed once.

Inside `src/`, the order is `zip` < `extract` < `create` < `c_api`: records and
bounds first, then extraction, then writing, then the foreign boundary. The
layer check rejects an import that climbs that order; it is one-way, so it
constrains what may reach upward, not what a lower module may reuse.
