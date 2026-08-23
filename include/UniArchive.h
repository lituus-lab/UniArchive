// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
#ifndef UNIARCHIVE_H
#define UNIARCHIVE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define UNIARCHIVE_VERSION "0.1.0"
typedef struct uar_archive uar_archive_t;
/* Open one validated immutable snapshot, or return NULL. */
uar_archive_t *uar_open(const char *path);
/* Release a handle; NULL is accepted. */
void uar_close(uar_archive_t *archive);
/* Return the validated entry count, or -1 for an invalid handle. */
int64_t uar_handle_entry_count(uar_archive_t *archive);
/* Copy an indexed UTF-8 name and NUL terminator; NULL queries name bytes. */
int64_t uar_handle_entry_name(uar_archive_t *archive, size_t index,
  char *output, size_t capacity);
/* Read twice from the same snapshot; NULL output queries the required size. */
int64_t uar_handle_read_entry(uar_archive_t *archive, const char *name,
  uint8_t *output, size_t capacity);
/* Return the entry count, or -1 if the bounded reader rejects the archive. */
int64_t uar_entry_count(const char *path);
/* Return bytes required/written, or -1 when the entry cannot be verified. */
int64_t uar_read_entry(const char *path, const char *name,
  uint8_t *output, size_t capacity);
/* Transactionally extract into a destination that must not exist. */
int uar_extract(const char *path, const char *destination);
/* Extract the union of exact files and directory subtrees. */
int uar_extract_selected(const char *path, const char *destination,
  const char *const *selectors, size_t count);
/* Create a new recursive ZIP; store is 0 for Deflate or 1 for Store. */
int uar_create_zip(const char *output, const char *const *inputs,
  size_t count, int store);
/* Return a process-lifetime version string. */
const char *uar_version(void);
#ifdef __cplusplus
}
#endif
#endif
