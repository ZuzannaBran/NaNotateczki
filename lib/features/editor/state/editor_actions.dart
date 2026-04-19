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
      textBlocks: page.textBlocks
          .where((item) => item.id != block.id)
          .toList(),
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

class OffsetPosition {
  const OffsetPosition(this.dx, this.dy);

  final double dx;
  final double dy;

  factory OffsetPosition.fromOffset(Offset offset) {
    return OffsetPosition(offset.dx, offset.dy);
  }

  Offset toOffset() => Offset(dx, dy);
}
