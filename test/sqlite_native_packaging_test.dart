import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Linux bundle resolves the SQLite hook after relocation', () async {
    final root = Directory.current;
    final directory = await Directory.systemTemp.createTemp(
      'nn-sqlite-packaging-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = Directory('${directory.path}/source')..createSync();
    final build = '${directory.path}/build';
    final bundle = '${directory.path}/bundle';
    final relocated = '${directory.path}/relocated';
    final policy = File(
      '${root.path}/linux/sqlite_native_assets.cmake',
    ).path.replaceAll('\\', '/');
    File('${source.path}/CMakeLists.txt').writeAsStringSync('''
cmake_minimum_required(VERSION 3.13)
project(sqlite_packaging_probe C)
add_library(sqlite3_flutter_libs_plugin SHARED sqlite.c)
include("$policy")
add_executable(probe probe.c)
target_link_libraries(probe PRIVATE sqlite3_flutter_libs_plugin \${CMAKE_DL_LIBS})
set_target_properties(probe PROPERTIES INSTALL_RPATH "\$ORIGIN/lib")
install(TARGETS probe RUNTIME DESTINATION .)
install(TARGETS sqlite3_flutter_libs_plugin LIBRARY DESTINATION lib)
''');
    File('${source.path}/sqlite.c').writeAsStringSync('''
int sqlite3_initialize(void) { return 42; }
''');
    File('${source.path}/probe.c').writeAsStringSync('''
#include <dlfcn.h>
#include <stdio.h>
extern int sqlite3_initialize(void);
int main(void) {
  if (sqlite3_initialize() != 42) return 1;
  void *library = dlopen("libsqlite3.so", RTLD_NOW | RTLD_LOCAL);
  if (!library) {
    fprintf(stderr, "%s\\n", dlerror());
    return 2;
  }
  int (*initialize)(void) = dlsym(library, "sqlite3_initialize");
  if (!initialize || initialize() != 42) return 3;
  dlclose(library);
  return 0;
}
''');

    Future<void> run(String executable, List<String> arguments) async {
      final result = await Process.run(
        executable,
        arguments,
        includeParentEnvironment: true,
        environment: const {'LD_LIBRARY_PATH': '', 'LD_PRELOAD': ''},
      );
      expect(
        result.exitCode,
        0,
        reason: '$executable $arguments\n${result.stdout}\n${result.stderr}',
      );
    }

    await run('cmake', ['-S', source.path, '-B', build]);
    await run('cmake', ['--build', build]);
    await run('cmake', ['--install', build, '--prefix', bundle]);
    await Directory(bundle).rename(relocated);
    await run('$relocated/probe', []);
    expect(File('$relocated/lib/libsqlite3.so').existsSync(), isTrue);
  }, skip: !Platform.isLinux);
}
