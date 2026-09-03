# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# UniArchive — archive containers for the lituus-lab Uni* family.

version       = "0.1.0"
author        = "lituus-lab"
description   = "Bounded pure-Nim ZIP archive engine (Nim + C-ABI + Python)"
license       = "Apache-2.0"
srcDir        = "src"

requires "nim >= 2.0.0"
requires "https://github.com/lbartoletti/NimContracts#main"
requires "https://github.com/lituus-lab/UniChecksum#main"
requires "https://github.com/lituus-lab/UniCompress#main"

# nimble 0.22 exits 0 even when an `exec` inside a task fails, so a task's exit
# code says nothing about whether its body ran. Each task writes a marker as
# its last statement; `tools/gate.nim` removes the marker, runs the task, and
# fails if it is not there afterwards. `nimble canary` proves the gate still
# bites -- if that one ever passes, every other green result is worthless.
const gateExe =
  when defined(windows): "build/unigate.exe" else: "build/unigate"

template done(task: string) =
  mkDir "build/.gate"
  writeFile("build/.gate/" & task & ".ok", "")

proc gate(task: string): string =
  ## `exec gate("test")` -- builds the tool on first use.
  if not fileExists(gateExe):
    exec "nim c --hints:off -o:" & gateExe & " tools/gate.nim"
  gateExe & " " & task

task canary, "Must fail: proves the gate still catches a broken build":
  # No `done` here on purpose: the exec below raises, so the marker is never
  # written and the gate reports the failure nimble swallowed.
  exec "nim c -r --hints:off --path:src -o:build/canary tests/canary_broken.nim"

task lint, "Fail if nimpretty would reformat a source":
  exec "nim c -r --hints:off -o:build/lint_tool tools/lint.nim"
  done "lint"

task checkVGraph, "Fail on an import that climbs the layers in vgraph.cfg":
  exec "nim c -r --hints:off -o:build/vgraph_tool tools/vgraph.nim"
  done "checkVGraph"

task docsDeps, "Install the docs toolchain (nimib)":
  exec "nimble install -y nimib"
  done "docsDeps"

task book, "Build the nimib book (needs nimib)":
  # nimib compiles and runs the book's code blocks: a drift fails the build.
  exec "nim c -r --path:src --hints:off -o:build/book book/index.nim"
  done "book"

task docs, "API reference + book into pages/ — what CI publishes":
  rmDir "pages"
  exec "nim doc --index:on --outdir:pages/api --project --hints:off src/UniArchive.nim"
  exec gate("book")
  # The book is the landing page; the generated reference sits under api/.
  cpFile "book/index.html", "pages/index.html"
  done "docs"

task test, "Nim tests (debug, contracts active)":
  exec "nim c -r --path:src -o:build/test_zip tests/test_zip.nim"
  done "test"

task testRelease, "Nim tests (release, contracts compiled away)":
  exec "nim c -r -d:release --path:src -o:build/test_zip_rel tests/test_zip.nim"
  done "testRelease"

task testCi, "Nim tests (CI subset, debug)":
  exec "nim c -r --path:src -o:build/test_zip tests/test_zip.nim"
  done "testCi"

task testCiRelease, "Nim tests (CI subset, release)":
  exec "nim c -r -d:release --path:src -o:build/test_zip_rel tests/test_zip.nim"
  done "testCiRelease"

task testAll, "debug + release + C ABI":
  exec gate("test")
  exec gate("testRelease")
  exec gate("ctest")
  done "testAll"

task example, "Nim demo":
  exec "nim c -r --path:src -o:build/demo examples/demo.nim"
  done "example"

task cli, "Build the safe uniarchive command-line tool":
  exec "nim c -d:release --path:src -o:build/uniarchive src/uniarchive_cli.nim"
  done "cli"

task benchmark, "Run ZIP creation benchmark":
  exec "nim c -d:release -r --path:src -o:build/bench_zip benchmarks/bench_zip.nim"
  done "benchmark"

task oracle, "Check writer output with Python zipfile and libarchive":
  # Writing a ZIP never replaces an existing file, by design — so every output
  # left by a previous run has to go first, or the task only ever succeeds once.
  for stale in ["oracle.zip", "oracle64.zip", "writer64.zip", "many64.zip",
                "descriptor.zip"]:
    rmFile "build/" & stale
  exec "nim c -r --path:src -o:build/generate_zip tests/oracles/generate_zip.nim build/oracle.zip"
  exec "python3 tests/oracles/check_python_zipfile.py build/oracle.zip comments"
  exec "sh tests/oracles/check_libarchive.sh build/oracle.zip"
  exec "python3 tests/oracles/generate_zip64.py build/oracle64.zip"
  exec "nim c -r --path:src -o:build/check_zip tests/oracles/check_zip.nim build/oracle64.zip"
  exec "nim c -r --path:src -o:build/generate_forced_zip64" &
       " tests/oracles/generate_forced_zip64.nim build/writer64.zip"
  exec "python3 tests/oracles/check_python_zipfile.py build/writer64.zip"
  exec "sh tests/oracles/check_libarchive.sh build/writer64.zip"
  exec "nim c -d:release -r --path:src -o:build/generate_many_zip64" &
       " tests/oracles/generate_many_zip64.nim build/many64.zip"
  exec "python3 tests/oracles/check_many_zip64.py build/many64.zip"
  exec "python3 tests/oracles/generate_descriptor.py build/descriptor.zip"
  exec "nim c -r --path:src -o:build/check_descriptor" &
       " tests/oracles/check_descriptor.nim build/descriptor.zip"
  done "oracle"

