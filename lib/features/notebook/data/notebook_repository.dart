import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/diagnostics/data_integrity_log.dart';
import '../../../core/error/app_error_log.dart';
import '../../../data/drift/notes_database.dart';
import '../domain/drawing_tool.dart';
import '../domain/image_block.dart';
import '../domain/ink_stroke.dart';
import '../domain/notebook.dart';
import '../domain/notebook_kind.dart';
import '../domain/note_page.dart';
import '../domain/text_block.dart';

typedef DataIntegrityIncidentHandler =
    Future<void> Function(
      DataIntegrityIncident incident,
      Notebook before,
      Notebook attempted,
    );

class NotebookRepository {
  NotebookRepository(
    this.database, {
    this.onChanged,
    void Function(Object error, StackTrace stackTrace, String source)?
    readErrorHandler,
    DataIntegrityIncidentHandler? dataIntegrityIncidentHandler,
  }) : _readErrorHandler = readErrorHandler,
       _dataIntegrityIncidentHandler = dataIntegrityIncidentHandler;

  final NotesDatabase database;
  final void Function()? onChanged;
  final void Function(Object error, StackTrace stackTrace, String source)?
  _readErrorHandler;
  final DataIntegrityIncidentHandler? _dataIntegrityIncidentHandler;
  final Uuid _uuid = const Uuid();
  bool _lastFetchSkippedCorruptRows = false;
  final List<String> _lastCorruptNotebookIds = <String>[];
  final Map<String, DateTime> _latestPersistedUpdates = <String, DateTime>{};
  final Map<String, Future<void>> _saveTails = <String, Future<void>>{};
  final Map<String, Notebook> _notebookCache = <String, Notebook>{};
  bool _isNotebookCacheComplete = false;

  bool get lastFetchSkippedCorruptRows => _lastFetchSkippedCorruptRows;
  int get lastCorruptNotebookCount => _lastCorruptNotebookIds.length;
  List<String> get lastCorruptNotebookIds =>
      List.unmodifiable(_lastCorruptNotebookIds);
  List<Notebook>? get cachedNotebooks => _isNotebookCacheComplete
      ? List<Notebook>.unmodifiable(_notebookCache.values)
      : null;

  Future<List<Notebook>> fetchNotebooks() async {
    try {
      final rows =
          await (database.select(database.notebookRows)..orderBy([
                (row) => OrderingTerm(
                  expression: row.updatedAt,
                  mode: OrderingMode.desc,
                ),
              ]))
              .get();
      final notebooks = <Notebook>[];
      final corruptIds = <String>[];
      for (final row in rows) {
        try {
          final result = await _readNotebook(row);
          notebooks.add(result.notebook);
          if (result.hadCorruptRows) {
            corruptIds.add(row.uid);
          }
        } catch (e, st) {
          corruptIds.add(row.uid);
          debugPrint('Skipped corrupt notebook uid=${row.uid}: $e');
          _recordReadError(
            e,
            st,
            'NotebookRepository.fetchNotebooks(${row.uid})',
          );
        }
      }
      _lastFetchSkippedCorruptRows = corruptIds.isNotEmpty;
      _lastCorruptNotebookIds
        ..clear()
        ..addAll(corruptIds);
      if (corruptIds.isEmpty) {
        _notebookCache
          ..clear()
          ..addEntries(notebooks.map((item) => MapEntry(item.uid, item)));
        _isNotebookCacheComplete = true;
      } else {
        _isNotebookCacheComplete = false;
      }
      return notebooks;
    } catch (e, st) {
      debugPrint('fetchNotebooks failed: $e\n$st');
      _recordReadError(e, st, 'NotebookRepository.fetchNotebooks');
      _lastFetchSkippedCorruptRows = true;
      rethrow;
    }
  }

