import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/storage/text_storage.dart';

/// Prevents silent loss if an older device still has unsent snapshot edits.
Future<void> requireEmptyRetiredOutbox(String accountId) async {
  final suffix = sha256
      .convert(utf8.encode(accountId))
      .toString()
      .substring(0, 16);
  final raw = await readStoredText('server_sync_state_$suffix.json');
  if (raw == null) {
    return;
  }
  final state = jsonDecode(raw);
  if (state is! Map<String, dynamic> || state['pending'] is! List) {
    throw const FormatException(
      'Invalid retired outbox. Recovery is required.',
    );
  }
  if ((state['pending'] as List).isNotEmpty) {
    throw StateError('Unsent retired edits require recovery before v2 starts.');
  }
}
