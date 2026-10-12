#include "linux_environment.h"

#include <glib.h>

void configure_linux_environment(const char* system_schema_dir) {
  const char* inherited = g_getenv("GSETTINGS_SCHEMA_DIR");
  if (inherited == nullptr ||
      g_strrstr(inherited, "/snap/code/") == nullptr) {
    return;
  }
  g_autofree char* compiled =
      g_build_filename(system_schema_dir, "gschemas.compiled", nullptr);
  if (!g_file_test(compiled, G_FILE_TEST_IS_REGULAR)) {
    return;
  }

  // VS Code Snap schemas belong to its runtime, not the host GTK libraries.
  // Set this before GTK/GIO caches its default schema source.
  g_setenv("GSETTINGS_SCHEMA_DIR", system_schema_dir, TRUE);
}