  Future<Notebook> saveRecoveredCopy(
    Notebook notebook, {
    String reason = 'Recovered copy',
  }) async {
    final recovered = notebook.copyWith(
      uid: _uuid.v4(),
      title: _buildRecoveredTitle(notebook.title, reason),
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await saveNotebook(recovered);
    return recovered;
  }

  Future<void> archiveNotebookBeforeDelete(
    Notebook notebook, {
    String reason = 'deleted',
  }) async {
    if (kIsWeb) {
      return;
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      final archiveDir = Directory('${docs.path}/deleted_notebooks');
      if (!await archiveDir.exists()) {
        await archiveDir.create(recursive: true);
      }
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final file = File(
        '${archiveDir.path}/${timestamp}_${Uri.encodeComponent(notebook.uid)}.json',
      );
      final payload = encodeNotebooks([notebook]).single;
      await file.writeAsString(
        jsonEncode({
          'reason': reason,
          'archivedAt': DateTime.now().toIso8601String(),
          'notebook': payload,
        }),
      );
    } catch (e, st) {
      debugPrint('Failed to archive notebook ${notebook.uid}: $e\n$st');
      AppErrorLog.instance.record(
        e,
        st,
        source: 'NotebookRepository.archiveNotebookBeforeDelete',
      );
    }
  }

  Future<Notebook> createNotebook({String? title, String? folder}) async {
    final now = DateTime.now();
    final notebook = Notebook(
      uid: _uuid.v4(),
      title: title ?? 'New Notebook',
      kind: NotebookKind.notebook,
      folder: folder ?? 'Notes',
      createdAt: now,
      updatedAt: now,
      pages: [
        NotePage(
          id: _uuid.v4(),
          title: 'Page 1',
          textBlocks: <TextBlock>[],
          imageBlocks: <ImageBlock>[],
          inkStrokes: <InkStroke>[],
          isBookmarked: false,
          indexTabs: <IndexTab>[],
        ),
      ],
    );

    await saveNotebook(notebook);
    return notebook;
  }

  Future<Notebook> createBoard({String? title, String? folder}) async {
    final now = DateTime.now();
    final board = Notebook(
      uid: _uuid.v4(),
      title: title ?? 'New Board',
      kind: NotebookKind.board,
      folder: folder ?? 'Notes',
      createdAt: now,
      updatedAt: now,
      pages: [
        NotePage(
          id: _uuid.v4(),
          title: 'Canvas',
          textBlocks: <TextBlock>[],
          imageBlocks: <ImageBlock>[],
          inkStrokes: <InkStroke>[],
          isBookmarked: false,
          indexTabs: <IndexTab>[],
        ),
      ],
    );

    await saveNotebook(board);
    return board;
  }

  Future<Notebook?> getNotebook(String uid) async {
    try {
      final row = await (database.select(
        database.notebookRows,
      )..where((item) => item.uid.equals(uid))).getSingleOrNull();
      if (row == null) {
        return null;
      }
      final result = await _readNotebook(row);
      if (result.hadCorruptRows) {
        _lastFetchSkippedCorruptRows = true;
        if (!_lastCorruptNotebookIds.contains(uid)) {
          _lastCorruptNotebookIds.add(uid);
        }
      }
      return result.notebook;
    } catch (e, st) {
      debugPrint('getNotebook failed for uid=$uid: $e');
      AppErrorLog.instance.record(
        e,
        st,
        source: 'NotebookRepository.getNotebook($uid)',
      );
      return null;
    }
  }

  Future<bool> saveNotebook(
    Notebook notebook, {
    bool preserveMetadata = false,
  }) async {
    if (notebook.pages.isEmpty) {
      throw ArgumentError.value(
        notebook.uid,
        'notebook.uid',
        'Cannot save a notebook without pages.',
      );
    }
    final previous = _saveTails[notebook.uid] ?? Future<void>.value();
    final requestStackTrace = StackTrace.current;
    final completion = Completer<void>();
    _saveTails[notebook.uid] = completion.future;
    try {
      await previous;
      return await _saveNotebookNow(
        notebook,
        requestStackTrace,
        preserveMetadata: preserveMetadata,
      );
    } finally {
      completion.complete();
      if (identical(_saveTails[notebook.uid], completion.future)) {
        _saveTails.remove(notebook.uid);
      }
    }
  }

  Future<bool> saveNotebookPages(Notebook notebook, Set<String> pageIds) async {
    if (pageIds.isEmpty) {
      return true;
    }
    if (notebook.pages.isEmpty) {
      throw ArgumentError.value(
        notebook.uid,
        'notebook.uid',
        'Cannot save a notebook without pages.',
      );
    }
    final previous = _saveTails[notebook.uid] ?? Future<void>.value();
    final requestStackTrace = StackTrace.current;
    final completion = Completer<void>();
    _saveTails[notebook.uid] = completion.future;
    try {
      await previous;
      return await _saveNotebookPagesNow(notebook, pageIds, requestStackTrace);
    } finally {
      completion.complete();
      if (identical(_saveTails[notebook.uid], completion.future)) {
        _saveTails.remove(notebook.uid);
      }
    }
  }

  Future<bool> _saveNotebookPagesNow(
    Notebook notebook,
    Set<String> pageIds,
    StackTrace requestStackTrace,
  ) async {
    if (_lastCorruptNotebookIds.contains(notebook.uid)) {
      return false;
    }
    final pagesById = <String, MapEntry<int, NotePage>>{
      for (final entry in notebook.pages.asMap().entries)
        if (pageIds.contains(entry.value.id)) entry.value.id: entry,
    };
    if (pagesById.length != pageIds.length) {
      return false;
    }
    final existingRow = await (database.select(
      database.notebookRows,
    )..where((row) => row.uid.equals(notebook.uid))).getSingleOrNull();
    if (existingRow == null) {
      return false;
    }
    final existingResult = await _readNotebook(existingRow);
    if (existingResult.hadCorruptRows) {
      _markNotebookCorrupt(notebook.uid);
      return false;
    }
    final attempted = _mergeSavedPages(
      existingResult.notebook,
      notebook,
      pageIds,
    );
    await _protectSuspiciousOverwrite(
      before: existingResult.notebook,
      attempted: attempted,
      operation: 'saveNotebookPages',
      affectedPageIds: pageIds,
      requestStackTrace: requestStackTrace,
    );
    DateTime? persistedAt;
    final saved = await database.transaction(() async {
      final existing = await (database.select(
        database.notebookRows,
      )..where((row) => row.uid.equals(notebook.uid))).getSingleOrNull();
      if (existing == null) {
        return false;
      }
      final trackedAt = _latestPersistedUpdates[notebook.uid];
      final latestAt =
          trackedAt != null && trackedAt.isAfter(existing.updatedAt)
          ? trackedAt
          : existing.updatedAt;
      final updatedAt = notebook.updatedAt.isAfter(latestAt)
          ? notebook.updatedAt
          : latestAt.add(const Duration(seconds: 1));
      persistedAt = updatedAt;
      await (database.update(database.notebookRows)
            ..where((row) => row.uid.equals(notebook.uid)))
          .write(NotebookRowsCompanion(updatedAt: Value(updatedAt)));
      for (final entry in pagesById.values) {
        await _deletePageChildren(entry.value.id);
        await _insertPage(notebook.uid, entry.value, entry.key);
      }
      return true;
    });
    if (saved) {
      final savedAt = persistedAt!;
      final persistedNotebook = notebook.copyWith(updatedAt: savedAt);
      _latestPersistedUpdates[notebook.uid] = savedAt;
      _notebookCache[notebook.uid] = persistedNotebook;
      onChanged?.call();
    }
    return saved;
  }

  Future<bool> _saveNotebookNow(
    Notebook notebook,
    StackTrace requestStackTrace, {
    bool preserveMetadata = false,
  }) async {
    if (_lastCorruptNotebookIds.contains(notebook.uid)) {
      debugPrint(
        'NotebookRepository.saveNotebook rejected partially read notebook '
        'uid=${notebook.uid}',
      );
      return false;
    }
    final existingRow = await (database.select(
      database.notebookRows,
    )..where((row) => row.uid.equals(notebook.uid))).getSingleOrNull();
    // The live editor owns page content, so its saves are authoritative and are
    // stamped only monotonically below. External callers (sync/import) must not
    // let an older snapshot clobber newer data.
    if (!preserveMetadata) {
      final persistedAt = existingRow?.updatedAt;
      final trackedAt = _latestPersistedUpdates[notebook.uid];
      final latestAt =
          trackedAt != null &&
              (persistedAt == null || trackedAt.isAfter(persistedAt))
          ? trackedAt
          : persistedAt;
      if (latestAt != null && latestAt.isAfter(notebook.updatedAt)) {
        return false;
      }
    }
    if (existingRow != null) {
      final existingResult = await _readNotebook(existingRow);
      if (existingResult.hadCorruptRows) {
        _markNotebookCorrupt(notebook.uid);
        return false;
      }
      await _protectSuspiciousOverwrite(
        before: existingResult.notebook,
        attempted: notebook,
        operation: 'saveNotebook',
        affectedPageIds: notebook.pages.map((page) => page.id).toSet(),
        requestStackTrace: requestStackTrace,
      );
    }
    final notebookToSave = await _persistInlineImages(notebook);

    DateTime? persistedAt;
    var effectiveTitle = notebookToSave.title;
    var effectiveFolder = notebookToSave.folder;
    final saved = await database.transaction(() async {
      final existing = await (database.select(
        database.notebookRows,
      )..where((row) => row.uid.equals(notebookToSave.uid))).getSingleOrNull();
      final existingAt = existing?.updatedAt;
      final trackedAt = _latestPersistedUpdates[notebookToSave.uid];
      final latestAt =
          trackedAt != null &&
              (existingAt == null || trackedAt.isAfter(existingAt))
          ? trackedAt
          : existingAt;
      if (!preserveMetadata &&
          latestAt != null &&
          latestAt.isAfter(notebookToSave.updatedAt)) {
        return false;
      }
      final updatedAt =
          preserveMetadata &&
              latestAt != null &&
              !notebookToSave.updatedAt.isAfter(latestAt)
          ? latestAt.add(const Duration(seconds: 1))
          : notebookToSave.updatedAt;
      persistedAt = updatedAt;
      if (preserveMetadata && existing != null) {
        effectiveTitle = existing.title;
        effectiveFolder = existing.folder;
      }
      await database
          .into(database.notebookRows)
          .insertOnConflictUpdate(
            NotebookRowsCompanion.insert(
              uid: notebookToSave.uid,
              title: effectiveTitle,
              kindIndex: notebookToSave.kind.indexValue,
              folder: effectiveFolder,
              createdAt: notebookToSave.createdAt,
              updatedAt: updatedAt,
            ),
          );
      await _deleteNotebookChildren(notebookToSave.uid);
      for (final entry in notebookToSave.pages.asMap().entries) {
        await _insertPage(notebookToSave.uid, entry.value, entry.key);
      }
      return true;
    });
    if (saved) {
      final savedAt = persistedAt!;
      final persisted = notebookToSave.copyWith(
        title: effectiveTitle,
        folder: effectiveFolder,
        updatedAt: savedAt,
      );
      _latestPersistedUpdates[notebookToSave.uid] = savedAt;
      _notebookCache[notebookToSave.uid] = persisted;
      onChanged?.call();
    }
    return saved;
  }

  Future<Notebook?> updateNotebookMetadata(
    String uid, {
    String? title,
    String? folder,
  }) async {
    DateTime? preciseUpdatedAt;
    final updated = await database.transaction(() async {
      final existing = await (database.select(
        database.notebookRows,
      )..where((row) => row.uid.equals(uid))).getSingleOrNull();
      if (existing == null) {
        return null;
      }
      final trackedAt = _latestPersistedUpdates[uid];
      final latestAt =
          trackedAt != null && trackedAt.isAfter(existing.updatedAt)
          ? trackedAt
          : existing.updatedAt;
      final now = DateTime.now();
      final updatedAt = now.isAfter(latestAt)
          ? now
          : latestAt.add(const Duration(seconds: 1));
      await (database.update(
        database.notebookRows,
      )..where((row) => row.uid.equals(uid))).write(
        NotebookRowsCompanion(
          title: title == null ? const Value.absent() : Value(title),
          folder: folder == null ? const Value.absent() : Value(folder),
          updatedAt: Value(updatedAt),
        ),
      );
      final row = await (database.select(
        database.notebookRows,
      )..where((item) => item.uid.equals(uid))).getSingle();
      preciseUpdatedAt = updatedAt;
      return (await _readNotebook(row)).notebook;
    });
    if (updated != null) {
      _latestPersistedUpdates[uid] = preciseUpdatedAt!;
      _notebookCache[uid] = updated;
      onChanged?.call();
    }
    return updated;
  }

  Future<Notebook> _persistInlineImages(Notebook notebook) async {
    final migratedPages = <NotePage>[];
    var migrated = false;
    for (final page in notebook.pages) {
      final migratedBlocks = <ImageBlock>[];
      var pageMigrated = false;
      for (final block in page.imageBlocks) {
        final persistedBlock = await _persistInlineImageBytes(block);
        if (persistedBlock != block) {
          migratedBlocks.add(persistedBlock);
          pageMigrated = true;
          migrated = true;
          continue;
        }
        migratedBlocks.add(block);
      }
      migratedPages.add(
        pageMigrated ? page.copyWith(imageBlocks: migratedBlocks) : page,
      );
    }
    return migrated ? notebook.copyWith(pages: migratedPages) : notebook;
  }

  Future<ImageBlock> _persistInlineImageBytes(ImageBlock block) async {
    final bytes = block.bytes;
    if (bytes == null || bytes.isEmpty) {
      return block;
    }
    if (kIsWeb) {
      return block.copyWith(path: '');
    }
    if (block.path.isNotEmpty &&
        File(block.path).existsSync() &&
        !_isVolatileImagePath(block.path)) {
      return block.copyWith(clearBytes: true);
    }

    final docs = await getApplicationDocumentsDirectory();
    final imagesDir = Directory('${docs.path}/images');
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }
    final extension = (block.imageExt ?? block.path.split('.').last)
        .toLowerCase();
    final safeExtension = RegExp(r'^[a-z0-9]+$').hasMatch(extension)
        ? extension
        : 'png';
    final file = File(
      '${imagesDir.path}/restored_${block.id}_'
      '${DateTime.now().millisecondsSinceEpoch}.$safeExtension',
    );
    await file.writeAsBytes(bytes, flush: true);
    return block.copyWith(path: file.path, clearBytes: true);
  }

