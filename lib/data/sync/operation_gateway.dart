import 'dart:convert';

import 'api_client.dart';
import 'operation_protocol.dart';

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
  HttpOperationGateway(
    this.apiClient, {
    this.shareId,
    this.guestTicket,
  }) {
    if ((shareId == null) != (guestTicket == null)) {
      throw ArgumentError('Share operations require a scoped guest ticket.');
    }
    if (guestTicket != null &&
        (guestTicket!.length < 40 ||
            guestTicket!.length > 256 ||
            RegExp(r'[\x00-\x20\x7f]').hasMatch(guestTicket!))) {
      throw ArgumentError('Invalid guest ticket.');
    }
  }

  final ApiClient apiClient;
  final String? shareId;

  /// Ephemeral, never written to SQLite, operation payloads or checkpoints.
  final String? guestTicket;

  Map<String, String>? get _shareHeaders => shareId == null
      ? null
      : {
          'X-Share-Id': shareId!,
          'Authorization': 'Bearer $guestTicket',
        };

  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async {
    for (final operation in operations) {
      operation.validateForV2Projection();
    }
    if (operations.isEmpty || operations.length > 50) {
      throw ArgumentError('An operation batch must contain 1-50 entries.');
    }
    final request = {
      'operations': [for (final op in operations) op.toJson()],
    };
    if (utf8.encode(jsonEncode(request)).length > 1024 * 1024) {
      throw ArgumentError('Operation batch exceeds server request limit.');
    }
    final response = await apiClient.postJson(
      '/v2/operations/batch',
      request,
      headers: _shareHeaders,
      authenticated: guestTicket == null,
    );
    final body = _object(response.decodeJson());
    final entries = body['acknowledgements'];
    final batchCursor = body['cursor'];
    if (batchCursor is! int ||
        batchCursor <= 0 ||
        entries is! List ||
        entries.length != operations.length) {
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
          (ack['status'] != 'applied' && ack['status'] != 'duplicate')) {
        throw const FormatException('Invalid operation acknowledgement.');
      }
      result.add(OperationReceipt(id, cursor));
    }
    if (result
            .map((receipt) => receipt.cursor)
            .reduce((current, next) => current > next ? current : next) !=
        batchCursor) {
      throw const FormatException('Inconsistent operation batch cursor.');
    }
    return result;
  }

  @override
  Future<OperationFeedPage> readAfter(int cursor) async {
    if (cursor < 0) {
      throw ArgumentError.value(cursor, 'cursor');
    }
    final response = await apiClient.request(
      'GET',
      '/v2/operations',
      query: {'after': '$cursor'},
      headers: _shareHeaders,
      authenticated: guestTicket == null,
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
      final envelope = OperationEnvelope.fromJson(_object(row['operation']));
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
