import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/core/theme/app_theme.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/editor_sqlite_projector.dart';
import 'package:program/data/sync/operation_gateway.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/data/sync/sync_engine.dart';
import 'package:program/data/sync/verified_editor_asset_buffer.dart';
import 'package:program/features/editor/presentation/widgets/page_overlay.dart';
import 'package:program/features/editor/presentation/widgets/text_edit_toolbar.dart';
import 'package:program/features/editor/presentation/widgets/text_hud_block.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/editor/state/editor_v2_operation_writer.dart';
import 'package:program/features/editor/state/quill_paste_plan.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/text_block.dart';

import 'support/native_test_documents.dart';

final _png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 1]);
String get _imageUri => 'data:image/png;base64,${base64Encode(_png)}';

class _Picker extends FilePicker {
  Future<FilePickerResult?> Function()? result;
  List<String>? extensions;

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
  }) async {
    expect(type, FileType.custom);
    expect(allowMultiple, isFalse);
    extensions = allowedExtensions;
    return result == null ? null : await result!();
  }
}

class _OfflineGateway implements OperationGateway {
  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async => throw StateError('Rich paste must not access transport.');
  @override
  Future<OperationFeedPage> readAfter(int cursor) async =>
      throw StateError('Rich paste must not access transport.');
}

class _Fixture {
  final database = NotesDatabase(NativeDatabase.memory());
  final buffer = VerifiedEditorAssetBuffer();
  late final NotebookRepository repository;
  late final OperationStore store;
  late final EditorSqliteProjector projector;
  late final SyncEngine engine;
  late final EditorV2OperationWriter writer;
  late final EditorController editor;
  late final quill.QuillController text;
  late final StreamSubscription<quill.DocChange> subscription;
  bool disposed = false;
  static const blockId = 'rich-paste-target';

  Future<void> initialize() async {
    repository = NotebookRepository(database);
    store = OperationStore(database);
    projector = EditorSqliteProjector(database, verifiedAssetBuffer: buffer);
    engine = SyncEngine(
      store: store,
      gateway: _OfflineGateway(),
      actorId: 'rich-paste',
      checkpointScope: 'rich-paste',
      enableRealtime: false,
      applyRemote: (operation, _) => projector.apply(operation),
    );
    writer = EditorV2OperationWriter(syncEngine: engine, projector: projector);
    final notebook = await repository.createNotebook();
    final block = TextBlock(
      id: blockId,
      text: 'KeepOriginal',
      deltaJson: jsonEncode([
        {
          'insert': 'Keep',
          'attributes': {'bold': true},
        },
        {
          'insert': 'Original',
          'attributes': {'italic': true},
        },
        {'insert': '\n'},
      ]),
      position: Offset.zero,
      fontSize: 18,
      color: const Color(0xFF123456),
      width: 320,
    );
    await writer.writePageChange(
      documentId: notebook.uid,
      before: notebook.pages.single,
      after: notebook.pages.single.copyWith(textBlocks: [block]),
    );
    final persisted = (await repository.getNotebook(notebook.uid))!;
    editor = EditorController(
      repository: repository,
      notebook: persisted,
      operationWriter: writer,
      saveDebounce: const Duration(days: 1),
    );
    await editor.historyReady;
    await editor.preferencesReady;
    text = quill.QuillController(
      document: quill.Document.fromJson(
        jsonDecode(persisted.pages.single.textBlocks.single.deltaJson!) as List,
      ),
      selection: const TextSelection(baseOffset: 0, extentOffset: 4),
    );
    editor.setActiveTextBlock(blockId, text);
    subscription = text.document.changes.listen((_) {
      if (disposed) {
        return;
      }
      editor.updateTextBlockContent(
        editor.currentPage.textBlocks.single,
        plainText: text.document.toPlainText(),
        deltaJson: jsonEncode(text.document.toDelta().toJson()),
      );
    });
  }

  Future<void> flush() async {
    await Future<void>.delayed(Duration.zero);
    await editor.flushPendingSaves();
  }

  Future<void> close() async {
    if (!disposed) {
      await flush();
      editor.dispose();
      disposed = true;
    }
    await subscription.cancel();
    text.dispose();
    await engine.stop();
    await database.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useIsolatedNativeTestDocuments();
  useInMemoryTestTextStorage();
  late _Fixture fixture;
  late _Picker picker;
  setUp(() async {
    picker = _Picker();
    FilePicker.platform = picker;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => null,
        );
    fixture = _Fixture();
    await fixture.initialize();
  });

