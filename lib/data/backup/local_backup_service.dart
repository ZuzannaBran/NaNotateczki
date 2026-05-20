import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../features/notebook/data/notebook_repository.dart';
import '../../features/notebook/domain/notebook.dart';

class LocalBackupService {
  LocalBackupService(this.repository);

  final NotebookRepository repository;

  static const _dirName = 'local_backup';
  static const _latest = 'notebooks_latest.json';
  static const _prev1 = 'notebooks_prev1.json';
  static const _prev2 = 'notebooks_prev2.json';

  Future<Directory> _backupDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_dirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _file(String name) async {
    final dir = await _backupDir();
    return File('${dir.path}/$name');
  }

  Future<void> snapshot(List<Notebook> items) async {
    try {
      final latest = await _file(_latest);
      final prev1 = await _file(_prev1);
      final prev2 = await _file(_prev2);

      if (await prev1.exists()) {
        try {
          await prev1.rename(prev2.path);
        } catch (_) {
          await prev1.delete();
        }
      }
      if (await latest.exists()) {
        try {
          await latest.rename(prev1.path);
        } catch (_) {
          await latest.delete();
        }
      }

      final payload = repository.encodeNotebooks(items);
      await latest.writeAsString(jsonEncode(payload));
    } catch (e, st) {
      debugPrint('LocalBackupService.snapshot failed: $e\n$st');
    }
  }

  Future<bool> hasLatest() async {
    try {
      return await (await _file(_latest)).exists();
    } catch (_) {
      return false;
    }
  }

  Future<List<Notebook>> readLatest() async {
    try {
      final file = await _file(_latest);
      if (!await file.exists()) {
        return <Notebook>[];
      }
      final content = await file.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is! List) {
        return <Notebook>[];
      }
      return repository.decodeNotebooks(decoded);
    } catch (e) {
      debugPrint('LocalBackupService.readLatest failed: $e');
      return <Notebook>[];
    }
  }

  Future<int> restoreFromLatest() async {
    final notebooks = await readLatest();
    var restored = 0;
    for (final notebook in notebooks) {
      try {
        await repository.saveNotebook(notebook);
        restored++;
      } catch (e) {
        debugPrint('LocalBackupService.restore: skipping ${notebook.uid}: $e');
      }
    }
    return restored;
  }
}
