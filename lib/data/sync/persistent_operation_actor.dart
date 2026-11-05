import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../core/storage/text_storage.dart';
import 'operation_store.dart';

/// Loads the actor in the active account namespace before starting v2 writers.
Future<String> loadPersistentOperationActor(OperationStore store) async {
  const key = 'account_v2_actor_id.json';
  final stored = await readStoredText(key);
  if (stored != null) {
    final decoded = jsonDecode(stored);
    final value = decoded is Map ? decoded['actorId'] : null;
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        value is! String ||
        !RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
          r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(value)) {
      throw const FormatException('Invalid persistent v2 actor identity.');
    }
    return value;
  }

  // Include blocked and delayed edits: losing their actor would fork the
  // causal history even though they are not ready to transmit right now.
  final pending = await store.database
      .customSelect('SELECT operation_id FROM operation_outbox LIMIT 1')
      .getSingleOrNull();
  if (pending != null) {
    throw StateError('Missing v2 actor identity with unacknowledged edits.');
  }
  final actorId = const Uuid().v4();
  await writeStoredText(key, jsonEncode({'version': 1, 'actorId': actorId}));
  return actorId;
}
