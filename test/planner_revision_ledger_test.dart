import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/planner_revision_ledger.dart';

Map<String, dynamic> row(
  String id, {
  int revision = 1,
  String title = 'Original',
  bool deleted = false,
  String time = '2032-01-01T00:00:00Z',
}) => {
  'id': id,
  'revision': revision,
  'deleted': deleted,
  'modifiedAt': time,
  'entry': deleted
      ? null
      : {
          'id': id,
          'kind': 'event',
          'title': title,
          'modifiedAt': time,
          'scheduledAt': '2026-11-04T10:00:00Z',
        },
};

void main() {
  test('changed device clock does not create a planner edit', () {
    final ledger = PlannerRevisionLedger();
    final original = row('e');
    ledger.acknowledge(original);
    expect(
      ledger.decide(
        id: 'e',
        local: row('e', time: '2000-01-01T00:00:00Z'),
        remote: original,
      ),
      PlannerSyncDecision.unchanged,
    );
  });

  test('independent edits send only when acknowledged base is unchanged', () {
    final ledger = PlannerRevisionLedger()..acknowledge(row('e'));
    final changed = row('e', title: 'Mine');
    expect(
      ledger.decide(id: 'e', local: changed, remote: row('e')),
      PlannerSyncDecision.sendLocal,
    );
    expect(
      ledger.decide(
        id: 'e',
        local: changed,
        remote: row('e', revision: 2, title: 'Theirs'),
      ),
      PlannerSyncDecision.conflict,
    );
  });

  test('remote tombstone wins and cannot be rolled back', () {
    final ledger = PlannerRevisionLedger()..acknowledge(row('e'));
    final tombstone = row('e', revision: 3, deleted: true);
    expect(
      ledger.decide(
        id: 'e',
        local: row('e', title: 'Offline edit'),
        remote: tombstone,
      ),
      PlannerSyncDecision.adoptRemote,
    );
    ledger.acknowledge(tombstone);
    expect(() => ledger.acknowledge(row('e')), throwsStateError);
  });

  test('local tombstone wins even if remote edit has a newer revision', () {
    final ledger = PlannerRevisionLedger()..acknowledge(row('e'));
    expect(
      ledger.decide(
        id: 'e',
        local: row('e', deleted: true),
        remote: row('e', revision: 2, title: 'Theirs'),
      ),
      PlannerSyncDecision.sendLocal,
    );
  });

  test('checkpoints survive restart and remain per-record', () {
    final ledger = PlannerRevisionLedger()
      ..acknowledge(row('one'))
      ..acknowledge(row('two', revision: 8, deleted: true));
    final restored = PlannerRevisionLedger.fromJson(
      // Read through JSON in the same shape as persisted storage.
      {
        'version': 1,
        'records': {
          'one': ledger['one']!.toJson(),
          'two': ledger['two']!.toJson(),
        },
      },
    );
    expect(restored['two']!.revision, 8);
    expect(restored.encode(), contains('deleted'));
  });

  test('unknown local and remote data are not silently overwritten', () {
    final ledger = PlannerRevisionLedger();
    expect(
      ledger.decide(
        id: 'e',
        local: row('e', title: 'Local'),
        remote: row('e', title: 'Account'),
      ),
      PlannerSyncDecision.conflict,
    );
  });
}
