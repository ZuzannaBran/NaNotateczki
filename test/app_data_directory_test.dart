import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/storage/app_data_directory.dart';

void main() {
  test(
    'creates an empty protected layout when the legacy directory is absent',
    () async {
      final sandbox = await Directory.systemTemp.createTemp('app-data-empty-');
      addTearDown(() => sandbox.delete(recursive: true));

      final report = await prepareAppDataDirectory(
        supportPath: '${sandbox.path}/support',
        legacyDocumentsPath: '${sandbox.path}/missing-documents',
      );

      expect(report.migratedPaths, isEmpty);
      expect(report.conflictingPaths, isEmpty);
      expect(
        File('${report.dataPath}/storage_layout.json').existsSync(),
        isTrue,
      );
    },
  );

  late Directory temporary;
  late Directory support;
  late Directory legacy;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('app-data-test-');
    support = Directory('${temporary.path}/support');
    legacy = Directory('${temporary.path}/documents');
    await support.create();
    await legacy.create();
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  test('migrates every known data category and records the layout', () async {
    await File('${legacy.path}/notes.sqlite').writeAsBytes([1, 2, 3]);
    await File('${legacy.path}/app_prefs.json').writeAsString('{}');
    await File(
      '${legacy.path}/account_profile.json',
    ).writeAsString('{"version":1}');
    await File('${legacy.path}/default.isar').writeAsBytes([9, 8, 7]);
    await File('${legacy.path}/schema_version.txt').writeAsString('legacy');
    await Directory('${legacy.path}/images/nested').create(recursive: true);
    await File('${legacy.path}/images/nested/image.png').writeAsBytes([4, 5]);
    await Directory('${legacy.path}/local_backup').create();
    await File(
      '${legacy.path}/local_backup/manifest.json',
    ).writeAsString('{"version":6}');

    final report = await prepareAppDataDirectory(
      supportPath: support.path,
      legacyDocumentsPath: legacy.path,
    );

    final data = Directory(report.dataPath);
    expect(await File('${data.path}/notes.sqlite').readAsBytes(), [1, 2, 3]);
    expect(await File('${data.path}/app_prefs.json').readAsString(), '{}');
    expect(
      await File('${data.path}/account_profile.json').readAsString(),
      '{"version":1}',
    );
    expect(await File('${data.path}/legacy/default.isar').readAsBytes(), [
      9,
      8,
      7,
    ]);
    expect(
      await File('${data.path}/legacy/schema_version.txt').readAsString(),
      'legacy',
    );
    expect(await File('${data.path}/images/nested/image.png').readAsBytes(), [
      4,
      5,
    ]);
    expect(
      await File('${data.path}/local_backup/manifest.json').readAsString(),
      '{"version":6}',
    );
    expect(await File('${legacy.path}/notes.sqlite').exists(), isFalse);
    expect(await Directory('${legacy.path}/images').exists(), isFalse);
    expect(report.conflictingPaths, isEmpty);

    final marker =
        jsonDecode(
              await File('${data.path}/storage_layout.json').readAsString(),
            )
            as Map<String, dynamic>;
    expect(marker['version'], 1);
    expect(marker['legacySource'], legacy.path);
  });

  test('does not overwrite a different destination file', () async {
    final data = Directory('${support.path}/data');
    await data.create();
    await File('${data.path}/notes.sqlite').writeAsString('current');
    await File('${legacy.path}/notes.sqlite').writeAsString('legacy');

    final report = await prepareAppDataDirectory(
      supportPath: support.path,
      legacyDocumentsPath: legacy.path,
    );

    expect(await File('${data.path}/notes.sqlite').readAsString(), 'current');
    expect(await File('${legacy.path}/notes.sqlite').readAsString(), 'legacy');
    expect(report.conflictingPaths, contains('notes.sqlite'));
  });

  test(
    'removes an identical legacy duplicate after checksum comparison',
    () async {
      final data = Directory('${support.path}/data');
      await data.create();
      await File('${data.path}/study_planner.json').writeAsString('same');
      await File('${legacy.path}/study_planner.json').writeAsString('same');

      final report = await prepareAppDataDirectory(
        supportPath: support.path,
        legacyDocumentsPath: legacy.path,
      );

      expect(report.conflictingPaths, isEmpty);
      expect(await File('${legacy.path}/study_planner.json').exists(), isFalse);
      expect(
        await File('${data.path}/study_planner.json').readAsString(),
        'same',
      );
    },
  );
}
