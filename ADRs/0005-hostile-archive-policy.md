<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0005: Hostile archive policy

- Status: Accepted
- Date: 2026-08-21
- Scope: UniArchive

## Decision

ZIP parsing is a security boundary. A reader snapshots one bounded source and
validates runtime limits, redundant local/central metadata, descriptors,
ZIP64 fields, duplicate names and non-overlapping physical record intervals
before exposing payloads. Decode-time size and CRC checks remain mandatory.

Extraction accepts only regular files and directories with portable confined
paths. It stages the complete destination beside its final location and
publishes it only after every entry succeeds. Existing destinations, links,
special files and ambiguous paths are refused.

## Consequences

Some archives tolerated by permissive tools are rejected. In particular,
overlapping records and inconsistent redundant fields have no compatibility
mode because accepting them would make the byte interpretation ambiguous.
Nested archive extraction remains opt-in future work and must inherit one
shared budget rather than resetting limits at each layer.
