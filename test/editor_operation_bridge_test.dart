import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/features/editor/state/editor_actions.dart';
import 'package:program/features/editor/state/editor_operation_bridge.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/image_block.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/text_block.dart';

NotePage _page({
  List<InkStroke> strokes = const [],
  List<TextBlock> texts = const [],
  List<ImageBlock> images = const [],
}) => NotePage(
  id: 'page-one',
  title: 'Page 1',
  isBookmarked: false,
  inkStrokes: strokes,
  textBlocks: texts,
  imageBlocks: images,
);

InkStroke _stroke(String id, {double x = 1}) => InkStroke(
  id: id,
  points: [InkPoint(dx: x, dy: 2, pressure: 0.5)],
  color: const Color(0xFF112233),
  width: 2,
  tool: DrawingTool.pen,
);

TextBlock _text(String text) => TextBlock(
  id: 'text-one',
  text: text,
  deltaJson: '[{"insert":"$text","attributes":{"bold":true}}]',
  position: const Offset(4, 8),
  fontSize: 18,
  color: const Color(0xFF112233),
  width: 200,
);

ImageBlock _image() => ImageBlock(
  id: 'image-one',
  path: '/private/local-file.png',
  ocrText: '',
  position: const Offset(5, 6),
  width: 100,
  height: 80,
  imageMime: 'image/png',
);

