import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
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
  final _BackupWorkerClient _backupWorker = _BackupWorkerClient();
  Future<void> _snapshotTail = Future<void>.value();

  ValueListenable<bool> get snapshotInProgress => _snapshotInProgress;

  @visibleForTesting
  int get debugBackupWorkerSpawnCount => _backupWorker.spawnCount;

  Future<void> dispose() async {
    _backupWorker.dispose();
    await _snapshotTail;
    _snapshotInProgress.dispose();
  }

  static const _dirName = 'local_backup';
  static const _incrementalDirName = 'notebooks';
  static const _historyDirName = 'history';
  static const _trashDirName = 'trash';
  static const _manifest = 'manifest.json';
  static const _historyRetention = 5;
  static const _trashRetention = 20;
  static const _latest = 'notebooks_latest.json';
  static const _webBackupKey = 'local_backup_web.json';
  static const _libraryFoldersFile = 'library_folders.json';
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
    Set<String>? dirtyNotebookUids,
    bool Function()? shouldInterrupt,
  }) async {
    final requestedDirtyUids = dirtyNotebookUids == null
        ? null
        : Set<String>.unmodifiable(dirtyNotebookUids);
    final previous = _snapshotTail;
    final completion = Completer<void>();
    _snapshotTail = completion.future;
    try {
      await previous;
      return await _snapshotNow(
        items,
        dirtyNotebookUids: requestedDirtyUids,
        shouldInterrupt: shouldInterrupt,
      );
    } finally {
      completion.complete();
    }
  }

  Future<BackupSnapshotReport> _snapshotNow(
    List<Notebook> items, {
    Set<String>? dirtyNotebookUids,
    bool Function()? shouldInterrupt,
  }) async {
    if (dirtyNotebookUids == null || kIsWeb) {
      _validateSnapshotItems(items);
    } else {
      _validateSnapshotNotebookIds(items);
    }
    _snapshotInProgress.value = true;
    try {
      if (kIsWeb) {
        return _snapshotForWeb(items);
      }
      final totalStopwatch = Stopwatch()..start();
      final notebooksDir = await _notebooksDir();
      await _recoverDirectoryAtomicWrites(notebooksDir);
      await _recoverDirectoryAtomicWrites(await _historyDir());
      final previousEntries = await _readManifestEntries();
      final notebookUidsToSnapshot = dirtyNotebookUids == null
          ? items.map((notebook) => notebook.uid).toSet()
          : Set<String>.from(dirtyNotebookUids);
      if (dirtyNotebookUids != null) {
        for (final notebook in items) {
          final previousEntry = previousEntries[notebook.uid];
          if (previousEntry == null ||
              !await _canReuseManifestEntryFast(previousEntry)) {
            notebookUidsToSnapshot.add(notebook.uid);
          }
        }
        _validateSnapshotItems([
          for (final notebook in items)
            if (notebookUidsToSnapshot.contains(notebook.uid)) notebook,
        ]);
      }
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
        if (!notebookUidsToSnapshot.contains(notebook.uid)) {
          final reusableEntry = previousEntry!;
          final previousFile = await _notebookFile(reusableEntry.fileName);
          currentEntries[notebook.uid] = reusableEntry;
          expectedFiles.add(previousFile.path);
          notebookStopwatch.stop();
          notebookReports.add(
            NotebookBackupReport(
              uid: notebook.uid,
              pages: notebook.pages.length,
              strokes: _strokeCount(notebook),
              points: _pointCount(notebook),
              jsonBytes: reusableEntry.jsonBytes!,
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
        if (previousEntry != null &&
            !notebook.updatedAt.isAfter(previousEntry.updatedAt) &&
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
        final workerResult = await _backupWorker.run(
          _BackupWorkerOperation.snapshot,
          notebook,
          shouldInterrupt: shouldInterrupt,
        );
        if (workerResult.missingImageIds.isNotEmpty) {
          throw BackupDataException(
            'Images disappeared or became unreadable during backup: '
            '${workerResult.missingImageIds.join(', ')}',
          );
        }
        final content = workerResult.content;
        final checksum = workerResult.checksum;
        final jsonBytes = workerResult.jsonBytes;
        final fileName = _notebookContentFileName(notebook.uid, checksum);
        final file = await _notebookFile(fileName);
        final entry = _BackupManifestEntry(
          uid: notebook.uid,
          updatedAt: notebook.updatedAt,
          fileName: fileName,
          checksum: checksum,
          checksumAlgorithm: _sha256Algorithm,
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
      final folders = await _foldersForSnapshot(items);
      final manifestBody = <String, dynamic>{
        'folders': folders,
        'notebooks': [
          for (final notebook in items) currentEntries[notebook.uid]!.toJson(),
        ],
      };
      final manifestPayload = <String, dynamic>{
        'version': 4,
        'checksumAlgorithm': _sha256Algorithm,
        'checksum': _sha256Checksum(jsonEncode(manifestBody)),
        ...manifestBody,
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
      _throwIfInterrupted(shouldInterrupt);
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
          if (await _moveStaleNotebookBackupToTrash(entity)) {
            staleMoved++;
          }
        }
      }
      await _trimTrash();
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

  Future<List<String>> _foldersForSnapshot(List<Notebook> items) async {
    final names = <String>{
      for (final notebook in items)
        if (notebook.folder.trim().isNotEmpty) notebook.folder.trim(),
    };
    try {
      final content = await _readStoredFolders();
      if (content != null) {
        final decoded = jsonDecode(content);
        if (decoded is! List<dynamic> ||
            decoded.any((item) => item is! String)) {
          throw const FormatException(
            'Stored library folder metadata is malformed.',
          );
        }
        names.addAll(
          decoded
              .cast<String>()
              .map((item) => item.trim())
              .where((item) => item.isNotEmpty),
        );
      }
    } catch (e, st) {
      AppErrorLog.instance.record(
        e,
        st,
        source: 'LocalBackupService._foldersForSnapshot',
      );
    }
    final folders = names.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return folders;
  }

  Future<String?> _readStoredFolders() async {
    if (kIsWeb) {
      return readStoredText(_libraryFoldersFile);
    }
    final docs = await _documentsDirectory();
    final file = File('${docs.path}/$_libraryFoldersFile');
    await _recoverAtomicWrite(file);
    if (!await file.exists()) {
      return null;
    }
    return file.readAsString();
  }

  Future<void> _restoreFolders(List<String>? folders) async {
    if (folders == null) {
      return;
    }
    final content = jsonEncode(folders);
    if (kIsWeb) {
      await writeStoredText(_libraryFoldersFile, content);
      return;
    }
    final docs = await _documentsDirectory();
    await _atomicWriteString(
      File('${docs.path}/$_libraryFoldersFile'),
      content,
    );
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
      final version = (decoded['version'] as num?)?.toInt();
      if (version != 1 && version != 2 && version != 3 && version != 4) {
        throw BackupDataException(
          'Unsupported existing backup manifest version: ${decoded['version']}',
        );
      }
      if (version == 4 && !_isManifestChecksumValid(decoded)) {
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
    } on BackupDataException {
      rethrow;
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
    final rawAlgorithm = json['checksumAlgorithm'];
    final parsedChecksum = checksum is String ? checksum : null;
    final checksumAlgorithm = rawAlgorithm is String
        ? rawAlgorithm
        : _inferChecksumAlgorithm(parsedChecksum);
    final jsonBytes = json['bytes'];
    return _BackupManifestEntry(
      uid: uid,
      updatedAt: parsed,
      fileName: fileName,
      checksum: parsedChecksum,
      checksumAlgorithm: checksumAlgorithm,
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

  Future<bool> _canReuseManifestEntryFast(
    _BackupManifestEntry entry,
  ) async {
    if (entry.checksum == null ||
        entry.jsonBytes == null ||
        (entry.checksumAlgorithm != _sha256Algorithm &&
            entry.checksumAlgorithm != _legacyFnv1a32Algorithm)) {
      return false;
    }
    final file = await _notebookFile(entry.fileName);
    await _recoverAtomicWrite(file);
    if (!await file.exists()) {
      return false;
    }
    try {
      return await file.length() == entry.jsonBytes;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _isManifestEntryValid(_BackupManifestEntry entry) async {
    if (entry.checksum == null ||
        entry.checksumAlgorithm == null ||
        entry.jsonBytes == null) {
      return false;
    }
    final file = await _notebookFile(entry.fileName);
    await _recoverAtomicWrite(file);
    if (!await file.exists()) {
      return false;
    }
    try {
      final content = await file.readAsString();
      if (utf8.encode(content).length != entry.jsonBytes) {
        return false;
      }
      final actual = switch (entry.checksumAlgorithm) {
        _sha256Algorithm => _sha256Checksum(content),
        _legacyFnv1a32Algorithm => _legacyFnv1a32Checksum(content),
        _ => null,
      };
      return actual != null && actual == entry.checksum;
    } catch (_) {
      return false;
    }
  }

  static const _sha256Algorithm = 'sha256';
  static const _legacyFnv1a32Algorithm = 'fnv1a32';

  String? _inferChecksumAlgorithm(String? checksum) {
    if (checksum == null) {
      return null;
    }
    if (RegExp(r'^[0-9a-f]{64}$').hasMatch(checksum)) {
      return _sha256Algorithm;
    }
    if (RegExp(r'^[0-9a-f]{8}$').hasMatch(checksum)) {
      return _legacyFnv1a32Algorithm;
    }
    return null;
  }

  bool _isManifestChecksumValid(Map<String, dynamic> decoded) {
    final checksum = decoded['checksum'];
    if (decoded['checksumAlgorithm'] != _sha256Algorithm ||
        checksum is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(checksum)) {
      return false;
    }
    final body = <String, dynamic>{
      'folders': decoded['folders'],
      'notebooks': decoded['notebooks'],
    };
    return _sha256Checksum(jsonEncode(body)) == checksum;
  }

  String _sha256Checksum(String content) {
    return sha256.convert(utf8.encode(content)).toString();
  }

  String _legacyFnv1a32Checksum(String content) {
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

  Future<List<Notebook>> readLatest({
    Set<String> requiredUids = const <String>{},
  }) async {
    return (await _readLatestResult(requiredUids: requiredUids)).data.notebooks;
  }

  Future<_BackupReadResult> _readLatestResult({
    Set<String> requiredUids = const <String>{},
  }) async {
    if (kIsWeb) {
      try {
        final content = await readStoredText(_webBackupKey);
        if (content == null) {
          return const _BackupReadResult.notFound();
        }
        final decoded = jsonDecode(content);
        if (decoded is! List<dynamic>) {
          throw const BackupValidationException(
            'Web backup root is not a JSON list.',
          );
        }
        final data = _BackupSnapshotData(
          notebooks: _decodeCompleteNotebookList(decoded),
          folders: null,
        );
        return _containsRequiredUids(data, requiredUids)
            ? _BackupReadResult.found(data)
            : const _BackupReadResult.notFound();
      } catch (e, st) {
        AppErrorLog.instance.record(
          e,
          st,
          source: 'LocalBackupService.readLatest(web)',
        );
        return const _BackupReadResult.notFound();
      }
    }

    try {
      final incremental = await _readIncrementalLatest();
      if (incremental != null &&
          _containsRequiredUids(incremental, requiredUids)) {
        return _BackupReadResult.found(incremental);
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
        if (historical != null &&
            _containsRequiredUids(historical, requiredUids)) {
          return _BackupReadResult.found(historical);
        }
      } catch (e, st) {
        AppErrorLog.instance.record(
          e,
          st,
          source: 'LocalBackupService.readLatest(history)',
        );
      }
    }

    final legacy = await _readLegacyLatest();
    if (legacy != null && _containsRequiredUids(legacy, requiredUids)) {
      return _BackupReadResult.found(legacy);
    }
    return const _BackupReadResult.notFound();
  }

  bool _containsRequiredUids(
    _BackupSnapshotData data,
    Set<String> requiredUids,
  ) {
    if (requiredUids.isEmpty) {
      return true;
    }
    final available = data.notebooks.map((item) => item.uid).toSet();
    return available.containsAll(requiredUids);
  }

  Future<_BackupSnapshotData?> _readIncrementalLatest() async {
    return _readManifestSnapshot(await _manifestFile());
  }

  Future<_BackupSnapshotData?> _readManifestSnapshot(File manifest) async {
    await _recoverAtomicWrite(manifest);
    if (!await manifest.exists()) {
      return null;
    }

    final decoded = jsonDecode(await manifest.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const BackupValidationException('Manifest is not a JSON object.');
    }
    final rawVersion = decoded['version'];
    final version = rawVersion is num ? rawVersion.toInt() : null;
    if (version != 1 && version != 2 && version != 3 && version != 4) {
      throw BackupValidationException(
        'Unsupported backup manifest version: $rawVersion',
      );
    }
    if (version == 4 && !_isManifestChecksumValid(decoded)) {
      throw const BackupValidationException(
        'Backup manifest checksum validation failed.',
      );
    }
    final folders = _foldersFromManifest(decoded);
    final notebookEntries = decoded['notebooks'];
    if (notebookEntries is! List<dynamic>) {
      throw const BackupValidationException(
        'Manifest does not contain a notebook list.',
      );
    }

    final notebooks = <Notebook>[];
    final seenUids = <String>{};
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
      if (!seenUids.add(entry.uid)) {
        throw BackupValidationException(
          'Manifest contains duplicate notebook uid: ${entry.uid}',
        );
      }
      final file = await _notebookFile(entry.fileName);
      await _recoverAtomicWrite(file);
      if (!await file.exists()) {
        throw BackupValidationException(
          'Backup file is missing: ${entry.fileName}',
        );
      }
      if (version != 1 && !await _isManifestEntryValid(entry)) {
        throw BackupValidationException(
          'Backup file failed checksum validation: ${entry.fileName}',
        );
      }

      final notebookJson = jsonDecode(await file.readAsString());
      if (notebookJson is! Map<String, dynamic>) {
        throw BackupValidationException(
          'Backup notebook is not a JSON object: ${entry.fileName}',
        );
      }
      final decodedNotebook = repository.decodeBackupStrict([notebookJson]);
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
    return _BackupSnapshotData(notebooks: notebooks, folders: folders);
  }

  List<String>? _foldersFromManifest(Map<String, dynamic> manifest) {
    final rawFolders = manifest['folders'];
    if (rawFolders == null) {
      return null;
    }
    if (rawFolders is! List<dynamic> ||
        rawFolders.any((item) => item is! String)) {
      throw const BackupValidationException(
        'Manifest contains malformed folder metadata.',
      );
    }
    final folders =
        rawFolders
            .cast<String>()
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toSet()
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return folders;
  }

  Future<_BackupSnapshotData?> _readLegacyLatest() async {
    try {
      final file = await _file(_latest);
      if (!await file.exists()) {
        return null;
      }
      final content = await file.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is! List<dynamic>) {
        throw const BackupValidationException(
          'Legacy backup root is not a JSON list.',
        );
      }
      return _BackupSnapshotData(
        notebooks: _decodeCompleteNotebookList(decoded),
        folders: null,
      );
    } catch (e, st) {
      debugPrint('LocalBackupService.readLegacyLatest failed: $e');
      AppErrorLog.instance.record(
        e,
        st,
        source: 'LocalBackupService.readLegacyLatest',
      );
      return null;
    }
  }

  List<Notebook> _decodeCompleteNotebookList(List<dynamic> items) {
    try {
      return repository.decodeBackupStrict(items);
    } on FormatException catch (e) {
      throw BackupValidationException(e.message);
    }
  }

  Future<int> restoreFromLatest() async {
    return (await restoreFromLatestDetailed()).restoredCount;
  }

  Future<BackupRestoreReport> restoreFromLatestDetailed() async {
    final read = await _readLatestResult();
    if (!read.snapshotFound) {
      return const BackupRestoreReport(
        snapshotFound: false,
        succeeded: false,
        restoredCount: 0,
      );
    }
    if (read.data.notebooks.isEmpty) {
      await _restoreFolders(read.data.folders);
      return const BackupRestoreReport(
        snapshotFound: true,
        succeeded: true,
        restoredCount: 0,
      );
    }
    int restored;
    try {
      restored = await repository.restoreNotebooksAtomically(
        read.data.notebooks,
      );
    } catch (e, st) {
      debugPrint('LocalBackupService.restoreFromLatest failed: $e');
      AppErrorLog.instance.record(
        e,
        st,
        source: 'LocalBackupService.restoreFromLatest',
      );
      return const BackupRestoreReport(
        snapshotFound: true,
        succeeded: false,
        restoredCount: 0,
      );
    }

    final succeeded = restored == read.data.notebooks.length;
    if (succeeded) {
      try {
        await _restoreFolders(read.data.folders);
      } catch (e, st) {
        AppErrorLog.instance.record(
          e,
          st,
          source: 'LocalBackupService.restoreFoldersAfterDocuments',
        );
      }
    }
    return BackupRestoreReport(
      snapshotFound: true,
      succeeded: succeeded,
      restoredCount: restored,
    );
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

  void _validateSnapshotNotebookIds(List<Notebook> items) {
    final notebookIds = <String>{};
    for (final notebook in items) {
      if (notebook.uid.isEmpty || !notebookIds.add(notebook.uid)) {
        throw BackupDataException(
          'Snapshot contains an empty or duplicate notebook id: '
          '${notebook.uid}',
        );
      }
    }
  }

  void _validateSnapshotItems(List<Notebook> items) {
    _validateSnapshotNotebookIds(items);
    final pageIds = <String>{};
    final tabIds = <String>{};
    final textIds = <String>{};
    final imageIds = <String>{};
    final strokeIds = <String>{};

    void requireUnique(Set<String> ids, String id, String type) {
      if (id.isEmpty || !ids.add(id)) {
        throw BackupDataException(
          'Snapshot contains an empty or duplicate $type id: $id',
        );
      }
    }

    for (final notebook in items) {
      if (notebook.pages.isEmpty) {
        throw BackupDataException(
          'Snapshot notebook has no pages: ${notebook.uid}',
        );
      }
      for (final page in notebook.pages) {
        requireUnique(pageIds, page.id, 'page');
        for (final tab in page.indexTabs) {
          requireUnique(tabIds, tab.id, 'index tab');
        }
        for (final block in page.textBlocks) {
          requireUnique(textIds, block.id, 'text block');
        }
        for (final block in page.imageBlocks) {
          requireUnique(imageIds, block.id, 'image block');
        }
        for (final stroke in page.inkStrokes) {
          requireUnique(strokeIds, stroke.id, 'ink stroke');
        }
      }
    }
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

  Future<void> _recoverDirectoryAtomicWrites(Directory directory) async {
    final targetPaths = <String>{};
    await for (final entity in directory.list()) {
      if (entity is! File) {
        continue;
      }
      if (entity.path.endsWith(_temporarySuffix)) {
        targetPaths.add(
          entity.path.substring(
            0,
            entity.path.length - _temporarySuffix.length,
          ),
        );
      } else if (entity.path.endsWith(_previousSuffix)) {
        targetPaths.add(
          entity.path.substring(0, entity.path.length - _previousSuffix.length),
        );
      }
    }
    for (final path in targetPaths) {
      await _recoverAtomicWrite(File(path));
    }
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

  Future<bool> _moveStaleNotebookBackupToTrash(File file) async {
    try {
      final trashDir = await _trashDir();
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final target = File(
        '${trashDir.path}/${timestamp}_${file.uri.pathSegments.last}',
      );
      await file.rename(target.path);
      return true;
    } catch (e, st) {
      debugPrint(
        'LocalBackupService._moveStaleNotebookBackupToTrash failed: $e\n$st',
      );
      AppErrorLog.instance.record(
        e,
        st,
        source: 'LocalBackupService._moveStaleNotebookBackupToTrash',
      );
      return false;
    }
  }

  Future<void> _trimTrash() async {
    final trash = await _trashDir();
    final files = <File>[];
    await for (final entity in trash.list()) {
      if (entity is File) {
        files.add(entity);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    final removeCount = files.length - _trashRetention;
    if (removeCount <= 0) {
      return;
    }
    for (final file in files.take(removeCount)) {
      try {
        await file.delete();
      } catch (e, st) {
        AppErrorLog.instance.record(
          e,
          st,
          source: 'LocalBackupService._trimTrash',
        );
      }
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
    required this.checksum,
    required this.jsonBytes,
    required this.flattenMs,
    required this.encodeMs,
    required this.jsonMs,
    required this.missingImageIds,
  });

  final String content;
  final String checksum;
  final int jsonBytes;
  final int flattenMs;
  final int encodeMs;
  final int jsonMs;
  final List<String> missingImageIds;
}

const int _workerReadyMessage = 0;
const int _workerResultMessage = 1;

class _BackupWorkerClient {
  Future<void>? _startFuture;
  Isolate? _isolate;
  ReceivePort? _responsePort;
  StreamSubscription<dynamic>? _responseSubscription;
  SendPort? _requestPort;
  final Map<int, Completer<_BackupWorkerResult>> _pending =
      <int, Completer<_BackupWorkerResult>>{};
  int _nextRequestId = 0;
  int _spawnCount = 0;
  bool _disposed = false;

  int get spawnCount => _spawnCount;

  Future<_BackupWorkerResult> run(
    _BackupWorkerOperation operation,
    Object message, {
    bool Function()? shouldInterrupt,
  }) async {
    if (_disposed) {
      throw StateError('Backup worker is disposed.');
    }
    if (shouldInterrupt?.call() ?? false) {
      throw const BackupSnapshotInterrupted();
    }

    await _ensureStarted();
    if (_disposed) {
      throw StateError('Backup worker is disposed.');
    }
    final requestPort = _requestPort;
    if (requestPort == null) {
      throw StateError('Backup worker did not start.');
    }

    final requestId = _nextRequestId++;
    final completer = Completer<_BackupWorkerResult>();
    _pending[requestId] = completer;
    requestPort.send(<Object?>[requestId, operation.index, message]);

    Timer? interruptTimer;
    if (shouldInterrupt != null) {
      interruptTimer = Timer.periodic(const Duration(milliseconds: 8), (_) {
        if (!completer.isCompleted && shouldInterrupt()) {
          _interruptActiveWork();
        }
      });
    }

    try {
      return await completer.future;
    } finally {
      interruptTimer?.cancel();
      _pending.remove(requestId);
    }
  }

  Future<void> _ensureStarted() async {
    final existing = _startFuture;
    if (existing != null) {
      await existing;
      return;
    }

    final start = _start();
    _startFuture = start;
    try {
      await start;
    } catch (_) {
      if (identical(_startFuture, start)) {
        _startFuture = null;
      }
      rethrow;
    }
  }

  Future<void> _start() async {
    final responsePort = ReceivePort();
    final ready = Completer<SendPort>();
    _responsePort = responsePort;
    _responseSubscription = responsePort.listen((message) {
      final response = message as List<Object?>;
      final type = response[0] as int;
      if (type == _workerReadyMessage) {
        if (!ready.isCompleted) {
          ready.complete(response[1] as SendPort);
        }
        return;
      }
      if (type != _workerResultMessage) {
        return;
      }

      final requestId = response[1] as int;
      final completer = _pending.remove(requestId);
      if (completer == null || completer.isCompleted) {
        return;
      }
      if (response[2] as bool) {
        completer.complete(response[3] as _BackupWorkerResult);
      } else {
        completer.completeError(
          RemoteError(response[3] as String, response[4] as String),
        );
      }
    });

    try {
      _spawnCount++;
      _isolate = await Isolate.spawn(
        _backupWorkerEntryPoint,
        responsePort.sendPort,
      );
      _requestPort = await ready.future;
    } catch (_) {
      _resetWorker();
      rethrow;
    }
  }

  void _interruptActiveWork() {
    if (_pending.isEmpty) {
      return;
    }
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(const BackupSnapshotInterrupted());
      }
    }
    _pending.clear();
    _resetWorker();
  }

  void _resetWorker() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _requestPort = null;
    _startFuture = null;

    final subscription = _responseSubscription;
    _responseSubscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
    _responsePort?.close();
    _responsePort = null;
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Backup worker was disposed.'));
      }
    }
    _pending.clear();
    _resetWorker();
  }
}

void _backupWorkerEntryPoint(SendPort responsePort) {
  final requestPort = ReceivePort();
  responsePort.send(<Object?>[_workerReadyMessage, requestPort.sendPort]);
  requestPort.listen((message) {
    final request = message as List<Object?>;
    final requestId = request[0] as int;
    try {
      final operation = _BackupWorkerOperation.values[request[1] as int];
      final result = switch (operation) {
        _BackupWorkerOperation.snapshot => _createBackupPayload(
          request[2] as Notebook,
        ),
      };
      responsePort.send(<Object?>[
        _workerResultMessage,
        requestId,
        true,
        result,
      ]);
    } catch (error, stackTrace) {
      responsePort.send(<Object?>[
        _workerResultMessage,
        requestId,
        false,
        error.toString(),
        stackTrace.toString(),
      ]);
    }
  });
}

_BackupWorkerResult _createBackupPayload(Notebook notebook) {
  final flattenStopwatch = Stopwatch()..start();
  final backupNotebook = flattenErasersForBackup(notebook);
  flattenStopwatch.stop();
  final encodeStopwatch = Stopwatch()..start();
  final encoded = NotebookRepository.encodeNotebook(backupNotebook);
  final missingImageIds = <String>[];
  final pages = encoded['pages'];
  if (pages is List<dynamic>) {
    for (final page in pages.whereType<Map<String, dynamic>>()) {
      final images = page['imageBlocks'];
      if (images is! List<dynamic>) {
        continue;
      }
      for (final image in images.whereType<Map<String, dynamic>>()) {
        final bytes = image['bytes'];
        if (bytes is! String || bytes.isEmpty) {
          missingImageIds.add(image['id']?.toString() ?? '<unknown>');
        }
      }
    }
  }
  encodeStopwatch.stop();
  final jsonStopwatch = Stopwatch()..start();
  final content = jsonEncode(encoded);
  jsonStopwatch.stop();
  final contentBytes = utf8.encode(content);
  final checksum = sha256.convert(contentBytes).toString();
  return _BackupWorkerResult(
    content: content,
    checksum: checksum,
    jsonBytes: contentBytes.length,
    flattenMs: flattenStopwatch.elapsedMilliseconds,
    encodeMs: encodeStopwatch.elapsedMilliseconds,
    jsonMs: jsonStopwatch.elapsedMilliseconds,
    missingImageIds: missingImageIds,
  );
}

class _BackupSnapshotData {
  const _BackupSnapshotData({required this.notebooks, required this.folders});

  final List<Notebook> notebooks;
  final List<String>? folders;
}

class _BackupReadResult {
  const _BackupReadResult.found(this.data) : snapshotFound = true;

  const _BackupReadResult.notFound()
    : data = const _BackupSnapshotData(notebooks: <Notebook>[], folders: null),
      snapshotFound = false;

  final _BackupSnapshotData data;
  final bool snapshotFound;
}

class BackupRestoreReport {
  const BackupRestoreReport({
    required this.snapshotFound,
    required this.succeeded,
    required this.restoredCount,
  });

  final bool snapshotFound;
  final bool succeeded;
  final int restoredCount;
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
    this.checksumAlgorithm,
    this.jsonBytes,
  });

  final String uid;
  final DateTime updatedAt;
  final String fileName;
  final String? checksum;
  final String? checksumAlgorithm;
  final int? jsonBytes;

  Map<String, Object> toJson() {
    return {
      'uid': uid,
      'updatedAt': updatedAt.toIso8601String(),
      'file': fileName,
      'checksum': ?checksum,
      'checksumAlgorithm': ?checksumAlgorithm,
      'bytes': ?jsonBytes,
    };
  }
}
