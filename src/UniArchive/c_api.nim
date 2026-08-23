# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Stable C ABI for bounded ZIP inspection and entry reads.

import ../UniArchive

const UniArchiveVersionC: cstring = "0.1.0"

type ArchiveHandle = object
  reader: ArchiveReader

proc cstringArray(values: ptr UncheckedArray[cstring]; count: csize_t;
    output: var seq[string]): bool =
  if values == nil or count == 0 or count > csize_t(high(int)): return false
  output = newSeq[string](int(count))
  for index in 0 ..< int(count):
    if values[index] == nil: return false
    output[index] = $values[index]
  true

# A static build initializes the Nim runtime on first use; a shared build is
# initialized for it, by DllMain or an ELF constructor, and must not do it
# twice. Without this, anything reading the environment faults on Windows.
when defined(staticNoAutoInit):
  {.emit: """/*VARSECTION*/
void NimMain(void);
#ifdef _WIN32
#  include <windows.h>
static INIT_ONCE uar_runtime_once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK uar_runtime_init(PINIT_ONCE o, PVOID p, PVOID *c) {
  (void)o; (void)p; (void)c; NimMain(); return TRUE;
}
static void uar_runtime_ensure(void) {
  InitOnceExecuteOnce(&uar_runtime_once, uar_runtime_init, NULL, NULL);
}
#else
#  include <pthread.h>
static pthread_once_t uar_runtime_once = PTHREAD_ONCE_INIT;
static void uar_runtime_init(void) { NimMain(); }
static void uar_runtime_ensure(void) {
  pthread_once(&uar_runtime_once, uar_runtime_init);
}
#endif
""".}
  template ensureRuntime() =
    # One-time init, not a plain flag: a flag set before NimMain returns lets a
    # second thread run against a half-initialized runtime.
    {.emit: "  uar_runtime_ensure();".}
else:
  template ensureRuntime() = discard

{.push exportc, cdecl, dynlib.}

proc uar_open(path: cstring): pointer {.raises: [].} =
  ensureRuntime()
  if path == nil: return nil
  try:
    let handle = create(ArchiveHandle)
    try:
      handle.reader = openArchive($path)
      result = cast[pointer](handle)
    except Exception:
      reset(handle[])
      dealloc(handle)
  except Exception:
    result = nil

proc uar_close(opaque: pointer) {.raises: [].} =
  ensureRuntime()
  if opaque == nil: return
  let handle = cast[ptr ArchiveHandle](opaque)
  reset(handle[])
  dealloc(handle)

proc uar_handle_entry_count(opaque: pointer): int64 {.raises: [].} =
  ensureRuntime()
  if opaque == nil: return -1
  try: int64(cast[ptr ArchiveHandle](opaque).reader.entries.len)
  except Exception: -1

proc uar_handle_entry_name(opaque: pointer; index: csize_t;
    output: ptr UncheckedArray[char]; capacity: csize_t): int64 {.raises: [].} =
  ensureRuntime()
  if opaque == nil: return -1
  try:
    let entries = cast[ptr ArchiveHandle](opaque).reader.entries
    if index >= csize_t(entries.len): return -1
    let name = entries[int(index)].name
    if name.len > high(int64): return -1
    if output == nil or capacity <= csize_t(name.len): return int64(name.len)
    if name.len > 0: copyMem(output, unsafeAddr name[0], name.len)
    output[name.len] = '\0'
    int64(name.len)
  except Exception: -1

proc uar_handle_read_entry(opaque: pointer; name: cstring;
    output: ptr UncheckedArray[byte]; capacity: csize_t): int64 {.raises: [].} =
  ensureRuntime()
  if opaque == nil or name == nil: return -1
  try:
    let data = cast[ptr ArchiveHandle](opaque).reader.readEntry($name)
    if data.len > high(int64): return -1
    if output == nil or capacity < csize_t(data.len): return int64(data.len)
    if data.len > 0: copyMem(output, unsafeAddr data[0], data.len)
    int64(data.len)
  except Exception: -1

proc uar_entry_count(path: cstring): int64 {.raises: [].} =
  ensureRuntime()
  let handle = uar_open(path)
  if handle == nil: return -1
  defer: uar_close(handle)
  uar_handle_entry_count(handle)

proc uar_read_entry(path, name: cstring; output: ptr UncheckedArray[byte];
    capacity: csize_t): int64 {.raises: [].} =
  ensureRuntime()
  if path == nil or name == nil: return -1
  let handle = uar_open(path)
  if handle == nil: return -1
  defer: uar_close(handle)
  uar_handle_read_entry(handle, name, output, capacity)

proc uar_extract(path, destination: cstring): cint {.raises: [].} =
  ensureRuntime()
  if path == nil or destination == nil: return -1
  try:
    discard extractAll($path, $destination)
    0
  except Exception: -1

proc uar_extract_selected(path, destination: cstring;
    selectors: ptr UncheckedArray[cstring]; count: csize_t): cint {.raises: [].} =
  ensureRuntime()
  if path == nil or destination == nil: return -1
  try:
    var values: seq[string]
    if not cstringArray(selectors, count, values): return -1
    discard extractSelected($path, $destination, values)
    0
  except Exception: -1

proc uar_create_zip(output: cstring; inputs: ptr UncheckedArray[cstring];
    count: csize_t; store: cint): cint {.raises: [].} =
  ensureRuntime()
  if output == nil or (store != 0 and store != 1): return -1
  try:
    var paths: seq[string]
    if not cstringArray(inputs, count, paths): return -1
    createZipFromPaths($output, paths, if store == 1: zmStore else: zmDeflate)
    0
  except Exception: -1

proc uar_version(): cstring {.raises: [].} = UniArchiveVersionC

{.pop.}

