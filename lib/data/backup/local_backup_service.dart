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
  static const _historyDirName = 'history';
  static const _trashDirName = 'trash';
  static const _manifest = 'manifest.json';
  static const _historyRetention = 5;
  static const _latest = 'notebooks_latest.json';
  static const _webBackupKey = 'local_backup_web.json';
  static const _temporarySuffix = '.tmp';
  static const _previousSuffix = '.previous';

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

  Future<Directory> _historyDir() async {
    final dir = Directory('${(await _backupDir()).path}/$_historyDirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _notebookFile(String fileName) async {
    if (!_isSafeNotebookFileName(fileName)) {
      throw FormatException('Unsafe backup notebook file name: $fileName');
    }
    final dir = await _notebooksDir();
    return File('${dir.path}/$fileName');
  }

  String _notebookContentFileName(String uid, String checksum) {
    return '${Uri.encodeComponent(uid)}_$checksum.json';
  }

  bool _isSafeNotebookFileName(String fileName) {
    return fileName.isNotEmpty &&
        fileName.endsWith('.json') &&
        !fileName.contains('/') &&
        !fileName.contains(r'\') &&
        !fileName.contains('..');
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
      final previousEntries = await _readManifestEntries();
      final currentEntries = <String, _BackupManifestEntry>{};
      final expectedFiles = <String>{};
      final notebookReports = <NotebookBackupReport>[];
      var readCompareMs = 0;
      var staleListMs = 0;
      var manifestMs = 0;
      var staleMoved = 0;
      for (final notebook in items) {
        _throwIfInterrupted(shouldInterrupt);
        final notebookStopwatch = Stopwatch()..start();
        final previousEntry = previousEntries[notebook.uid];
        if (previousEntry != null &&
            previousEntry.updatedAt == notebook.updatedAt &&
            await _isManifestEntryValid(previousEntry)) {
          final previousFile = await _notebookFile(previousEntry.fileName);
          currentEntries[notebook.uid] = previousEntry;
          expectedFiles.add(previousFile.path);
          notebookStopwatch.stop();
          notebookReports.add(
            NotebookBackupReport(
              uid: notebook.uid,
              pages: notebook.pages.length,
              strokes: _strokeCount(notebook),
              points: _pointCount(notebook),
              jsonBytes: previousEntry.jsonBytes!,
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

        await _validateNotebookImages(notebook);
        final workerResult = await _runBackupWorker<_BackupWorkerResult>(
          _BackupWorkerOperation.snapshot,
          notebook,
          shouldInterrupt,
        );
        final content = workerResult.content;
        final checksum = _contentChecksum(content);
        final jsonBytes = utf8.encode(content).length;
        final fileName = _notebookContentFileName(notebook.uid, checksum);
        final file = await _notebookFile(fileName);
        final entry = _BackupManifestEntry(
          uid: notebook.uid,
          updatedAt: notebook.updatedAt,
          fileName: fileName,
          checksum: checksum,
          jsonBytes: jsonBytes,
        );
        currentEntries[notebook.uid] = entry;
        expectedFiles.add(file.path);
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
          await _atomicWriteString(file, content);
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
            jsonBytes: jsonBytes,
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
      final manifestPayload = {
        'version': 2,
        'notebooks': [
          for (final notebook in items) currentEntries[notebook.uid]!.toJson(),
        ],
      };
      final manifestStopwatch = Stopwatch()..start();
      final manifest = await _manifestFile();
      await _recoverAtomicWrite(manifest);
      final manifestContent = jsonEncode(manifestPayload);
      if (await manifest.exists()) {
        final previousManifest = await manifest.readAsString();
        if (previousManifest != manifestContent) {
          await _archiveManifest(previousManifest);
        }
      }
      await _atomicWriteString(manifest, manifestContent);
      await _trimHistory();
      manifestStopwatch.stop();
      manifestMs = manifestStopwatch.elapsedMilliseconds;

      _throwIfInterrupted(shouldInterrupt);
      final retainedFiles = await _referencedNotebookPaths();
      retainedFiles.addAll(expectedFiles);
      final staleStopwatch = Stopwatch()..start();
      await for (final entity in notebooksDir.list()) {
        if (entity is File &&
            entity.path.endsWith('.json') &&
            !retainedFiles.contains(entity.path)) {
          await _moveStaleNotebookBackupToTrash(entity);
          staleMoved++;
        }
      }
      staleStopwatch.stop();
      staleListMs = staleStopwatch.elapsedMilliseconds;

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
      final manifest = await _manifestFile();
      await _recoverAtomicWrite(manifest);
      if (await manifest.exists()) {
        return true;
      }
      if ((await _historyManifestFiles()).isNotEmpty) {
        return true;
      }
      return await (await _file(_latest)).exists();
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, _BackupManifestEntry>> _readManifestEntries() async {
    final file = await _manifestFile();
    await _recoverAtomicWrite(file);
    if (!await file.exists()) {
      return const <String, _BackupManifestEntry>{};
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return const <String, _BackupManifestEntry>{};
      }
      final entries = decoded['notebooks'];
      if (entries is! List<dynamic>) {
        return const <String, _BackupManifestEntry>{};
      }
      final result = <String, _BackupManifestEntry>{};
      for (final entry in entries.whereType<Map<String, dynamic>>()) {
        final parsed = _manifestEntryFromJson(entry);
        if (parsed != null) {
          result[parsed.uid] = parsed;
        }
      }
      return result;
    } catch (_) {
      return const <String, _BackupManifestEntry>{};
    }
  }

  _BackupManifestEntry? _manifestEntryFromJson(Map<String, dynamic> json) {
    final uid = json['uid'];
    final updatedAt = json['updatedAt'];
    final fileName = json['file'];
    if (uid is! String ||
        updatedAt is! String ||
        fileName is! String ||
        !_isSafeNotebookFileName(fileName)) {
      return null;
    }
    final parsed = DateTime.tryParse(updatedAt);
    if (parsed == null) {
      return null;
    }
    final checksum = json['checksum'];
    final jsonBytes = json['bytes'];
    return _BackupManifestEntry(
      uid: uid,
      updatedAt: parsed,
      fileName: fileName,
      checksum: checksum is String ? checksum : null,
      jsonBytes: jsonBytes is num ? jsonBytes.toInt() : null,
    );
  }

  Future<void> _validateNotebookImages(Notebook notebook) async {
    for (final page in notebook.pages) {
      for (final image in page.imageBlocks) {
        final inlineBytes = image.bytes;
        if (inlineBytes != null && inlineBytes.isNotEmpty) {
          continue;
        }
        if (image.path.isEmpty) {
          throw BackupDataException(
            'Image ${image.id} has no persisted file or inline bytes.',
          );
        }
        final file = File(image.path);
        if (!await file.exists()) {
          throw BackupDataException(
            'Image file is missing for ${image.id}: ${image.path}',
          );
        }
        try {
          if (await file.length() <= 0) {
            throw BackupDataException(
              'Image file is empty for ${image.id}: ${image.path}',
            );
          }
          await file.openRead(0, 1).drain<void>();
        } on BackupDataException {
          rethrow;
        } catch (e) {
          throw BackupDataException(
            'Image file cannot be read for ${image.id}: ${image.path}; $e',
          );
        }
      }
    }
  }

  Future<bool> _isManifestEntryValid(_BackupManifestEntry entry) async {
    if (entry.checksum == null || entry.jsonBytes == null) {
      return false;
    }
    final file = await _notebookFile(entry.fileName);
    await _recoverAtomicWrite(file);
    if (!await file.exists()) {
      return false;
    }
    try {
      final content = await file.readAsString();
      return utf8.encode(content).length == entry.jsonBytes &&
          _contentChecksum(content) == entry.checksum;
    } catch (_) {
      return false;
    }
  }

  String _contentChecksum(String content) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(content)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
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
    try {
      final incremental = await _readIncrementalLatest();
      if (incremental != null) {
        return incremental;
      }
    } catch (e, st) {
      debugPrint('LocalBackupService.readLatest incremental failed: $e');
      AppErrorLog.instance.record(
        e,
        st,
        source: 'LocalBackupService.readLatest(incremental)',
      );
    }

    for (final manifest in await _historyManifestFiles()) {
      try {
        final historical = await _readManifestSnapshot(manifest);
        if (historical != null) {
          return historical;
        }
      } catch (e, st) {
        AppErrorLog.instance.record(
          e,
          st,
          source: 'LocalBackupService.readLatest(history)',
        );
      }
    }
    return _readLegacyLatest();
  }

  Future<List<Notebook>?> _readIncrementalLatest() async {
    return _readManifestSnapshot(await _manifestFile());
  }

  Future<List<Notebook>?> _readManifestSnapshot(File manifest) async {
    await _recoverAtomicWrite(manifest);
    if (!await manifest.exists()) {
      return null;
    }

    final decoded = jsonDecode(await manifest.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const BackupValidationException('Manifest is not a JSON object.');
    }
    final notebookEntries = decoded['notebooks'];
    if (notebookEntries is! List<dynamic>) {
      throw const BackupValidationException(
        'Manifest does not contain a notebook list.',
      );
    }

    final notebooks = <Notebook>[];
    for (final rawEntry in notebookEntries) {
      if (rawEntry is! Map<String, dynamic>) {
        throw const BackupValidationException(
          'Manifest contains an invalid notebook entry.',
        );
      }
      final entry = _manifestEntryFromJson(rawEntry);
      if (entry == null) {
        throw const BackupValidationException(
          'Manifest contains an incomplete notebook entry.',
        );
      }
      if (!await _isManifestEntryValid(entry)) {
        throw BackupValidationException(
          'Backup file failed checksum validation: ${entry.fileName}',
        );
      }

      final file = await _notebookFile(entry.fileName);
      final notebookJson = jsonDecode(await file.readAsString());
      if (notebookJson is! Map<String, dynamic>) {
        throw BackupValidationException(
          'Backup notebook is not a JSON object: ${entry.fileName}',
        );
      }
      final decodedNotebook = repository.decodeNotebooks([notebookJson]);
      if (decodedNotebook.length != 1) {
        throw BackupValidationException(
          'Backup notebook could not be decoded: ${entry.fileName}',
        );
      }
      final notebook = decodedNotebook.single;
      if (notebook.uid != entry.uid || notebook.updatedAt != entry.updatedAt) {
        throw BackupValidationException(
          'Backup notebook metadata does not match manifest: '
          '${entry.fileName}',
        );
      }
      notebooks.add(notebook);
    }
    return notebooks;
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

  Future<void> _archiveManifest(String content) async {
    final history = await _historyDir();
    final file = File(
      '${history.path}/manifest_'
      '${DateTime.now().microsecondsSinceEpoch}.json',
    );
    await _atomicWriteString(file, content);
  }

  Future<List<File>> _historyManifestFiles() async {
    final history = await _historyDir();
    final files = <File>[];
    await for (final entity in history.list()) {
      if (entity is File &&
          entity.uri.pathSegments.last.startsWith('manifest_') &&
          entity.path.endsWith('.json')) {
        files.add(entity);
      }
    }
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  Future<void> _trimHistory() async {
    final files = await _historyManifestFiles();
    for (final file in files.skip(_historyRetention)) {
      await file.delete();
    }
  }

  Future<Set<String>> _referencedNotebookPaths() async {
    final result = <String>{};
    final manifests = <File>[await _manifestFile()];
    manifests.addAll(await _historyManifestFiles());
    for (final manifest in manifests) {
      await _recoverAtomicWrite(manifest);
      if (!await manifest.exists()) {
        continue;
      }
      try {
        final decoded = jsonDecode(await manifest.readAsString());
        if (decoded is! Map<String, dynamic>) {
          continue;
        }
        final entries = decoded['notebooks'];
        if (entries is! List<dynamic>) {
          continue;
        }
        for (final raw in entries.whereType<Map<String, dynamic>>()) {
          final entry = _manifestEntryFromJson(raw);
          if (entry != null) {
            result.add((await _notebookFile(entry.fileName)).path);
          }
        }
      } catch (_) {
        continue;
      }
    }
    return result;
  }

  Future<void> _atomicWriteString(File file, String content) async {
    await _recoverAtomicWrite(file);
    final temporary = File('${file.path}$_temporarySuffix');
    final previous = File('${file.path}$_previousSuffix');
    if (await temporary.exists()) {
      await temporary.delete();
    }
    if (await previous.exists()) {
      await previous.delete();
    }
    await temporary.writeAsString(content, flush: true);
    if (await file.exists()) {
      await file.rename(previous.path);
    }
    try {
      await temporary.rename(file.path);
      if (await previous.exists()) {
        await previous.delete();
      }
    } catch (_) {
      if (!await file.exists() && await previous.exists()) {
        await previous.rename(file.path);
      }
      rethrow;
    }
  }

  Future<void> _recoverAtomicWrite(File file) async {
    final temporary = File('${file.path}$_temporarySuffix');
    final previous = File('${file.path}$_previousSuffix');
    if (!await file.exists() && await previous.exists()) {
      await previous.rename(file.path);
    } else if (await previous.exists()) {
      await previous.delete();
    }
    if (await temporary.exists()) {
      await temporary.delete();
    }
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

class BackupValidationException implements Exception {
  const BackupValidationException(this.message);

  final String message;

  @override
  String toString() => 'BackupValidationException: $message';
}

class BackupDataException implements Exception {
  const BackupDataException(this.message);

  final String message;

  @override
  String toString() => 'BackupDataException: $message';
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

class _BackupManifestEntry {
  const _BackupManifestEntry({
    required this.uid,
    required this.updatedAt,
    required this.fileName,
    this.checksum,
    this.jsonBytes,
  });

  final String uid;
  final DateTime updatedAt;
  final String fileName;
  final String? checksum;
  final int? jsonBytes;

  Map<String, Object> toJson() {
    return {
      'uid': uid,
      'updatedAt': updatedAt.toIso8601String(),
      'file': fileName,
      if (checksum != null) 'checksum': checksum!,
      if (jsonBytes != null) 'bytes': jsonBytes!,
    };
  }
}
