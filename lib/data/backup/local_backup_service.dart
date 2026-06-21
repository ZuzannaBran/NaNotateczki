import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/error/app_error_log.dart';
import '../../core/storage/text_storage.dart';
import '../../features/notebook/data/notebook_repository.dart';
import '../../features/notebook/domain/notebook.dart';
import 'backup_eraser_flattening.dart';

class LocalBackupService {
  LocalBackupService(this.repository);

  final NotebookRepository repository;

  static const _dirName = 'local_backup';
  static const _incrementalDirName = 'notebooks';
  static const _trashDirName = 'trash';
  static const _manifest = 'manifest.json';
  static const _latest = 'notebooks_latest.json';
  static const _webBackupKey = 'local_backup_web.json';

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

  Future<Directory> _trashDir() async {
    final dir = Directory('${(await _backupDir()).path}/$_trashDirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<BackupSnapshotReport> snapshot(List<Notebook> items) async {
    try {
      if (kIsWeb) {
        return _snapshotForWeb(items);
      }
      final totalStopwatch = Stopwatch()..start();
      final notebooksDir = await _notebooksDir();
      final expectedFiles = <String>{};
      final notebookReports = <NotebookBackupReport>[];
      var readCompareMs = 0;
      var staleListMs = 0;
      var manifestMs = 0;
      var staleMoved = 0;
      for (final notebook in items) {
        final notebookStopwatch = Stopwatch()..start();
        final flattenStopwatch = Stopwatch()..start();
        final backupNotebook = flattenErasersForBackup(notebook);
        flattenStopwatch.stop();
        final encodeStopwatch = Stopwatch()..start();
        final encoded = repository.encodeNotebooks([backupNotebook]).single;
        encodeStopwatch.stop();
        final jsonStopwatch = Stopwatch()..start();
        final content = jsonEncode(encoded);
        jsonStopwatch.stop();
        final file = await _notebookFile(notebook.uid);
        expectedFiles.add(file.path);
        var compareMs = 0;
        var writeMs = 0;
        var changed = true;
        if (await file.exists()) {
          final compareStopwatch = Stopwatch()..start();
          final previous = await file.readAsString();
          compareStopwatch.stop();
          compareMs = compareStopwatch.elapsedMilliseconds;
          readCompareMs += compareMs;
          if (previous == content) {
            changed = false;
          }
        }
        if (changed) {
          final writeStopwatch = Stopwatch()..start();
          await file.writeAsString(content);
          writeStopwatch.stop();
          writeMs = writeStopwatch.elapsedMilliseconds;
        }
        notebookStopwatch.stop();
        notebookReports.add(
          NotebookBackupReport(
            uid: notebook.uid,
            pages: notebook.pages.length,
            strokes: _strokeCount(notebook),
            points: _pointCount(notebook),
            jsonBytes: utf8.encode(content).length,
            flattenMs: flattenStopwatch.elapsedMilliseconds,
            encodeMs: encodeStopwatch.elapsedMilliseconds,
            jsonMs: jsonStopwatch.elapsedMilliseconds,
            compareMs: compareMs,
            writeMs: writeMs,
            totalMs: notebookStopwatch.elapsedMilliseconds,
            changed: changed,
          ),
        );
      }

      final staleStopwatch = Stopwatch()..start();
      await for (final entity in notebooksDir.list()) {
        if (entity is File &&
            entity.path.endsWith('.json') &&
            !expectedFiles.contains(entity.path)) {
          await _moveStaleNotebookBackupToTrash(entity);
          staleMoved++;
        }
      }
      staleStopwatch.stop();
      staleListMs = staleStopwatch.elapsedMilliseconds;

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
      final manifestStopwatch = Stopwatch()..start();
      await (await _manifestFile()).writeAsString(jsonEncode(manifestPayload));
      manifestStopwatch.stop();
      manifestMs = manifestStopwatch.elapsedMilliseconds;
      totalStopwatch.stop();
      return BackupSnapshotReport(
        notebookCount: items.length,
        pageCount: items.fold<int>(
          0,
          (sum, notebook) => sum + notebook.pages.length,
        ),
        strokeCount: items.fold<int>(0, (sum, notebook) {
          return sum + _strokeCount(notebook);
        }),
        pointCount: items.fold<int>(0, (sum, notebook) {
          return sum + _pointCount(notebook);
        }),
        jsonBytes: notebookReports.fold<int>(
          0,
          (sum, report) => sum + report.jsonBytes,
        ),
        changedCount: notebookReports.where((report) => report.changed).length,
        unchangedCount: notebookReports
            .where((report) => !report.changed)
            .length,
        readCompareMs: readCompareMs,
        staleListMs: staleListMs,
        staleMoved: staleMoved,
        manifestMs: manifestMs,
        totalMs: totalStopwatch.elapsedMilliseconds,
        notebookReports: notebookReports,
      );
    } catch (e, st) {
      debugPrint('LocalBackupService.snapshot failed: $e\n$st');
      AppErrorLog.instance.record(e, st, source: 'LocalBackupService.snapshot');
      rethrow;
    }
  }

  Future<bool> hasLatest() async {
    try {
      if (kIsWeb) {
        return await readStoredText(_webBackupKey) != null;
      }
      return await (await _manifestFile()).exists() ||
          await (await _file(_latest)).exists();
    } catch (_) {
      return false;
    }
  }

  Future<List<Notebook>> readLatest() async {
    if (kIsWeb) {
      final content = await readStoredText(_webBackupKey);
      if (content == null) {
        return <Notebook>[];
      }
      final decoded = jsonDecode(content);
      return decoded is List
          ? repository.decodeNotebooks(decoded)
          : <Notebook>[];
    }
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
      AppErrorLog.instance.record(
        e,
        null,
        source: 'LocalBackupService.readIncrementalLatest',
      );
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
      AppErrorLog.instance.record(
        e,
        null,
        source: 'LocalBackupService.readLegacyLatest',
      );
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
        AppErrorLog.instance.record(
          e,
          null,
          source: 'LocalBackupService.restoreFromLatest(${notebook.uid})',
        );
      }
    }
    return restored;
  }

  Future<BackupSnapshotReport> _snapshotForWeb(List<Notebook> items) async {
    final stopwatch = Stopwatch()..start();
    final encoded = repository.encodeNotebooks(
      items.map(flattenErasersForBackup).toList(),
    );
    final content = jsonEncode(encoded);
    await writeStoredText(_webBackupKey, content);
    stopwatch.stop();
    return BackupSnapshotReport(
      notebookCount: items.length,
      pageCount: items.fold(0, (sum, notebook) => sum + notebook.pages.length),
      strokeCount: items.fold(
        0,
        (sum, notebook) => sum + _strokeCount(notebook),
      ),
      pointCount: items.fold(0, (sum, notebook) => sum + _pointCount(notebook)),
      jsonBytes: utf8.encode(content).length,
      changedCount: items.length,
      unchangedCount: 0,
      readCompareMs: 0,
      staleListMs: 0,
      staleMoved: 0,
      manifestMs: 0,
      totalMs: stopwatch.elapsedMilliseconds,
      notebookReports: const [],
    );
  }

  Future<void> _moveStaleNotebookBackupToTrash(File file) async {
    try {
      final trashDir = await _trashDir();
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final target = File(
        '${trashDir.path}/${timestamp}_${file.uri.pathSegments.last}',
      );
      await file.rename(target.path);
    } catch (e, st) {
      debugPrint(
        'LocalBackupService._moveStaleNotebookBackupToTrash failed: $e\n$st',
      );
      AppErrorLog.instance.record(
        e,
        st,
        source: 'LocalBackupService._moveStaleNotebookBackupToTrash',
      );
    }
  }

  int _strokeCount(Notebook notebook) {
    return notebook.pages.fold<int>(
      0,
      (sum, page) => sum + page.inkStrokes.length,
    );
  }

  int _pointCount(Notebook notebook) {
    return notebook.pages.fold<int>(0, (sum, page) {
      return sum +
          page.inkStrokes.fold<int>(
            0,
            (strokeSum, stroke) => strokeSum + stroke.points.length,
          );
    });
  }
}

