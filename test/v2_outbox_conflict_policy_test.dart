import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/v2_outbox_conflict_policy.dart';

OperationEnvelope _operation(
  OperationKind kind, {
  required Map<String, dynamic> payload,
  String documentId = 'document-a',
  String? pageId,
  String? objectId,
  bool remote = false,
}) {
  return OperationEnvelope(
    operationId: remote
        ? '00000000-0000-4000-8000-000000000001'
        : '00000000-0000-4000-8000-000000000002',
    actorId: remote ? 'remote-device' : 'local-device',
    actorSeq: 1,
    logicalClock: remote ? 2 : 1,
    dependencies: const [],
    documentId: documentId,
    pageId: pageId,
    objectId: objectId,
    kind: kind,
    payload: payload,
  );
}

bool _allowed(OperationEnvelope remote, OperationEnvelope local) {
  return V2OutboxConflictPolicy.canApply(remote, [local]);
}

void main() {
  test('document and page fields commute across scopes', () {
    final title = _operation(
      OperationKind.documentSet,
      remote: true,
      payload: const {
        'properties': {'title': 'Remote'},
      },
    );
    final folder = _operation(
      OperationKind.documentSet,
      payload: const {
        'properties': {'folder': 'Local'},
      },
    );
    final competingTitle = _operation(
      OperationKind.documentSet,
      payload: const {
        'properties': {'title': 'Local'},
      },
    );
    final pageTitle = _operation(
      OperationKind.pageSet,
      objectId: 'page-a',
      payload: const {
        'properties': {'title': 'Page'},
      },
    );
    expect(_allowed(title, folder), isTrue);
    expect(_allowed(title, pageTitle), isTrue);
    expect(_allowed(title, competingTitle), isFalse);
    expect(_allowed(pageTitle, folder), isTrue);
  });

  test('page metadata merges per page and disjoint field', () {
    final bookmark = _operation(
      OperationKind.pageSet,
      objectId: 'page-a',
      remote: true,
      payload: const {
        'properties': {'isBookmarked': true},
      },
    );
    final localTitle = _operation(
      OperationKind.pageSet,
      objectId: 'page-a',
      payload: const {
        'properties': {'title': 'Local page'},
      },
    );
    final otherPage = _operation(
      OperationKind.pageSet,
      objectId: 'page-b',
      payload: const {
        'properties': {'isBookmarked': false},
      },
    );
    final competing = _operation(
      OperationKind.pageSet,
      objectId: 'page-a',
      payload: const {
        'properties': {'isBookmarked': false},
      },
    );
    expect(_allowed(bookmark, localTitle), isTrue);
    expect(_allowed(bookmark, otherPage), isTrue);
    expect(_allowed(bookmark, competing), isFalse);
  });

  test('metadata cannot bypass destructive edits or foreign namespace', () {
    final title = _operation(
      OperationKind.documentSet,
      remote: true,
      payload: const {
        'properties': {'title': 'Remote'},
      },
    );
    final removed = _operation(
      OperationKind.documentDelete,
      payload: const {},
    );
    final foreign = _operation(
      OperationKind.objectSet,
      documentId: 'document-b',
      objectId: 'ink-a',
      pageId: 'page-a',
      payload: const {
        'properties': {'width': 3.0},
      },
    );
    final ink = _operation(
      OperationKind.objectSet,
      objectId: 'ink-a',
      pageId: 'page-a',
      payload: const {
        'properties': {'width': 3.0},
      },
    );
    expect(_allowed(title, removed), isFalse);
    expect(_allowed(title, foreign), isFalse);
    expect(_allowed(title, ink), isTrue);
    expect(
      V2OutboxConflictPolicy.canApply(title, [ink, removed]),
      isFalse,
    );
  });

  test('object field updates merge only across disjoint property names', () {
    final color = _operation(
      OperationKind.objectSet,
      remote: true,
      objectId: 'stroke-a',
      pageId: 'page-a',
      payload: const {
        'properties': {'colorValue': 0xFF223344},
      },
    );
    final width = _operation(
      OperationKind.objectSet,
      objectId: 'stroke-a',
      pageId: 'page-a',
      payload: const {
        'properties': {'width': 3.0},
      },
    );
    final sameColor = _operation(
      OperationKind.objectSet,
      objectId: 'stroke-a',
      pageId: 'page-a',
      payload: const {
        'properties': {'colorValue': 0xFF998877},
      },
    );
    final moving = _operation(
      OperationKind.objectMove,
      objectId: 'stroke-a',
      pageId: 'page-a',
      payload: const {
        'toPageId': 'page-b',
        'sortIndex': 0,
      },
    );
    expect(_allowed(color, width), isTrue);
    expect(_allowed(color, sameColor), isFalse);
    expect(_allowed(color, moving), isFalse);
  });

  test('concurrent Quill inserts and deletes preserve independent atoms', () {
    const first = '00000000-0000-4000-8000-0000000000a1';
    const second = '00000000-0000-4000-8000-0000000000a2';
    final insert = _operation(
      OperationKind.textInsert,
      remote: true,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {'id': first, 'text': 'Remote'},
        ],
      },
    );
    final independent = _operation(
      OperationKind.textInsert,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {'id': second, 'text': 'Local'},
        ],
      },
    );
    final colliding = _operation(
      OperationKind.textInsert,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {'id': first, 'text': 'Conflict'},
        ],
      },
    );
    final deleted = _operation(
      OperationKind.textDelete,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'atomIds': [second],
      },
    );
    final anchored = _operation(
      OperationKind.textInsert,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'afterAtomId': first,
        'atoms': [
          {'id': second, 'text': 'After'},
        ],
      },
    );
    expect(_allowed(insert, independent), isTrue);
    expect(_allowed(insert, colliding), isFalse);
    expect(_allowed(insert, deleted), isTrue);
    final dependsOnLocal = _operation(
      OperationKind.textInsert,
      remote: true,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'afterAtomId': second,
        'atoms': [
          {'id': first, 'text': 'Needs local atom'},
        ],
      },
    );
    expect(_allowed(dependsOnLocal, independent), isFalse);
    final deleteAnchor = _operation(
      OperationKind.textDelete,
      remote: true,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'atomIds': [first],
      },
    );
    expect(_allowed(deleteAnchor, anchored), isFalse);
  });

  test('Quill formatting handles different atoms and attributes', () {
    const first = '00000000-0000-4000-8000-0000000000a1';
    const second = '00000000-0000-4000-8000-0000000000a2';
    final bold = _operation(
      OperationKind.textFormat,
      remote: true,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'atomIds': [first],
        'attributes': {'bold': true},
      },
    );
    final italic = _operation(
      OperationKind.textFormat,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'atomIds': [first],
        'attributes': {'italic': true},
      },
    );
    final sameAttribute = _operation(
      OperationKind.textFormat,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'atomIds': [first],
        'attributes': {'bold': null},
      },
    );
    final deleted = _operation(
      OperationKind.textDelete,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'atomIds': [second],
      },
    );
    final overlappingDelete = _operation(
      OperationKind.textDelete,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'atomIds': [first],
      },
    );
    expect(_allowed(bold, italic), isTrue);
    expect(_allowed(bold, sameAttribute), isFalse);
    expect(_allowed(bold, deleted), isTrue);
    expect(_allowed(bold, overlappingDelete), isFalse);
  });

  test('two objects may not reuse a pending Quill asset identity', () {
    const id = '00000000-0000-4000-8000-0000000000a1';
    final embed = _operation(
      OperationKind.textInsert,
      remote: true,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {
            'id': id,
            'text': '\uFFFC',
            'embed': {'image': 'asset:shared-file'},
          },
        ],
      },
    );
    final colliding = _operation(
      OperationKind.assetAttach,
      pageId: 'page-a',
      objectId: 'image-b',
      payload: {
        'assetId': 'shared-file',
        'sha256': ''.padLeft(64, '0'),
        'sizeBytes': 8,
        'mediaType': 'image/png',
      },
    );
    final separate = _operation(
      OperationKind.assetAttach,
      pageId: 'page-a',
      objectId: 'image-b',
      payload: {
        'assetId': 'another-file',
        'sha256': ''.padLeft(64, '0'),
        'sizeBytes': 8,
        'mediaType': 'image/png',
      },
    );
    expect(_allowed(embed, colliding), isFalse);
    expect(_allowed(embed, separate), isTrue);
  });

  test('a remote deletion still waits for the local outbox', () {
    final deleted = _operation(
      OperationKind.documentDelete,
      remote: true,
      payload: const {},
    );
    final pending = _operation(
      OperationKind.objectDelete,
      pageId: 'page-a',
      objectId: 'stroke-a',
      payload: const {},
    );
    expect(_allowed(deleted, pending), isFalse);
    expect(V2OutboxConflictPolicy.canApply(deleted, []), isTrue);
  });
}