  bool _isVolatileImagePath(String path) {
    return path.contains('/images_cache/') || path.contains('\\images_cache\\');
  }

  Notebook _mergeSavedPages(
    Notebook before,
    Notebook incoming,
    Set<String> pageIds,
  ) {
    final incomingById = {
      for (final page in incoming.pages)
        if (pageIds.contains(page.id)) page.id: page,
    };
    return before.copyWith(
      updatedAt: incoming.updatedAt,
      pages: [for (final page in before.pages) incomingById[page.id] ?? page],
    );
  }

  Future<void> _protectSuspiciousOverwrite({
    required Notebook before,
    required Notebook attempted,
    required String operation,
    required Set<String> affectedPageIds,
    required StackTrace requestStackTrace,
  }) async {
    final beforeSummary = _NotebookContentSummary.fromNotebook(before);
    final attemptedSummary = _NotebookContentSummary.fromNotebook(attempted);
    final reasons = _suspiciousReductionReasons(
      beforeSummary,
      attemptedSummary,
    );
    final beforePages = {for (final page in before.pages) page.id: page};
    final attemptedPages = {for (final page in attempted.pages) page.id: page};
    for (final pageId in affectedPageIds) {
      final beforePage = beforePages[pageId];
      final attemptedPage = attemptedPages[pageId];
      if (beforePage == null || attemptedPage == null) {
        continue;
      }
      final pageReasons = _suspiciousReductionReasons(
        _NotebookContentSummary.fromPages([beforePage]),
        _NotebookContentSummary.fromPages([attemptedPage]),
      );
      reasons.addAll(pageReasons.map((reason) => 'page:$pageId:$reason'));
    }
    if (reasons.isEmpty) {
      return;
    }

    final incident = DataIntegrityIncident(
      id: _uuid.v4(),
      occurredAt: DateTime.now(),
      operation: operation,
      notebookUid: before.uid,
      notebookTitle: before.title,
      reasons: reasons,
      affectedPageIds: affectedPageIds.toList()..sort(),
      before: beforeSummary.toJson(),
      attempted: attemptedSummary.toJson(),
      stackTrace: requestStackTrace.toString(),
    );
    final handler = _dataIntegrityIncidentHandler;
    if (handler != null) {
      await handler(incident, before, attempted);
      return;
    }
    await _recordDataIntegrityIncident(incident, before, attempted);
  }

