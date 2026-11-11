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
    expect(_allowed(title, competingTitle), isTrue);
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
    expect(_allowed(bookmark, competing), isTrue);
  });

  test('metadata cannot bypass destructive edits or foreign namespace', () {
    final title = _operation(
      OperationKind.documentSet,
      remote: true,
      payload: const {
        'properties': {'title': 'Remote'},
      },
    );
    final removed = _operation(OperationKind.documentDelete, payload: const {});
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
    expect(V2OutboxConflictPolicy.canApply(title, [ink, removed]), isFalse);
  });

  test('object field updates and concurrent move preserve ranks', () {
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
      payload: const {'toPageId': 'page-b', 'sortIndex': 0},
    );
    expect(_allowed(color, width), isTrue);
    expect(_allowed(color, sameColor), isTrue);
    expect(_allowed(color, moving), isTrue);
  });

  test('concurrent Quill inserts and tombstone anchors converge', () {
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
    expect(_allowed(deleteAnchor, anchored), isTrue);
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
    expect(_allowed(bold, sameAttribute), isTrue);
    expect(_allowed(bold, deleted), isTrue);
    expect(_allowed(bold, overlappingDelete), isTrue);
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

  test('new page commutes with offline deletion on another page', () {
    final created = _operation(
      OperationKind.pageCreate,
      remote: true,
      objectId: 'page-added',
      payload: const {
        'value': {'title': 'Remote', 'isBookmarked': false},
      },
    );
    final removed = _operation(
      OperationKind.objectDelete,
      pageId: 'page-existing',
      objectId: 'old-stroke',
      payload: const {},
    );
    final unsafe = _operation(
      OperationKind.objectDelete,
      pageId: 'page-added',
      objectId: 'old-stroke',
      payload: const {},
    );
    expect(_allowed(created, removed), isTrue);
    expect(_allowed(removed, created), isTrue);
    expect(_allowed(created, unsafe), isFalse);
    expect(_allowed(unsafe, created), isFalse);
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

  test('image creation reserves its asset ID against a remote attach', () {
    final image = _operation(
      OperationKind.objectCreate,
      pageId: 'page-a',
      objectId: 'image-a',
      payload: const {
        'value': {'objectType': 'image', 'assetId': 'receipt-shared'},
      },
    );
    final matching = _operation(
      OperationKind.assetAttach,
      remote: true,
      pageId: 'page-a',
      objectId: 'image-b',
      payload: {
        'assetId': 'receipt-shared',
        'sha256': ''.padLeft(64, 'a'),
        'sizeBytes': 100,
        'mediaType': 'image/png',
      },
    );
    final independent = _operation(
      OperationKind.assetAttach,
      remote: true,
      pageId: 'page-a',
      objectId: 'image-b',
      payload: {
        'assetId': 'receipt-distinct',
        'sha256': ''.padLeft(64, 'b'),
        'sizeBytes': 100,
        'mediaType': 'image/png',
      },
    );
    expect(_allowed(matching, image), isFalse);
    expect(_allowed(independent, image), isTrue);
    expect(_allowed(image, matching), isFalse);
  });

  test('two Quill embeds in one block must not claim the same asset ID', () {
    const remoteAtom = '00000000-0000-4000-8000-0000000000c1';
    const localAtom = '00000000-0000-4000-8000-0000000000c2';
    final remote = _operation(
      OperationKind.textInsert,
      remote: true,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {
            'id': remoteAtom,
            'text': '\uFFFC',
            'embed': {'image': 'asset:shared-asset'},
          },
        ],
      },
    );
    final sameAsset = _operation(
      OperationKind.textInsert,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {
            'id': localAtom,
            'text': '\uFFFC',
            'embed': {'pdf': 'asset:shared-asset'},
          },
        ],
      },
    );
    final otherAsset = _operation(
      OperationKind.textInsert,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {
            'id': localAtom,
            'text': '\uFFFC',
            'embed': {'pdf': 'asset:other-asset'},
          },
        ],
      },
    );
    expect(_allowed(remote, sameAsset), isFalse);
    expect(_allowed(remote, otherAsset), isTrue);
  });

  test('bad embed identifier fails closed before independent text merge', () {
    const first = '00000000-0000-4000-8000-0000000000c1';
    const second = '00000000-0000-4000-8000-0000000000c2';
    final remote = _operation(
      OperationKind.textInsert,
      remote: true,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {
            'id': first,
            'text': '\uFFFC',
            'embed': {'image': 'https://invalid.example/image.png'},
          },
        ],
      },
    );
    final local = _operation(
      OperationKind.textInsert,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {'id': second, 'text': 'offline'},
        ],
      },
    );
    expect(_allowed(remote, local), isFalse);
  });

  test('all local edits commute only when each target is safe', () {
    final remote = _operation(
      OperationKind.pageSet,
      remote: true,
      objectId: 'page-a',
      payload: const {
        'properties': {'title': 'Remote'},
      },
    );
    final independent = _operation(
      OperationKind.objectSet,
      objectId: 'ink-a',
      pageId: 'page-a',
      payload: const {
        'properties': {'width': 2.0},
      },
    );
    final localBookmark = _operation(
      OperationKind.pageSet,
      objectId: 'page-a',
      payload: const {
        'properties': {'isBookmarked': true},
      },
    );
    final localTitle = _operation(
      OperationKind.pageSet,
      objectId: 'page-a',
      payload: const {
        'properties': {'title': 'Local'},
      },
    );
    expect(
      V2OutboxConflictPolicy.canApply(remote, [independent, localBookmark]),
      isTrue,
    );
    expect(
      V2OutboxConflictPolicy.canApply(remote, [independent, localTitle]),
      isTrue,
    );
    expect(
      V2OutboxConflictPolicy.canApply(remote, [localTitle, independent]),
      isTrue,
    );
    final pendingDelete = _operation(
      OperationKind.pageDelete,
      objectId: 'page-a',
      payload: const {},
    );
    expect(
      V2OutboxConflictPolicy.canApply(remote, [independent, pendingDelete]),
      isFalse,
    );
    expect(
      V2OutboxConflictPolicy.canApply(remote, [pendingDelete, independent]),
      isFalse,
    );
  });

  test('page deletion commutes with document metadata only', () {
    final document = _operation(
      OperationKind.documentSet,
      remote: true,
      payload: const {
        'properties': {'title': 'Remote'},
      },
    );
    final deleted = _operation(
      OperationKind.pageDelete,
      objectId: 'page-a',
      payload: const {},
    );
    final pageTitle = _operation(
      OperationKind.pageSet,
      objectId: 'page-a',
      payload: const {
        'properties': {'title': 'Local'},
      },
    );
    expect(_allowed(document, deleted), isTrue);
    expect(_allowed(document, pageTitle), isTrue);
    expect(_allowed(pageTitle, deleted), isFalse);
  });

  test('text geometry commutes with concurrent Quill edits both ways', () {
    const atom = '00000000-0000-4000-8000-0000000000d1';
    final geometry = _operation(
      OperationKind.objectSet,
      remote: true,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'properties': {'dx': 10.0, 'width': 180.0},
      },
    );
    final insertion = _operation(
      OperationKind.textInsert,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {'id': atom, 'text': 'Offline'},
        ],
      },
    );
    final formatting = _operation(
      OperationKind.textFormat,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'atomIds': [atom],
        'attributes': {'bold': true},
      },
    );
    final deletion = _operation(
      OperationKind.textDelete,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'atomIds': [atom],
      },
    );
    expect(_allowed(geometry, insertion), isTrue);
    expect(_allowed(geometry, formatting), isTrue);
    expect(_allowed(geometry, deletion), isTrue);
    expect(_allowed(insertion, geometry), isTrue);
    expect(
      V2OutboxConflictPolicy.canApply(geometry, [insertion, formatting]),
      isTrue,
    );
  });

  test('text metadata rejects snapshots but permits concurrent moves', () {
    const atom = '00000000-0000-4000-8000-0000000000d1';
    final insert = _operation(
      OperationKind.textInsert,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {'id': atom, 'text': 'Text'},
        ],
      },
    );
    final unsafe = _operation(
      OperationKind.objectSet,
      remote: true,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'properties': {'assetId': 'unrelated'},
      },
    );
    final oldText = _operation(
      OperationKind.objectSet,
      remote: true,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'properties': {'text': 'snapshot is forbidden'},
      },
    );
    final moving = _operation(
      OperationKind.objectMove,
      remote: true,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {'toPageId': 'page-b', 'sortIndex': 1},
    );
    expect(_allowed(unsafe, insert), isFalse);
    expect(_allowed(oldText, insert), isFalse);
    expect(_allowed(moving, insert), isTrue);
  });

  test('text atoms never commute with ink-only transform or reorder', () {
    const atom = '00000000-0000-4000-8000-0000000000d4';
    final edit = _operation(
      OperationKind.textInsert,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {'id': atom, 'text': 'Offline'},
        ],
      },
    );
    final transform = _operation(
      OperationKind.objectTransform,
      remote: true,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'properties': {'dx': 20.0},
      },
    );
    final reorder = _operation(
      OperationKind.objectReorder,
      remote: true,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'properties': {'sortIndex': 1},
      },
    );
    final set = _operation(
      OperationKind.objectSet,
      remote: true,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'properties': {'dx': 20.0},
      },
    );
    expect(_allowed(transform, edit), isFalse);
    expect(_allowed(reorder, edit), isFalse);
    expect(_allowed(set, edit), isTrue);
  });

  test('remote objects commute with pending document and page metadata', () {
    final remoteStroke = _operation(
      OperationKind.strokeCreate,
      remote: true,
      pageId: 'page-a',
      objectId: 'peer-stroke',
      payload: const {
        'value': {'objectType': 'stroke'},
      },
    );
    final localTitle = _operation(
      OperationKind.documentSet,
      payload: const {
        'properties': {'title': 'Offline notebook'},
      },
    );
    final localBookmark = _operation(
      OperationKind.pageSet,
      objectId: 'page-a',
      payload: const {
        'properties': {'isBookmarked': true},
      },
    );
    expect(_allowed(remoteStroke, localTitle), isTrue);
    expect(_allowed(remoteStroke, localBookmark), isTrue);
    expect(
      V2OutboxConflictPolicy.canApply(remoteStroke, [
        localTitle,
        localBookmark,
      ]),
      isTrue,
    );
  });

  test('object changes commute with metadata on unrelated pages', () {
    final remoteWidth = _operation(
      OperationKind.objectSet,
      remote: true,
      pageId: 'page-a',
      objectId: 'ink-a',
      payload: const {
        'properties': {'width': 5.0},
      },
    );
    final pageA = _operation(
      OperationKind.pageSet,
      objectId: 'page-a',
      payload: const {
        'properties': {'title': 'Page A'},
      },
    );
    final pageB = _operation(
      OperationKind.pageSet,
      objectId: 'page-b',
      payload: const {
        'properties': {'title': 'Page B'},
      },
    );
    expect(_allowed(remoteWidth, pageA), isTrue);
    expect(_allowed(remoteWidth, pageB), isTrue);
    expect(_allowed(pageA, remoteWidth), isTrue);
    expect(_allowed(pageB, remoteWidth), isTrue);
  });

  test('document deletion blocks; another page may be removed', () {
    final remote = _operation(
      OperationKind.objectSet,
      remote: true,
      pageId: 'page-a',
      objectId: 'ink-a',
      payload: const {
        'properties': {'width': 5.0},
      },
    );
    final documentDelete = _operation(
      OperationKind.documentDelete,
      payload: const {},
    );
    final pageDelete = _operation(
      OperationKind.pageDelete,
      objectId: 'page-b',
      payload: const {},
    );
    final objectDelete = _operation(
      OperationKind.objectDelete,
      pageId: 'page-b',
      objectId: 'ink-b',
      payload: const {},
    );
    expect(_allowed(remote, documentDelete), isFalse);
    expect(_allowed(remote, pageDelete), isTrue);
    expect(_allowed(remote, objectDelete), isTrue);
    final samePageDelete = _operation(
      OperationKind.pageDelete,
      objectId: 'page-a',
      payload: const {},
    );
    expect(_allowed(remote, samePageDelete), isFalse);
    expect(_allowed(samePageDelete, remote), isFalse);
  });

  test('remote Quill inserts commute with pending page title', () {
    const atomId = '00000000-0000-4000-8000-0000000000e1';
    final remoteText = _operation(
      OperationKind.textInsert,
      remote: true,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {'id': atomId, 'text': 'Remote'},
        ],
      },
    );
    final title = _operation(
      OperationKind.pageSet,
      objectId: 'page-a',
      payload: const {
        'properties': {'title': 'Offline'},
      },
    );
    expect(_allowed(remoteText, title), isTrue);
    expect(_allowed(title, remoteText), isTrue);
  });

  test('identical asset receipts can serve independent remote owners', () {
    final remote = _operation(
      OperationKind.assetAttach,
      remote: true,
      pageId: 'page-a',
      objectId: 'image-a',
      payload: {
        'assetId': 'shared-asset',
        'sha256': ''.padLeft(64, 'a'),
        'sizeBytes': 12,
        'mediaType': 'image/png',
      },
    );
    final anotherOwner = _operation(
      OperationKind.assetAttach,
      pageId: 'page-b',
      objectId: 'image-b',
      payload: {
        'assetId': 'shared-asset',
        'sha256': ''.padLeft(64, 'a'),
        'sizeBytes': 12,
        'mediaType': 'image/png',
      },
    );
    expect(_allowed(remote, anotherOwner), isTrue);
    expect(_allowed(anotherOwner, remote), isTrue);
  });

  test('asset alias reuse rejects different bytes, mime and same owner', () {
    final remote = _operation(
      OperationKind.assetAttach,
      remote: true,
      pageId: 'page-a',
      objectId: 'image-a',
      payload: {
        'assetId': 'shared-asset',
        'sha256': ''.padLeft(64, 'a'),
        'sizeBytes': 12,
        'mediaType': 'image/png',
      },
    );
    OperationEnvelope local(Map<String, dynamic> payload, String owner) =>
        _operation(
          OperationKind.assetAttach,
          pageId: 'page-b',
          objectId: owner,
          payload: payload,
        );
    expect(
      _allowed(
        remote,
        local({
          'assetId': 'shared-asset',
          'sha256': ''.padLeft(64, 'b'),
          'sizeBytes': 12,
          'mediaType': 'image/png',
        }, 'image-b'),
      ),
      isFalse,
    );
    expect(
      _allowed(
        remote,
        local({
          'assetId': 'shared-asset',
          'sha256': ''.padLeft(64, 'a'),
          'sizeBytes': 12,
          'mediaType': 'application/pdf',
        }, 'image-b'),
      ),
      isFalse,
    );
    expect(
      _allowed(
        remote,
        local({
          'assetId': 'shared-asset',
          'sha256': ''.padLeft(64, 'a'),
          'sizeBytes': 12,
          'mediaType': 'image/png',
        }, 'image-a'),
      ),
      isFalse,
    );
  });

  test('new page and existing metadata commute in both directions', () {
    final created = _operation(
      OperationKind.pageCreate,
      remote: true,
      objectId: 'page-new',
      payload: const {
        'value': {'title': 'Remote', 'isBookmarked': false},
      },
    );
    final title = _operation(
      OperationKind.documentSet,
      payload: const {
        'properties': {'title': 'Offline'},
      },
    );
    final otherPage = _operation(
      OperationKind.pageSet,
      objectId: 'page-old',
      payload: const {
        'properties': {'isBookmarked': true},
      },
    );
    expect(_allowed(created, title), isTrue);
    expect(_allowed(title, created), isTrue);
    expect(_allowed(created, otherPage), isTrue);
    expect(_allowed(otherPage, created), isTrue);
    expect(
      V2OutboxConflictPolicy.canApply(created, [title, otherPage]),
      isTrue,
    );
  });

  test('new page does not block ink or Quill on existing page', () {
    final created = _operation(
      OperationKind.pageCreate,
      remote: true,
      objectId: 'page-new',
      payload: const {
        'value': {'title': 'Remote', 'isBookmarked': false},
      },
    );
    final stroke = _operation(
      OperationKind.strokeCreate,
      pageId: 'page-old',
      objectId: 'stroke-old',
      payload: const {
        'value': {'objectType': 'stroke'},
      },
    );
    final text = _operation(
      OperationKind.textInsert,
      pageId: 'page-old',
      objectId: 'text-old',
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {'id': '00000000-0000-4000-8000-0000000000e2', 'text': 'Offline'},
        ],
      },
    );
    expect(_allowed(created, stroke), isTrue);
    expect(_allowed(created, text), isTrue);
    expect(_allowed(stroke, created), isTrue);
    expect(_allowed(text, created), isTrue);
  });

  test('concurrent page creation cannot reorder pending new pages', () {
    final created = _operation(
      OperationKind.pageCreate,
      remote: true,
      objectId: 'page-new',
      payload: const {
        'value': {'title': 'Remote', 'isBookmarked': false},
      },
    );
    final another = _operation(
      OperationKind.pageCreate,
      objectId: 'page-other',
      payload: const {
        'value': {'title': 'Offline', 'isBookmarked': false},
      },
    );
    final samePage = _operation(
      OperationKind.pageSet,
      objectId: 'page-new',
      payload: const {
        'properties': {'title': 'Local'},
      },
    );
    expect(_allowed(created, another), isFalse);
    expect(_allowed(another, created), isFalse);
    expect(_allowed(created, samePage), isFalse);
    expect(_allowed(samePage, created), isFalse);
  });

  test('new page does not skip destructive and container operations', () {
    final created = _operation(
      OperationKind.pageCreate,
      remote: true,
      objectId: 'page-new',
      payload: const {
        'value': {'title': 'Remote', 'isBookmarked': false},
      },
    );
    final deleted = _operation(
      OperationKind.pageDelete,
      objectId: 'page-old',
      payload: const {},
    );
    final moved = _operation(
      OperationKind.objectMove,
      pageId: 'page-old',
      objectId: 'ink',
      payload: const {'toPageId': 'page-new', 'sortIndex': 0},
    );
    final targetNew = _operation(
      OperationKind.objectSet,
      pageId: 'page-new',
      objectId: 'ink',
      payload: const {
        'properties': {'width': 2.0},
      },
    );
    expect(_allowed(created, deleted), isFalse);
    expect(_allowed(created, moved), isFalse);
    expect(_allowed(created, targetNew), isFalse);
  });

  test('new page gate rejects unrelated document namespaces', () {
    final created = _operation(
      OperationKind.pageCreate,
      remote: true,
      objectId: 'page-new',
      payload: const {
        'value': {'title': 'Remote', 'isBookmarked': false},
      },
    );
    final foreign = _operation(
      OperationKind.documentSet,
      documentId: 'other-document',
      payload: const {
        'properties': {'title': 'Foreign'},
      },
    );
    expect(_allowed(created, foreign), isFalse);
  });

  test('page delete commutes with offline document and other page fields', () {
    final removed = _operation(
      OperationKind.pageDelete,
      remote: true,
      objectId: 'page-old',
      payload: const {},
    );
    final title = _operation(
      OperationKind.documentSet,
      payload: const {
        'properties': {'title': 'Offline'},
      },
    );
    final bookmark = _operation(
      OperationKind.pageSet,
      objectId: 'page-kept',
      payload: const {
        'properties': {'isBookmarked': true},
      },
    );
    expect(_allowed(removed, title), isTrue);
    expect(_allowed(title, removed), isTrue);
    expect(_allowed(removed, bookmark), isTrue);
    expect(_allowed(bookmark, removed), isTrue);
    expect(V2OutboxConflictPolicy.canApply(removed, [title, bookmark]), isTrue);
  });

  test('page delete keeps ink and text intents on unaffected page', () {
    final removed = _operation(
      OperationKind.pageDelete,
      remote: true,
      objectId: 'page-old',
      payload: const {},
    );
    final ink = _operation(
      OperationKind.strokeCreate,
      pageId: 'page-kept',
      objectId: 'stroke-a',
      payload: const {
        'value': {'objectType': 'stroke'},
      },
    );
    final text = _operation(
      OperationKind.textInsert,
      pageId: 'page-kept',
      objectId: 'text-a',
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {'id': '00000000-0000-4000-8000-0000000000f2', 'text': 'Hello'},
        ],
      },
    );
    expect(_allowed(removed, ink), isTrue);
    expect(_allowed(ink, removed), isTrue);
    expect(_allowed(removed, text), isTrue);
    expect(_allowed(text, removed), isTrue);
  });

  test('page delete never skips edits on the removed page', () {
    final removed = _operation(
      OperationKind.pageDelete,
      remote: true,
      objectId: 'page-old',
      payload: const {},
    );
    final pageTitle = _operation(
      OperationKind.pageSet,
      objectId: 'page-old',
      payload: const {
        'properties': {'title': 'Local'},
      },
    );
    final ink = _operation(
      OperationKind.objectSet,
      pageId: 'page-old',
      objectId: 'ink-a',
      payload: const {
        'properties': {'width': 5.0},
      },
    );
    expect(_allowed(removed, pageTitle), isFalse);
    expect(_allowed(pageTitle, removed), isFalse);
    expect(_allowed(removed, ink), isFalse);
    expect(_allowed(ink, removed), isFalse);
  });

  test('page delete waits for moves, creates and media changes', () {
    final removed = _operation(
      OperationKind.pageDelete,
      remote: true,
      objectId: 'page-old',
      payload: const {},
    );
    final moved = _operation(
      OperationKind.objectMove,
      pageId: 'page-kept',
      objectId: 'ink-a',
      payload: const {'toPageId': 'page-old', 'sortIndex': 0},
    );
    final created = _operation(
      OperationKind.pageCreate,
      objectId: 'page-added',
      payload: const {
        'value': {'title': 'Local', 'isBookmarked': false},
      },
    );
    final media = _operation(
      OperationKind.assetAttach,
      pageId: 'page-kept',
      objectId: 'image-a',
      payload: {
        'assetId': 'shared',
        'sha256': ''.padLeft(64, 'a'),
        'sizeBytes': 1024,
        'mediaType': 'image/png',
      },
    );
    final switchAsset = _operation(
      OperationKind.objectSet,
      pageId: 'page-kept',
      objectId: 'image-a',
      payload: const {
        'properties': {'assetId': 'shared'},
      },
    );
    final embed = _operation(
      OperationKind.textInsert,
      pageId: 'page-kept',
      objectId: 'text-a',
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {
            'id': '00000000-0000-4000-8000-0000000000f3',
            'text': '\uFFFC',
            'embed': {'image': 'asset:shared'},
          },
        ],
      },
    );
    expect(_allowed(removed, moved), isFalse);
    expect(_allowed(removed, created), isFalse);
    expect(_allowed(removed, media), isFalse);
    expect(_allowed(removed, switchAsset), isFalse);
    expect(_allowed(removed, embed), isFalse);
    expect(_allowed(moved, removed), isFalse);
  });

  test('all pending edits must commute with remote page delete', () {
    final removed = _operation(
      OperationKind.pageDelete,
      remote: true,
      objectId: 'page-old',
      payload: const {},
    );
    final safe = _operation(
      OperationKind.documentSet,
      payload: const {
        'properties': {'title': 'Offline'},
      },
    );
    final unsafe = _operation(
      OperationKind.pageSet,
      objectId: 'page-old',
      payload: const {
        'properties': {'title': 'Conflict'},
      },
    );
    expect(V2OutboxConflictPolicy.canApply(removed, [safe]), isTrue);
    expect(V2OutboxConflictPolicy.canApply(removed, [safe, unsafe]), isFalse);
  });

  test('move of one ink object commutes with another ink edit', () {
    final move = _operation(
      OperationKind.objectMove,
      remote: true,
      pageId: 'first',
      objectId: 'ink-moved',
      payload: const {'toPageId': 'second', 'sortIndex': 3},
    );
    final style = _operation(
      OperationKind.objectSet,
      pageId: 'first',
      objectId: 'ink-untouched',
      payload: const {
        'properties': {'colorValue': 0xFF224466},
      },
    );
    final newStroke = _operation(
      OperationKind.strokeCreate,
      pageId: 'second',
      objectId: 'ink-new',
      payload: const {
        'value': {'objectType': 'stroke'},
      },
    );
    expect(_allowed(move, style), isTrue);
    expect(_allowed(style, move), isTrue);
    expect(_allowed(move, newStroke), isTrue);
    expect(_allowed(newStroke, move), isTrue);
    expect(V2OutboxConflictPolicy.canApply(move, [style, newStroke]), isTrue);
  });

  test('same-object move rebases fields but not concurrent moves', () {
    final move = _operation(
      OperationKind.objectMove,
      remote: true,
      pageId: 'first',
      objectId: 'same-ink',
      payload: const {'toPageId': 'second', 'sortIndex': 2},
    );
    final color = _operation(
      OperationKind.objectSet,
      pageId: 'first',
      objectId: 'same-ink',
      payload: const {
        'properties': {'colorValue': 0xFF445566},
      },
    );
    final pendingMove = _operation(
      OperationKind.objectMove,
      pageId: 'first',
      objectId: 'same-ink',
      payload: const {'toPageId': 'third', 'sortIndex': 1},
    );
    expect(_allowed(move, color), isTrue);
    expect(_allowed(color, move), isTrue);
    expect(_allowed(move, pendingMove), isFalse);
    expect(_allowed(pendingMove, move), isFalse);
  });

  test('independent concurrent moves use rank rather than pending gate', () {
    final remote = _operation(
      OperationKind.objectMove,
      remote: true,
      pageId: 'source',
      objectId: 'same-stroke',
      payload: const {'toPageId': 'remote-page', 'sortIndex': 2},
    );
    final local = _operation(
      OperationKind.objectMove,
      pageId: 'source',
      objectId: 'same-stroke',
      payload: const {'toPageId': 'local-page', 'sortIndex': 3},
    );
    expect(_allowed(remote, local), isTrue);
    expect(_allowed(local, remote), isTrue);

    final dependent = OperationEnvelope.fromJson({
      ...remote.toJson(),
      'dependencies': [local.operationId],
    });
    expect(_allowed(dependent, local), isFalse);
    final movedAgain = OperationEnvelope.fromJson({
      ...local.toJson(),
      'pageId': 'other-source',
    });
    expect(_allowed(remote, movedAgain), isFalse);

    final invalid = _operation(
      OperationKind.objectMove,
      pageId: 'source',
      objectId: 'same-stroke',
      payload: const {'toPageId': 'local-page', 'sortIndex': 1000000},
    );
    expect(_allowed(remote, invalid), isFalse);
  });

  test('move cannot race with deleting its source or destination', () {
    final move = _operation(
      OperationKind.objectMove,
      remote: true,
      pageId: 'source',
      objectId: 'moved-ink',
      payload: const {'toPageId': 'target', 'sortIndex': 1},
    );
    final deleteSource = _operation(
      OperationKind.pageDelete,
      objectId: 'source',
      payload: const {},
    );
    final deleteTarget = _operation(
      OperationKind.pageDelete,
      objectId: 'target',
      payload: const {},
    );
    expect(_allowed(move, deleteSource), isFalse);
    expect(_allowed(deleteSource, move), isFalse);
    expect(_allowed(move, deleteTarget), isFalse);
    expect(_allowed(deleteTarget, move), isFalse);
  });

  test('remote move and offline page bookmark remain independent', () {
    final move = _operation(
      OperationKind.objectMove,
      remote: true,
      pageId: 'source',
      objectId: 'moved-ink',
      payload: const {'toPageId': 'target', 'sortIndex': 1},
    );
    final metadata = _operation(
      OperationKind.pageSet,
      objectId: 'source',
      payload: const {
        'properties': {'isBookmarked': true},
      },
    );
    final title = _operation(
      OperationKind.documentSet,
      payload: const {
        'properties': {'title': 'Offline notebook'},
      },
    );
    expect(_allowed(move, metadata), isTrue);
    expect(_allowed(metadata, move), isTrue);
    expect(_allowed(move, title), isTrue);
    expect(_allowed(title, move), isTrue);
  });

  test('same-field metadata uses LWW, but deletes still block', () {
    final title = _operation(
      OperationKind.documentSet,
      remote: true,
      payload: const {
        'properties': {'title': 'Remote wins'},
      },
    );
    final pendingTitle = _operation(
      OperationKind.documentSet,
      payload: const {
        'properties': {'title': 'Offline title'},
      },
    );
    final pageTitle = _operation(
      OperationKind.pageSet,
      objectId: 'page-x',
      remote: true,
      payload: const {
        'properties': {'title': 'Remote page'},
      },
    );
    final pendingPageTitle = _operation(
      OperationKind.pageSet,
      objectId: 'page-x',
      payload: const {
        'properties': {'title': 'Offline page'},
      },
    );
    final deletePage = _operation(
      OperationKind.pageDelete,
      objectId: 'page-x',
      payload: const {},
    );
    expect(_allowed(title, pendingTitle), isTrue);
    expect(_allowed(pendingTitle, title), isTrue);
    expect(_allowed(pageTitle, pendingPageTitle), isTrue);
    expect(_allowed(pendingPageTitle, pageTitle), isTrue);
    expect(_allowed(pageTitle, deletePage), isFalse);
  });

  test('scalar collision converges while asset alias stays guarded', () {
    final width = _operation(
      OperationKind.objectSet,
      remote: true,
      pageId: 'page-x',
      objectId: 'image-x',
      payload: const {
        'properties': {'width': 230.0},
      },
    );
    final pendingWidth = _operation(
      OperationKind.objectSet,
      pageId: 'page-x',
      objectId: 'image-x',
      payload: const {
        'properties': {'width': 160.0},
      },
    );
    final pendingCrop = _operation(
      OperationKind.objectSet,
      pageId: 'page-x',
      objectId: 'image-x',
      payload: const {
        'properties': {'cropLeft': 0.2},
      },
    );
    final pendingAsset = _operation(
      OperationKind.objectSet,
      pageId: 'page-x',
      objectId: 'image-x',
      payload: const {
        'properties': {'assetId': 'replacement'},
      },
    );
    final pendingMove = _operation(
      OperationKind.objectMove,
      pageId: 'page-x',
      objectId: 'image-x',
      payload: const {'toPageId': 'another', 'sortIndex': 0},
    );
    expect(_allowed(width, pendingWidth), isTrue);
    expect(_allowed(pendingWidth, width), isTrue);
    expect(_allowed(width, pendingCrop), isTrue);
    expect(_allowed(pendingCrop, width), isTrue);
    expect(_allowed(width, pendingAsset), isFalse);
    expect(_allowed(width, pendingMove), isTrue);
  });

  test('same-atom format and delete converge through tombstones', () {
    const atom = '00000000-0000-4000-8000-0000000000e1';
    final bold = _operation(
      OperationKind.textFormat,
      remote: true,
      pageId: 'page-x',
      objectId: 'text-x',
      payload: const {
        'atomIds': [atom],
        'attributes': {'bold': true},
      },
    );
    final removeBold = _operation(
      OperationKind.textFormat,
      pageId: 'page-x',
      objectId: 'text-x',
      payload: const {
        'atomIds': [atom],
        'attributes': {'bold': null},
      },
    );
    final deleteAtom = _operation(
      OperationKind.textDelete,
      pageId: 'page-x',
      objectId: 'text-x',
      payload: const {
        'atomIds': [atom],
      },
    );
    expect(_allowed(bold, removeBold), isTrue);
    expect(_allowed(removeBold, bold), isTrue);
    expect(_allowed(bold, deleteAtom), isTrue);
    expect(_allowed(deleteAtom, bold), isTrue);
  });

  test('scalar LWW never crosses pages or target operation kinds', () {
    final inFirst = _operation(
      OperationKind.objectSet,
      pageId: 'page-a',
      objectId: 'shared-identity',
      remote: true,
      payload: const {
        'properties': {'width': 5.0},
      },
    );
    final inSecond = _operation(
      OperationKind.objectSet,
      pageId: 'page-b',
      objectId: 'shared-identity',
      payload: const {
        'properties': {'width': 6.0},
      },
    );
    final unsafeSnapshot = _operation(
      OperationKind.objectSet,
      pageId: 'page-a',
      objectId: 'shared-identity',
      payload: const {
        'properties': {'text': 'replace entire snapshot'},
      },
    );
    final transform = _operation(
      OperationKind.objectTransform,
      pageId: 'page-a',
      objectId: 'shared-identity',
      payload: const {
        'properties': {'width': 6.0},
      },
    );
    expect(_allowed(inFirst, inSecond), isFalse);
    expect(_allowed(inFirst, unsafeSnapshot), isFalse);
    expect(_allowed(inFirst, transform), isFalse);
  });

  test('same-object reorder uses LWW, other operation kinds stay strict', () {
    final reorder = _operation(
      OperationKind.objectReorder,
      remote: true,
      pageId: 'page-a',
      objectId: 'stroke-a',
      payload: const {
        'properties': {'sortIndex': 6},
      },
    );
    final queued = _operation(
      OperationKind.objectReorder,
      pageId: 'page-a',
      objectId: 'stroke-a',
      payload: const {
        'properties': {'sortIndex': 3},
      },
    );
    final transform = _operation(
      OperationKind.objectTransform,
      pageId: 'page-a',
      objectId: 'stroke-a',
      payload: const {
        'properties': {
          'points': [
            [1.0, 2.0, 0.6],
          ],
        },
      },
    );
    expect(_allowed(reorder, queued), isTrue);
    expect(_allowed(queued, reorder), isTrue);
    expect(_allowed(reorder, transform), isTrue);
    expect(_allowed(transform, reorder), isTrue);
  });

  test('snapshot and OCR-like keys cannot bypass scalar gate', () {
    final geometry = _operation(
      OperationKind.objectSet,
      remote: true,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'properties': {'width': 220.0},
      },
    );
    final replaceWholeText = _operation(
      OperationKind.objectSet,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'properties': {'text': 'Legacy snapshot'},
      },
    );
    final unverifiedOcr = _operation(
      OperationKind.objectSet,
      pageId: 'page-a',
      objectId: 'text-a',
      payload: const {
        'properties': {'ocrText': 'Not an editor scalar'},
      },
    );
    expect(_allowed(geometry, replaceWholeText), isFalse);
    expect(_allowed(geometry, unverifiedOcr), isFalse);
  });

  test('concurrent ink transforms use deterministic point-register rank', () {
    final movedPoints = _operation(
      OperationKind.objectTransform,
      remote: true,
      pageId: 'page-a',
      objectId: 'ink-a',
      payload: const {
        'properties': {
          'points': [
            [3.0, 4.0, 0.6],
          ],
        },
      },
    );
    final pendingPoints = _operation(
      OperationKind.objectTransform,
      pageId: 'page-a',
      objectId: 'ink-a',
      payload: const {
        'properties': {
          'points': [
            [1.0, 2.0, 0.5],
          ],
        },
      },
    );
    final differentPage = _operation(
      OperationKind.objectTransform,
      pageId: 'page-b',
      objectId: 'ink-a',
      payload: const {
        'properties': {
          'points': [
            [1.0, 2.0, 0.5],
          ],
        },
      },
    );
    expect(_allowed(movedPoints, pendingPoints), isTrue);
    expect(_allowed(pendingPoints, movedPoints), isTrue);
    expect(_allowed(movedPoints, differentPage), isFalse);
  });

  test('multi-field image transforms are not incorrectly ranked as ink', () {
    final geometry = _operation(
      OperationKind.objectTransform,
      remote: true,
      pageId: 'page-a',
      objectId: 'image-a',
      payload: const {
        'properties': {'width': 320.0},
      },
    );
    final pending = _operation(
      OperationKind.objectTransform,
      pageId: 'page-a',
      objectId: 'image-a',
      payload: const {
        'properties': {'width': 220.0},
      },
    );
    expect(_allowed(geometry, pending), isFalse);
  });

  test('unknown notebook and page snapshot keys stay blocked', () {
    final title = _operation(
      OperationKind.documentSet,
      remote: true,
      payload: const {
        'properties': {'title': 'Remote'},
      },
    );
    final snapshot = _operation(
      OperationKind.documentSet,
      payload: const {
        'properties': {'pages': 'replace all'},
      },
    );
    final pageTitle = _operation(
      OperationKind.pageSet,
      objectId: 'page-a',
      remote: true,
      payload: const {
        'properties': {'title': 'Remote'},
      },
    );
    final oldSnapshot = _operation(
      OperationKind.pageSet,
      objectId: 'page-a',
      payload: const {
        'properties': {'objects': 'replace all'},
      },
    );
    expect(_allowed(title, snapshot), isFalse);
    expect(_allowed(snapshot, title), isFalse);
    expect(_allowed(pageTitle, oldSnapshot), isFalse);
    expect(_allowed(oldSnapshot, pageTitle), isFalse);
  });
  test('page creation and removal commute with unrelated moves', () {
    final move = _operation(
      OperationKind.objectMove,
      remote: true,
      objectId: 'stroke-a',
      pageId: 'page-a',
      payload: const {'toPageId': 'page-b', 'sortIndex': 1},
    );
    final created = _operation(
      OperationKind.pageCreate,
      objectId: 'page-c',
      payload: const {
        'value': {'title': 'New', 'isBookmarked': false},
      },
    );
    final deleted = _operation(
      OperationKind.pageDelete,
      objectId: 'page-c',
      payload: const {},
    );
    expect(_allowed(move, created), isTrue);
    expect(_allowed(created, move), isTrue);
    expect(_allowed(move, deleted), isTrue);
    expect(_allowed(deleted, move), isTrue);
    final deleteSource = _operation(
      OperationKind.pageDelete,
      objectId: 'page-a',
      payload: const {},
    );
    final deleteDestination = _operation(
      OperationKind.pageDelete,
      objectId: 'page-b',
      payload: const {},
    );
    final createDestination = _operation(
      OperationKind.pageCreate,
      objectId: 'page-b',
      payload: const {
        'value': {'title': 'Destination', 'isBookmarked': false},
      },
    );
    expect(_allowed(move, deleteSource), isFalse);
    expect(_allowed(deleteDestination, move), isFalse);
    expect(_allowed(move, createDestination), isFalse);
    expect(_allowed(createDestination, move), isFalse);
  });

  test('cross-page move rebases fields and protects unsafe media', () {
    final move = _operation(
      OperationKind.objectMove,
      remote: true,
      objectId: 'stroke-a',
      pageId: 'page-a',
      payload: const {'toPageId': 'page-b', 'sortIndex': 3},
    );
    final color = _operation(
      OperationKind.objectSet,
      objectId: 'stroke-a',
      pageId: 'page-a',
      payload: const {
        'properties': {'colorValue': 0xFF334455},
      },
    );
    final delete = _operation(
      OperationKind.objectDelete,
      objectId: 'stroke-a',
      pageId: 'page-a',
      payload: const {},
    );
    final assetChange = _operation(
      OperationKind.objectSet,
      objectId: 'stroke-a',
      pageId: 'page-a',
      payload: const {
        'properties': {'assetId': 'attachment'},
      },
    );
    expect(_allowed(move, color), isTrue);
    expect(_allowed(color, move), isTrue);
    expect(_allowed(move, delete), isTrue);
    expect(_allowed(move, assetChange), isFalse);
  });
}
