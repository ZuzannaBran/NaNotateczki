#include <glib.h>
#include <glib/gstdio.h>

#include "../../linux/runner/linux_environment.h"

namespace {

char* schema_dir;

void restores_system_schemas_from_code_snap() {
  g_setenv("GSETTINGS_SCHEMA_DIR",
           "/home/user/snap/code/268/.local/share/glib-2.0/schemas", TRUE);
  configure_linux_environment(schema_dir);
  g_assert_cmpstr(g_getenv("GSETTINGS_SCHEMA_DIR"), ==, schema_dir);
}

void restores_system_schemas_from_snap_install() {
  g_setenv("GSETTINGS_SCHEMA_DIR",
           "/snap/code/268/usr/share/glib-2.0/schemas", TRUE);
  configure_linux_environment(schema_dir);
  g_assert_cmpstr(g_getenv("GSETTINGS_SCHEMA_DIR"), ==, schema_dir);
}

void preserves_explicit_schema_directory() {
  g_setenv("GSETTINGS_SCHEMA_DIR", "/opt/notatek/schemas", TRUE);
  configure_linux_environment(schema_dir);
  g_assert_cmpstr(g_getenv("GSETTINGS_SCHEMA_DIR"), ==,
                  "/opt/notatek/schemas");
}

void preserves_other_snap_schema_directory() {
  g_setenv("GSETTINGS_SCHEMA_DIR", "/snap/notatek/current/schemas", TRUE);
  configure_linux_environment(schema_dir);
  g_assert_cmpstr(g_getenv("GSETTINGS_SCHEMA_DIR"), ==,
                  "/snap/notatek/current/schemas");
}

void preserves_default_environment() {
  g_unsetenv("GSETTINGS_SCHEMA_DIR");
  configure_linux_environment(schema_dir);
  g_assert_null(g_getenv("GSETTINGS_SCHEMA_DIR"));
}

void does_not_select_missing_system_schemas() {
  const char* inherited = "/snap/code/268/schemas";
  g_setenv("GSETTINGS_SCHEMA_DIR", inherited, TRUE);
  g_autofree char* missing = g_build_filename(schema_dir, "missing", nullptr);
  configure_linux_environment(missing);
  g_assert_cmpstr(g_getenv("GSETTINGS_SCHEMA_DIR"), ==, inherited);
}

}  // namespace

int main(int argc, char** argv) {
  g_test_init(&argc, &argv, nullptr);
  g_autofree char* previous = g_strdup(g_getenv("GSETTINGS_SCHEMA_DIR"));
  schema_dir = g_dir_make_tmp("nanotateczki-linux-env-XXXXXX", nullptr);
  g_assert_nonnull(schema_dir);
  g_autofree char* compiled =
      g_build_filename(schema_dir, "gschemas.compiled", nullptr);
  g_assert_true(g_file_set_contents(compiled, "fixture", -1, nullptr));

  g_test_add_func("/linux/environment/code-snap",
                  restores_system_schemas_from_code_snap);
  g_test_add_func("/linux/environment/snap-install",
                  restores_system_schemas_from_snap_install);
  g_test_add_func("/linux/environment/explicit",
                  preserves_explicit_schema_directory);
  g_test_add_func("/linux/environment/other-snap",
                  preserves_other_snap_schema_directory);
  g_test_add_func("/linux/environment/default", preserves_default_environment);
  g_test_add_func("/linux/environment/missing",
                  does_not_select_missing_system_schemas);
  const int result = g_test_run();
  if (previous != nullptr) {
    g_setenv("GSETTINGS_SCHEMA_DIR", previous, TRUE);
  } else {
    g_unsetenv("GSETTINGS_SCHEMA_DIR");
  }
  g_assert_cmpint(g_remove(compiled), ==, 0);
  g_assert_cmpint(g_rmdir(schema_dir), ==, 0);
  g_free(schema_dir);
  return result;
}
