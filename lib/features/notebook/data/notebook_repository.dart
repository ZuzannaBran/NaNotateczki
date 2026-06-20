import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/error/app_error_log.dart';
import '../../../data/drift/notes_database.dart';
import '../domain/drawing_tool.dart';
import '../domain/image_block.dart';
import '../domain/ink_stroke.dart';
import '../domain/notebook.dart';
import '../domain/notebook_kind.dart';
import '../domain/note_page.dart';
import '../domain/text_block.dart';

class NotebookRepository {
  NotebookRepository(
    this.database, {
    this.onChanged,
    void Function(Object error, StackTrace stackTrace, String source)?
    readErrorHandler,
  }) : _readErrorHandler = readErrorHandler;

  final NotesDatabase database;
  final void Function()? onChanged;
  final void Function(Object error, StackTrace stackTrace, String source)?
  _readErrorHandler;
  final Uuid _uuid = const Uuid();
  bool _lastFetchSkippedCorruptRows = false;
  final List<String> _lastCorruptNotebookIds = <String>[];
  final Map<String, DateTime> _latestPersistedUpdates = <String, DateTime>{};
  final Map<String, Future<void>> _saveTails = <String, Future<void>>{};

  bool get lastFetchSkippedCorruptRows => _lastFetchSkippedCorruptRows;
  int get lastCorruptNotebookCount => _lastCorruptNotebookIds.length;
  List<String> get lastCorruptNotebookIds =>
      List.unmodifiable(_lastCorruptNotebookIds);

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

  Future<bool> saveNotebook(Notebook notebook) async {
    if (notebook.pages.isEmpty) {
      throw ArgumentError.value(
        notebook.uid,
        'notebook.uid',
        'Cannot save a notebook without pages.',
      );
    }
    final previous = _saveTails[notebook.uid] ?? Future<void>.value();
    final completion = Completer<void>();
    _saveTails[notebook.uid] = completion.future;
    try {
      await previous;
      return await _saveNotebookNow(notebook);
    } finally {
      completion.complete();
      if (identical(_saveTails[notebook.uid], completion.future)) {
        _saveTails.remove(notebook.uid);
      }
    }
  }

  Future<bool> _saveNotebookNow(Notebook notebook) async {
    if (_lastCorruptNotebookIds.contains(notebook.uid)) {
      debugPrint(
        'NotebookRepository.saveNotebook rejected partially read notebook '
        'uid=${notebook.uid}',
      );
      return false;
    }
    final notebookToSave = await _persistInlineImages(notebook);

    final saved = await database.transaction(() async {
      final existing = await (database.select(
        database.notebookRows,
      )..where((row) => row.uid.equals(notebookToSave.uid))).getSingleOrNull();
      final persistedAt = existing?.updatedAt;
      final trackedAt = _latestPersistedUpdates[notebookToSave.uid];
      final latestAt =
          trackedAt != null &&
              (persistedAt == null || trackedAt.isAfter(persistedAt))
          ? trackedAt
          : persistedAt;
      if (latestAt != null && latestAt.isAfter(notebookToSave.updatedAt)) {
        return false;
      }
      await database
          .into(database.notebookRows)
          .insertOnConflictUpdate(
            NotebookRowsCompanion.insert(
              uid: notebookToSave.uid,
              title: notebookToSave.title,
              kindIndex: notebookToSave.kind.indexValue,
              folder: notebookToSave.folder,
              createdAt: notebookToSave.createdAt,
              updatedAt: notebookToSave.updatedAt,
            ),
          );
      await _deleteNotebookChildren(notebookToSave.uid);
      for (final entry in notebookToSave.pages.asMap().entries) {
        await _insertPage(notebookToSave.uid, entry.value, entry.key);
      }
      return true;
    });
    if (saved) {
      _latestPersistedUpdates[notebookToSave.uid] = notebookToSave.updatedAt;
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
          : latestAt.add(const Duration(microseconds: 1));
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
    onChanged?.call();
  }

  List<Map<String, dynamic>> encodeNotebooks(List<Notebook> items) {
    return items.map(_notebookToJson).toList();
  }

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
        .insert(
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
      await (database.delete(
        database.indexTabRows,
      )..where((item) => item.pageUid.equals(page.uid))).go();
      await (database.delete(
        database.textBlockRows,
      )..where((item) => item.pageUid.equals(page.uid))).go();
      await (database.delete(
        database.imageBlockRows,
      )..where((item) => item.pageUid.equals(page.uid))).go();
      await (database.delete(
        database.inkStrokeRows,
      )..where((item) => item.pageUid.equals(page.uid))).go();
    }
    await (database.delete(
      database.pageRows,
    )..where((item) => item.notebookUid.equals(notebookUid))).go();
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

  Map<String, dynamic> _notebookToJson(Notebook notebook) {
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

  Map<String, dynamic> _pageToJson(NotePage page) {
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

  Map<String, dynamic> _indexTabToJson(IndexTab tab) {
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

  Map<String, dynamic> _textToJson(TextBlock block) {
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

  Map<String, dynamic> _imageToJson(ImageBlock block) {
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

  Uint8List? _imageBytesForJson(ImageBlock block) {
    final bytes = block.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      return bytes;
    }
    if (block.path.isEmpty) {
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

  Map<String, dynamic> _strokeToJson(InkStroke stroke) {
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

  int _toolToIndex(DrawingTool tool) => tool.index;

  Uint8List? _bytesFromEntity(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    return Uint8List.fromList(bytes);
  }

  String? _bytesToBase64(Uint8List? bytes) {
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
