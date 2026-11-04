import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/operation_protocol.dart';

const firstId = '11111111-1111-4111-8111-111111111111';
const secondId = '22222222-2222-4222-8222-222222222222';

OperationEnvelope operation({
  String operationId = firstId,
  OperationKind kind = OperationKind.strokeCreate,
  String? objectId = 'stroke-1',
  String? pageId = 'page-1',
  String documentId = 'document-1',
  List<String> dependencies = const [],
  int schemaVersion = 1,
}) {
  return OperationEnvelope(
    operationId: operationId,
    actorId: 'device-1',
    actorSeq: 1,
    documentId: documentId,
    objectId: objectId,
    pageId: pageId,
    kind: kind,
    payload: {
      'points': [
        {'dx': 4.5, 'dy': 2.0, 'pressure': 0.5},
      ],
    },
    dependencies: dependencies,
    logicalClock: 7,
    schemaVersion: schemaVersion,
  );
}

void main() {
  test('wire format round-trips without losing stable IDs', () {
    final original = operation();
    final decoded = OperationEnvelope.fromJson(
      jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
    );
    expect(decoded.toJson(), original.toJson());
    expect(decoded.operationId, firstId);
    expect(decoded.kind, OperationKind.strokeCreate);
  });

  test('supports all editor, library and metadata operations', () {
    for (final kind in OperationKind.values) {
      final op = operation(
        kind: kind,
        documentId:
            kind.target == OperationTarget.folder ||
                kind.target == OperationTarget.task
            ? OperationEnvelope.libraryDocumentId
            : 'document-1',
        pageId: kind.target == OperationTarget.object ? 'page-1' : null,
        objectId: kind.target == OperationTarget.document ? null : 'id-1',
      );
      expect(OperationEnvelope.fromJson(op.toJson()).kind, kind);
    }
  });

  test('rejects unknown versions and operation kinds', () {
    expect(() => operation(schemaVersion: 2), throwsFormatException);
    final json = operation().toJson()..['type'] = 'document.replace';
    expect(() => OperationEnvelope.fromJson(json), throwsFormatException);
  });

  test('rejects self dependencies and duplicate dependency IDs', () {
    expect(() => operation(dependencies: [firstId]), throwsFormatException);
    expect(
      () => operation(dependencies: [secondId, secondId]),
      throwsFormatException,
    );
  });

  test('rejects viewport data in document identity fields', () {
    expect(
      () => operation(
        kind: OperationKind.documentDelete,
        objectId: 'selected-object',
      ),
      throwsFormatException,
    );
    expect(
      () => operation(kind: OperationKind.objectSet, pageId: null),
      throwsFormatException,
    );
  });

  test('payload is immutable and never aliases original nested lists', () {
    final points = <int>[1, 2];
    final envelope = OperationEnvelope(
      operationId: firstId,
      actorId: 'device-a',
      actorSeq: 1,
      documentId: 'document-1',
      pageId: 'page-1',
      objectId: 'stroke-1',
      kind: OperationKind.strokeCreate,
      payload: {
        'value': {'points': points},
      },
      dependencies: [],
      logicalClock: 1,
    );
    points.clear();
    expect((envelope.toJson()['payload'] as Map)['value']['points'], [1, 2]);
    expect(
      () => (envelope.payload['value'] as Map)['points'] = <int>[],
      throwsUnsupportedError,
    );
  });

  test('rejects integers outside JavaScript exact integer range', () {
    expect(
      () => OperationEnvelope(
        operationId: firstId,
        actorId: 'device-a',
        actorSeq: OperationEnvelope.maxSafeInteger + 1,
        documentId: 'document-1',
        kind: OperationKind.documentSet,
        payload: {},
        dependencies: [],
        logicalClock: 1,
      ),
      throwsFormatException,
    );
  });

  test('undo is a new operation referencing the original', () {
    final undo = OperationEnvelope(
      operationId: secondId,
      actorId: 'device-1',
      actorSeq: 2,
      documentId: 'document-1',
      pageId: 'page-1',
      objectId: 'stroke-1',
      kind: OperationKind.objectDelete,
      payload: {},
      dependencies: [firstId],
      logicalClock: 8,
      revertsOperationId: firstId,
    );
    expect(undo.toJson()['revertsOperationId'], firstId);
    expect(undo.operationId, isNot(firstId));
  });

  test('v2 accepts empty create values but requires an exact payload key', () {
    expect(
      () => OperationEnvelope.validateV2Payload(
        kind: OperationKind.pageCreate,
        documentId: 'doc',
        objectId: 'page',
        payload: const {'value': <String, Object?>{}},
      ),
      returnsNormally,
    );
    expect(
      () => OperationEnvelope.validateV2Payload(
        kind: OperationKind.pageSet,
        documentId: 'doc',
        objectId: 'page',
        payload: const {
          'properties': {'x': 4},
          'unexpected': true,
        },
      ),
      throwsFormatException,
    );
  });

  test('v2 property edits cannot change stable identity', () {
    for (final field in ['id', 'uid']) {
      expect(
        () => OperationEnvelope.validateV2Payload(
          kind: OperationKind.pageSet,
          documentId: 'doc',
          objectId: 'page',
          payload: {
            'properties': {field: 'forged'},
          },
        ),
        throwsFormatException,
      );
    }
  });

  test('wire identifier rules reject control characters and long IDs', () {
    expect(() => operation(objectId: 'bad\n'), throwsFormatException);
    expect(
      () => operation(pageId: List.filled(129, 'x').join()),
      throwsFormatException,
    );
    expect(() => operation(documentId: 'bad\u0000'), throwsFormatException);
  });

  test('wire UUIDs must not accept a trailing newline', () {
    expect(() => operation(operationId: '$firstId\n'), throwsFormatException);
    expect(
      () => operation(dependencies: ['$secondId\n']),
      throwsFormatException,
    );
    expect(
      () => OperationEnvelope(
        operationId: secondId,
        actorId: 'device-a',
        actorSeq: 2,
        documentId: 'document-1',
        pageId: 'page-1',
        objectId: 'stroke-1',
        kind: OperationKind.objectDelete,
        payload: const {},
        dependencies: const [firstId],
        logicalClock: 2,
        revertsOperationId: '$firstId\n',
      ),
      throwsFormatException,
    );
    expect(
      () => OperationEnvelope.validateV2Payload(
        kind: OperationKind.textInsert,
        documentId: 'document-1',
        objectId: 'text-1',
        payload: {
          'afterAtomId': '$firstId\n',
          'atoms': [
            {'id': secondId, 'text': 'a'},
          ],
        },
      ),
      throwsFormatException,
    );
  });

  test('inverse reference requires its causal dependency', () {
    expect(
      () => OperationEnvelope(
        operationId: secondId,
        actorId: 'device-a',
        actorSeq: 2,
        documentId: 'document-1',
        pageId: 'page-1',
        objectId: 'stroke-1',
        kind: OperationKind.objectDelete,
        payload: const {},
        dependencies: const [],
        logicalClock: 2,
        revertsOperationId: firstId,
      ),
      throwsFormatException,
    );
  });

  test('task operations require library scope and stable IDs', () {
    final task = OperationEnvelope(
      operationId: firstId,
      actorId: 'device-a',
      actorSeq: 1,
      documentId: OperationEnvelope.libraryDocumentId,
      objectId: 'task-1',
      kind: OperationKind.taskCreate,
      payload: {
        'value': {'plannerUid': 'planner-1', 'title': 'Read chapter'},
      },
      dependencies: [],
      logicalClock: 1,
    );
    task.validateForV2Projection();
    expect(
      OperationEnvelope.fromJson(task.toJson()).kind,
      OperationKind.taskCreate,
    );
    expect(
      () => operation(
        kind: OperationKind.taskDelete,
        documentId: 'regular-document',
        pageId: null,
      ),
      throwsFormatException,
    );
    expect(
      () => OperationEnvelope.validateV2Payload(
        kind: OperationKind.taskCreate,
        documentId: OperationEnvelope.libraryDocumentId,
        objectId: 'task-2',
        payload: {
          'value': {'title': 'Missing planner'},
        },
      ),
      throwsFormatException,
    );
  });
  test('v2 cross-page moves validate exact destination and order', () {
    final valid = OperationEnvelope(
      operationId: firstId,
      actorId: 'device-a',
      actorSeq: 1,
      documentId: 'document',
      pageId: 'source',
      objectId: 'ink',
      kind: OperationKind.objectMove,
      payload: {'toPageId': 'destination', 'sortIndex': 1},
      dependencies: const [],
      logicalClock: 1,
    );
    expect(valid.validateForV2Projection, returnsNormally);
    for (final payload in [
      {'toPageId': 'source', 'sortIndex': 1},
      {'toPageId': 'destination', 'sortIndex': -1},
      {'toPageId': 'destination', 'sortIndex': 1, 'extra': 'unsafe'},
    ]) {
      expect(
        () => OperationEnvelope.validateV2Payload(
          kind: OperationKind.objectMove,
          documentId: 'document',
          pageId: 'source',
          objectId: 'ink',
          payload: payload,
        ),
        throwsFormatException,
      );
    }
  });

  test('v2 validates rich text atom attributes and format edits', () {
    expect(
      () => OperationEnvelope.validateV2Payload(
        kind: OperationKind.textInsert,
        documentId: 'document',
        objectId: 'text',
        payload: {
          'afterAtomId': null,
          'atoms': [
            {
              'id': firstId,
              'text': 'A',
              'attributes': {'bold': true},
            },
          ],
        },
      ),
      returnsNormally,
    );
    expect(
      () => OperationEnvelope.validateV2Payload(
        kind: OperationKind.textFormat,
        documentId: 'document',
        objectId: 'text',
        payload: {
          'atomIds': [firstId],
          'attributes': {'bold': null},
        },
      ),
      returnsNormally,
    );
    expect(
      () => OperationEnvelope.validateV2Payload(
        kind: OperationKind.textFormat,
        documentId: 'document',
        objectId: 'text',
        payload: {
          'atomIds': [firstId],
          'attributes': {
            'invalid': <int>[1],
          },
        },
      ),
      throwsFormatException,
    );
  });

  test('v2 asset attach/detach enforce verified metadata shape', () {
    final payload = {
      'assetId': 'photo-1',
      'sha256': List.filled(64, 'a').join(),
      'sizeBytes': 100,
      'mediaType': 'image/png',
    };
    expect(
      () => OperationEnvelope.validateV2Payload(
        kind: OperationKind.assetAttach,
        documentId: 'document',
        objectId: 'image-1',
        payload: payload,
      ),
      returnsNormally,
    );
    expect(
      () => OperationEnvelope.validateV2Payload(
        kind: OperationKind.assetDetach,
        documentId: 'document',
        objectId: 'image-1',
        payload: const {'assetId': 'photo-1'},
      ),
      returnsNormally,
    );
    for (final corrupt in [
      {...payload, 'sizeBytes': -1},
      {...payload, 'mediaType': 'text/html'},
      {...payload, 'sha256': 'not-a-checksum'},
      {...payload, 'unexpected': true},
    ]) {
      expect(
        () => OperationEnvelope.validateV2Payload(
          kind: OperationKind.assetAttach,
          documentId: 'document',
          objectId: 'image-1',
          payload: corrupt,
        ),
        throwsFormatException,
      );
    }
  });
}
