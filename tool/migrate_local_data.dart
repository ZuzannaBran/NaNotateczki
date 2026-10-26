import 'dart:convert';
import 'dart:io';

import 'package:program/core/storage/app_data_directory_io.dart';

Future<void> main(List<String> arguments) async {
  final support = _argument(arguments, '--support');
  final legacy = _argument(arguments, '--legacy');
  _validatePath(support);
  _validatePath(legacy);
  final report = await migrateNativeAppData(
    supportPath: support,
    legacyDocumentsPath: legacy,
  );
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'dataPath': report.dataPath,
      'migratedCount': report.migratedPaths.length,
      'conflictingPaths': report.conflictingPaths,
    }),
  );
  if (report.hasConflicts) {
    exitCode = 2;
  }
}

String _argument(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) {
    throw ArgumentError('Required argument: $name <absolute path>');
  }
  return arguments[index + 1];
}

void _validatePath(String path) {
  if (!path.startsWith('/') ||
      path == '/' ||
      path == Platform.environment['HOME']) {
    throw ArgumentError.value(
      path,
      'path',
      'Use a specific absolute directory.',
    );
  }
}
