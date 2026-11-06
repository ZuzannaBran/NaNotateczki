import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
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
            : Uint8List.fromList([37, 80, 68, 70]);
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
          editor.undo();
          await tester.runAsync(editor.flushPendingSaves);
          expect(editor.pages.single.textBlocks.single.deltaJson, savedDelta);
        }
        editor.undo();
        await tester.runAsync(editor.flushPendingSaves);
        expect(editor.pages.single.textBlocks.single.deltaJson, originalDelta);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
