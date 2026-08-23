<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0004: Public surfaces

- Status: Accepted
- Date: 2026-08-21
- Scope: UniArchive

## Decision

The Nim API is authoritative. The C ABI uses the `uar_` prefix and the Python
binding delegates to that ABI. Reader capabilities and resource policies stay
explicit; container implementations are not forced into a random-access API.
