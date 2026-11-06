import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/editor_history_store.dart';
import 'package:program/data/sync/editor_sqlite_projector.dart';
import 'package:program/data/sync/operation_gateway.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/data/sync/sync_engine.dart';
import 'package:program/data/sync/verified_editor_asset_buffer.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/editor/state/editor_v2_operation_writer.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';

import 'support/native_test_documents.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
  'AAAADUlEQVR4nGMQMgn7DwAClAGcHVtGXwAAAABJRU5ErkJggg==',
);

class _Picker extends FilePicker {
  _Picker(this.file);
  final File file;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult([
    PlatformFile(
      name: file.uri.pathSegments.last,
      size: await file.length(),
      path: file.path,
    ),
  ]);
}

class _TemporaryDirectoryProvider extends PathProviderPlatform {
  _TemporaryDirectoryProvider(this.original, this.path);
  final PathProviderPlatform original;
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() =>
      original.getApplicationDocumentsPath();
  @override
  Future<String?> getApplicationSupportPath() =>
      original.getApplicationSupportPath();
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _OfflineGateway implements OperationGateway {
  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async => throw const SocketException('Offline native media regression');
  @override
  Future<OperationFeedPage> readAfter(int cursor) async =>
      throw const SocketException('Offline native media regression');
}

class _Session {
  late final NotesDatabase database;
  late final NotebookRepository repository;
  late final SyncEngine engine;
  late final EditorController editor;
  bool _closed = false;