void main() {
  late EditorOperationBridge bridge;
  setUp(() => bridge = EditorOperationBridge());

  test('a local cache path change is not a verified image content change', () {
    final original = _image().copyWith(
      bytes: Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 1]),
    );
    final cached = original.copyWith(
      path: '/private/rebuilt-cache.png',
      position: const Offset(20, 30),
    );
    final drafts = bridge.planPageChange(
      before: _page(images: [original]),
      after: _page(images: [cached]),
    );
    expect(drafts, hasLength(1));
    expect(drafts.single.kind, OperationKind.objectSet);
    expect(drafts.single.payload['properties'], {'dx': 20.0, 'dy': 30.0});
    expect(EditorOperationBridge.sameImageContent(original, cached), isTrue);
  });

  test('path-only or changed bytes still require a verified replacement', () {
    final pathOnly = _image();
    expect(
      () => bridge.planPageChange(
        before: _page(images: [pathOnly]),
        after: _page(images: [pathOnly.copyWith(path: '/other.png')]),
      ),
      throwsStateError,
    );
    final empty = pathOnly.copyWith(bytes: Uint8List(0));
    expect(
      () => bridge.planPageChange(
        before: _page(images: [empty]),
        after: _page(images: [empty.copyWith(path: '/other.png')]),
      ),
      throwsStateError,
    );
    final original = pathOnly.copyWith(bytes: Uint8List.fromList([1, 2, 3]));
    for (final changed in [
      original.copyWith(bytes: Uint8List.fromList([1, 2, 4])),
      original.copyWith(path: '/other.png', clearBytes: true),
      original.copyWith(imageMime: 'image/jpeg'),
    ]) {
      expect(
        () => bridge.planPageChange(
          before: _page(images: [original]),
          after: _page(images: [changed]),
        ),
        throwsStateError,
      );
    }
  });

  test('stroke action creates exactly one typed operation', () {
    final before = _page();
    final stroke = _stroke('ink-one');
    final action = AddInkStrokeAction(stroke);
    final drafts = bridge.planAction(
      action: action,
      before: before,
      after: action.apply(before),
    );
    expect(drafts, hasLength(1));
    expect(drafts.single.kind, OperationKind.strokeCreate);
    expect(drafts.single.pageId, before.id);
    expect(drafts.single.objectId, stroke.id);
    expect((drafts.single.payload['value'] as Map)['points'], [
      [1.0, 2.0, 0.5],
    ]);
  });

  test('eraser gesture deletes removed IDs and adds fragments', () {
    final before = _page(strokes: [_stroke('old'), _stroke('unchanged')]);
    final after = _page(
      strokes: [_stroke('unchanged'), _stroke('fragment', x: 3)],
    );
    final drafts = bridge.planPageChange(before: before, after: after);
    expect(drafts.map((d) => d.kind), [
      OperationKind.objectDelete,
      OperationKind.objectReorder,
      OperationKind.strokeCreate,
    ]);
    expect(drafts.first.objectId, 'old');
    expect(drafts.last.objectId, 'fragment');
  });

  test('text create keeps Quill formatting in text atoms', () {
    final before = _page();
    final action = AddTextAction(_text('Hi'));
    final drafts = bridge.planAction(
      action: action,
      before: before,
      after: action.apply(before),
    );
    expect(drafts.map((d) => d.kind), [
      OperationKind.objectCreate,
      OperationKind.textInsert,
    ]);
    final atoms = drafts.last.payload['atoms'] as List;
    expect(atoms, hasLength(2));
    expect((atoms.first as Map)['attributes'], {'bold': true});
  });

  test('Quill terminal newline is retained while text stays trimmed', () {
    final before = _page();
    final block = _text('Hi').copyWith(deltaJson: r'[{"insert":"Hi\n"}]');
    final drafts = bridge.planPageChange(
      before: before,
      after: _page(texts: [block]),
    );
    expect(drafts.map((draft) => draft.kind), [
      OperationKind.objectCreate,
      OperationKind.textInsert,
    ]);
    final inserted = drafts.last.payload['atoms'] as List;
    expect(inserted, hasLength(3));
    expect((inserted.last as Map)['text'], '\n');
  });

  test('text update without durable atoms fails before save', () {
    final old = _text('Hi');
    final updated = _text('Bye');
    expect(
      () => bridge.planPageChange(
        before: _page(texts: [old]),
        after: _page(texts: [updated]),
      ),
      throwsStateError,
    );
  });

  test('image create requires verified bytes; never sends local path', () {
    final after = _page(images: [_image()]);
    expect(
      () => bridge.planPageChange(before: _page(), after: after),
      throwsStateError,
    );
    final drafts = bridge.planPageChange(
      before: _page(),
      after: after,
      verifiedAssets: {
        'image-one': const VerifiedEditorAsset(
          assetId: 'asset-one',
          sha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          sizeBytes: 10,
          mediaType: 'image/png',
        ),
      },
    );
    expect(drafts.map((d) => d.kind), [
      OperationKind.objectCreate,
      OperationKind.assetAttach,
    ]);
    expect((drafts.first.payload['value'] as Map).containsKey('path'), isFalse);
  });

  test('verified Quill image is attached before its text atom', () {
    final block = _text(
      '\uFFFC',
    ).copyWith(deltaJson: '[{"insert":{"image":"asset:embed-one"}}]');
    final drafts = bridge.planPageChange(
      before: _page(),
      after: _page(texts: [block]),
      verifiedAssets: {
        'embed-one': const VerifiedEditorAsset(
          assetId: 'embed-one',
          sha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          sizeBytes: 128,
          mediaType: 'image/png',
        ),
      },
    );
    expect(drafts.map((draft) => draft.kind), [
      OperationKind.objectCreate,
      OperationKind.assetAttach,
      OperationKind.textInsert,
    ]);
    final atoms = drafts.last.payload['atoms'] as List;
    expect((atoms.single as Map)['embed'], {'image': 'asset:embed-one'});
  });

  test('repeated Quill asset references attach only once', () {
    final block = _text('\uFFFC\uFFFC').copyWith(
      deltaJson:
          '[{"insert":{"pdf":"asset:pdf-one"}},'
          '{"insert":{"pdf":"asset:pdf-one"}}]',
    );
    final drafts = bridge.planPageChange(
      before: _page(),
      after: _page(texts: [block]),
      verifiedAssets: {
        'pdf-one': const VerifiedEditorAsset(
          assetId: 'pdf-one',
          sha256:
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          sizeBytes: 256,
          mediaType: 'application/pdf',
        ),
      },
    );
    expect(
      drafts.where((draft) => draft.kind == OperationKind.assetAttach),
      hasLength(1),
    );
    final atoms = drafts.last.payload['atoms'] as List;
    expect(atoms, hasLength(2));
  });

  test('unverified or external Quill embeds fail closed', () {
    final block = _text(
      '\uFFFC',
    ).copyWith(deltaJson: '[{"insert":{"image":"asset:missing"}}]');
    expect(
      () => bridge.planPageChange(
        before: _page(),
        after: _page(texts: [block]),
      ),
      throwsStateError,
    );
    expect(
      () => bridge.planPageChange(
        before: _page(),
        after: _page(
          texts: [
            block.copyWith(
              deltaJson: '[{"insert":{"image":"https://example.org/x.png"}}]',
            ),
          ],
        ),
      ),
      throwsFormatException,
    );
  });

  test('Quill embed MIME cannot differ from verified file', () {
    final block = _text(
      '\uFFFC',
    ).copyWith(deltaJson: '[{"insert":{"pdf":"asset:one"}}]');
    expect(
      () => bridge.planPageChange(
        before: _page(),
        after: _page(texts: [block]),
        verifiedAssets: {
          'one': const VerifiedEditorAsset(
            assetId: 'one',
            sha256:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            sizeBytes: 20,
            mediaType: 'image/png',
          ),
        },
      ),
      throwsStateError,
    );
  });

  test('image replacement attaches, updates and detaches in order', () {
    final original = _image();
    final replacement = original.copyWith(
      path: '/private/replaced.jpg',
      imageMime: 'image/jpeg',
    );
    final drafts = bridge.planPageChange(
      before: _page(images: [original]),
      after: _page(images: [replacement]),
      existingAssetIds: {'image-one': 'old-asset'},
      verifiedAssets: {
        'image-one': const VerifiedEditorAsset(
          assetId: 'new-asset',
          sha256:
              'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
          sizeBytes: 200,
          mediaType: 'image/jpeg',
        ),
      },
    );
    expect(drafts.map((draft) => draft.kind), [
      OperationKind.assetAttach,
      OperationKind.objectSet,
      OperationKind.assetDetach,
    ]);
    expect((drafts[1].payload['properties'] as Map)['assetId'], 'new-asset');
    expect(drafts.last.payload, {'assetId': 'old-asset'});
  });

  test('image replacement without prior asset identity is rejected', () {
    final original = _image();
    expect(
      () => bridge.planPageChange(
        before: _page(images: [original]),
        after: _page(
          images: [original.copyWith(path: '/private/replaced.jpg')],
        ),
        verifiedAssets: {
          'image-one': const VerifiedEditorAsset(
            assetId: 'new-asset',
            sha256:
                'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
            sizeBytes: 200,
            mediaType: 'image/jpeg',
          ),
        },
      ),
      throwsStateError,
    );
  });

  test('moving an image between pages preserves original identity', () {
    final image = _image();
    final action = MoveImageBetweenPagesAction(
      fromPageId: 'page-one',
      toPageId: 'page-two',
      originalIndex: 0,
      before: image,
      after: image.copyWith(position: const Offset(20, 30)),
    );
    final drafts = bridge.planCrossPageImageMove(action, targetIndex: 1);
    expect(drafts.map((d) => d.kind), [
      OperationKind.objectMove,
      OperationKind.objectSet,
    ]);
    expect(drafts.first.pageId, 'page-one');
    expect(drafts.last.pageId, 'page-two');
    expect(drafts.last.objectId, image.id);
  });

  test('identical object IDs across layer types fail closed', () {
    expect(
      () => bridge.planPageChange(
        before: _page(),
        after: _page(
          strokes: [_stroke('duplicate')],
          texts: [_text('Hi').copyWith(id: 'duplicate')],
        ),
      ),
      throwsStateError,
    );
  });

  test('page creation contains no snapshot of unrelated pages', () {
    final drafts = bridge.planCreatePage(_page(strokes: [_stroke('one')]));
    expect(drafts.map((d) => d.kind), [
      OperationKind.pageCreate,
      OperationKind.strokeCreate,
    ]);
    expect(bridge.planDeletePage('page-one').kind, OperationKind.pageDelete);
  });
}
