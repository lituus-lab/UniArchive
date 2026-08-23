#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
set -eu
test "$(bsdtar -tf "$1")" = "stored.txt
deflated.txt"
