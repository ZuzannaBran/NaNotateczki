import 'dart:ui';

import '../../notebook/domain/image_block.dart';
import '../../notebook/domain/ink_stroke.dart';
import '../../notebook/domain/note_page.dart';
import '../../notebook/domain/text_block.dart';

abstract class EditorAction {
  NotePage apply(NotePage page);
  NotePage revert(NotePage page);
}

class AddTextAction extends EditorAction {
  AddTextAction(this.block);

  final TextBlock block;

  @override
  NotePage apply(NotePage page) {
    return page.copyWith(textBlocks: [...page.textBlocks, block]);
  }

  @override
  NotePage revert(NotePage page) {
    return page.copyWith(
      textBlocks: page.textBlocks.where((item) => item.id != block.id).toList(),
    );
  }
}

class AddImageAction extends EditorAction {
  AddImageAction(this.block);

  final ImageBlock block;

  @override
  NotePage apply(NotePage page) {
    return page.copyWith(imageBlocks: [...page.imageBlocks, block]);
  }

  @override
  NotePage revert(NotePage page) {
    return page.copyWith(
      imageBlocks: page.imageBlocks
          .where((item) => item.id != block.id)
          .toList(),
    );
  }
}

class AddInkStrokeAction extends EditorAction {
  AddInkStrokeAction(this.stroke);

  final InkStroke stroke;

  @override
  NotePage apply(NotePage page) {
    return page.copyWith(inkStrokes: [...page.inkStrokes, stroke]);
  }

  @override
  NotePage revert(NotePage page) {
    return page.copyWith(
      inkStrokes: page.inkStrokes
          .where((item) => item.id != stroke.id)
          .toList(),
    );
  }
}

class RemoveInkStrokesAction extends EditorAction {
  RemoveInkStrokesAction({required this.before, required this.after});

  final List<InkStroke> before;
  final List<InkStroke> after;

  @override
  NotePage apply(NotePage page) {
    return page.copyWith(inkStrokes: after);
  }

  @override
  NotePage revert(NotePage page) {
    return page.copyWith(inkStrokes: before);
  }
}

class UpdateIndexTabAction extends EditorAction {
  UpdateIndexTabAction({required this.before, required this.after});

  final NotePage before;
  final NotePage after;

  @override
  NotePage apply(NotePage page) => after;

  @override
  NotePage revert(NotePage page) => before;
}

class UpdateTextAction extends EditorAction {
  UpdateTextAction({required this.before, required this.after});

  final TextBlock before;
  final TextBlock after;

  @override
  NotePage apply(NotePage page) {
    return page.copyWith(
      textBlocks: page.textBlocks
          .map((item) => item.id == after.id ? after : item)
          .toList(),
    );
  }

  @override
  NotePage revert(NotePage page) {
    return page.copyWith(
      textBlocks: page.textBlocks
          .map((item) => item.id == before.id ? before : item)
          .toList(),
    );
  }
}

class DeleteTextAction extends EditorAction {
  DeleteTextAction(this.block);

  final TextBlock block;

  @override
  NotePage apply(NotePage page) {
    return page.copyWith(
      textBlocks: page.textBlocks.where((item) => item.id != block.id).toList(),
    );
  }

  @override
  NotePage revert(NotePage page) {
    return page.copyWith(textBlocks: [...page.textBlocks, block]);
  }
}

class MoveTextAction extends EditorAction {
  MoveTextAction({required this.id, required this.from, required this.to});

  final String id;
  final OffsetPosition from;
  final OffsetPosition to;

  @override
  NotePage apply(NotePage page) {
    return _update(page, to);
  }

  @override
  NotePage revert(NotePage page) {
    return _update(page, from);
  }

  NotePage _update(NotePage page, OffsetPosition position) {
    return page.copyWith(
      textBlocks: page.textBlocks
          .map(
            (item) => item.id == id
                ? item.copyWith(position: position.toOffset())
                : item,
          )
          .toList(),
    );
  }
}

class MoveImageAction extends EditorAction {
  MoveImageAction({required this.id, required this.from, required this.to});

  final String id;
  final OffsetPosition from;
  final OffsetPosition to;

  @override
  NotePage apply(NotePage page) {
    return _update(page, to);
  }

  @override
  NotePage revert(NotePage page) {
    return _update(page, from);
  }

  NotePage _update(NotePage page, OffsetPosition position) {
    return page.copyWith(
      imageBlocks: page.imageBlocks
          .map(
            (item) => item.id == id
                ? item.copyWith(position: position.toOffset())
                : item,
          )
          .toList(),
    );
  }
}

class UpdateImageOcrAction extends EditorAction {
  UpdateImageOcrAction({
    required this.id,
    required this.ocrText,
    required this.before,
  });

  final String id;
  final String ocrText;
  final List<ImageBlock> before;

  @override
  NotePage apply(NotePage page) {
    return page.copyWith(
      imageBlocks: page.imageBlocks
          .map((item) => item.id == id ? item.copyWith(ocrText: ocrText) : item)
          .toList(),
    );
  }