  Future<void> _recordDataIntegrityIncident(
    DataIntegrityIncident incident,
    Notebook before,
    Notebook attempted,
  ) async {
    String? archivePath;
    if (!kIsWeb) {
      try {
        archivePath = await _archiveDataIntegrityIncident(
          incident,
          before,
          attempted,
        );
      } catch (e, st) {
        AppErrorLog.instance.record(
          e,
          st,
          source: 'NotebookRepository.dataIntegrityArchive(${incident.id})',
        );
        throw DataIntegrityProtectionException(
          'Suspicious save blocked because its evidence archive failed. '
          'incidentId=${incident.id}, notebookUid=${incident.notebookUid}',
        );
      }
    }

    final recorded = incident.copyWith(archivePath: archivePath);
    try {
      await DataIntegrityLog.instance.record(recorded);
    } catch (e, st) {
      AppErrorLog.instance.record(
        e,
        st,
        source: 'NotebookRepository.dataIntegrityLog(${incident.id})',
      );
      if (archivePath == null) {
        throw DataIntegrityProtectionException(
          'Suspicious save blocked because no evidence could be persisted. '
          'incidentId=${incident.id}, notebookUid=${incident.notebookUid}',
        );
      }
    }
    AppErrorLog.instance.record(
      DataIntegrityProtectionException(
        'Suspicious content reduction quarantined before write. '
        'incidentId=${incident.id}, notebookUid=${incident.notebookUid}, '
        'reasons=${incident.reasons.join(',')}, '
        'archivePath=${archivePath ?? 'data_integrity_log.json'}',
      ),
      StackTrace.fromString(incident.stackTrace),
      source: 'NotebookRepository.${incident.operation}.dataIntegrity',
    );
    debugPrint('[data-integrity] ${recorded.format()}');
  }

  Future<String> _archiveDataIntegrityIncident(
    DataIntegrityIncident incident,
    Notebook before,
    Notebook attempted,
  ) async {
    final docs = await getApplicationDocumentsDirectory();
    final archiveDir = Directory('${docs.path}/data_integrity_incidents');
    if (!await archiveDir.exists()) {
      await archiveDir.create(recursive: true);
    }
    final timestamp = incident.occurredAt.toIso8601String().replaceAll(
      ':',
      '-',
    );
    final file = File(
      '${archiveDir.path}/${timestamp}_${incident.id}_'
      '${Uri.encodeComponent(incident.notebookUid)}.json',
    );
    final recorded = incident.copyWith(archivePath: file.path);
    await file.writeAsString(
      jsonEncode({
        'version': 1,
        'incident': recorded.toJson(),
        'before': encodeNotebook(before),
        'attempted': encodeNotebook(attempted),
      }),
      flush: true,
    );
    return file.path;
  }

  void _markNotebookCorrupt(String uid) {
    _lastFetchSkippedCorruptRows = true;
    if (!_lastCorruptNotebookIds.contains(uid)) {
      _lastCorruptNotebookIds.add(uid);
    }
    _isNotebookCacheComplete = false;
  }

