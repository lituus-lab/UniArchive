# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Author py/notebooks/quickstart.ipynb, then execute it so the committed file
carries real outputs for GitHub to render. Run from the repo root:

    python3 py/notebooks/build_quickstart.py

CI re-executes the notebook against an installed wheel; this script only
regenerates it after an API change."""
import os

import nbformat as nbf
from nbclient import NotebookClient

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(HERE, "quickstart.ipynb")

CELLS = [
    ("md", """# UniArchive — Python quickstart

`uniarchive` is a Cython extension over the UniArchive C ABI, shipped as a
self-contained wheel: the native library travels inside the package, so
installing it needs neither Nim nor a compiler.

```
pip install lituus-uniarchive
```

CI executes this notebook against the wheel the release actually publishes, so
an output below that stops matching fails the build."""),
    ("md", """## Creating an archive

`create` takes an output path and the paths to archive. It never replaces an
existing output — a caller that wants replacement removes the file first."""),
    ("code", """import os, tempfile, uniarchive

work = tempfile.mkdtemp()
os.chdir(work)
os.makedirs("data", exist_ok=True)
open("notes.txt", "w").write("one\\n")
open("data/values.csv", "w").write("a,b\\n1,2\\n")

uniarchive.create("demo.zip", ["notes.txt", "data"])
uniarchive.version(), os.path.getsize("demo.zip")"""),
    ("md", "## Inspecting it"),
    ("code", """{
    "entries": uniarchive.entry_count("demo.zip"),
    "names": uniarchive.names("demo.zip"),
    "notes.txt": uniarchive.read_entry("demo.zip", "notes.txt"),
}"""),
    ("md", """## Extraction is transactional

Every payload is verified in a private staging tree; the destination appears
only once the whole archive has succeeded. Selectors pick exact files or whole
subtrees."""),
    ("code", """uniarchive.extract("demo.zip", "out")
sorted(os.path.relpath(os.path.join(r, f), "out")
       for r, _, fs in os.walk("out") for f in fs)"""),
    ("code", """uniarchive.extract("demo.zip", "partial", ["notes.txt"])
sorted(os.listdir("partial"))"""),
    ("md", "## A refused output"),
    ("code", """try:
    uniarchive.create("demo.zip", ["notes.txt"])
except Exception as exc:
    print(type(exc).__name__ + ":", exc)"""),
]


def main():
    nb = nbf.v4.new_notebook()
    nb.cells = [
        nbf.v4.new_markdown_cell(src) if kind == "md" else nbf.v4.new_code_cell(src)
        for kind, src in CELLS
    ]
    nb.metadata["kernelspec"] = {
        "display_name": "Python 3",
        "language": "python",
        "name": "python3",
    }
    # Execute from the repo root, never from py/: there, `import uniarchive`
    # would resolve to the py/uniarchive source tree instead of the installed
    # package, and the notebook would stop testing what it claims to test.
    NotebookClient(nb, timeout=120, kernel_name="python3",
                   resources={"metadata": {"path": ROOT}}).execute()
    with open(OUT, "w") as f:
        nbf.write(nb, f)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