  @override
  NotePage revert(NotePage page) {
    return page.copyWith(imageBlocks: before);
  }
}

class UpdateImageAction extends EditorAction {
  UpdateImageAction({required this.before, required this.after});

  final ImageBlock before;
  final ImageBlock after;

  @override
  NotePage apply(NotePage page) {
    return page.copyWith(
      imageBlocks: page.imageBlocks
          .map((item) => item.id == after.id ? after : item)
          .toList(),
    );
  }

  @override
  NotePage revert(NotePage page) {
    return page.copyWith(
      imageBlocks: page.imageBlocks
          .map((item) => item.id == before.id ? before : item)
          .toList(),
    );
  }
}

class DeleteImageAction extends EditorAction {
  DeleteImageAction(this.block);

  final ImageBlock block;

  @override
  NotePage apply(NotePage page) {
    return page.copyWith(
      imageBlocks: page.imageBlocks
          .where((item) => item.id != block.id)
          .toList(),
    );
  }

  @override
  NotePage revert(NotePage page) {
    return page.copyWith(imageBlocks: [...page.imageBlocks, block]);
  }
}

class MoveSelectionAction extends EditorAction {
  MoveSelectionAction({
    required this.strokeIds,
    required this.textBlockIds,
    required this.imageBlockIds,
    required this.delta,
  });

  final List<String> strokeIds;
  final List<String> textBlockIds;
  final List<String> imageBlockIds;
  final OffsetPosition delta;

  @override
  NotePage apply(NotePage page) => _applyDelta(page, delta.toOffset());

  @override
  NotePage revert(NotePage page) => _applyDelta(page, -delta.toOffset());

  NotePage _applyDelta(NotePage page, Offset d) {
    return page.copyWith(
      inkStrokes: page.inkStrokes
          .map((s) => strokeIds.contains(s.id) ? _moveStroke(s, d) : s)
          .toList(),
      textBlocks: page.textBlocks
          .map(
            (t) => textBlockIds.contains(t.id)
                ? t.copyWith(position: t.position + d)
                : t,
          )
          .toList(),
      imageBlocks: page.imageBlocks
          .map(
            (i) => imageBlockIds.contains(i.id)
                ? i.copyWith(position: i.position + d)
                : i,
          )
          .toList(),
    );
  }

  InkStroke _moveStroke(InkStroke stroke, Offset d) {
    return stroke.copyWith(
      points: stroke.points
          .map(
            (p) => InkPoint(
              dx: p.dx + d.dx,
              dy: p.dy + d.dy,
              pressure: p.pressure,
            ),
          )
          .toList(),
    );
  }
}

class DeleteSelectionAction extends EditorAction {
  DeleteSelectionAction({
    required this.deletedStrokes,
    required this.deletedTextBlocks,
    required this.deletedImageBlocks,
  });

  final List<InkStroke> deletedStrokes;
  final List<TextBlock> deletedTextBlocks;
  final List<ImageBlock> deletedImageBlocks;

  @override
  NotePage apply(NotePage page) {
    return page.copyWith(
      inkStrokes: page.inkStrokes
          .where((s) => !deletedStrokes.any((d) => d.id == s.id))
          .toList(),
      textBlocks: page.textBlocks
          .where((t) => !deletedTextBlocks.any((d) => d.id == t.id))
          .toList(),
      imageBlocks: page.imageBlocks
          .where((i) => !deletedImageBlocks.any((d) => d.id == i.id))
          .toList(),
    );
  }

  @override
  NotePage revert(NotePage page) {
    return page.copyWith(
      inkStrokes: [...page.inkStrokes, ...deletedStrokes],
      textBlocks: [...page.textBlocks, ...deletedTextBlocks],
      imageBlocks: [...page.imageBlocks, ...deletedImageBlocks],
    );
  }
}

class PasteSelectionAction extends EditorAction {
  PasteSelectionAction({
    required this.strokes,
    required this.textBlocks,
    required this.imageBlocks,
  });

  final List<InkStroke> strokes;
  final List<TextBlock> textBlocks;
  final List<ImageBlock> imageBlocks;

  @override
  NotePage apply(NotePage page) {
    return page.copyWith(
      inkStrokes: [...page.inkStrokes, ...strokes],
      textBlocks: [...page.textBlocks, ...textBlocks],
      imageBlocks: [...page.imageBlocks, ...imageBlocks],
    );
  }

  @override
  NotePage revert(NotePage page) {
    return page.copyWith(
      inkStrokes: page.inkStrokes
          .where((s) => !strokes.any((d) => d.id == s.id))
          .toList(),
      textBlocks: page.textBlocks
          .where((t) => !textBlocks.any((d) => d.id == t.id))
          .toList(),
      imageBlocks: page.imageBlocks
          .where((i) => !imageBlocks.any((d) => d.id == i.id))
          .toList(),
    );
  }
}

class OffsetPosition {
  const OffsetPosition(this.dx, this.dy);

  final double dx;
  final double dy;

  factory OffsetPosition.fromOffset(Offset offset) {
    return OffsetPosition(offset.dx, offset.dy);
  }

  Offset toOffset() => Offset(dx, dy);
}
