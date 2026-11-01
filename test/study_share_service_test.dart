import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:program/data/sync/study_share_service.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';
import 'package:program/features/share/presentation/study_share_dialog.dart';
import 'package:program/features/share/presentation/study_share_guest_screen.dart';

void main() {
  test('extension keeps the same owner document and invitation', () {
    final original = ActiveStudyShare(
      id: 'e5b63a5e-82f3-4a2a-9c57-16255f4e4431',
      documentUid: 'original-document-uid',
      title: 'Biology',
      expiresAt: DateTime.utc(2026, 11, 1, 18),
    );
    final extended = original.copyWith(
      expiresAt: DateTime.utc(2026, 11, 1, 22),
    );

    expect(extended.documentUid, original.documentUid);
    expect(extended.id, original.id);
    expect(extended.title, original.title);
    expect(extended.expiresAt.isAfter(original.expiresAt), isTrue);
    expect(extended.link, original.link);
  });

  testWidgets('sharing accepts a single character but rejects empty input', (
    tester,
  ) async {
    final service = _RecordingStudyShareService();
    final now = DateTime.utc(2026, 11, 1);
    final document = Notebook(
      uid: 'test-document',
      title: 'Test board',
      kind: NotebookKind.board,
      folder: '',
      createdAt: now,
      updatedAt: now,
      pages: [],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showStudyShareDialog(
                context,
                document: document,
                service: service,
                active: null,
                onChanged: (_) {},
                onEnded: () {},
              ),
              child: const Text('Open sharing'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open sharing'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Everyone with the link and password can edit'),
      findsOneWidget,
    );
    expect(find.textContaining('Only you can edit'), findsNothing);
    expect(
      find.textContaining("saved in the host's original document."),
      findsOneWidget,
    );

    await tester.tap(find.text('Create link'));
    await tester.pump();
    expect(find.text('Enter a session password.'), findsOneWidget);
    expect(service.createdPassword, isNull);

    await tester.enterText(find.byType(TextField), 'x');
    await tester.tap(find.text('Create link'));
    await tester.pumpAndSettle();

    expect(service.createdPassword, 'x');
    expect(find.text('Invitation link'), findsOneWidget);
  });

  testWidgets('guest link requests a password without account login', (
    tester,
  ) async {
    await tester.pumpWidget(
      const StudyShareGuestApp(
        sessionId: 'e5b63a5e-82f3-4a2a-9c57-16255f4e4431',
      ),
    );
    expect(
      find.text('Enter the password to join the session.'),
      findsOneWidget,
    );
    expect(find.text('Session password'), findsOneWidget);
    expect(find.text('Join'), findsOneWidget);
  });
}

class _RecordingStudyShareService implements StudyShareService {
  String? createdPassword;

  @override
  Future<ActiveStudyShare> create({
    required String documentUid,
    required String title,
    required String password,
  }) async {
    createdPassword = password;
    return ActiveStudyShare(
      id: 'e5b63a5e-82f3-4a2a-9c57-16255f4e4431',
      documentUid: documentUid,
      title: title,
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 4)),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
