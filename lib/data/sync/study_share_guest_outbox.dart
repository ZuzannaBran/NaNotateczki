import 'dart:convert';

import '../../core/storage/storage_namespace_manager.dart';
import '../../core/storage/text_storage.dart';

/// A guest edit that has not yet been acknowledged by the server.
/// The stored record deliberately excludes passwords and bearer tickets.
class PendingStudyShareEdit {
  const PendingStudyShareEdit({
    required this.baseRevision,
    required this.baseNotebook,
    required this.notebook,
    this.localMergeBase,
  });

  final int baseRevision;
  final Map<String, dynamic> baseNotebook;
  final Map<String, dynamic> notebook;

  /// Visible state at the last accepted upload, needed to rebase new edits.
  final Map<String, dynamic>? localMergeBase;
}

/// Keeps one pending snapshot per invitation in the browser's local storage.
/// Do not clear it until the server accepts the submitted changes.
class StudyShareGuestOutbox {
  StudyShareGuestOutbox(String shareId)
    : _key = StorageNamespace.share(shareId, 'legacy-web-guest')
          .fileKey('outbox.json');

  final String _key;

  Future<PendingStudyShareEdit?> read() async {
    final value = await readStoredText(_key);
    if (value == null || value.isEmpty) {
      return null;
    }
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != 1 ||
        decoded['baseRevision'] is! int ||
        decoded['baseRevision'] < 1 ||
        decoded['baseNotebook'] is! Map<String, dynamic> ||
        decoded['notebook'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid guest recovery record.');
    }
    final base = decoded['baseNotebook'] as Map<String, dynamic>;
    final notebook = decoded['notebook'] as Map<String, dynamic>;
    if (base['uid'] is! String ||
        base['uid'] != notebook['uid'] ||
        base['pages'] is! List ||
        notebook['pages'] is! List) {
      throw const FormatException('Guest recovery document mismatch.');
    }
    final localMergeBase = decoded['localMergeBase'];
    if (localMergeBase != null &&
        (localMergeBase is! Map<String, dynamic> ||
            localMergeBase['uid'] != notebook['uid'] ||
            localMergeBase['pages'] is! List)) {
      throw const FormatException('Invalid guest recovery merge base.');
    }
    return PendingStudyShareEdit(
      baseRevision: decoded['baseRevision'] as int,
      baseNotebook: base,
      notebook: notebook,
      localMergeBase: localMergeBase as Map<String, dynamic>?,
    );
  }

  Future<void> write(PendingStudyShareEdit pending) {
    return writeStoredText(
      _key,
      jsonEncode({
        'version': 1,
        'baseRevision': pending.baseRevision,
        'baseNotebook': pending.baseNotebook,
        'notebook': pending.notebook,
        if (pending.localMergeBase != null)
          'localMergeBase': pending.localMergeBase,
      }),
    );
  }

  Future<void> clear() => writeStoredText(_key, '');
}
