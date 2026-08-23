# cython: language_level=3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
from libc.stdint cimport uint8_t, int64_t
from libc.stddef cimport size_t
from cpython.bytearray cimport PyByteArray_AS_STRING
from cpython.mem cimport PyMem_Free, PyMem_Malloc

cdef extern from "UniArchive.h":
    ctypedef struct uar_archive_t:
        pass
    uar_archive_t *uar_open(const char *)
    void uar_close(uar_archive_t *)
    int64_t uar_handle_entry_count(uar_archive_t *)
    int64_t uar_handle_entry_name(uar_archive_t *, size_t, char *, size_t)
    int64_t uar_handle_read_entry(uar_archive_t *, const char *, uint8_t *, size_t)
    int64_t uar_entry_count(const char *)
    int64_t uar_read_entry(const char *, const char *, uint8_t *, size_t)
    int uar_extract(const char *, const char *)
    int uar_extract_selected(const char *, const char *, const char **, size_t)
    int uar_create_zip(const char *, const char **, size_t, int)
    const char *uar_version()

def entry_count(str path):
    cdef bytes encoded = path.encode()
    cdef uar_archive_t *handle = uar_open(encoded)
    cdef int64_t count
    if handle == NULL: raise ValueError("archive could not be opened")
    try:
        count = uar_handle_entry_count(handle)
        if count < 0: raise ValueError("archive could not be opened")
        return count
    finally:
        uar_close(handle)

def read_entry(str path, str name):
    cdef bytes encoded_path = path.encode()
    cdef bytes encoded_name = name.encode()
    cdef uar_archive_t *handle = uar_open(encoded_path)
    cdef int64_t needed
    cdef bytearray output
    cdef int64_t written
    if handle == NULL: raise ValueError("archive could not be opened")
    try:
        needed = uar_handle_read_entry(handle, encoded_name, NULL, 0)
        if needed < 0: raise ValueError("entry could not be read")
        output = bytearray(needed)
        written = uar_handle_read_entry(handle, encoded_name,
            <uint8_t *>PyByteArray_AS_STRING(output), needed)
        if written != needed: raise ValueError("entry could not be read")
        return bytes(output)
    finally:
        uar_close(handle)

def names(str path):
    cdef bytes encoded = path.encode()
    cdef uar_archive_t *handle = uar_open(encoded)
    cdef int64_t count
    cdef int64_t needed
    cdef bytearray output
    cdef list result = []
    cdef int64_t index
    if handle == NULL: raise ValueError("archive could not be opened")
    try:
        count = uar_handle_entry_count(handle)
        if count < 0: raise ValueError("archive could not be opened")
        for index in range(count):
            needed = uar_handle_entry_name(handle, <size_t>index, NULL, 0)
            if needed < 0: raise ValueError("entry name could not be read")
            output = bytearray(needed + 1)
            if uar_handle_entry_name(handle, <size_t>index,
                    PyByteArray_AS_STRING(output), needed + 1) != needed:
                raise ValueError("entry name could not be read")
            result.append(bytes(output[:needed]).decode("utf-8"))
        return result
    finally:
        uar_close(handle)

def extract(str path, str destination, selectors=None):
    cdef bytes encoded_path = path.encode()
    cdef bytes encoded_destination = destination.encode()
    cdef list encoded_selectors
    cdef const char **raw = NULL
    cdef Py_ssize_t index
    cdef bytes value
    if selectors is None:
        if uar_extract(encoded_path, encoded_destination) != 0:
            raise ValueError("archive could not be extracted")
        return
    encoded_selectors = [str(selector).encode() for selector in selectors]
    if not encoded_selectors: raise ValueError("selectors cannot be empty")
    raw = <const char **>PyMem_Malloc(len(encoded_selectors) * sizeof(char *))
    if raw == NULL: raise MemoryError()
    try:
        for index in range(len(encoded_selectors)):
            value = encoded_selectors[index]
            raw[index] = value
        if uar_extract_selected(encoded_path, encoded_destination, raw,
                len(encoded_selectors)) != 0:
            raise ValueError("archive could not be extracted")
    finally:
        PyMem_Free(raw)

def create(str output, inputs, bint store=False):
    cdef bytes encoded_output = output.encode()
    cdef list encoded_inputs = [str(path).encode() for path in inputs]
    cdef const char **raw = NULL
    cdef Py_ssize_t index
    cdef bytes value
    if not encoded_inputs: raise ValueError("inputs cannot be empty")
    raw = <const char **>PyMem_Malloc(len(encoded_inputs) * sizeof(char *))
    if raw == NULL: raise MemoryError()
    try:
        for index in range(len(encoded_inputs)):
            value = encoded_inputs[index]
            raw[index] = value
        if uar_create_zip(encoded_output, raw, len(encoded_inputs),
                1 if store else 0) != 0:
            raise ValueError("archive could not be created")
    finally:
        PyMem_Free(raw)

def version():
    return uar_version()
