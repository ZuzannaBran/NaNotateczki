import 'package:flutter_test/flutter_test.dart';

import 'package:program/data/sync/study_share_service.dart';
import 'package:program/features/share/presentation/study_share_guest_screen.dart';

void main() {
  test('extension keeps the same owner document and invitation', () {
    final original = ActiveStudyShare(
      id: 'e5b63a5e-82f3-4a2a-9c57-16255f4e4431',
      documentUid: 'original-document-uid',
      title: 'Biology',
      expiresAt: DateTime.utc(2026, 11, 1, 18),
    );
    final extended = original.copyWith(expiresAt: DateTime.utc(2026, 11, 1, 22));

    expect(extended.documentUid, original.documentUid);
    expect(extended.id, original.id);
    expect(extended.title, original.title);
    expect(extended.expiresAt.isAfter(original.expiresAt), isTrue);
    expect(extended.link, original.link);
  });

  testWidgets('guest link requests a password without account login', (tester) async {
    await tester.pumpWidget(
      const StudyShareGuestApp(sessionId: 'e5b63a5e-82f3-4a2a-9c57-16255f4e4431'),
    );
    expect(find.text('Enter the password to join the session.'), findsOneWidget);
    expect(find.text('Session password'), findsOneWidget);
    expect(find.text('Join'), findsOneWidget);
  });
}
