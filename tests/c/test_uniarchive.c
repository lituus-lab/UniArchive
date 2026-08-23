// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#  include <direct.h>
#  define uar_rmdir _rmdir
#else
#  include <unistd.h>
#  define uar_rmdir rmdir
#endif
#include "UniArchive.h"

/* Extraction never publishes over an existing destination, so a second run
 * would fail on the first one's leftovers. Clear them before each attempt. */
static void clear_destination(const char *dir, const char *entry) {
  char path[256];
  snprintf(path, sizeof path, "%s/%s", dir, entry);
  remove(path);
  uar_rmdir(dir);
}

/* Refusal paths: every entry point must reject NULL without touching it. */
static int refusals(void) {
  if (strcmp(uar_version(), UNIARCHIVE_VERSION) != 0) return 1;
  if (uar_entry_count("missing.zip") != -1) return 2;
  if (uar_open("missing.zip") != NULL) return 3;
  if (uar_handle_entry_count(NULL) != -1) return 4;
  if (uar_handle_read_entry(NULL, "entry", NULL, 0) != -1) return 5;
  if (uar_handle_entry_name(NULL, 0, NULL, 0) != -1) return 6;
  if (uar_extract(NULL, "output") != -1) return 7;
  if (uar_extract_selected(NULL, "output", NULL, 0) != -1) return 8;
  if (uar_create_zip(NULL, NULL, 0, 0) != -1) return 9;
  uar_close(NULL);
  return 0;
}

/* A full round trip. Without this the suite only ever exercised the guards,
 * so no successful operation was covered from C at all. */
static int round_trip(void) {
  const char *source = "cabi_payload.txt";
  const char *archive = "cabi_archive.zip";
  const char *text = "UniArchive C ABI payload\n";
  const size_t length = 25;

  remove(archive);
  FILE *f = fopen(source, "wb");
  if (f == NULL) return 20;
  if (fwrite(text, 1, length, f) != length) { fclose(f); return 21; }
  fclose(f);

  const char *inputs[] = {source};
  if (uar_create_zip(archive, inputs, 1, 0) != 0) return 22;
  if (uar_entry_count(archive) != 1) return 23;

  uar_archive_t *handle = uar_open(archive);
  if (handle == NULL) return 24;
  char name[64];
  int64_t named = uar_handle_entry_name(handle, 0, name, sizeof name);
  if (named <= 0) { uar_close(handle); return 25; }
  int64_t got = uar_handle_read_entry(handle, source, NULL, 0);
  uar_close(handle);
  if (got != (int64_t)length) return 26;

  uint8_t buffer[64];
  if (uar_read_entry(archive, source, buffer, sizeof buffer) != (int64_t)length)
    return 27;
  if (memcmp(buffer, text, length) != 0) return 28;

  /* Extraction, the one path Python was the only caller of. */
  clear_destination("cabi_out", source);
  if (uar_extract(archive, "cabi_out") != 0) return 29;
  clear_destination("cabi_out_selected", source);
  const char *selectors[] = {source};
  if (uar_extract_selected(archive, "cabi_out_selected", selectors, 1) != 0)
    return 30;

  remove(source);
  remove(archive);
  return 0;
}

int main(void) {
  int code = refusals();
  if (code != 0) { printf("refusal check failed: %d\n", code); return code; }
  code = round_trip();
  if (code != 0) { printf("round trip failed: %d\n", code); return code; }
  puts("All C ABI tests passed.");
  return 0;
}