  final inlineFiles = <String, List<int>>{
    'png': [137, 80, 78, 71, 13, 10, 26, 10, 1],
    'jpeg': [255, 216, 255, 1],
    'webp': [82, 73, 70, 70, 0, 0, 0, 0, 87, 69, 66, 80],
    'pdf': [37, 80, 68, 70, 45, 49],
  };
  for (final entry in inlineFiles.entries) {
    test(
      'inline ${entry.key} replaces only selection and survives Undo/Redo',
      () async {
        final original = fixture.editor.currentPage.textBlocks.single.deltaJson;
        final bytes = Uint8List.fromList(entry.value);
        expect(
          await fixture.editor.insertQuillFile(
            blockId: _Fixture.blockId,
            readBytes: () async => bytes,
          ),
          isTrue,
        );
        await fixture.flush();
        final block = fixture.editor.currentPage.textBlocks.single;
        expect(block.text, contains('Original'));
        expect(block.text, isNot(contains('Keep')));
        final delta = jsonDecode(block.deltaJson!) as List;
        final embed =
            (delta.singleWhere((dynamic op) => op['insert'] is Map)
                    as Map)['insert']
                as Map;
        final type = entry.key == 'pdf' ? 'pdf' : 'image';
        expect(embed.keys.single, type);
        final assetId = (embed.values.single as String).substring(6);
        expect(
          await fixture.projector.verifiedTextAssetBytes(
            documentId: fixture.editor.notebook.uid,
            pageId: fixture.editor.currentPage.id,
            objectId: _Fixture.blockId,
            assetId: assetId,
          ),
          entry.value,
        );
        expect(
          (await fixture.store.pending()).where(
            (op) => op.kind == OperationKind.assetAttach,
          ),
          hasLength(1),
        );
        expect(fixture.editor.currentPage.imageBlocks, isEmpty);
        fixture.buffer.clear();
        fixture.editor.undo();
        await fixture.flush();
        expect(
          fixture.editor.currentPage.textBlocks.single.deltaJson,
          original,
        );
        fixture.editor.redo();
        await fixture.flush();
        expect(
          fixture.editor.currentPage.textBlocks.single.deltaJson,
          block.deltaJson,
        );
      },
    );
  }

  test(
    'inline picker cancellation and invalid bytes preserve selection',
    () async {
      final original = fixture.text.document.toDelta().toJson();
      final selection = fixture.text.selection;
      final pendingBefore = (await fixture.store.pending()).length;
      expect(
        await fixture.editor.insertQuillFile(blockId: _Fixture.blockId),
        isFalse,
      );
      expect(
        picker.extensions,
        containsAll(['png', 'jpg', 'jpeg', 'webp', 'pdf']),
      );
      await expectLater(
        fixture.editor.insertQuillFile(
          blockId: _Fixture.blockId,
          readBytes: () async => Uint8List.fromList([1, 2, 3]),
        ),
        throwsFormatException,
      );
      expect(fixture.text.document.toDelta().toJson(), original);
      expect(fixture.text.selection, selection);
      expect(await fixture.store.pending(), hasLength(pendingBefore));
    },
  );

  test(
    'inline picker reads native paths and rejects oversized metadata first',
    () async {
      final dir = await Directory.systemTemp.createTemp('nn-inline-file-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/selected.pdf');
      await file.writeAsBytes(inlineFiles['pdf']!);
      picker.result = () async => FilePickerResult([
        PlatformFile(name: 'selected.pdf', size: 6, path: file.path),
      ]);
      await fixture.editor.insertQuillFile(blockId: _Fixture.blockId);
      await fixture.flush();
      expect(
        fixture.editor.currentPage.textBlocks.single.deltaJson,
        contains('"pdf"'),
      );
      final before = fixture.text.document.toDelta().toJson();
      picker.result = () async => FilePickerResult([
        PlatformFile(
          name: 'oversized.pdf',
          size: QuillPastePlan.maximumBytes + 1,
          path: '${dir.path}/not-readable.pdf',
        ),
      ]);
      await expectLater(
        fixture.editor.insertQuillFile(blockId: _Fixture.blockId),
        throwsFormatException,
      );
      expect(fixture.text.document.toDelta().toJson(), before);
    },
  );

