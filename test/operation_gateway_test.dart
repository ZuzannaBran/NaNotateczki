import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/operation_gateway.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:uuid/uuid.dart';

OperationEnvelope _operation() => OperationEnvelope(
  operationId: const Uuid().v4(),
  actorId: 'device-test',
  actorSeq: 1,
  documentId: 'document-test',
  kind: OperationKind.documentCreate,
  payload: const {
    'value': {'title': 'Notes'},
  },
  dependencies: const [],
  logicalClock: 1,
);

void main() {
  ApiClient clientFor(
    Future<http.Response> Function(http.Request) handler,
  ) {
    final api = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient(handler),
    );
    api.setAccessToken('test-access-token');
    addTearDown(api.close);
    return api;
  }

  test('send preserves IDs, Bearer and the server-assigned cursor', () async {
    final operation = _operation();
    final client = clientFor((request) async {
      expect(request.url.path, '/v2/operations/batch');
      expect(request.headers['Authorization'], 'Bearer test-access-token');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect((body['operations'] as List).single['operationId'],
          operation.operationId);
      return http.Response(
        jsonEncode({
          'cursor': 23,
          'acknowledgements': [
            {
              'operationId': operation.operationId,
              'cursor': 23,
              'status': 'applied',
            },
          ],
        }),
        200,
      );
    });
    final ack = await HttpOperationGateway(client).send([operation]);
    expect(ack.single.operationId, operation.operationId);
    expect(ack.single.cursor, 23);
  });

  test('a partial ACK batch cannot be accepted', () async {
    final operation = _operation();
    final client = clientFor((_) async {
      return http.Response(
        jsonEncode({'cursor': 1, 'acknowledgements': []}),
        200,
      );
    });
    await expectLater(
      HttpOperationGateway(client).send([operation]),
      throwsFormatException,
    );
  });

  test('a malformed or non-monotonic feed cannot advance the cursor',
      () async {
    final operation = _operation();
    final client = clientFor((_) async {
      return http.Response(
        jsonEncode({
          'cursor': 4,
          'hasMore': false,
          'operations': [
            {'cursor': 4, 'operation': operation.toJson()},
            {'cursor': 3, 'operation': operation.toJson()},
          ],
        }),
        200,
      );
    });
    await expectLater(
      HttpOperationGateway(client).readAfter(2),
      throwsFormatException,
    );
  });

  test('a valid feed preserves envelopes and the next cursor', () async {
    final operation = _operation();
    final client = clientFor((request) async {
      expect(request.url.path, '/v2/operations');
      expect(request.url.queryParameters['after'], '9');
      return http.Response(
        jsonEncode({
          'cursor': 11,
          'hasMore': false,
          'operations': [
            {'cursor': 11, 'operation': operation.toJson()},
          ],
        }),
        200,
      );
    });
    final page = await HttpOperationGateway(client).readAfter(9);
    expect(page.cursor, 11);
    expect(page.operations.single.operation.operationId,
        operation.operationId);
  });
}
