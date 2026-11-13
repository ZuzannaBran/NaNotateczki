import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/storage/text_storage.dart';
import '../../features/notebook/data/notebook_repository.dart';
import '../../features/notebook/domain/notebook.dart';

/// Read-only import support for the retired snapshot protocol.
abstract final class LegacySyncArchive {
  static Map<String, dynamic> encodeCutoverNotebook(Notebook notebook) =>
      _normalizeSyncNotebook(NotebookRepository.encodeNotebook(notebook));

  static Map<String, dynamic> _normalizeSyncNotebook(
    Map<String, dynamic> encoded,
  ) {
    // Keep the authenticated base snapshot intact for server verification.
    encoded = Map<String, dynamic>.of(encoded);
    // SQLite returns local DateTimes; wire comparisons must use one zone.
    for (final key in ['createdAt', 'updatedAt']) {
      final value = encoded[key];
      if (value is String) {
        encoded[key] = DateTime.parse(value).toUtc().toIso8601String();
      }
    }
    final pages = encoded['pages'];
    if (pages is! List<dynamic>) {
      return encoded;
    }
    final normalizedPages = <dynamic>[];
    encoded['pages'] = normalizedPages;
    for (final page in pages) {
      normalizedPages.add(page);
      if (page is! Map<String, dynamic>) {
        continue;
      }
      final images = page['imageBlocks'];
      if (images is! List<dynamic>) {
        continue;
      }
      final normalizedImages = <dynamic>[];
      normalizedPages[normalizedPages.length - 1] = {
        ...page,
        'imageBlocks': normalizedImages,
      };
      for (final image in images) {
        if (image is Map<String, dynamic> &&
            image['bytes'] is String &&
            (image['bytes'] as String).isNotEmpty) {
          normalizedImages.add({...image, 'path': ''});
        } else {
          normalizedImages.add(image);
        }
      }
    }
    return encoded;
  }

  static String _stateKey(String id) {
    final suffix = sha256.convert(utf8.encode(id)).toString().substring(0, 16);
    return 'server_sync_state_$suffix.json';
  }

  /// A legacy delete may exist only in the v1 outbox, without a SQLite row.
  /// Do not switch writers while a device still holds unsent legacy intent.
  static Future<void> requireEmptyLegacyOutbox(String userId) async {
    if ((await readCutoverState(userId)).pending.isNotEmpty) {
      throw StateError('V2 activation blocked by unsent legacy edits.');
    }
  }

  static Future<({int cursor, Map<String, int> revisions, Set<String> pending})>
  readCutoverState(String userId) async {
    final raw = await readStoredText(_stateKey(userId));
    if (raw == null) {
      return (
        cursor: 0,
        revisions: const <String, int>{},
        pending: const <String>{},
      );
    }
    final state = jsonDecode(raw);
    if (state is! Map<String, dynamic> || state['version'] != 1) {
      throw const FormatException('Invalid saved legacy sync state.');
    }
    final pending = state['pending'];
    if (pending is! List ||
        pending.any((uid) => uid is! String || uid.isEmpty)) {
      throw const FormatException('Invalid saved legacy outbox.');
    }
    final cursor = state['cursor'] ?? 0;
    final revisions = state['revisions'] ?? const <String, dynamic>{};
    if (cursor is! int ||
        cursor < 0 ||
        revisions is! Map<String, dynamic> ||
        revisions.values.any((value) => value is! int || value < 1)) {
      throw const FormatException('Invalid saved legacy revision receipts.');
    }
    return (
      cursor: cursor,
      revisions: Map<String, int>.from(revisions),
      pending: pending.cast<String>().toSet(),
    );
  }
}
