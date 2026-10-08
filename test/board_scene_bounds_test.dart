import 'package:flutter_test/flutter_test.dart';
import 'package:program/features/board/presentation/board_screen.dart';

void main() {
  test('board coordinates do not rebase during object transforms', () {
    final resolver = BoardSceneBoundsResolver();
    const viewport = Size(900, 650);
    const initialContent = Rect.fromLTWH(80, 110, 200, 130);
    const expandedContent = Rect.fromLTWH(-1200, -800, 2200, 1900);

    Rect resolve(
      Rect content, {
      required bool freeze,
      Offset pan = Offset.zero,
    }) {
      return resolver.resolve(
        contentBounds: content,
        viewPan: pan,
        viewScale: 1,
        viewportSize: viewport,
        freeze: freeze,
      );
    }

    final initial = resolve(initialContent, freeze: false);

    expect(resolve(expandedContent, freeze: true), initial);
    expect(
      resolve(expandedContent, freeze: true, pan: const Offset(200, 200)),
      initial,
    );

    final updated = resolve(expandedContent, freeze: false);
    expect(updated, isNot(initial));
    expect(updated.left, -1900);
    expect(updated.top, -1500);

    expect(resolve(initialContent, freeze: true), updated);
    expect(resolve(initialContent, freeze: false), initial);
  });

  test('board bounds can freeze on the first render', () {
    final resolver = BoardSceneBoundsResolver();
    const content = Rect.fromLTWH(0, 0, 100, 100);

    Rect resolve(bool freeze, Rect contentBounds) {
      return resolver.resolve(
        contentBounds: contentBounds,
        viewPan: Offset.zero,
        viewScale: 2,
        viewportSize: const Size(800, 600),
        freeze: freeze,
      );
    }

    final first = resolve(true, content);
    expect(resolve(true, content.shift(const Offset(-2000, 0))), first);
    expect(resolve(false, content), first);
  });
}