  Future<void> deleteNotebook(String uid) async {
    final notebook = await getNotebook(uid);
    if (notebook != null) {
      await archiveNotebookBeforeDelete(notebook);
    }
    await database.transaction(() async {
      await _deleteNotebookChildren(uid);
      await (database.delete(
        database.notebookRows,
      )..where((item) => item.uid.equals(uid))).go();
    });
    _latestPersistedUpdates.remove(uid);
    _notebookCache.remove(uid);
    onChanged?.call();
  }

  List<Map<String, dynamic>> encodeNotebooks(List<Notebook> items) {
    return items.map(encodeNotebook).toList();
  }

  static Map<String, dynamic> encodeNotebook(Notebook notebook) =>
      _notebookToJson(notebook);

  List<Notebook> decodeNotebooks(List<dynamic> items) {
    return items
        .whereType<Map<String, dynamic>>()
        .map(_notebookFromJson)
        .toList();
  }

  Future<_NotebookReadResult> _readNotebook(NotebookRow row) async {
    var hadCorruptRows = false;
    final pageRows = await _readRowsSafely(
      read: () =>
          (database.select(database.pageRows)
                ..where((item) => item.notebookUid.equals(row.uid))
                ..orderBy([(item) => OrderingTerm.asc(item.pageIndex)]))
              .get(),
      source: 'NotebookRepository._readNotebook(${row.uid}, pages)',
      onError: () => hadCorruptRows = true,
    );
    final pages = <NotePage>[];
    for (final pageRow in pageRows) {
      try {
        final result = await _readPage(pageRow);
        pages.add(result.page);
        hadCorruptRows = hadCorruptRows || result.hadCorruptRows;
      } catch (error, stackTrace) {
        hadCorruptRows = true;
        _recordReadError(
          error,
          stackTrace,
          'NotebookRepository._readNotebook(${row.uid}, page=${pageRow.uid})',
        );
      }
    }
    return _NotebookReadResult(
      notebook: Notebook(
        uid: row.uid,
        title: row.title,
        kind: NotebookKindValue.fromIndex(row.kindIndex),
        folder: row.folder,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        pages: pages,
      ),
      hadCorruptRows: hadCorruptRows,
    );
  }

  Future<_PageReadResult> _readPage(PageRow row) async {
    var hadCorruptRows = false;
    void markCorrupt() => hadCorruptRows = true;
    final tabs = await _readRowsSafely(
      read: () => (database.select(
        database.indexTabRows,
      )..where((item) => item.pageUid.equals(row.uid))).get(),
      source: 'NotebookRepository._readPage(${row.uid}, tabs)',
      onError: markCorrupt,
    );
    final textBlocks = await _readRowsSafely(
      read: () =>
          (database.select(database.textBlockRows)
                ..where((item) => item.pageUid.equals(row.uid))
                ..orderBy([(item) => OrderingTerm.asc(item.sortIndex)]))
              .get(),
      source: 'NotebookRepository._readPage(${row.uid}, text)',
      onError: markCorrupt,
    );
    final imageBlocks = await _readRowsSafely(
      read: () =>
          (database.select(database.imageBlockRows)
                ..where((item) => item.pageUid.equals(row.uid))
                ..orderBy([(item) => OrderingTerm.asc(item.sortIndex)]))
              .get(),
      source: 'NotebookRepository._readPage(${row.uid}, images)',
      onError: markCorrupt,
    );
    final strokes = await _readRowsSafely(
      read: () =>
          (database.select(database.inkStrokeRows)
                ..where((item) => item.pageUid.equals(row.uid))
                ..orderBy([(item) => OrderingTerm.asc(item.sortIndex)]))
              .get(),
      source: 'NotebookRepository._readPage(${row.uid}, strokes)',
      onError: markCorrupt,
    );
    return _PageReadResult(
      page: NotePage(
        id: row.uid,
        title: row.title,
        textBlocks: _convertRowsSafely(
          textBlocks,
          _textFromRow,
          'NotebookRepository._readPage(${row.uid}, text row)',
          markCorrupt,
        ),
        imageBlocks: _convertRowsSafely(
          imageBlocks,
          _imageFromRow,
          'NotebookRepository._readPage(${row.uid}, image row)',
          markCorrupt,
        ),
        inkStrokes: _convertRowsSafely(
          strokes,
          _strokeFromRow,
          'NotebookRepository._readPage(${row.uid}, stroke row)',
          markCorrupt,
        ),
        isBookmarked: row.isBookmarked,
        indexTabs: _indexTabsFromRows(
          row,
          _convertRowsSafely(
            tabs,
            _indexTabFromRow,
            'NotebookRepository._readPage(${row.uid}, tab row)',
            markCorrupt,
          ),
        ),
      ),
      hadCorruptRows: hadCorruptRows,
    );
  }

  Future<List<T>> _readRowsSafely<T>({
    required Future<List<T>> Function() read,
    required String source,
    required void Function() onError,
  }) async {
    try {
      return await read();
    } catch (error, stackTrace) {
      onError();
      _recordReadError(error, stackTrace, source);
      return <T>[];
    }
  }

  List<R> _convertRowsSafely<T, R>(
    List<T> rows,
    R Function(T row) convert,
    String source,
    void Function() onError,
  ) {
    final converted = <R>[];
    for (final row in rows) {
      try {
        converted.add(convert(row));
      } catch (error, stackTrace) {
        onError();
        _recordReadError(error, stackTrace, source);
      }
    }
    return converted;
  }

  void _recordReadError(Object error, StackTrace stackTrace, String source) {
    debugPrint('$source: $error');
    final handler = _readErrorHandler;
    if (handler != null) {
      handler(error, stackTrace, source);
      return;
    }
    AppErrorLog.instance.record(error, stackTrace, source: source);
  }

