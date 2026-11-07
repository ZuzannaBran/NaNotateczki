import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_box_transform/flutter_box_transform.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/core/theme/app_colors.dart';
import 'package:program/core/theme/app_theme.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/editor_sqlite_projector.dart';
import 'package:program/data/sync/operation_gateway.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/data/sync/sync_engine.dart';
import 'package:program/data/sync/verified_editor_asset_buffer.dart';
import 'package:program/features/editor/presentation/widgets/page_overlay.dart';
import 'package:program/features/editor/presentation/widgets/text_hud_block.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/editor/state/editor_operation_bridge.dart';
import 'package:program/features/editor/state/editor_v2_operation_writer.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/text_block.dart';

import 'support/native_test_documents.dart';

class _OfflineGateway implements OperationGateway {
  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async => throw StateError('Widget regression stays offline.');

  @override
  Future<OperationFeedPage> readAfter(int cursor) async =>
      throw StateError('Widget regression stays offline.');
}

Color? _colorOfText(InlineSpan span, String text, [Color? inherited]) {
  if (span is! TextSpan) {
    return null;
  }
  final color = span.style?.color ?? inherited;
  if (span.text?.contains(text) == true) {
    return color;
  }
  for (final child in span.children ?? const <InlineSpan>[]) {
    final found = _colorOfText(child, text, color);
    if (found != null) {
      return found;
    }
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useIsolatedNativeTestDocuments();
  useInMemoryTestTextStorage();

  for (final rich in [false, true]) {
    testWidgets('v2 text frame persists only on release, rich=$rich', (
      tester,
    ) async {
      final database = NotesDatabase(NativeDatabase.memory());
      Future<void>? sourceClose;
      Future<void> closeSource() => sourceClose ??= database.close();
      addTearDown(closeSource);
      final repository = NotebookRepository(database);
      final store = OperationStore(database);
      final projector = EditorSqliteProjector(database);
      final engine = SyncEngine(
        store: store,
        gateway: _OfflineGateway(),
        actorId: 'widget-text-transform',
        checkpointScope: 'widget-text-transform',
        enableRealtime: false,
        applyRemote: (operation, _) => projector.apply(operation),
      );
      addTearDown(engine.stop);
      final writer = EditorV2OperationWriter(
        syncEngine: engine,
        projector: projector,
      );
      final preferences = AppPreferencesController();
      addTearDown(preferences.dispose);
      final block = TextBlock(
        id: 'text-transform',
        text: 'Bold plain',
        deltaJson: jsonEncode([
          if (rich)
            {
              'insert': 'Bold',
              'attributes': {'bold': true, 'size': '22'},
            },
          {'insert': rich ? ' plain\n' : 'Bold plain\n'},
        ]),
        position: const Offset(60, 100),
        fontSize: 18,
        color: const Color(0xFF123456),
        width: 240,
      );
      final editor = (await tester.runAsync(() async {
        await repository.enableAccountOperations(writer);
        final notebook = await repository.createNotebook();
        await writer.writePageChange(
          documentId: notebook.uid,
          before: notebook.pages.single,
          after: notebook.pages.single.copyWith(textBlocks: [block]),
        );
        final editor = EditorController(
          repository: repository,
          notebook: (await repository.getNotebook(notebook.uid))!,
          operationWriter: writer,
        );
        await editor.historyReady;
        await editor.preferencesReady;
        return editor;
      }))!;
      addTearDown(editor.dispose);
      editor.setTool(DrawingTool.edit);
      editor.setActiveTextBlock(block.id, null);
      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: preferences),
              ChangeNotifierProvider.value(value: editor),
            ],
            child: Scaffold(
              body: Consumer<EditorController>(
                builder: (_, controller, _) => PageOverlay(
                  controller: controller,
                  renderBackground: false,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(TextHudBlock), rich ? findsNothing : findsOneWidget);
      final sideHandle = rich
          ? find.byKey(const ValueKey('quill-text-width-handle'))
          : find.byType(DefaultSideHandle);
      final moveHandle = rich
          ? find.byTooltip('Move')
          : find.byKey(const ValueKey('object-transform-move-handle'));
      final cornerHandle = rich
          ? find.byKey(const ValueKey(HandlePosition.topLeft))
          : find.byWidgetPredicate(
              (widget) =>
                  widget is DefaultCornerHandle &&
                  widget.handle == HandlePosition.topLeft,
            );
      final initial = editor.currentPage.textBlocks.single;

      Future<TextBlock> flushAndRead() async {
        return (await tester.runAsync(() async {
          await editor.flushPendingSaves();
          final saved = await repository.getNotebook(editor.notebook.uid);
          return saved!.pages.single.textBlocks.single;
        }))!;
      }

      for (final (handle, property) in [
        (sideHandle, 'width'),
        (moveHandle, 'position'),
        (cornerHandle, 'font'),
      ]) {
        final scaling = property == 'font';
        double geometry(TextBlock block) => switch (property) {
          'width' => block.width,
          'position' => block.position.dx,
          _ => block.fontSize,
        };
        for (final cancel in [true, false]) {
          editor.setActiveTextBlock(block.id, null);
          await tester.pump();
          final pending = (await tester.runAsync(() => store.pending()))!;
          final start = tester.getCenter(handle);
          final gesture = await tester.startGesture(start);
          await gesture.moveBy(
            scaling ? const Offset(-32, -16) : const Offset(32, 0),
          );
          await gesture.moveBy(
            scaling ? const Offset(-28, -14) : const Offset(28, 0),
          );
          await tester.pump();
          if (!scaling || !rich) {
            expect(tester.getCenter(handle), isNot(start));
          }
          expect(editor.isObjectTransformActive, isTrue);
          expect(
            geometry(editor.currentPage.textBlocks.single),
            geometry(initial),
          );
          final during = await flushAndRead();
          expect(geometry(during), geometry(initial));
          expect(during.deltaJson, initial.deltaJson);
          expect(
            await tester.runAsync(() => store.pending()),
            hasLength(pending.length),
          );

          if (cancel) {
            await gesture.cancel();
            await tester.pump();
            expect(tester.getCenter(handle).dx, closeTo(start.dx, 0.1));
          } else {
            await tester.runAsync(gesture.up);
            await tester.pump();
            final committed = await flushAndRead();
            expect(geometry(committed), greaterThan(geometry(initial)));
            final operations = (await tester.runAsync(() => store.pending()))!;
            final added = operations.skip(pending.length);
            if (scaling) {
              expect(committed.text, initial.text);
              expect(committed.deltaJson, isNot(initial.deltaJson));
              expect(
                added.map((operation) => operation.kind),
                containsAll([
                  OperationKind.objectSet,
                  OperationKind.textFormat,
                ]),
              );
              if (rich) {
                final attributes =
                    (jsonDecode(committed.deltaJson!) as List)
                            .first['attributes']
                        as Map;
                expect(attributes['bold'], isTrue);
                expect(
                  double.parse(attributes['size'].toString()),
                  greaterThan(22),
                );
              }
            } else {
              expect(committed.deltaJson, initial.deltaJson);
              expect(added.single.kind, OperationKind.objectSet);
            }
            await tester.runAsync(() async {
              editor.undo();
              await editor.flushPendingSaves();
            });
            await tester.pump();
          }
          expect(editor.isObjectTransformActive, isFalse);
          final restored = await flushAndRead();
          expect(geometry(restored), geometry(initial));
          expect(restored.deltaJson, initial.deltaJson);
          expect(editor.canUndo, isFalse);
        }
      }

      editor.setActiveTextBlock(block.id, null);
      final editedDelta = jsonDecode(initial.deltaJson!) as List<dynamic>;
      editedDelta.insert(0, {'insert': 'New '});
      editor.updateTextBlockContent(
        editor.currentPage.textBlocks.single,
        plainText: 'New ${initial.text}\n',
        deltaJson: jsonEncode(editedDelta),
      );
      await tester.pump();
      final interrupted = await tester.startGesture(
        tester.getCenter(sideHandle),
      );
      await interrupted.moveBy(const Offset(32, 0));
      await interrupted.moveBy(const Offset(28, 0));
      await tester.pump();
      expect(editor.isObjectTransformActive, isTrue);
      final concurrentSave = await flushAndRead();
      expect(concurrentSave.text, 'New ${initial.text}');
      expect(concurrentSave.width, initial.width);
      final pendingBeforeUnmount = (await tester.runAsync(
        () => store.pending(),
      ))!;

      await tester.pumpWidget(const SizedBox.shrink());
      await interrupted.up();
      await tester.pump();
      expect(editor.isObjectTransformActive, isFalse);
      expect((await flushAndRead()).width, initial.width);
      expect(
        await tester.runAsync(() => store.pending()),
        hasLength(pendingBeforeUnmount.length),
      );

      final replayed = (await tester.runAsync(() async {
        await closeSource();
        final peer = NotesDatabase(NativeDatabase.memory());
        try {
          final peerStore = OperationStore(peer);
          final peerProjector = EditorSqliteProjector(peer);
          for (final (index, operation) in pendingBeforeUnmount.indexed) {
            await peerStore.applyRemote(
              operation,
              serverSequence: index + 1,
              apply: () => peerProjector.apply(operation),
            );
          }
          final notebook = await NotebookRepository(
            peer,
          ).getNotebook(editor.notebook.uid);
          return notebook!.pages.single.textBlocks.single;
        } finally {
          await peer.close();
        }
      }))!;
      expect(replayed.position, concurrentSave.position);
      expect(replayed.width, concurrentSave.width);
      expect(replayed.fontSize, concurrentSave.fontSize);
      expect(replayed.text, concurrentSave.text);
      expect(replayed.deltaJson, concurrentSave.deltaJson);
    });
  }

  for (final kind in ['rich', 'image', 'pdf']) {
    for (final dark in [false, true]) {
      testWidgets('v2 $kind editing preserves Delta and media, dark=$dark', (
        tester,
      ) async {
        final database = NotesDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final repository = NotebookRepository(database);
        final buffer = VerifiedEditorAssetBuffer();
        final projector = EditorSqliteProjector(
          database,
          verifiedAssetBuffer: buffer,
        );
        final engine = SyncEngine(
          store: OperationStore(database),
          gateway: _OfflineGateway(),
          actorId: 'widget-quill',
          checkpointScope: 'widget-quill',
          enableRealtime: false,
          applyRemote: (operation, _) => projector.apply(operation),
        );
        addTearDown(engine.stop);
        final writer = EditorV2OperationWriter(
          syncEngine: engine,
          projector: projector,
        );
        final preferences = AppPreferencesController();
        addTearDown(preferences.dispose);
        final bytes = kind == 'image'
            ? base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
                'AAAAC0lEQVR42mP8/x8AAwMCAO+a3xkAAAAASUVORK5CYII=',
              )
            : Uint8List.fromList([37, 80, 68, 70, 45, 49]);
        final asset = VerifiedEditorAsset(
          assetId: 'widget-inline-asset',
          sha256: crypto.sha256.convert(bytes).toString(),
          sizeBytes: bytes.length,
          mediaType: kind == 'pdf' ? 'application/pdf' : 'image/png',
        );
        final block = TextBlock(
          id: 'widget-rich-text',
          text: 'Bold${kind == 'rich' ? '' : '\uFFFC'}plain',
          deltaJson: jsonEncode([
            {
              'insert': 'Bold',
              'attributes': {'bold': true, 'color': '#123456'},
            },
            if (kind != 'rich')
              {
                'insert': {kind: 'asset:${asset.assetId}'},
              },
            {
              'insert': 'plain',
              'attributes': {'italic': true},
            },
            {'insert': '\n'},
          ]),
          position: const Offset(30, 50),
          fontSize: 18,
          color: const Color(0xFF123456),
          width: 300,
        );
        late EditorController editor;
        late String originalDelta;
        await tester.runAsync(() async {
          final notebook = await repository.createNotebook();
          if (kind != 'rich') {
            buffer.stage(receipt: asset.attachPayload, bytes: bytes);
          }
          await writer.writeNotebookChange(
            before: notebook,
            after: notebook.copyWith(
              pages: [
                notebook.pages.single.copyWith(textBlocks: [block]),
              ],
            ),
            verifiedAssets: kind == 'rich' ? {} : {asset.assetId: asset},
          );
          final stored = (await repository.getNotebook(notebook.uid))!;
          originalDelta = stored.pages.single.textBlocks.single.deltaJson!;
          editor = EditorController(
            repository: repository,
            notebook: stored,
            operationWriter: writer,
          );
          await editor.historyReady;
          await editor.preferencesReady;
        });
        addTearDown(editor.dispose);
        Widget screen() => MaterialApp(
          theme: dark ? AppTheme.dark() : AppTheme.light(),
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<AppPreferencesController>.value(
                value: preferences,
              ),
              ChangeNotifierProvider<EditorController>.value(value: editor),
            ],
            child: Scaffold(
              body: Consumer<EditorController>(
                builder: (_, controller, _) => PageOverlay(
                  controller: controller,
                  renderBackground: false,
                ),
              ),
            ),
          ),
        );
        editor.setTool(DrawingTool.text);
        editor.setActiveTextBlock(block.id, null);
        await tester.pumpWidget(screen());
        await tester.pump();
        expect(find.byType(TextHudBlock), findsNothing);
        expect(find.byType(quill.QuillEditor), findsOneWidget);
        final active = editor.activeTextController!;
        expect(active.readOnly, isFalse);
        String? importedReference;
        if (kind == 'rich') {
          final importedBytes = base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
            'AAAAC0lEQVR42mP8/x8AAwMCAO+a3xkAAAAASUVORK5CYII=',
          );
          // ignore: experimental_member_use
          final clipboard = active.config.clipboardConfig!;
          editor.clearActiveTextBlock();
          final canceled = await tester.runAsync<String?>(
            () => clipboard.onImagePaste!(importedBytes),
          );
          expect(canceled, isNull);
          expect(
            editor.pages.single.textBlocks.single.deltaJson,
            originalDelta,
          );
          editor.setActiveTextBlock(block.id, active);
          importedReference = await tester.runAsync<String?>(
            () => clipboard.onImagePaste!(importedBytes),
          );
          expect(importedReference, startsWith('asset:'));
          active.replaceText(
            4,
            0,
            quill.BlockEmbed.image(importedReference!),
            const TextSelection.collapsed(offset: 5),
          );
        }
        final renderedColors = tester
            .widgetList<RichText>(find.byType(RichText))
            .map((widget) => _colorOfText(widget.text, 'Bold'))
            .whereType<Color>()
            .toList();
        expect(renderedColors, isNotEmpty);
        expect(
          renderedColors,
          everyElement(
            AppColors.displayInkColor(const Color(0xFF123456), darkMode: dark),
          ),
        );
        active.replaceText(4, 0, '!', const TextSelection.collapsed(offset: 5));
        await tester.pump();
        await tester.runAsync(editor.flushPendingSaves);
        final saved = (await tester.runAsync(
          () => repository.getNotebook(editor.notebook.uid),
        ))!;
        final savedDelta = saved.pages.single.textBlocks.single.deltaJson!;
        expect(jsonDecode(savedDelta), active.document.toDelta().toJson());
        expect(saved.pages.single.textBlocks.single.text, contains('Bold!'));
        expect(jsonDecode(savedDelta).first['attributes']['bold'], isTrue);
        expect(jsonDecode(savedDelta).first['attributes']['color'], '#123456');
        final reference = importedReference;
        if (reference != null) {
          expect(savedDelta, contains(reference));
          final imported = await tester.runAsync(
            () => projector.verifiedTextAssetBytes(
              documentId: saved.uid,
              pageId: saved.pages.single.id,
              objectId: block.id,
              assetId: reference.substring(6),
            ),
          );
          expect(imported, isNotEmpty);
        }
        if (kind != 'rich') {
          expect(savedDelta, contains('asset:${asset.assetId}'));
          expect(
            await tester.runAsync(
              () => projector.verifiedTextAssetBytes(
                documentId: saved.uid,
                pageId: saved.pages.single.id,
                objectId: block.id,
                assetId: asset.assetId,
              ),
            ),
            bytes,
          );
        }
        if (kind == 'rich' && !dark) {
          active.replaceText(
            0,
            active.document.length - 1,
            'Uniform',
            const TextSelection.collapsed(offset: 7),
          );
          await tester.pumpWidget(screen());
          await tester.pump();
          expect(find.byType(TextHudBlock), findsNothing);
          expect(find.byType(quill.QuillEditor), findsOneWidget);
          expect(editor.activeTextController, same(active));
          expect(active.readOnly, isFalse);
          await tester.runAsync(editor.flushPendingSaves);
          await tester.runAsync(() async {
            editor.undo();
            await editor.flushPendingSaves();
          });
          expect(editor.pages.single.textBlocks.single.deltaJson, savedDelta);
        }
        await tester.runAsync(() async {
          editor.undo();
          await editor.flushPendingSaves();
        });
        expect(editor.pages.single.textBlocks.single.deltaJson, originalDelta);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
