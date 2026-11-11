import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/local_import_plan.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/text_block.dart';

Notebook notebook(String uid, String title, {String folder = 'Notes'}) =>
    Notebook(
      uid: uid,
      title: title,
      kind: NotebookKind.notebook,
      folder: folder,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      pages: [
        NotePage(
          id: 'page-$uid',
          title: 'Page',
          textBlocks: [
            TextBlock(
              id: 'text-$uid',
              text: 'Preserved',
              position: Offset.zero,
              fontSize: 16,
              color: const Color(0xff000000),
              width: 250,
            ),
          ],
          imageBlocks: [],
          inkStrokes: [],
          isBookmarked: true,
        ),
      ],
    );

void main() {
  test('stable IDs, deep page mapping, account-specific copies', () async {
    final source = notebook('source', 'Math');
    final a = LocalImportPlan(
      accountId: 'account-a',
      local: [source],
      account: [notebook('existing', 'Math')],
    );
    final b = LocalImportPlan(
      accountId: 'account-b', local: [source], account: [],
    );
    final copy = await a.materialize(a.documents.single);
    expect(copy.title, 'Math (1)');
    expect(copy.uid, isNot(source.uid));
    expect(copy.uid, isNot(b.documentUid(source.uid)));
    expect(copy.pages.single.id, isNot(source.pages.single.id));
    expect(copy.pages.single.textBlocks.single.id,
        isNot(source.pages.single.textBlocks.single.id));
    expect(copy.pages.single.textBlocks.single.text, 'Preserved');

    final resumed = LocalImportPlan(
      accountId: 'account-a', local: [source], account: [copy],
    );
    expect(resumed.documents.single.exists, isTrue);
    expect(resumed.documentUid(source.uid), copy.uid);
  });

  test('library tasks add idempotently; account covers remain authoritative', () {
    final plan = LocalImportPlan(
      accountId: 'account-a',
      local: [notebook('local-doc', 'Planner')],
      account: [],
    );
    const source = {
      'folders': ['School', 'Notes'],
      'covers': {'School': {'shape': 'star'}},
      'plannerTasks': {
        'local-doc': [
          {'id': 'task-1', 'title': 'Read', 'completed': true},
        ],
      },
      'recentCoverColors': [1],
    };
    const account = {
      'folders': ['School', 'Account'],
      'covers': {'School': {'shape': 'heart'}},
      'plannerTasks': {},
      'recentCoverColors': [2],
    };
    final first = plan.mergeLibrary(local: source, account: account);
    final second = plan.mergeLibrary(local: source, account: first);
    expect(jsonEncode(second), jsonEncode(first));
    expect(first['folders'], ['Account', 'Notes', 'School']);
    expect(first['covers']['School']['shape'], 'heart');
    expect(first['recentCoverColors'], [2]);
    final tasks = first['plannerTasks'][plan.documentUid('local-doc')] as List;
    expect(tasks.single['completed'], isTrue);
  });

  test('planner IDs and series are remapped without reviving tombstones', () {
    final plan = LocalImportPlan(accountId: 'A', local: [], account: []);
    final entry = {
      'id': 'series',
      'seriesId': 'parent',
      'title': 'Study',
      'scheduledAt': '2026-11-12T10:00:00Z',
      'repeat': 'weekly',
      'status': 'completed',
    };
    final mapped = plan.newPlannerEntries(
      local: {'sessions': [entry]},
      accountIds: [],
      accountTombstones: [],
    );
    expect(mapped.single['seriesId'],
        importedLocalUid('A', 'study', 'parent'));
    expect(mapped.single['status'], 'completed');
    expect(plan.newPlannerEntries(
      local: {'sessions': [entry]},
      accountIds: [],
      accountTombstones: [mapped.single['id'] as String],
    ), isEmpty);
    expect(plan.newPlannerEntries(
      local: {'sessions': [entry]},
      accountIds: [mapped.single['id'] as String],
      accountTombstones: [],
    ), isEmpty);
  });

  test('corrupt local metadata fails before replacing account data', () {
    expect(() => decodeLocalImportMetadata('42'), throwsFormatException);
    expect(decodeLocalImportMetadata('["Notes"]')['folders'], ['Notes']);
    expect(() => importedLocalUid('', 'doc', 'x'), throwsArgumentError);
  });

  test('unverified Quill embed is not silently imported', () async {
    final source = notebook('source', 'Text');
    final original = source.pages.single.textBlocks.single;
    final withEmbed = source.copyWith(pages: [
      source.pages.single.copyWith(textBlocks: [
        original.copyWith(deltaJson:
            '[{"insert":{"image":"asset:missing"}}]'),
      ]),
    ]);
    final plan = LocalImportPlan(
      accountId: 'A', local: [withEmbed], account: [],
    );
    await expectLater(
      plan.materialize(plan.documents.single),
      throwsUnsupportedError,
    );
  });
}
