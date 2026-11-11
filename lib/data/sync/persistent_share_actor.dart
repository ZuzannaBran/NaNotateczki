import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../core/storage/storage_namespace_manager.dart';
import '../../core/storage/text_storage.dart';
import 'operation_store.dart';

/// A stable identity for a single guest browser and invitation.
///
/// Missing identity with a nonempty journal is a recovery failure, never
/// permission to silently abandon its causal history.
Future<String> loadPersistentShareActor(
  OperationStore store, {
  required String shareId,
  required String guestActorId,
}) async {
  final key = StorageNamespace.share(
    shareId,
    guestActorId,
  ).fileKey('actor.json');
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
      throw const FormatException('Invalid shared operation actor.');
    }
    return value;
  }

  final existing = await store.database
      .customSelect('SELECT operation_id FROM operations LIMIT 1')
      .getSingleOrNull();
  final pending = await store.database
      .customSelect('SELECT operation_id FROM operation_outbox LIMIT 1')
      .getSingleOrNull();
  if (existing != null || pending != null) {
    throw StateError(
      'Shared operation actor was lost. Preserve the database for recovery.',
    );
  }

  final actorId = const Uuid().v4();
  await writeStoredText(key, jsonEncode({'version': 1, 'actorId': actorId}));
  return actorId;
}