  List<IndexTab> _indexTabsFromRows(PageRow page, List<IndexTab> tabs) {
    if (tabs.isNotEmpty || page.legacyIndexTabColorValue == null) {
      return tabs;
    }
    return [
      IndexTab(
        id: _uuid.v4(),
        color: Color(page.legacyIndexTabColorValue!),
        position: page.legacyIndexTabPosition ?? 0.0,
      ),
    ];
  }

  Future<void> _insertPage(
    String notebookUid,
    NotePage page,
    int pageIndex,
  ) async {
    await database
        .into(database.pageRows)
        .insertOnConflictUpdate(
          PageRowsCompanion.insert(
            uid: page.id,
            notebookUid: notebookUid,
            pageIndex: pageIndex,
            title: page.title,
            isBookmarked: page.isBookmarked,
            legacyIndexTabColorValue: Value(
              page.indexTabs.firstOrNull?.color.toARGB32(),
            ),
            legacyIndexTabPosition: Value(page.indexTabs.firstOrNull?.position),
          ),
        );
    for (final tab in page.indexTabs) {
      await database
          .into(database.indexTabRows)
          .insert(_indexTabToCompanion(page.id, tab));
    }
    for (final entry in page.textBlocks.asMap().entries) {
      await database
          .into(database.textBlockRows)
          .insert(_textToCompanion(page.id, entry.value, entry.key));
    }
    for (final entry in page.imageBlocks.asMap().entries) {
      await database
          .into(database.imageBlockRows)
          .insert(_imageToCompanion(page.id, entry.value, entry.key));
    }
    for (final entry in page.inkStrokes.asMap().entries) {
      await database
          .into(database.inkStrokeRows)
          .insert(_strokeToCompanion(page.id, entry.value, entry.key));
    }
  }

  Future<void> _deleteNotebookChildren(String notebookUid) async {
    final pages = await (database.select(
      database.pageRows,
    )..where((item) => item.notebookUid.equals(notebookUid))).get();
    for (final page in pages) {
      await _deletePageChildren(page.uid);
    }
    await (database.delete(
      database.pageRows,
    )..where((item) => item.notebookUid.equals(notebookUid))).go();
  }

  Future<void> _deletePageChildren(String pageUid) async {
    await (database.delete(
      database.indexTabRows,
    )..where((item) => item.pageUid.equals(pageUid))).go();
    await (database.delete(
      database.textBlockRows,
    )..where((item) => item.pageUid.equals(pageUid))).go();
    await (database.delete(
      database.imageBlockRows,
    )..where((item) => item.pageUid.equals(pageUid))).go();
    await (database.delete(
      database.inkStrokeRows,
    )..where((item) => item.pageUid.equals(pageUid))).go();
  }

  String _buildRecoveredTitle(String title, String reason) {
    final trimmedTitle = title.trim().isEmpty ? 'Untitled' : title.trim();
    return '$trimmedTitle ($reason)';
  }

  IndexTab _indexTabFromRow(IndexTabRow row) {
    return IndexTab(
      id: row.uid,
      color: Color(row.colorValue),
      position: row.position,
    );
  }

  IndexTabRowsCompanion _indexTabToCompanion(String pageUid, IndexTab tab) {
    return IndexTabRowsCompanion.insert(
      uid: tab.id,
      pageUid: pageUid,
      colorValue: tab.color.toARGB32(),
      position: tab.position,
    );
  }

  TextBlock _textFromRow(TextBlockRow row) {
    return TextBlock(
      id: row.uid,
      text: row.plainText,
      deltaJson: row.deltaJson,
      position: Offset(row.dx, row.dy),
      fontSize: row.fontSize,
      color: Color(row.colorValue),
      width: row.width,
      rotation: row.rotation,
    );
  }

  TextBlockRowsCompanion _textToCompanion(
    String pageUid,
    TextBlock block,
    int sortIndex,
  ) {
    return TextBlockRowsCompanion.insert(
      uid: block.id,
      pageUid: pageUid,
      plainText: block.text,
      deltaJson: Value(block.deltaJson),
      fontSize: block.fontSize,
      colorValue: block.color.toARGB32(),
      width: block.width,
      rotation: block.rotation,
      dx: block.position.dx,
      dy: block.position.dy,
      sortIndex: sortIndex,
    );
  }

  ImageBlock _imageFromRow(ImageBlockRow row) {
    return ImageBlock(
      id: row.uid,
      path: row.path,
      ocrText: row.ocrText,
      position: Offset(row.dx, row.dy),
      width: row.width,
      height: row.height,
      bytes: _bytesFromEntity(row.bytes),
      imageExt: row.imageExt,
      imageMime: row.imageMime,
      rotation: row.rotation,
      cropLeft: row.cropLeft,
      cropTop: row.cropTop,
      cropRight: row.cropRight,
      cropBottom: row.cropBottom,
    );
  }

  ImageBlockRowsCompanion _imageToCompanion(
    String pageUid,
    ImageBlock block,
    int sortIndex,
  ) {
    return ImageBlockRowsCompanion.insert(
      uid: block.id,
      pageUid: pageUid,
      path: block.path,
      ocrText: block.ocrText,
      bytes: Value(block.path.isEmpty ? block.bytes : null),
      imageExt: Value(block.imageExt),
      imageMime: Value(block.imageMime),
      width: block.width,
      height: block.height,
      rotation: block.rotation,
      dx: block.position.dx,
      dy: block.position.dy,
      cropLeft: block.cropLeft,
      cropTop: block.cropTop,
      cropRight: block.cropRight,
      cropBottom: block.cropBottom,
      sortIndex: sortIndex,
    );
  }

  InkStroke _strokeFromRow(InkStrokeRow row) {
    return InkStroke(
      id: row.uid,
      points: _pointsFromJson(row.pointsJson),
      color: Color(row.colorValue),
      width: row.width,
      tool: _toolFromIndex(row.toolIndex),
    );
  }

  InkStrokeRowsCompanion _strokeToCompanion(
    String pageUid,
    InkStroke stroke,
    int sortIndex,
  ) {
    return InkStrokeRowsCompanion.insert(
      uid: stroke.id,
      pageUid: pageUid,
      colorValue: stroke.color.toARGB32(),
      width: stroke.width,
      toolIndex: _toolToIndex(stroke.tool),
      pointsJson: _pointsToJson(stroke.points),
      sortIndex: sortIndex,
    );
  }