class BackupSnapshotReport {
  const BackupSnapshotReport({
    required this.notebookCount,
    required this.pageCount,
    required this.strokeCount,
    required this.pointCount,
    required this.jsonBytes,
    required this.changedCount,
    required this.unchangedCount,
    required this.readCompareMs,
    required this.staleListMs,
    required this.staleMoved,
    required this.manifestMs,
    required this.totalMs,
    required this.notebookReports,
  });

  final int notebookCount;
  final int pageCount;
  final int strokeCount;
  final int pointCount;
  final int jsonBytes;
  final int changedCount;
  final int unchangedCount;
  final int readCompareMs;
  final int staleListMs;
  final int staleMoved;
  final int manifestMs;
  final int totalMs;
  final List<NotebookBackupReport> notebookReports;

  String toLogString() {
    final slowest = _slowestNotebook;
    return 'nb=$notebookCount pages=$pageCount strokes=$strokeCount '
        'pts=$pointCount jsonBytes=$jsonBytes changed=$changedCount '
        'same=$unchangedCount compareMs=$readCompareMs '
        'staleListMs=$staleListMs staleMoved=$staleMoved '
        'manifestMs=$manifestMs'
        '${slowest == null ? "" : " slowest{${slowest.toLogString()}}"}';
  }

  NotebookBackupReport? get _slowestNotebook {
    if (notebookReports.isEmpty) {
      return null;
    }
    final sorted = List<NotebookBackupReport>.from(notebookReports)
      ..sort((a, b) => b.totalMs.compareTo(a.totalMs));
    return sorted.first;
  }
}

class NotebookBackupReport {
  const NotebookBackupReport({
    required this.uid,
    required this.pages,
    required this.strokes,
    required this.points,
    required this.jsonBytes,
    required this.flattenMs,
    required this.encodeMs,
    required this.jsonMs,
    required this.compareMs,
    required this.writeMs,
    required this.totalMs,
    required this.changed,
  });

  final String uid;
  final int pages;
  final int strokes;
  final int points;
  final int jsonBytes;
  final int flattenMs;
  final int encodeMs;
  final int jsonMs;
  final int compareMs;
  final int writeMs;
  final int totalMs;
  final bool changed;

  String toLogString() {
    return 'uid=$uid pages=$pages strokes=$strokes pts=$points '
        'jsonBytes=$jsonBytes changed=${changed ? 1 : 0} '
        'flattenMs=$flattenMs encodeMs=$encodeMs jsonMs=$jsonMs '
        'compareMs=$compareMs writeMs=$writeMs totalMs=$totalMs';
  }
}
