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
  ApiClient clientFor(Future<http.Response> Function(http.Request) handler) {
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
      expect(
        (body['operations'] as List).single['operationId'],
        operation.operationId,
      );
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

  test('invalid create payload cannot reach the HTTP transport', () async {
    var requested = false;
    final client = clientFor((_) async {
      requested = true;
      return http.Response('{}', 200);
    });
    final original = _operation();
    final invalid = OperationEnvelope(
      operationId: original.operationId,
      actorId: original.actorId,
      actorSeq: original.actorSeq,
      documentId: original.documentId,
      kind: original.kind,
      payload: const {
        'properties': {'title': 'Invalid create'},
      },
      dependencies: original.dependencies,
      logicalClock: original.logicalClock,
    );
    await expectLater(
      HttpOperationGateway(client).send([invalid]),
      throwsFormatException,
    );
    expect(requested, isFalse);
  });

  test('Share REST uses a scoped guest ticket, not the account JWT',
      () async {
    const shareId = '11111111-1111-4111-8111-111111111111';
    const ticket = '01234567890123456789012345678901234567890123456789';
    final operation = _operation();
    final client = clientFor((request) async {
      expect(request.headers['X-Share-Id'], shareId);
      expect(request.headers['Authorization'], 'Bearer $ticket');
      if (request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'cursor': 2,
            'acknowledgements': [
              {
                'operationId': operation.operationId,
                'cursor': 2,
                'status': 'applied',
              },
            ],
          }),
          200,
        );
      }
      expect(request.method, 'GET');
      expect(request.url.queryParameters['after'], '2');
      return http.Response(
        jsonEncode({'cursor': 2, 'hasMore': false, 'operations': []}),
        200,
      );
    });
    final gateway = HttpOperationGateway(
      client, shareId: shareId, guestTicket: ticket,
    );
    expect((await gateway.send([operation])).single.cursor, 2);
    expect((await gateway.readAfter(2)).cursor, 2);
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

  test('a malformed or non-monotonic feed cannot advance the cursor', () async {
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
    expect(page.operations.single.operation.operationId, operation.operationId);
  });
  test('guest Share REST works without any owner access token', () async {
    const shareId = '11111111-1111-4111-8111-111111111111';
    const ticket = '01234567890123456789012345678901234567890123456789';
    final operation = _operation();
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer $ticket');
        expect(request.headers['X-Share-Id'], shareId);
        return http.Response(
          jsonEncode({
            'cursor': 1,
            'acknowledgements': [
              {
                'operationId': operation.operationId,
                'cursor': 1,
                'status': 'applied',
              },
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(client.close);
    final guest = HttpOperationGateway(
      client, shareId: shareId, guestTicket: ticket,
    );
    expect((await guest.send([operation])).single.cursor, 1);
  });

  test('invalid or missing Share credentials are rejected before HTTP', () {
    final client = clientFor((_) async => http.Response('{}', 200));
    const shareId = '11111111-1111-4111-8111-111111111111';
    const ticket = '01234567890123456789012345678901234567890123456789';
    expect(
      () => HttpOperationGateway(client, shareId: shareId),
      throwsArgumentError,
    );
    expect(
      () => HttpOperationGateway(client, guestTicket: ticket),
      throwsArgumentError,
    );
    expect(
      () => HttpOperationGateway(
        client, shareId: shareId, guestTicket: 'bad\nheader',
      ),
      throwsArgumentError,
    );
  });
}
