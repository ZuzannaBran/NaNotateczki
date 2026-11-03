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
        documentId: kind.target == OperationTarget.folder
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
    expect(
      () => OperationEnvelope.fromJson(json),
      throwsFormatException,
    );
  });

  test('rejects self dependencies and duplicate dependency IDs', () {
    expect(
      () => operation(dependencies: [firstId]),
      throwsFormatException,
    );
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
}