  static Future<_Session> open(
    File file, {
    String? documentId,
    bool v2 = true,
  }) async {
    final session = _Session();
    session.database = NotesDatabase(NativeDatabase(file));
    session.repository = NotebookRepository(session.database);
    final notebook = documentId == null
        ? await session.repository.createNotebook()
        : (await session.repository.getNotebook(documentId))!;
    final projector = EditorSqliteProjector(
      session.database,
      verifiedAssetBuffer: VerifiedEditorAssetBuffer(),
    );
    session.engine = SyncEngine(
      store: OperationStore(session.database),
      gateway: _OfflineGateway(),
      actorId: 'native-image-peer',
      checkpointScope: 'native-image-account',
      enableRealtime: false,
      applyRemote: (operation, _) => projector.apply(operation),
    );
    session.editor = EditorController(
      repository: session.repository,
      notebook: notebook,
      operationWriter: v2
          ? EditorV2OperationWriter(
              syncEngine: session.engine,
              projector: projector,
            )
          : null,
    );
    await session.editor.historyReady;
    await session.editor.preferencesReady;
    return session;
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      await editor.flushPendingSaves();
    } finally {
      editor.dispose();
      await engine.stop();
      await database.close();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useIsolatedNativeTestDocuments();
  late Directory directory;
  late File source;
  late File databaseFile;
  late FilePicker originalPicker;
  late PathProviderPlatform originalPaths;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'nn-native-media-history-',
    );
    source = File('${directory.path}/native.png');
    await source.writeAsBytes(_png);
    databaseFile = File('${directory.path}/notes.sqlite');
    originalPicker = FilePicker.platform;
    FilePicker.platform = _Picker(source);
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TemporaryDirectoryProvider(
      originalPaths,
      directory.path,
    );
  });
  tearDown(() async {
    FilePicker.platform = originalPicker;
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  test(
    'native picker freezes bytes before commit and recovers image history after restart',
    () async {
      var session = await _Session.open(databaseFile);
      addTearDown(() => session.close());
      final held = Completer<void>();
      final release = Completer<void>();
      final transaction = session.database.transaction(() async {
        held.complete();
        await release.future;
      });
      await held.future;
      try {
        expect(await session.editor.insertFromFilePicker(Offset.zero), isNull);
        final image = session.editor.currentPage.imageBlocks.single;
        expect(image.bytes, _png);
        await File(image.path).delete();
        await source.delete();
      } finally {
        release.complete();
        await transaction;
      }
      await session.editor.flushPendingSaves();
      final documentId = session.editor.notebook.uid;
      final imageId = session.editor.currentPage.imageBlocks.single.id;
      final checkpoint = (await EditorHistoryStore(session.engine.store).load(
        documentId: documentId,
        ownerId: session.engine.actorIdForDocument(documentId),
      ))!;
      expect(checkpoint.undo, hasLength(1));
      expect(
        jsonEncode(checkpoint.undo.single.after),
        isNot(contains(directory.path)),
      );
      await session.close();
      session = await _Session.open(databaseFile, documentId: documentId);
      expect(session.editor.canUndo, isTrue);
      expect(session.editor.currentPage.imageBlocks.single.bytes, _png);
      session.editor.undo();
      await session.editor.flushPendingSaves();
      expect(session.editor.currentPage.imageBlocks, isEmpty);
      session.editor.redo();
      await session.editor.flushPendingSaves();
      final restored = session.editor.currentPage.imageBlocks.single;
      expect(restored.id, isNot(imageId));
      expect(restored.bytes, _png);
      expect(
        (await session.repository.getNotebook(
          documentId,
        ))!.pages.single.imageBlocks.single.bytes,
        _png,
      );
    },
  );

  test(
    'restoring native image cache keeps bytes without duplicating assets or Undo steps',
    () async {
      final session = await _Session.open(databaseFile);
      addTearDown(session.close);
      expect(await session.editor.insertFromFilePicker(Offset.zero), isNull);
      await session.editor.flushPendingSaves();
      final original = session.editor.currentPage.imageBlocks.single;
      final before = await session.engine.store.pending();
      await File(original.path).delete();
      await session.editor.restoreImageCache(0, original.id);
      final cached = session.editor.currentPage.imageBlocks.single;
      expect(cached.bytes, _png);
      expect(cached.path, isNot(original.path));
      expect(await File(cached.path).exists(), isTrue);
      await session.editor.flushPendingSaves();
      expect(
        (await session.engine.store.pending()).map((op) => op.operationId),
        before.map((op) => op.operationId),
      );
      session.editor.addInkStroke(const [
        InkPoint(dx: 2, dy: 3, pressure: 0.6),
      ]);
      await session.editor.flushPendingSaves();
      final after = await session.engine.store.pending();
      expect(after.length, before.length + 1);
      expect(after.last.kind, OperationKind.strokeCreate);
      expect(
        after.where((op) => op.kind == OperationKind.assetAttach).length,
        before.where((op) => op.kind == OperationKind.assetAttach).length,
      );
      await File(cached.path).delete();
      session.editor.undo();
      await session.editor.flushPendingSaves();
      expect(session.editor.currentPage.inkStrokes, isEmpty);
      expect(session.editor.currentPage.imageBlocks.single.bytes, _png);
    },
  );

  test(
    'Linux PDF pages freeze rendered PNG bytes before the history transaction',
    () async {
      final document = pw.Document();
      document.addPage(
        pw.Page(
          pageFormat: const PdfPageFormat(40, 60),
          margin: pw.EdgeInsets.zero,
          build: (_) =>
              pw.Container(width: 20, height: 20, color: PdfColors.blue),
        ),
      );
      final pdf = File('${directory.path}/native.pdf');
      await pdf.writeAsBytes(await document.save());
      FilePicker.platform = _Picker(pdf);
      final session = await _Session.open(databaseFile);
      addTearDown(session.close);
      final held = Completer<void>();
      final release = Completer<void>();
      final transaction = session.database.transaction(() async {
        held.complete();
        await release.future;
      });
      await held.future;
      try {
        expect(await session.editor.insertFromFilePicker(Offset.zero), isNull);
        final image = session.editor.currentPage.imageBlocks.single;
        expect(image.imageMime, 'image/png');
        expect(image.bytes, isNotNull);
        expect(image.bytes!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
        await File(image.path).delete();
        await pdf.delete();
      } finally {
        release.complete();
        await transaction;
      }
      await session.editor.flushPendingSaves();
      final expected = Uint8List.fromList(
        session.editor.currentPage.imageBlocks.single.bytes!,
      );
      session.editor.undo();
      await session.editor.flushPendingSaves();
      expect(session.editor.currentPage.imageBlocks, isEmpty);
      session.editor.redo();
      await session.editor.flushPendingSaves();
      expect(session.editor.currentPage.imageBlocks.single.bytes, expected);
    },
    skip: !Platform.isLinux,
  );

  test('legacy native imports remain file-backed', () async {
    final session = await _Session.open(databaseFile, v2: false);
    addTearDown(session.close);
    expect(await session.editor.insertFromFilePicker(Offset.zero), isNull);
    await session.editor.flushPendingSaves();
    final image = session.editor.currentPage.imageBlocks.single;
    expect(image.bytes, isNull);
    expect(await File(image.path).exists(), isTrue);
    expect(await session.engine.store.pending(), isEmpty);
  });

  for (final size in [0, 64 * 1024 * 1024 + 1]) {
    test(
      'rejects a $size-byte native image without changing the journal',
      () async {
        final handle = await source.open(mode: FileMode.write);
        try {
          await handle.truncate(size);
        } finally {
          await handle.close();
        }
        final session = await _Session.open(databaseFile);
        addTearDown(session.close);
        expect(
          await session.editor.insertFromFilePicker(Offset.zero),
          'Failed to insert file.',
        );
        await session.editor.flushPendingSaves();
        expect(session.editor.currentPage.imageBlocks, isEmpty);
        expect(session.editor.canUndo, isFalse);
        expect(await session.engine.store.pending(), isEmpty);
        expect(
          (await session.repository.getNotebook(
            session.editor.notebook.uid,
          ))!.pages.single.imageBlocks,
          isEmpty,
        );
      },
    );
  }
}