  String _pointsToJson(List<InkPoint> points) {
    return jsonEncode(
      points
          .map(
            (point) => {
              'dx': point.dx,
              'dy': point.dy,
              'pressure': point.pressure,
            },
          )
          .toList(),
    );
  }

  List<InkPoint> _pointsFromJson(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! List<dynamic>) {
      return <InkPoint>[];
    }
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(
          (point) => InkPoint(
            dx: (point['dx'] as num).toDouble(),
            dy: (point['dy'] as num).toDouble(),
            pressure: (point['pressure'] as num?)?.toDouble() ?? 0.5,
          ),
        )
        .toList();
  }

  static Map<String, dynamic> _notebookToJson(Notebook notebook) {
    return {
      'uid': notebook.uid,
      'title': notebook.title,
      'kind': notebook.kind.indexValue,
      'folder': notebook.folder,
      'createdAt': notebook.createdAt.toIso8601String(),
      'updatedAt': notebook.updatedAt.toIso8601String(),
      'pages': notebook.pages.map(_pageToJson).toList(),
    };
  }

  Notebook _notebookFromJson(Map<String, dynamic> json) {
    return Notebook(
      uid: json['uid'] as String,
      title: json['title'] as String,
      kind: NotebookKindValue.fromIndex((json['kind'] as num?)?.toInt() ?? 0),
      folder: (json['folder'] as String?) ?? 'Notes',
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      pages: (json['pages'] as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(_pageFromJson)
          .toList(),
    );
  }

  static Map<String, dynamic> _pageToJson(NotePage page) {
    return {
      'id': page.id,
      'title': page.title,
      'isBookmarked': page.isBookmarked,
      'indexTabColor': page.indexTabs.firstOrNull?.color.toARGB32(),
      'indexTabPosition': page.indexTabs.firstOrNull?.position,
      'indexTabs': page.indexTabs.map(_indexTabToJson).toList(),
      'textBlocks': page.textBlocks.map(_textToJson).toList(),
      'imageBlocks': page.imageBlocks.map(_imageToJson).toList(),
      'inkStrokes': page.inkStrokes.map(_strokeToJson).toList(),
    };
  }

  NotePage _pageFromJson(Map<String, dynamic> json) {
    return NotePage(
      id: json['id'] as String,
      title: json['title'] as String,
      textBlocks: (json['textBlocks'] as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(_textFromJson)
          .toList(),
      imageBlocks: (json['imageBlocks'] as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(_imageFromJson)
          .toList(),
      inkStrokes: (json['inkStrokes'] as List<dynamic>? ?? <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(_strokeFromJson)
          .toList(),
      isBookmarked: json['isBookmarked'] as bool? ?? false,
      indexTabs: _indexTabsFromJson(json),
    );
  }

  static Map<String, dynamic> _indexTabToJson(IndexTab tab) {
    return {
      'id': tab.id,
      'color': tab.color.toARGB32(),
      'position': tab.position,
    };
  }

  List<IndexTab> _indexTabsFromJson(Map<String, dynamic> json) {
    final tabs = (json['indexTabs'] as List<dynamic>? ?? <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(_indexTabFromJson)
        .toList();
    if (tabs.isNotEmpty || json['indexTabColor'] == null) {
      return tabs;
    }
    return [
      IndexTab(
        id: _uuid.v4(),
        color: Color(json['indexTabColor'] as int),
        position: (json['indexTabPosition'] as num?)?.toDouble() ?? 0.0,
      ),
    ];
  }

  IndexTab _indexTabFromJson(Map<String, dynamic> json) {
    return IndexTab(
      id: (json['id'] as String?) ?? _uuid.v4(),
      color: Color(json['color'] as int),
      position: (json['position'] as num).toDouble(),
    );
  }

  static Map<String, dynamic> _textToJson(TextBlock block) {
    return {
      'id': block.id,
      'text': block.text,
      'deltaJson': block.deltaJson,
      'fontSize': block.fontSize,
      'color': block.color.toARGB32(),
      'width': block.width,
      'rotation': block.rotation,
      'dx': block.position.dx,
      'dy': block.position.dy,
    };
  }

  TextBlock _textFromJson(Map<String, dynamic> json) {
    return TextBlock(
      id: json['id'] as String,
      text: json['text'] as String,
      deltaJson: json['deltaJson'] as String?,
      position: Offset(
        (json['dx'] as num).toDouble(),
        (json['dy'] as num).toDouble(),
      ),
      fontSize: (json['fontSize'] as num).toDouble(),
      color: Color(json['color'] as int),
      width: (json['width'] as num).toDouble(),
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0.0,
    );
  }

  static Map<String, dynamic> _imageToJson(ImageBlock block) {
    final bytesBase64 = _bytesToBase64(_imageBytesForJson(block));
    return {
      'id': block.id,
      'path': block.path,
      'ocrText': block.ocrText,
      'bytes': bytesBase64,
      'imageExt': block.imageExt,
      'imageMime': block.imageMime,
      'width': block.width,
      'height': block.height,
      'rotation': block.rotation,
      'cropLeft': block.cropLeft,
      'cropTop': block.cropTop,
      'cropRight': block.cropRight,
      'cropBottom': block.cropBottom,
      'dx': block.position.dx,
      'dy': block.position.dy,
    };
  }

  ImageBlock _imageFromJson(Map<String, dynamic> json) {
    return ImageBlock(
      id: json['id'] as String,
      path: json['path'] as String? ?? '',
      ocrText: json['ocrText'] as String? ?? '',
      bytes: _bytesFromBase64(json['bytes']),
      imageExt: json['imageExt'] as String?,
      imageMime: json['imageMime'] as String?,
      position: Offset(
        (json['dx'] as num).toDouble(),
        (json['dy'] as num).toDouble(),
      ),
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0.0,
      cropLeft: (json['cropLeft'] as num?)?.toDouble() ?? 0.0,
      cropTop: (json['cropTop'] as num?)?.toDouble() ?? 0.0,
      cropRight: (json['cropRight'] as num?)?.toDouble() ?? 1.0,
      cropBottom: (json['cropBottom'] as num?)?.toDouble() ?? 1.0,
    );
  }

  static Uint8List? _imageBytesForJson(ImageBlock block) {
    final bytes = block.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      return bytes;
    }
    if (block.path.isEmpty) {
      return null;
    }
    if (kIsWeb) {
      return null;
    }
    final file = File(block.path);
    if (!file.existsSync()) {
      return null;
    }
    try {
      return file.readAsBytesSync();
    } catch (e) {
      debugPrint('NotebookRepository._imageBytesForJson failed: $e');
      return null;
    }
  }

  static Map<String, dynamic> _strokeToJson(InkStroke stroke) {
    return {
      'id': stroke.id,
      'color': stroke.color.toARGB32(),
      'width': stroke.width,
      'tool': _toolToIndex(stroke.tool),
      'points': stroke.points
          .map(
            (point) => {
              'dx': point.dx,
              'dy': point.dy,
              'pressure': point.pressure,
            },
          )
          .toList(),
    };
  }

  InkStroke _strokeFromJson(Map<String, dynamic> json) {
    final toolIndex = (json['tool'] as num?)?.toInt() ?? 0;
    return InkStroke(
      id: json['id'] as String,
      color: Color(json['color'] as int),
      width: (json['width'] as num).toDouble(),
      tool: _toolFromIndex(toolIndex),
      points: (json['points'] as List<dynamic>? ?? <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(
            (point) => InkPoint(
              dx: (point['dx'] as num).toDouble(),
              dy: (point['dy'] as num).toDouble(),
              pressure: (point['pressure'] as num?)?.toDouble() ?? 0.5,
            ),
          )
          .toList(),
    );
  }

  DrawingTool _toolFromIndex(int index) {
    final values = DrawingTool.values;
    if (index < 0 || index >= values.length) {
      return DrawingTool.pen;
    }
    return values[index];
  }

  static int _toolToIndex(DrawingTool tool) => tool.index;

  Uint8List? _bytesFromEntity(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    return Uint8List.fromList(bytes);
  }

  static String? _bytesToBase64(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    return base64Encode(bytes);
  }

  Uint8List? _bytesFromBase64(Object? value) {
    if (value is! String || value.isEmpty) {
      return null;
    }
    try {
      return base64Decode(value);
    } catch (_) {
      return null;
    }
  }
}

class _NotebookReadResult {
  const _NotebookReadResult({
    required this.notebook,
    required this.hadCorruptRows,
  });

  final Notebook notebook;
  final bool hadCorruptRows;
}

class _PageReadResult {
  const _PageReadResult({required this.page, required this.hadCorruptRows});

  final NotePage page;
  final bool hadCorruptRows;
}

class DataIntegrityProtectionException implements Exception {
  const DataIntegrityProtectionException(this.message);

  final String message;

  @override
  String toString() => 'DataIntegrityProtectionException: $message';
}

class _NotebookContentSummary {
  const _NotebookContentSummary({
    required this.pages,
    required this.textBlocks,
    required this.textCharacters,
    required this.imageBlocks,
    required this.inkStrokes,
    required this.inkPoints,
    required this.indexTabs,
  });

  factory _NotebookContentSummary.fromNotebook(Notebook notebook) {
    return _NotebookContentSummary.fromPages(notebook.pages);
  }

  factory _NotebookContentSummary.fromPages(List<NotePage> pages) {
    var textBlocks = 0;
    var textCharacters = 0;
    var imageBlocks = 0;
    var inkStrokes = 0;
    var inkPoints = 0;
    var indexTabs = 0;
    for (final page in pages) {
      textBlocks += page.textBlocks.length;
      textCharacters += page.textBlocks.fold<int>(
        0,
        (sum, block) => sum + block.text.length,
      );
      imageBlocks += page.imageBlocks.length;
      inkStrokes += page.inkStrokes.length;
      inkPoints += page.inkStrokes.fold<int>(
        0,
        (sum, stroke) => sum + stroke.points.length,
      );
      indexTabs += page.indexTabs.length;
    }
    return _NotebookContentSummary(
      pages: pages.length,
      textBlocks: textBlocks,
      textCharacters: textCharacters,
      imageBlocks: imageBlocks,
      inkStrokes: inkStrokes,
      inkPoints: inkPoints,
      indexTabs: indexTabs,
    );
  }

  final int pages;
  final int textBlocks;
  final int textCharacters;
  final int imageBlocks;
  final int inkStrokes;
  final int inkPoints;
  final int indexTabs;

  int get contentItems => textBlocks + imageBlocks + inkStrokes;

  int get contentScore =>
      textCharacters + imageBlocks * 100 + inkStrokes * 10 + inkPoints;

  Map<String, int> toJson() {
    return {
      'pages': pages,
      'textBlocks': textBlocks,
      'textCharacters': textCharacters,
      'imageBlocks': imageBlocks,
      'inkStrokes': inkStrokes,
      'inkPoints': inkPoints,
      'indexTabs': indexTabs,
      'contentItems': contentItems,
      'contentScore': contentScore,
    };
  }
}

List<String> _suspiciousReductionReasons(
  _NotebookContentSummary before,
  _NotebookContentSummary attempted,
) {
  final reasons = <String>[];
  if (before.contentItems > 0 && attempted.contentItems == 0) {
    reasons.add('all_content_removed');
  }
  if (before.pages > attempted.pages &&
      before.contentItems > attempted.contentItems) {
    reasons.add('pages_and_content_removed');
  }
  if (before.contentScore >= 100 &&
      attempted.contentScore * 10 <= before.contentScore) {
    reasons.add('content_score_dropped_at_least_90_percent');
  }
  return reasons;
}
