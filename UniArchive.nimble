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

task lint, "Fail if nimpretty would reformat a source":
  exec "nim c -r --hints:off -o:build/lint_tool tools/lint.nim"

task checkVGraph, "Fail on an import that climbs the layers in vgraph.cfg":
  exec "nim c -r --hints:off -o:build/vgraph_tool tools/vgraph.nim"

task docsDeps, "Install the docs toolchain (nimib)":
  exec "nimble install -y nimib"

task book, "Build the nimib book (needs nimib)":
  # nimib compiles and runs the book's code blocks: a drift fails the build.
  exec "nim c -r --path:src --hints:off -o:build/book book/index.nim"

task docs, "API reference + book into pages/ — what CI publishes":
  rmDir "pages"
  exec "nim doc --index:on --outdir:pages/api --project --hints:off src/UniArchive.nim"
  exec "nimble book"
  # The book is the landing page; the generated reference sits under api/.
  cpFile "book/index.html", "pages/index.html"

task test, "Nim tests (debug, contracts active)":
  exec "nim c -r --path:src -o:build/test_zip tests/test_zip.nim"

task testRelease, "Nim tests (release, contracts compiled away)":
  exec "nim c -r -d:release --path:src -o:build/test_zip_rel tests/test_zip.nim"

task testCi, "Nim tests (CI subset, debug)":
  exec "nim c -r --path:src -o:build/test_zip tests/test_zip.nim"

task testCiRelease, "Nim tests (CI subset, release)":
  exec "nim c -r -d:release --path:src -o:build/test_zip_rel tests/test_zip.nim"

task testAll, "debug + release + C ABI":
  exec "nimble test"
  exec "nimble testRelease"
  exec "nimble ctest"

task example, "Nim demo":
  exec "nim c -r --path:src -o:build/demo examples/demo.nim"

task cli, "Build the safe uniarchive command-line tool":
  exec "nim c -d:release --path:src -o:build/uniarchive src/uniarchive_cli.nim"

task benchmark, "Run ZIP creation benchmark":
  exec "nim c -d:release -r --path:src -o:build/bench_zip benchmarks/bench_zip.nim"

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

task clibStatic, "C static library":
  exec "nim c --app:staticlib --noMain --mm:arc -d:release -d:staticNoAutoInit -o:" & staticLib &
       " src/UniArchive/c_api.nim"

task clibMsvc, "C static library, MSVC ABI (Windows Python extension)":
  # CPython on Windows is MSVC-built and cannot link MinGW output.
  exec "nim c --cc:vcc --app:staticlib --noMain --mm:arc -d:release -d:staticNoAutoInit" &
       " -o:UniArchive.lib src/UniArchive/c_api.nim"

# Nim's MinGW toolchain names it mingw32-make.
let makeExe = if findExe("mingw32-make").len > 0: "mingw32-make" else: "make"

# `make -C`, not `cd dir && make`: nimble's exec runs no shell on Windows.
task ctest, "C ABI tests":
  exec "nimble clibStatic"
  exec makeExe & " -C tests/c"

task cexample, "C demo":
  exec "nimble clibStatic"
  exec makeExe & " -C examples/c"

# `python3` is not on PATH on Windows: actions/setup-python puts `python.exe`
# there, and the Store shim answers `python3` with an installer prompt.
const pythonExe = when defined(windows): "python" else: "python3"

task pyDeps, "Install Python build deps (setuptools, Cython, pytest) if missing":
  exec pythonExe & " -m pip install --break-system-packages --quiet setuptools wheel \"Cython>=3.0.0\" pytest"

# The extension links the vcc static lib on Windows, the shared lib elsewhere.
task pyLib, "Build the library the Python extension links against":
  when defined(windows):
    exec "nimble clibMsvc"
  else:
    exec "nimble clib"

task buildCython, "Cython extension in-place":
  exec "nimble pyLib"
  exec "nimble pyDeps"
  withDir "py":
    exec pythonExe & " setup.py build_ext --inplace"

task pyTest, "Cython extension + pytest":
  exec "nimble buildCython"
  withDir "py":
    exec pythonExe & " -m pytest -q"

task pyWheel, "wheel":
  exec "nimble pyLib"
  exec "nimble pyDeps"
  withDir "py":
    exec pythonExe & " setup.py bdist_wheel"

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
