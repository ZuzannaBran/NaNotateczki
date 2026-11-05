import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_test/flutter_test.dart';
import 'package:program/features/editor/presentation/widgets/page_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('verified Quill PDF embed renders without a remote URL', (
    tester,
  ) async {
    final document = quill.Document.fromJson(const [
      {
        'insert': {'pdf': 'asset:verified-pdf'},
      },
      {'insert': '\n'},
    ]);
    final controller = quill.QuillController(
      document: document,
      selection: const TextSelection.collapsed(offset: 0),
    );
    addTearDown(controller.dispose);
    final requested = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: quill.QuillEditor.basic(
            controller: controller,
            config: quill.QuillEditorConfig(
              embedBuilders: [
                VerifiedQuillEmbedBuilder(
                  type: 'pdf',
                  load: (id) async {
                    requested.add(id);
                    return Uint8List.fromList([37, 80, 68, 70]);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(requested, contains('verified-pdf'));
    expect(find.text('Embedded PDF'), findsOneWidget);
  });

  testWidgets('non-asset Quill references never invoke the loader', (
    tester,
  ) async {
    final document = quill.Document.fromJson(const [
      {
        'insert': {'image': 'https://external.example/file.png'},
      },
      {'insert': '\n'},
    ]);
    final controller = quill.QuillController(
      document: document,
      selection: const TextSelection.collapsed(offset: 0),
    );
    addTearDown(controller.dispose);
    var loaded = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: quill.QuillEditor.basic(
            controller: controller,
            config: quill.QuillEditorConfig(
              embedBuilders: [
                VerifiedQuillEmbedBuilder(
                  type: 'image',
                  load: (_) async {
                    loaded = true;
                    return Uint8List.fromList([1]);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(loaded, isFalse);
    expect(find.byIcon(Icons.broken_image_outlined), findsWidgets);
  });
}
