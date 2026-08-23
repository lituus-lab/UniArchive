// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "UniArchive.h"

/* Self-contained: writes a file, archives it, then reads it back through the
 * ABI. Takes no argument, so `make run` needs no fixture. */
int main(void) {
  const char *source = "demo_payload.txt";
  const char *archive = "demo_archive.zip";
  const char *text = "UniArchive demo payload\n";

  remove(archive); /* uar_create_zip refuses to replace an existing output. */
  FILE *f = fopen(source, "wb");
  if (f == NULL) return 1;
  fwrite(text, 1, strlen(text), f);
  fclose(f);

  const char *inputs[] = {source};
  if (uar_create_zip(archive, inputs, 1, 0) != 0) return 2;

  int64_t count = uar_entry_count(archive);
  if (count < 0) return 3;
  printf("UniArchive %s\n", uar_version());
  printf("entries: %lld\n", (long long)count);

  /* NULL output asks for the size first, as every read entry point does. */
  int64_t needed = uar_read_entry(archive, source, NULL, 0);
  if (needed < 0) return 4;
  uint8_t buffer[128];
  if ((size_t)needed > sizeof buffer) return 5;
  if (uar_read_entry(archive, source, buffer, sizeof buffer) != needed) return 6;
  printf("read back %lld bytes: %.*s", (long long)needed, (int)needed, buffer);

  remove(source);
  remove(archive);
  return 0;
}
