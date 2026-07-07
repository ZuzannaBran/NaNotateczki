import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/error/app_error_log.dart';
import '../../core/storage/text_storage.dart';
import '../../features/notebook/data/notebook_repository.dart';
import '../../features/notebook/domain/notebook.dart';
import 'backup_eraser_flattening.dart';

class LocalBackupService {
  LocalBackupService(
    this.repository, {
    Future<Directory> Function()? documentsDirectory,
  }) : _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory;

  final NotebookRepository repository;
  final Future<Directory> Function() _documentsDirectory;
  final ValueNotifier<bool> _snapshotInProgress = ValueNotifier(false);

  ValueListenable<bool> get snapshotInProgress => _snapshotInProgress;

  static const _dirName = 'local_backup';
  static const _incrementalDirName = 'notebooks';
  static const _trashDirName = 'trash';
  static const _manifest = 'manifest.json';
  static const _latest = 'notebooks_latest.json';
  static const _webBackupKey = 'local_backup_web.json';

  Future<Directory> _backupDir() async {
    final docs = await _documentsDirectory();
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

  Future<BackupSnapshotReport> snapshot(
    List<Notebook> items, {
    bool Function()? shouldInterrupt,
  }) async {
    _snapshotInProgress.value = true;
    try {
      if (kIsWeb) {
        return _snapshotForWeb(items);
      }
      final totalStopwatch = Stopwatch()..start();
      final notebooksDir = await _notebooksDir();
      final previousUpdates = await _readManifestUpdates();
      final expectedFiles = <String>{};
      final notebookReports = <NotebookBackupReport>[];
      var readCompareMs = 0;
      var staleListMs = 0;
      var manifestMs = 0;
      var staleMoved = 0;
      for (final notebook in items) {
        _throwIfInterrupted(shouldInterrupt);
        final notebookStopwatch = Stopwatch()..start();
        final file = await _notebookFile(notebook.uid);
        expectedFiles.add(file.path);
        if (previousUpdates[notebook.uid] == notebook.updatedAt &&
            await file.exists()) {
          notebookStopwatch.stop();
          notebookReports.add(
            NotebookBackupReport(
              uid: notebook.uid,
              pages: notebook.pages.length,
              strokes: _strokeCount(notebook),
              points: _pointCount(notebook),
              jsonBytes: await file.length(),
              flattenMs: 0,
              encodeMs: 0,
              jsonMs: 0,
              compareMs: 0,
              writeMs: 0,
              totalMs: notebookStopwatch.elapsedMilliseconds,
              changed: false,
            ),
          );
          continue;
        }
        final workerResult = await _runBackupWorker<_BackupWorkerResult>(
          _BackupWorkerOperation.snapshot,
          notebook,
          shouldInterrupt,
        );
        final content = workerResult.content;
        _throwIfInterrupted(shouldInterrupt);
        var compareMs = 0;
        var writeMs = 0;
        var changed = true;
        if (await file.exists()) {
          final compareStopwatch = Stopwatch()..start();
          final previous = await file.readAsString();
          compareStopwatch.stop();
          _throwIfInterrupted(shouldInterrupt);
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
            flattenMs: workerResult.flattenMs,
            encodeMs: workerResult.encodeMs,
            jsonMs: workerResult.jsonMs,
            compareMs: compareMs,
            writeMs: writeMs,
            totalMs: notebookStopwatch.elapsedMilliseconds,
            changed: changed,
          ),
        );
      }

      _throwIfInterrupted(shouldInterrupt);
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
    } on BackupSnapshotInterrupted {
      rethrow;
    } catch (e, st) {
      debugPrint('LocalBackupService.snapshot failed: $e\n$st');
      AppErrorLog.instance.record(e, st, source: 'LocalBackupService.snapshot');
      rethrow;
    } finally {
      _snapshotInProgress.value = false;
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

  Future<Map<String, DateTime>> _readManifestUpdates() async {
    final file = await _manifestFile();
    if (!await file.exists()) {
      return const <String, DateTime>{};
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return const <String, DateTime>{};
      }
      final entries = decoded['notebooks'];
      if (entries is! List<dynamic>) {
        return const <String, DateTime>{};
      }
      final updates = <String, DateTime>{};
      for (final entry in entries.whereType<Map<String, dynamic>>()) {
        final uid = entry['uid'];
        final updatedAt = entry['updatedAt'];
        if (uid is String && updatedAt is String) {
          final parsed = DateTime.tryParse(updatedAt);
          if (parsed != null) {
            updates[uid] = parsed;
          }
        }
      }
      return updates;
    } catch (_) {
      return const <String, DateTime>{};
    }
  }

  void _throwIfInterrupted(bool Function()? shouldInterrupt) {
    if (shouldInterrupt?.call() ?? false) {
      throw const BackupSnapshotInterrupted();
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

enum _BackupWorkerOperation { snapshot }

class _BackupWorkerResult {
  const _BackupWorkerResult({
    required this.content,
    required this.flattenMs,
    required this.encodeMs,
    required this.jsonMs,
  });

  final String content;
  final int flattenMs;
  final int encodeMs;
  final int jsonMs;
}

Future<T> _runBackupWorker<T>(
  _BackupWorkerOperation operation,
  Object message,
  bool Function()? shouldInterrupt,
) async {
  if (shouldInterrupt?.call() ?? false) {
    throw const BackupSnapshotInterrupted();
  }
  final resultPort = ReceivePort();
  final completer = Completer<T>();
  Isolate? isolate;
  Timer? interruptTimer;
  final subscription = resultPort.listen((message) {
    if (completer.isCompleted) {
      return;
    }
    final response = message as List<Object?>;
    if (response[0] as bool) {
      completer.complete(response[1] as T);
      return;
    }
    completer.completeError(
      RemoteError(response[1] as String, response[2] as String),
    );
  });
  try {
    isolate = await Isolate.spawn(_backupWorkerEntryPoint, <Object?>[
      resultPort.sendPort,
      operation.index,
      message,
    ]);
    interruptTimer = Timer.periodic(const Duration(milliseconds: 8), (_) {
      if (!completer.isCompleted && (shouldInterrupt?.call() ?? false)) {
        isolate?.kill(priority: Isolate.immediate);
        completer.completeError(const BackupSnapshotInterrupted());
      }
    });
    return await completer.future;
  } finally {
    interruptTimer?.cancel();
    isolate?.kill(priority: Isolate.immediate);
    await subscription.cancel();
    resultPort.close();
  }
}

void _backupWorkerEntryPoint(List<Object?> request) {
  final sendPort = request[0] as SendPort;
  try {
    final operation = _BackupWorkerOperation.values[request[1] as int];
    final result = switch (operation) {
      _BackupWorkerOperation.snapshot => _createBackupPayload(
        request[2] as Notebook,
      ),
    };
    sendPort.send(<Object?>[true, result]);
  } catch (error, stackTrace) {
    sendPort.send(<Object?>[false, error.toString(), stackTrace.toString()]);
  }
}

_BackupWorkerResult _createBackupPayload(Notebook notebook) {
  final flattenStopwatch = Stopwatch()..start();
  final backupNotebook = flattenErasersForBackup(notebook);
  flattenStopwatch.stop();
  final encodeStopwatch = Stopwatch()..start();
  final encoded = NotebookRepository.encodeNotebook(backupNotebook);
  encodeStopwatch.stop();
  final jsonStopwatch = Stopwatch()..start();
  final content = jsonEncode(encoded);
  jsonStopwatch.stop();
  return _BackupWorkerResult(
    content: content,
    flattenMs: flattenStopwatch.elapsedMilliseconds,
    encodeMs: encodeStopwatch.elapsedMilliseconds,
    jsonMs: jsonStopwatch.elapsedMilliseconds,
  );
}

class BackupSnapshotInterrupted implements Exception {
  const BackupSnapshotInterrupted();
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
