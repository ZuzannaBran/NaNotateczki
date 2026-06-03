import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';

import 'entities/notebook_entity.dart';

const int kManualSchemaRevision = 5;

class IsarOpenResult {
  IsarOpenResult({
    required this.service,
    required this.wasReset,
    required this.freshFile,
    this.resetReason,
  });

  final IsarService service;
  final bool wasReset;
  final bool freshFile;
  final String? resetReason;
}

class IsarService {
  IsarService(this.isar);

  final Isar isar;

  static const _versionFileName = 'schema_version.txt';
  static const _isarFileName = 'default.isar';
  static const _isarLockFileName = 'default.isar.lock';

  static Future<IsarOpenResult> open() async {
    final dir = await getApplicationDocumentsDirectory();
    final isarFile = File('${dir.path}/$_isarFileName');
    final freshFile = !isarFile.existsSync();

    final current = _computeSchemaFingerprint();
    final stored = await _readStoredFingerprint(dir);

    bool wasReset = false;
    String? resetReason;

    if (stored != null && stored != current) {
      await _wipeDatabaseFiles(dir);
      wasReset = true;
      resetReason = 'schema_mismatch';
      debugPrint('IsarService: wipe before open (schema_mismatch)');
    }

    Isar? isar;
    try {
      isar = await Isar.open([NotebookEntitySchema], directory: dir.path);
    } catch (e) {
      debugPrint('IsarService: Isar.open failed: $e — wiping and retrying');
      await _wipeDatabaseFiles(dir);
      wasReset = true;
      resetReason = 'open_failed';
      isar = await Isar.open([NotebookEntitySchema], directory: dir.path);
    }

    final smokeOk = await _smokeTest(isar);
    if (!smokeOk) {
      debugPrint('IsarService: smoke test failed — wiping and reopening');
      await isar.close();
      await _wipeDatabaseFiles(dir);
      wasReset = true;
      resetReason = 'smoke_test_failed';
      isar = await Isar.open([NotebookEntitySchema], directory: dir.path);
    }

    await _writeFingerprint(dir, current);

    return IsarOpenResult(
      service: IsarService(isar),
      wasReset: wasReset,
      freshFile: freshFile,
      resetReason: resetReason,
    );
  }

  Future<void> close() => isar.close();

  static String _computeSchemaFingerprint() {
    final ids = <int>[
      NotebookEntitySchema.id,
      NotePageEntitySchema.id,
      IndexTabEntitySchema.id,
      TextBlockEntitySchema.id,
      ImageBlockEntitySchema.id,
      InkStrokeEntitySchema.id,
      InkPointEntitySchema.id,
    ];
    return 'v$kManualSchemaRevision:${ids.join(",")}';
  }

  static Future<String?> _readStoredFingerprint(Directory dir) async {
    try {
      final file = File('${dir.path}/$_versionFileName');
      if (!await file.exists()) {
        return null;
      }
      final content = (await file.readAsString()).trim();
      return content.isEmpty ? null : content;
    } catch (e) {
      debugPrint('IsarService._readStoredFingerprint failed: $e');
      return null;
    }
  }

  static Future<void> _writeFingerprint(Directory dir, String value) async {
    try {
      final file = File('${dir.path}/$_versionFileName');
      await file.writeAsString(value);
    } catch (e) {
      debugPrint('IsarService: writing fingerprint failed: $e');
    }
  }

  static Future<void> _wipeDatabaseFiles(Directory dir) async {
    for (final name in const [_isarFileName, _isarLockFileName]) {
      final file = File('${dir.path}/$name');
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (e) {
          debugPrint('IsarService: cannot delete $name: $e');
        }
      }
    }
  }

  static Future<bool> _smokeTest(Isar isar) async {
    try {
      await isar.notebookEntitys.where().limit(1).findAll();
      return true;
    } catch (e) {
      debugPrint('IsarService: smoke test threw: $e');
      return false;
    }
  }
}
