import 'operation_protocol.dart';
import 'api_client.dart';

/// A server-assigned position for an idempotently committed operation.
class OperationReceipt {
  const OperationReceipt(this.operationId, this.cursor);

  final String operationId;
  final int cursor;
}

class SequencedOperation {
  const SequencedOperation(this.cursor, this.operation);

  final int cursor;
  final OperationEnvelope operation;
}

class OperationFeedPage {
  const OperationFeedPage({
    required this.cursor,
    required this.hasMore,
    required this.operations,
  });

  final int cursor;
  final bool hasMore;
  final List<SequencedOperation> operations;
}

/// Transport boundary; tests can emulate lost responses and reconnects.
abstract class OperationGateway {
  Future<List<OperationReceipt>> send(List<OperationEnvelope> operations);
  Future<OperationFeedPage> readAfter(int cursor);
}

/// REST v2 is authoritative. WebSocket only signals that REST should run.
class HttpOperationGateway implements OperationGateway {
  const HttpOperationGateway(this.apiClient);

  final ApiClient apiClient;

  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async {
    if (operations.isEmpty || operations.length > 50) {
      throw ArgumentError('An operation batch must contain 1-50 entries.');
    }
    final response = await apiClient.postJson('/v2/operations/batch', {
      'operations': [for (final op in operations) op.toJson()],
    });
    final body = _object(response.decodeJson());
    final entries = body['acknowledgements'];
    if (entries is! List || entries.length != operations.length) {
      throw const FormatException('Incomplete operation ACK batch.');
    }
    final expected = operations.map((op) => op.operationId).toSet();
    final seen = <String>{};
    final result = <OperationReceipt>[];
    for (final raw in entries) {
      final ack = _object(raw);
      final id = ack['operationId'];
      final cursor = ack['cursor'];
      if (id is! String ||
          !expected.contains(id) ||
          !seen.add(id) ||
          cursor is! int ||
          cursor <= 0 ||
          (ack['status'] != 'applied' &&
              ack['status'] != 'duplicate')) {
        throw const FormatException('Invalid operation acknowledgement.');
      }
      result.add(OperationReceipt(id, cursor));
    }
    return result;
  }

  @override
  Future<OperationFeedPage> readAfter(int cursor) async {
    if (cursor < 0) {
      throw ArgumentError.value(cursor, 'cursor');
    }
    final response = await apiClient.get(
      '/v2/operations',
      query: {'after': '$cursor'},
    );
    final body = _object(response.decodeJson());
    final pageCursor = body['cursor'];
    final hasMore = body['hasMore'];
    final rows = body['operations'];
    if (pageCursor is! int ||
        pageCursor < cursor ||
        hasMore is! bool ||
        rows is! List) {
      throw const FormatException('Invalid operations feed.');
    }
    var lastCursor = cursor;
    final operations = <SequencedOperation>[];
    for (final raw in rows) {
      final row = _object(raw);
      final sequence = row['cursor'];
      if (sequence is! int || sequence <= lastCursor) {
        throw const FormatException('Non-monotonic feed cursor.');
      }
      final envelope = OperationEnvelope.fromJson(
        _object(row['operation']),
      );
      operations.add(SequencedOperation(sequence, envelope));
      lastCursor = sequence;
    }
    if (lastCursor != pageCursor || (hasMore && operations.isEmpty)) {
      throw const FormatException('Incomplete operations feed page.');
    }
    return OperationFeedPage(
      cursor: pageCursor,
      hasMore: hasMore,
      operations: operations,
    );
  }

  static Map<String, dynamic> _object(Object? value) {
    if (value is! Map) {
      throw const FormatException('Expected a JSON object.');
    }
    return Map<String, dynamic>.from(value);
  }
}