  test(
    'concurrent inline imports cannot overwrite the first completed import',
    () async {
      final firstBytes = Completer<Uint8List?>();
      final secondBytes = Completer<Uint8List?>();
      final first = fixture.editor.insertQuillFile(
        blockId: _Fixture.blockId,
        readBytes: () => firstBytes.future,
      );
      final second = fixture.editor.insertQuillFile(
        blockId: _Fixture.blockId,
        readBytes: () => secondBytes.future,
      );
      secondBytes.complete(Uint8List.fromList(inlineFiles['pdf']!));
      await second;
      firstBytes.complete(_png);
      await first;
      await fixture.flush();
      final delta = fixture.editor.currentPage.textBlocks.single.deltaJson!;
      expect(delta, contains('"pdf"'));
      expect(delta, isNot(contains('"image"')));
      expect(
        (await fixture.store.pending()).where(
          (op) => op.kind == OperationKind.assetAttach,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'inline picker rejects unexpected counts and inaccessible files',
    () async {
      final original = fixture.text.document.toDelta().toJson();
      final file = PlatformFile(name: 'selected.pdf', size: 6);
      for (final files in <List<PlatformFile>>[
        [],
        [file, file],
        [file],
      ]) {
        picker.result = () async => FilePickerResult(files);
        await expectLater(
          fixture.editor.insertQuillFile(blockId: _Fixture.blockId),
          throwsFormatException,
        );
        expect(fixture.text.document.toDelta().toJson(), original);
      }
      picker.result = () async => throw StateError('Picker unavailable');
      await expectLater(
        fixture.editor.insertQuillFile(blockId: _Fixture.blockId),
        throwsStateError,
      );
      expect(fixture.text.document.toDelta().toJson(), original);
    },
  );

  test(
    'inline picker checks actual native length before loading bytes',
    () async {
      final dir = await Directory.systemTemp.createTemp('nn-inline-size-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/large.pdf');
      final handle = await file.open(mode: FileMode.write);
      try {
        await handle.truncate(QuillPastePlan.maximumBytes + 1);
      } finally {
        await handle.close();
      }
      picker.result = () async => FilePickerResult([
        PlatformFile(name: 'large.pdf', size: 6, path: file.path),
      ]);
      final original = fixture.text.document.toDelta().toJson();
      await expectLater(
        fixture.editor.insertQuillFile(blockId: _Fixture.blockId),
        throwsFormatException,
      );
      expect(fixture.text.document.toDelta().toJson(), original);
      expect(
        (await fixture.store.pending()).any(
          (op) => op.kind == OperationKind.assetAttach,
        ),
        isFalse,
      );
    },
  );

  test(
    'inline picker never reads a file after its target becomes inactive',
    () async {
      final chosen = Completer<FilePickerResult?>();
      picker.result = () => chosen.future;
      final original = fixture.text.document.toDelta().toJson();
      final pending = fixture.editor.insertQuillFile(blockId: _Fixture.blockId);
      fixture.editor.clearActiveTextBlock();
      chosen.complete(
        FilePickerResult([
          PlatformFile(
            name: 'missing.pdf',
            size: 6,
            path: '/unavailable/nanotateczki-inline-canceled.pdf',
          ),
        ]),
      );
      expect(await pending, isTrue);
      expect(fixture.text.document.toDelta().toJson(), original);
    },
  );

  test(
    'inline picker cancels after selection changes and never opens read-only',
    () async {
      final bytes = Completer<Uint8List?>();
      final original = fixture.text.document.toDelta().toJson();
      final pending = fixture.editor.insertQuillFile(
        blockId: _Fixture.blockId,
        readBytes: () => bytes.future,
      );
      fixture.text.updateSelection(
        const TextSelection.collapsed(offset: 2),
        quill.ChangeSource.local,
      );
      bytes.complete(_png);
      await pending;
      expect(fixture.text.document.toDelta().toJson(), original);
      fixture.text.readOnly = true;
      await fixture.editor.insertQuillFile(
        blockId: _Fixture.blockId,
        readBytes: () async => throw StateError('Must not open picker'),
      );
      expect(fixture.text.document.toDelta().toJson(), original);
      expect(
        (await fixture.store.pending()).any(
          (op) => op.kind == OperationKind.assetAttach,
        ),
        isFalse,
      );
    },
  );

  testWidgets('text toolbar imports a PDF through the actual picker callback', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    picker.result = () async => FilePickerResult([
      PlatformFile(
        name: 'document.pdf',
        size: 6,
        bytes: Uint8List.fromList(inlineFiles['pdf']!),
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextEditToolbar(
            editorController: fixture.editor,
            block: fixture.editor.currentPage.textBlocks.single,
          ),
        ),
      ),
    );
    final button = find.byKey(const ValueKey('text-inline-file-button'));
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pump();
    await tester.runAsync(fixture.flush);
    expect(
      fixture.editor.currentPage.textBlocks.single.deltaJson,
      contains('"pdf"'),
    );
    expect(fixture.editor.currentPage.imageBlocks, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('text toolbar reports invalid media without changing text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final original = fixture.text.document.toDelta().toJson();
    picker.result = () async => FilePickerResult([
      PlatformFile(
        name: 'wrong.pdf',
        size: 3,
        bytes: Uint8List.fromList([1, 2, 3]),
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextEditToolbar(
            editorController: fixture.editor,
            block: fixture.editor.currentPage.textBlocks.single,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('text-inline-file-button')));
    await tester.pump();
    expect(find.text('Could not insert this file.'), findsOneWidget);
    expect(fixture.text.document.toDelta().toJson(), original);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unmounted text toolbar cancels a pending file picker', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chosen = Completer<FilePickerResult?>();
    picker.result = () => chosen.future;
    final original = fixture.text.document.toDelta().toJson();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextEditToolbar(
            editorController: fixture.editor,
            block: fixture.editor.currentPage.textBlocks.single,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('text-inline-file-button')));
    await tester.pumpWidget(const SizedBox.shrink());
    chosen.complete(
      FilePickerResult([
        PlatformFile(
          name: 'selected.pdf',
          size: 6,
          bytes: Uint8List.fromList(inlineFiles['pdf']!),
        ),
      ]),
    );
    await tester.pump();
    expect(fixture.text.document.toDelta().toJson(), original);
    expect(tester.takeException(), isNull);
  });
  tearDown(() async {
    await fixture.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  TextEditingController activateHud() {
    fixture.editor.setTool(DrawingTool.text);
    fixture.editor.setActiveTextBlock(_Fixture.blockId, null);
    final hud = TextEditingController(text: 'KeepOriginal')
      ..selection = const TextSelection(baseOffset: 4, extentOffset: 0);
    fixture.editor.bindHudTextController(_Fixture.blockId, hud);
    addTearDown(() {
      fixture.editor.unbindHudTextController(_Fixture.blockId, hud);
      hud.dispose();
    });
    return hud;
  }

  for (final type in ['image', 'pdf']) {
    for (final dark in [false, true]) {
      testWidgets(
        'plain HUD imports $type and hands the caret to Quill, dark=$dark',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(1500, 900));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.runAsync(() async {
            fixture.editor.setTool(DrawingTool.text);
            fixture.editor.setActiveTextBlock(_Fixture.blockId, null);
            fixture.editor.updateTextBlockContent(
              fixture.editor.currentPage.textBlocks.single,
              plainText: 'KeepOriginal',
              deltaJson: jsonEncode([
                {'insert': 'KeepOriginal\n'},
              ]),
            );
            await fixture.flush();
          });
          final original =
              fixture.editor.currentPage.textBlocks.single.deltaJson;
          final preferences = AppPreferencesController();
          addTearDown(preferences.dispose);
          picker.result = () async => FilePickerResult([
            PlatformFile(
              name: type == 'pdf' ? 'selected.pdf' : 'selected.png',
              size: type == 'pdf' ? 6 : _png.length,
              bytes: type == 'pdf'
                  ? Uint8List.fromList(inlineFiles['pdf']!)
                  : _png,
            ),
          ]);
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? AppTheme.dark() : AppTheme.light(),
              home: MultiProvider(
                providers: [
                  ChangeNotifierProvider<EditorController>.value(
                    value: fixture.editor,
                  ),
                  ChangeNotifierProvider<AppPreferencesController>.value(
                    value: preferences,
                  ),
                ],
                child: Scaffold(
                  body: Consumer<EditorController>(
                    builder: (_, editor, _) => Stack(
                      children: [
                        Positioned.fill(
                          child: PageOverlay(
                            controller: editor,
                            renderBackground: false,
                          ),
                        ),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: TextEditToolbar(
                            editorController: editor,
                            block: editor.currentPage.textBlocks.single,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(find.byType(TextHudBlock), findsOneWidget);
          expect(find.byType(quill.QuillEditor), findsNothing);
          final hud = tester.widget<EditableText>(find.byType(EditableText));
          expect(hud.contextMenuBuilder, isNotNull);
          hud.controller.selection = const TextSelection(
            baseOffset: 0,
            extentOffset: 4,
          );
          await tester.tap(
            find.byKey(const ValueKey('text-inline-file-button')),
          );
          await tester.pump();
          await tester.pump();
          expect(find.byType(TextHudBlock), findsNothing);
          expect(find.byType(quill.QuillEditor), findsOneWidget);
          final active = fixture.editor.activeTextController!;
          expect(active.selection.isCollapsed, isTrue);
          expect(
            active.selection.extentOffset,
            lessThan(active.document.length - 1),
          );
          expect(active.document.toPlainText(), contains('Original'));
          expect(active.document.toPlainText(), isNot(contains('Keep')));
          await tester.runAsync(fixture.flush);
          await tester.pump();
          if (type == 'pdf') {
            expect(find.text('Embedded PDF'), findsOneWidget);
          }
          await tester.runAsync(() async {
            fixture.editor.undo();
            await fixture.flush();
          });
          await tester.pump();
          expect(
            fixture.editor.currentPage.textBlocks.single.deltaJson,
            original,
          );
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  test(
    'inline preview uses verified staging until the durable commit',
    () async {
      activateHud();
      await fixture.editor.insertQuillFile(
        blockId: _Fixture.blockId,
        readBytes: () async => _png,
      );
      final delta =
          jsonDecode(fixture.editor.currentPage.textBlocks.single.deltaJson!)
              as List;
      final embed =
          (delta.singleWhere((dynamic op) => op['insert'] is Map)
                  as Map)['insert']
              as Map;
      final assetId = (embed.values.single as String).substring(6);
      Future<Uint8List> preview(String documentId) =>
          fixture.writer.quillAssetBytes(
            documentId: documentId,
            pageId: fixture.editor.currentPage.id,
            objectId: _Fixture.blockId,
            assetId: assetId,
          );
      expect(await preview(fixture.editor.notebook.uid), _png);
      await expectLater(preview('foreign-document'), throwsStateError);
      await fixture.flush();
      fixture.buffer.clear();
      expect(await preview(fixture.editor.notebook.uid), _png);
    },
  );

  testWidgets(
    'HUD cancel preserves the field and uniform rich paste still hands off',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        fixture.editor.setTool(DrawingTool.text);
        fixture.editor.setActiveTextBlock(_Fixture.blockId, null);
        fixture.editor.updateTextBlockContent(
          fixture.editor.currentPage.textBlocks.single,
          plainText: 'KeepOriginal',
          deltaJson: jsonEncode([
            {'insert': 'KeepOriginal\n'},
          ]),
        );
        await fixture.flush();
      });
      final preferences = AppPreferencesController();
      addTearDown(preferences.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<EditorController>.value(
                value: fixture.editor,
              ),
              ChangeNotifierProvider<AppPreferencesController>.value(
                value: preferences,
              ),
            ],
            child: Scaffold(
              body: Consumer<EditorController>(
                builder: (_, editor, _) => Stack(
                  children: [
                    Positioned.fill(
                      child: PageOverlay(
                        controller: editor,
                        renderBackground: false,
                      ),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: TextEditToolbar(
                        editorController: editor,
                        block: editor.currentPage.textBlocks.single,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final hud = tester.widget<EditableText>(find.byType(EditableText));
      hud.controller.selection = const TextSelection(
        baseOffset: 2,
        extentOffset: 5,
      );
      final value = hud.controller.value;
      await tester.tap(find.byKey(const ValueKey('text-inline-file-button')));
      await tester.pump();
      expect(find.byType(TextHudBlock), findsOneWidget);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller,
        same(hud.controller),
      );
      expect(hud.controller.value, value);
      hud.controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: hud.controller.text.length,
      );
      await tester.runAsync(
        () => fixture.editor.pasteQuillHtml(
          blockId: _Fixture.blockId,
          readHtml: () async => '<p>Replacement</p>',
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(TextHudBlock), findsNothing);
      expect(find.byType(quill.QuillEditor), findsOneWidget);
      expect(
        fixture.editor.activeTextController!.document.toPlainText(),
        contains('Replacement'),
      );
      expect(
        fixture.editor.activeTextController!.document.toDelta().toJson().every(
          (op) => op['insert'] is String,
        ),
        isTrue,
      );
      await tester.runAsync(fixture.flush);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final type in ['image', 'pdf']) {
    test(
      'HUD $type import preserves text, selection handoff and Undo',
      () async {
        final original = fixture.editor.currentPage.textBlocks.single.deltaJson;
        final hud = activateHud();
        final value = hud.value;
        await fixture.editor.insertQuillFile(
          blockId: _Fixture.blockId,
          readBytes: () async =>
              type == 'pdf' ? Uint8List.fromList(inlineFiles['pdf']!) : _png,
        );
        expect(hud.value, value);
        final block = fixture.editor.currentPage.textBlocks.single;
        expect(block.text, contains('Original'));
        expect(block.text, isNot(contains('Keep')));
        expect(block.deltaJson, contains('"$type"'));
        expect(fixture.editor.hasQuillHandoff(_Fixture.blockId), isTrue);
        final selection = fixture.editor.takeQuillHandoff(
          _Fixture.blockId,
          block.deltaJson,
        );
        expect(selection, isNotNull);
        expect(selection!.isCollapsed, isTrue);
        expect(selection.extentOffset, greaterThan(0));
        expect(
          fixture.editor.takeQuillHandoff(_Fixture.blockId, block.deltaJson),
          isNull,
        );
        await fixture.flush();
        fixture.editor.undo();
        await fixture.flush();
        expect(
          fixture.editor.currentPage.textBlocks.single.deltaJson,
          original,
        );
        fixture.editor.redo();
        await fixture.flush();
        expect(
          fixture.editor.currentPage.textBlocks.single.deltaJson,
          block.deltaJson,
        );
      },
    );
  }

  test(
    'HUD rich paste preserves formatting and stages canonical media',
    () async {
      activateHud();
      await fixture.editor.pasteQuillHtml(
        blockId: _Fixture.blockId,
        readHtml: () async =>
            '<p><strong>Rich</strong><img src="$_imageUri"></p>',
      );
      await fixture.flush();
      final block = fixture.editor.currentPage.textBlocks.single;
      expect(block.deltaJson, contains('"bold":true'));
      expect(block.deltaJson, contains('asset:'));
      expect(block.deltaJson, isNot(contains('data:')));
      expect(block.text, contains('Original'));
    },
  );

  test(
    'HUD import respects UTF-16 selection and keeps earlier typing as separate Undo',
    () async {
      final original = fixture.editor.currentPage.textBlocks.single.deltaJson;
      final hud = activateHud();
      const typed = 'A😀B\nsecond';
      hud.value = const TextEditingValue(
        text: typed,
        selection: TextSelection(baseOffset: 1, extentOffset: 3),
      );
      fixture.editor.updateTextBlockContent(
        fixture.editor.currentPage.textBlocks.single,
        plainText: typed,
        deltaJson: jsonEncode([
          {'insert': '$typed\n'},
        ]),
      );
      await fixture.editor.insertQuillFile(
        blockId: _Fixture.blockId,
        readBytes: () async => Uint8List.fromList(inlineFiles['pdf']!),
      );
      await fixture.flush();
      final imported = fixture.editor.currentPage.textBlocks.single;
      expect(imported.text, isNot(contains('😀')));
      expect(imported.text, contains('A'));
      expect(imported.text, contains('B\nsecond'));
      fixture.editor.undo();
      await fixture.flush();
      expect(fixture.editor.currentPage.textBlocks.single.text, typed);
      fixture.editor.undo();
      await fixture.flush();
      expect(fixture.editor.currentPage.textBlocks.single.deltaJson, original);
    },
  );

  for (final source in ['hud', 'quill']) {
    test('$source import rejects selection inside a surrogate pair', () async {
      const value = 'A😀B';
      if (source == 'hud') {
        final hud = activateHud();
        hud.value = const TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: 2),
        );
        fixture.editor.updateTextBlockContent(
          fixture.editor.currentPage.textBlocks.single,
          plainText: value,
          deltaJson: jsonEncode([
            {'insert': '$value\n'},
          ]),
        );
      } else {
        fixture.text.replaceText(
          0,
          fixture.text.document.length - 1,
          value,
          const TextSelection.collapsed(offset: 2),
        );
        await Future<void>.delayed(Duration.zero);
      }
      final original = fixture.editor.currentPage.textBlocks.single.deltaJson;
      await expectLater(
        fixture.editor.insertQuillFile(
          blockId: _Fixture.blockId,
          readBytes: () async => _png,
        ),
        throwsFormatException,
      );
      expect(fixture.editor.currentPage.textBlocks.single.deltaJson, original);
      expect(
        (await fixture.store.pending()).any(
          (op) => op.kind == OperationKind.assetAttach,
        ),
        isFalse,
      );
    });
  }

  for (final reason in [
    'selection',
    'typing',
    'composing',
    'unmounted',
    'replaced',
  ]) {
    test('HUD pending import cancels after $reason changes', () async {
      final hud = activateHud();
      final original = fixture.editor.currentPage.textBlocks.single.deltaJson;
      final bytes = Completer<Uint8List?>();
      final pending = fixture.editor.insertQuillFile(
        blockId: _Fixture.blockId,
        readBytes: () => bytes.future,
      );
      switch (reason) {
        case 'selection':
          hud.selection = const TextSelection.collapsed(offset: 2);
        case 'typing':
          hud.value = const TextEditingValue(
            text: 'Changed',
            selection: TextSelection.collapsed(offset: 7),
          );
        case 'composing':
          hud.value = hud.value.copyWith(
            composing: const TextRange(start: 0, end: 2),
          );
        case 'unmounted':
          fixture.editor.unbindHudTextController(_Fixture.blockId, hud);
        case 'replaced':
          final replacement = TextEditingController(text: hud.text)
            ..selection = hud.selection;
          addTearDown(replacement.dispose);
          fixture.editor.bindHudTextController(_Fixture.blockId, replacement);
          fixture.editor.unbindHudTextController(_Fixture.blockId, hud);
          expect(fixture.editor.activeHudTextController, same(replacement));
      }
      bytes.complete(_png);
      await pending;
      expect(fixture.editor.currentPage.textBlocks.single.deltaJson, original);
      expect(fixture.editor.hasQuillHandoff(_Fixture.blockId), isFalse);
      expect(
        (await fixture.store.pending()).any(
          (op) => op.kind == OperationKind.assetAttach,
        ),
        isFalse,
      );
    });
  }

  test(
    'HUD rejects bytes, stale Delta and stale caret without changing the document',
    () async {
      final hud = activateHud();
      final original = fixture.editor.currentPage.textBlocks.single.deltaJson;
      await expectLater(
        fixture.editor.insertQuillFile(
          blockId: _Fixture.blockId,
          readBytes: () async => Uint8List.fromList([1, 2, 3]),
        ),
        throwsFormatException,
      );
      expect(fixture.editor.hasQuillHandoff(_Fixture.blockId), isFalse);
      expect(fixture.editor.currentPage.textBlocks.single.deltaJson, original);
      hud.value = const TextEditingValue(
        text: 'Not the model',
        selection: TextSelection.collapsed(offset: 3),
      );
      await expectLater(
        fixture.editor.insertQuillFile(
          blockId: _Fixture.blockId,
          readBytes: () async => _png,
        ),
        throwsFormatException,
      );
      expect(fixture.editor.currentPage.textBlocks.single.deltaJson, original);
      hud.value = const TextEditingValue(
        text: 'KeepOriginal',
        selection: TextSelection.collapsed(offset: 4),
      );
      await fixture.editor.insertQuillFile(
        blockId: _Fixture.blockId,
        readBytes: () async => _png,
      );
      expect(
        fixture.editor.takeQuillHandoff(_Fixture.blockId, original),
        isNull,
      );
      expect(fixture.editor.hasQuillHandoff(_Fixture.blockId), isFalse);
    },
  );

  test(
    'HTML paste atomically preserves formatting, media and Undo/Redo',
    () async {
      final original = fixture.editor.currentPage.textBlocks.single.deltaJson;
      final pendingBefore = (await fixture.store.pending()).length;
      expect(
        await fixture.editor.pasteQuillHtml(
          blockId: _Fixture.blockId,
          readHtml: () async =>
              '<p><strong>Pasted</strong> <em>rich</em>'
              '<img src="$_imageUri"><img src="$_imageUri"></p>',
        ),
        isTrue,
      );
      await fixture.flush();
      final block = fixture.editor.currentPage.textBlocks.single;
      expect(block.text, contains('Pasted'));
      expect(block.text, contains('Original'));
      expect(block.text, isNot(contains('Keep')));
      final delta = jsonDecode(block.deltaJson!) as List;
      final embeds = delta.where((dynamic op) => op['insert'] is Map).toList();
      expect(embeds, hasLength(2));
      expect(embeds[0]['insert'], embeds[1]['insert']);
      expect(
        delta.any(
          (dynamic op) => (op['attributes'] as Map? ?? {})['bold'] == true,
        ),
        isTrue,
      );
      expect(
        delta.any(
          (dynamic op) => (op['attributes'] as Map? ?? {})['italic'] == true,
        ),
        isTrue,
      );
      expect(block.deltaJson, isNot(contains('data:')));
      final added = (await fixture.store.pending())
          .skip(pendingBefore)
          .toList();
      final attaches = added
          .where((op) => op.kind == OperationKind.assetAttach)
          .toList();
      expect(attaches, hasLength(1));
      final receipt = attaches.single.payload;
      expect(
        await fixture.projector.verifiedTextAssetBytes(
          documentId: fixture.editor.notebook.uid,
          pageId: fixture.editor.currentPage.id,
          objectId: _Fixture.blockId,
          assetId: receipt['assetId'] as String,
        ),
        _png,
      );
      fixture.buffer.clear();
      fixture.editor.undo();
      await fixture.flush();
      expect(fixture.editor.currentPage.textBlocks.single.deltaJson, original);
      fixture.editor.redo();
      await fixture.flush();
      expect(
        fixture.editor.currentPage.textBlocks.single.deltaJson,
        block.deltaJson,
      );
    },
  );

  for (final html in [
    '<p><img src="https://example.test/image.png"></p>',
    '<p><img src="asset:foreign-document-asset"></p>',
    '<p><img src="$_imageUri"><img src="file:///tmp/foreign.png"></p>',
    '<p><img src="data:image/png;base64,JVBERi0x"></p>',
  ]) {
    test(
      'rejected rich paste preserves selection, content and outbox: $html',
      () async {
        final original = fixture.text.document.toDelta().toJson();
        final selection = fixture.text.selection;
        final pendingBefore = (await fixture.store.pending())
            .map((op) => op.operationId)
            .toList();
        await expectLater(
          fixture.editor.pasteQuillHtml(
            blockId: _Fixture.blockId,
            readHtml: () async => html,
          ),
          throwsFormatException,
        );
        expect(fixture.text.document.toDelta().toJson(), original);
        expect(fixture.text.selection, selection);
        expect(
          (await fixture.store.pending()).map((op) => op.operationId),
          pendingBefore,
        );
        expect(
          await fixture.database
              .customSelect('SELECT * FROM operation_asset_bytes')
              .get(),
          isEmpty,
        );
      },
    );
  }

  for (final reason in ['selection', 'typing', 'block', 'widget', 'dispose']) {
    test(
      'async paste cancels after $reason changes without overwriting input',
      () async {
        final html = Completer<String?>();
        final original = fixture.text.document.toDelta().toJson();
        var mounted = true;
        final pending = fixture.editor.pasteQuillHtml(
          blockId: _Fixture.blockId,
          readHtml: () => html.future,
          canPaste: () => mounted,
        );
        switch (reason) {
          case 'selection':
            fixture.text.updateSelection(
              const TextSelection.collapsed(offset: 2),
              quill.ChangeSource.local,
            );
          case 'typing':
            fixture.text.replaceText(
              0,
              0,
              'X',
              const TextSelection.collapsed(offset: 1),
            );
          case 'block':
            fixture.editor.clearActiveTextBlock();
          case 'widget':
            mounted = false;
          case 'dispose':
            await fixture.flush();
            fixture.editor.dispose();
            fixture.disposed = true;
        }
        html.complete('<p><img src="$_imageUri">Delayed</p>');
        expect(await pending, isTrue);
        if (reason == 'typing') {
          await fixture.flush();
          expect(
            fixture.editor.currentPage.textBlocks.single.text,
            'XKeepOriginal',
          );
        } else {
          expect(fixture.text.document.toDelta().toJson(), original);
        }
        expect(
          (await fixture.store.pending()).any(
            (op) => op.kind == OperationKind.assetAttach,
          ),
          isFalse,
        );
      },
    );
  }

  test(
    'internal copy reuses a new staged asset before its first autosave',
    () async {
      await fixture.editor.pasteQuillHtml(
        blockId: _Fixture.blockId,
        readHtml: () async => '<p><img src="$_imageUri"></p>',
      );
      await Future<void>.delayed(Duration.zero);
      var offset = 0;
      for (final operation in fixture.text.document.toDelta().toList()) {
        if (operation.data is Map) {
          break;
        }
        offset += (operation.data as String).length;
      }
      fixture.text.updateSelection(
        TextSelection(baseOffset: offset, extentOffset: offset + 1),
        quill.ChangeSource.local,
      );
      // ignore: experimental_member_use
      expect(fixture.text.clipboardSelection(true), isTrue);
      fixture.text.updateSelection(
        TextSelection.collapsed(offset: fixture.text.document.length - 1),
        quill.ChangeSource.local,
      );
      expect(
        (await fixture.store.pending()).any(
          (op) => op.kind == OperationKind.assetAttach,
        ),
        isFalse,
      );
      await fixture.editor.pasteQuillHtml(
        blockId: _Fixture.blockId,
        readPlainText: () async => fixture.text.pastePlainText,
        readHtml: () async =>
            throw StateError('Internal copy must preserve Delta'),
      );
      await fixture.flush();
      final delta =
          jsonDecode(fixture.editor.currentPage.textBlocks.single.deltaJson!)
              as List;
      final embeds = delta.where((dynamic op) => op['insert'] is Map).toList();
      expect(embeds, hasLength(2));
      expect(embeds.first['insert'], embeds.last['insert']);
      expect(
        (await fixture.store.pending()).where(
          (op) => op.kind == OperationKind.assetAttach,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'empty HTML lets ordinary clipboard handling continue without deletion',
    () async {
      final original = fixture.text.document.toDelta().toJson();
      expect(
        await fixture.editor.pasteQuillHtml(
          blockId: _Fixture.blockId,
          readHtml: () async => null,
        ),
        isFalse,
      );
      expect(fixture.text.document.toDelta().toJson(), original);
    },
  );

  test(
    'copied assets require matching scope, type and remaining budget',
    () async {
      await fixture.editor.pasteQuillHtml(
        blockId: _Fixture.blockId,
        readHtml: () async => '<p><img src="$_imageUri"></p>',
      );
      await fixture.flush();
      fixture.buffer.clear();
      final attach = (await fixture.store.pending()).singleWhere(
        (op) => op.kind == OperationKind.assetAttach,
      );
      final assetId = attach.payload['assetId'] as String;
      Future<Map<String, dynamic>> verify({
        String? documentId,
        String type = 'image',
        int limit = QuillPastePlan.maximumBytes,
      }) => fixture.writer.verifyQuillAssetReference(
        documentId: documentId ?? fixture.editor.notebook.uid,
        assetId: assetId,
        embedType: type,
        byteLimit: limit,
      );
      expect(await verify(), attach.payload);
      await expectLater(
        verify(documentId: 'another-document'),
        throwsFormatException,
      );
      await expectLater(verify(type: 'pdf'), throwsFormatException);
      await expectLater(verify(limit: _png.length - 1), throwsFormatException);
      await fixture.database.customStatement(
        'UPDATE operation_asset_bytes SET bytes = ?',
        [Uint8List.fromList(List.filled(_png.length, 0))],
      );
      await expectLater(verify(), throwsFormatException);
    },
  );
}
