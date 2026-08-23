# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Resolve local lower-layer engines during family development.
switch("path", "../UniChecksum/src")
switch("path", "../UniCompress/src")
# when defined(amd64) and not defined(scalarUniArchive):
#   switch("passC", "-ffp-contract=off")
