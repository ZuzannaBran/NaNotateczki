# The native asset hook resolves libsqlite3.so, including in Drift isolates.
set_target_properties(sqlite3_flutter_libs_plugin PROPERTIES OUTPUT_NAME sqlite3)
