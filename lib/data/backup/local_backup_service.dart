import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../features/notebook/data/notebook_repository.dart';
import '../../features/notebook/domain/notebook.dart';
import 'backup_eraser_flattening.dart';

class LocalBackupService {
  LocalBackupService(this.repository);

  final NotebookRepository repository;

  static const _dirName = 'local_backup';
  static const _incrementalDirName = 'notebooks';
  static const _manifest = 'manifest.json';
  static const _latest = 'notebooks_latest.json';

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

  Future<Directory> _notebooksDir() async {
    final dir = Directory('${(await _backupDir()).path}/$_incrementalDirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _manifestFile() async {
    final dir = await _backupDir();
    return File('${dir.path}/$_manifest');
  }

  Future<File> _notebookFile(String uid) async {
    final dir = await _notebooksDir();
    return File('${dir.path}/${Uri.encodeComponent(uid)}.json');
  }

  Future<void> snapshot(List<Notebook> items) async {
    try {
      final notebooksDir = await _notebooksDir();
      final expectedFiles = <String>{};
      for (final notebook in items) {
        final backupNotebook = flattenErasersForBackup(notebook);
        final encoded = repository.encodeNotebooks([backupNotebook]).single;
        final content = jsonEncode(encoded);
        final file = await _notebookFile(notebook.uid);
        expectedFiles.add(file.path);
        if (await file.exists()) {
          final previous = await file.readAsString();
          if (previous == content) {
            continue;
          }
        }
        await file.writeAsString(content);
      }

      await for (final entity in notebooksDir.list()) {
        if (entity is File &&
            entity.path.endsWith('.json') &&
            !expectedFiles.contains(entity.path)) {
          await entity.delete();
        }
      }

      final manifestPayload = {
        'version': 1,
        'notebooks': [
          for (final notebook in items)
            {
              'uid': notebook.uid,
              'updatedAt': notebook.updatedAt.toIso8601String(),
              'file': '${Uri.encodeComponent(notebook.uid)}.json',
            },
        ],
      };
      await (await _manifestFile()).writeAsString(jsonEncode(manifestPayload));
    } catch (e, st) {
      debugPrint('LocalBackupService.snapshot failed: $e\n$st');
    }
  }

  Future<bool> hasLatest() async {
    try {
      return await (await _manifestFile()).exists() ||
          await (await _file(_latest)).exists();
    } catch (_) {
      return false;
    }
  }

  Future<List<Notebook>> readLatest() async {
    final incremental = await _readIncrementalLatest();
    if (incremental.isNotEmpty) {
      return incremental;
    }
    return _readLegacyLatest();
  }

  Future<List<Notebook>> _readIncrementalLatest() async {
    try {
      final manifest = await _manifestFile();
      if (!await manifest.exists()) {
        return <Notebook>[];
      }
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return <Notebook>[];
      }
      final notebookEntries = decoded['notebooks'];
      if (notebookEntries is! List) {
        return <Notebook>[];
      }
      final decodedNotebooks = <Object?>[];
      for (final entry in notebookEntries) {
        if (entry is! Map<String, dynamic>) {
          continue;
        }
        final fileName = entry['file'];
        if (fileName is! String || fileName.isEmpty) {
          continue;
        }
        final file = File('${(await _notebooksDir()).path}/$fileName');
        if (!await file.exists()) {
          continue;
        }
        decodedNotebooks.add(jsonDecode(await file.readAsString()));
      }
      return repository.decodeNotebooks(decodedNotebooks);
    } catch (e) {
      debugPrint('LocalBackupService.readIncrementalLatest failed: $e');
      return <Notebook>[];
    }
  }

  Future<List<Notebook>> _readLegacyLatest() async {
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
      debugPrint('LocalBackupService.readLegacyLatest failed: $e');
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
