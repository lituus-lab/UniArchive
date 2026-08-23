# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Bounded ZIP reads through the UniArchive C ABI."""
from ._core import create, entry_count, extract, names, read_entry, version as _version
__version__ = _version().decode("ascii")
def version():
    return _version().decode("ascii")
__all__ = ["create", "entry_count", "extract", "names", "read_entry", "version",
           "__version__"]