# Nim takes `-o:` literally and appends no platform extension.
const
  sharedLib =
    when defined(windows): "libUniArchive.dll"
    elif defined(macosx): "libUniArchive.dylib"
    else: "libUniArchive.so"
  staticLib = "libUniArchive.a"  # MinGW `ar` on Windows, so `.a` everywhere.

  # @rpath install_name, so the copy bundled in the wheel is found at import.
  macArgs =
    when defined(macosx): " --passL:\"-Wl,-install_name,@rpath/" & sharedLib & "\""
    else: ""

task clib, "C shared library":
  exec "nim c --app:lib --noMain --mm:arc -d:release -o:" & sharedLib & macArgs &
       " src/UniArchive/c_api.nim"
  done "clib"

task clibStatic, "C static library":
  exec "nim c --app:staticlib --noMain --mm:arc -d:release -d:staticNoAutoInit -o:" & staticLib &
       " src/UniArchive/c_api.nim"
  done "clibStatic"

task clibMsvc, "C static library, MSVC ABI (Windows Python extension)":
  # CPython on Windows is MSVC-built and cannot link MinGW output.
  exec "nim c --cc:vcc --app:staticlib --noMain --mm:arc -d:release -d:staticNoAutoInit" &
       " -o:UniArchive.lib src/UniArchive/c_api.nim"
  done "clibMsvc"

# Nim's MinGW toolchain names it mingw32-make.
let makeExe = if findExe("mingw32-make").len > 0: "mingw32-make" else: "make"

# `make -C`, not `cd dir && make`: nimble's exec runs no shell on Windows.
task ctest, "C ABI tests":
  exec gate("clibStatic")
  exec makeExe & " -C tests/c"
  done "ctest"

task cexample, "C demo":
  exec gate("clibStatic")
  exec makeExe & " -C examples/c"
  done "cexample"

# `python3` is not on PATH on Windows: actions/setup-python puts `python.exe`
# there, and the Store shim answers `python3` with an installer prompt.
const pythonExe = when defined(windows): "python" else: "python3"

task pyDeps, "Install Python build deps (setuptools, Cython, pytest) if missing":
  exec pythonExe & " -m pip install --break-system-packages --quiet setuptools wheel \"Cython>=3.0.0\" pytest"
  done "pyDeps"

# The extension links the vcc static lib on Windows, the shared lib elsewhere.
task pyLib, "Build the library the Python extension links against":
  when defined(windows):
    exec gate("clibMsvc")
  else:
    exec gate("clib")
  done "pyLib"

task buildCython, "Cython extension in-place":
  exec gate("pyLib")
  exec gate("pyDeps")
  withDir "py":
    exec pythonExe & " setup.py build_ext --inplace"
  done "buildCython"

task pyTest, "Cython extension + pytest":
  exec gate("buildCython")
  withDir "py":
    exec pythonExe & " -m pytest -q"
  done "pyTest"

task pyWheel, "wheel":
  exec gate("pyLib")
  exec gate("pyDeps")
  withDir "py":
    exec pythonExe & " setup.py bdist_wheel"
  done "pyWheel"

task coverage, "LCOV + HTML coverage report for the Nim sources (needs lcov)":
  # gcov and lcov driven directly, no coco. Linux and macOS only.
  # --debugger:native attributes lines to the .nim sources, not the generated C.
  # --include keeps stdlib out of the capture, where lcov 2.x aborts on Nim's
  # codegen. Together they leave nothing to suppress: no --ignore-errors here,
  # so a real problem still fails the build.
  let cache = "build/covcache"
  rmDir cache
  rmDir "coverage"
  exec "nim c --path:src --nimcache:" & cache &
       " --debugger:native --passC:--coverage --passL:--coverage" &
       " -o:build/test_coverage tests/test_zip.nim"
  exec "./build/test_coverage"
  exec "lcov --capture --directory " & cache & " --base-directory ." &
       " --include \"*/src/UniArchive/*\" --output-file lcov.info --quiet"
  exec "genhtml lcov.info --output-directory coverage --legend --quiet"
  exec "lcov --summary lcov.info"
  done "coverage"
