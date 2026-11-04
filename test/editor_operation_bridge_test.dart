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
      OperationKind.strokeCreate,
      OperationKind.objectReorder,
    ]);
    expect(drafts.first.objectId, 'old');
    expect(drafts[1].objectId, 'fragment');
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
    expect(drafts.toString().contains('/private/local-file.png'), isFalse);
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

  test('page creation contains no snapshot of unrelated pages', () {
    final drafts = bridge.planCreatePage(_page(strokes: [_stroke('one')]));
    expect(drafts.map((d) => d.kind), [
      OperationKind.pageCreate,
      OperationKind.strokeCreate,
    ]);
    expect(bridge.planDeletePage('page-one').kind, OperationKind.pageDelete);
  });
}
