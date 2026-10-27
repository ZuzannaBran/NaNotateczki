import 'package:flutter_test/flutter_test.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

import '../tool/website_widget_demo.dart';

void main() {
  test('website demo starts with one empty notebook page', () {
    final now = DateTime.utc(2026, 10, 27);
    final notebook = createWebsiteDemoNotebook(now);

    expect(notebook.kind, NotebookKind.notebook);
    expect(notebook.title, 'Pismo i tło strony');
    expect(notebook.pages, hasLength(1));
    expect(notebook.pages.single.inkStrokes, isEmpty);
    expect(notebook.pages.single.textBlocks, isEmpty);
    expect(notebook.pages.single.imageBlocks, isEmpty);
    expect(notebook.createdAt, now);
  });

  test('website demo uses a different database from the regular app', () {
    expect(websiteDemoDatabaseName, isNot('notes.sqlite'));
    expect(websiteDemoDatabaseName, contains('demo'));
  });
}
