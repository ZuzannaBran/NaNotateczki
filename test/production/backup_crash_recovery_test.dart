import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

import '../support/native_test_documents.dart';

Notebook _fixture(String title, int revision) {
  final created = DateTime.utc(2026, 1, 1);
  return Notebook(
    uid: 'recovery-fixture',
    title: title,
    folder: 'Recovery',
    kind: NotebookKind.notebook,
    createdAt: created,
    updatedAt: created.add(Duration(minutes: revision)),
    pages: [
      NotePage(
        id: 'recovery-page',
        title: 'Page $revision',
        textBlocks: const [],
        imageBlocks: const [],
        inkStrokes: const [],
        isBookmarked: false,
      ),
    ],
  );
}

void main() {
  useIsolatedNativeTestDocuments();
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documents;
  late NotesDatabase database;
  late LocalBackupService backup;
  late File manifest;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('backup-crash-test-');
    database = NotesDatabase(NativeDatabase.memory());
    backup = LocalBackupService(
      NotebookRepository(database),
      documentsDirectory: () async => documents,
    );
    manifest = File('${documents.path}/local_backup/manifest.json');
  });

  tearDown(() async {
    await backup.dispose();
    await database.close();
    await documents.delete(recursive: true);
  });

  test('crash after moving manifest restores previous committed snapshot',
      () async {
    await backup.snapshot([_fixture('Committed', 1)]);
    final original = await manifest.readAsString();
    await manifest.rename('${manifest.path}.previous');
    await File('${manifest.path}.tmp').writeAsString('{"partial":');

    final recovered = await backup.readLatest();

    expect(recovered, hasLength(1));
    expect(recovered.single.title, 'Committed');
    expect(await manifest.readAsString(), original);
    expect(await File('${manifest.path}.tmp').exists(), isFalse);
    expect(await File('${manifest.path}.previous').exists(), isFalse);
  });

  test('crash before cleanup preserves newer committed manifest', () async {
    await backup.snapshot([_fixture('Previous', 1)]);
    final oldManifest = await manifest.readAsString();
    await backup.snapshot([_fixture('Current', 2)]);
    await File('${manifest.path}.previous').writeAsString(oldManifest);
    await File('${manifest.path}.tmp').writeAsString('{"partial":');

    final recovered = await backup.readLatest();

    expect(recovered.single.title, 'Current');
    expect(await File('${manifest.path}.previous').exists(), isFalse);
    expect(await File('${manifest.path}.tmp').exists(), isFalse);
  });

  test('filesystem write failure retains committed backup until retry',
      () async {
    await backup.snapshot([_fixture('Committed', 1)]);
    final originalManifest = await manifest.readAsString();
    final pages = Directory('${documents.path}/local_backup/pages');
    final movedPages = Directory('${pages.path}-temporarily-offline');
    await pages.rename(movedPages.path);
    final blocker = File(pages.path);
    await blocker.writeAsString('directory unavailable');

    try {
      await expectLater(
        backup.snapshot([_fixture('New revision', 2)]),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      await blocker.delete();
      await movedPages.rename(pages.path);
    }

    expect(await manifest.readAsString(), originalManifest);
    expect((await backup.readLatest()).single.title, 'Committed');

    await backup.snapshot([_fixture('New revision', 2)]);
    expect((await backup.readLatest()).single.title, 'New revision');
  });

  test('interrupted snapshot leaves last committed manifest unchanged',
      () async {
    await backup.snapshot([_fixture('Committed', 1)]);
    final originalManifest = await manifest.readAsString();

    await expectLater(
      backup.snapshot(
        [_fixture('Not committed', 2)],
        shouldInterrupt: () => true,
      ),
      throwsA(isA<BackupSnapshotInterrupted>()),
    );

    expect(await manifest.readAsString(), originalManifest);
    expect((await backup.readLatest()).single.title, 'Committed');
  });
}
