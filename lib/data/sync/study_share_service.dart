import '../../core/storage/app_save_coordinator.dart';
import '../../features/editor/state/page_background.dart';
import '../../features/notebook/data/notebook_repository.dart';
import 'account_session_controller.dart';
import 'api_client.dart';
import 'editor_v2_account_runtime.dart';

class ActiveStudyShare {
  const ActiveStudyShare({
    required this.id,
    required this.documentUid,
    required this.title,
    required this.expiresAt,
  });

  final String id;
  final String documentUid;
  final String title;
  final DateTime expiresAt;
  String get protocol => 'v2';

  ActiveStudyShare copyWith({DateTime? expiresAt}) => ActiveStudyShare(
    id: id,
    documentUid: documentUid,
    title: title,
    expiresAt: expiresAt ?? this.expiresAt,
  );

  String get link => Uri.base
      .replace(path: '/share/$id', query: null, fragment: null)
      .toString();
}

/// Sharing does not transfer ownership of the original notebook.
class StudyShareService {
  StudyShareService({
    required this.session,
    required this.v2Runtime,
    required this.repository,
  });

  final AccountSessionController session;
  final EditorV2AccountRuntime v2Runtime;
  final NotebookRepository repository;

  Future<void> _refreshIfNeeded() async {
    if (!session.isSignedIn) {
      throw StateError('Sign in before sharing a document.');
    }
    final expires = session.accessExpiresAt;
    if (expires == null ||
        expires.isBefore(
          DateTime.now().toUtc().add(const Duration(minutes: 1)),
        )) {
      await session.refresh();
    }
  }

  /// Refuse closure when the last changes have not reached the owner's account.
  Future<void> ensureSavedOnAccount(String uid) async {
    await _refreshIfNeeded();
    final runtime = v2Runtime;
    if (!runtime.engine.isStarted) {
      throw StateError('The v2 account is not ready to share.');
    }
    await AppSaveCoordinator.instance.flushPending();
    await repository.waitForPendingSaves();
    if (await repository.getNotebook(uid) == null) {
      throw StateError('The source document is no longer available.');
    }
    await runtime.engine.syncNow();
    final pending = await runtime.store.pending(
      documentId: uid,
      limit: 1,
      includeDeferred: true,
    );
    if (runtime.engine.lastError != null || pending.isNotEmpty) {
      throw StateError(
        'Commit pending v2 operations before creating a share link.',
      );
    }
  }

  Future<ActiveStudyShare> create({
    required String documentUid,
    required String title,
    required String password,
  }) async {
    await ensureSavedOnAccount(documentUid);
    final response = await session.apiClient.postJson('/v2/study-shares', {
      'documentUid': documentUid,
      'title': title,
      'password': password,
    });
    final body = response.decodeJson();
    if (body is! Map<String, dynamic> ||
        body['id'] is! String ||
        body['expiresAt'] is! String) {
      throw const FormatException('Invalid session response.');
    }
    return ActiveStudyShare(
      id: body['id'] as String,
      documentUid: documentUid,
      title: title,
      expiresAt: DateTime.parse(body['expiresAt'] as String),
    );
  }

  Future<List<ActiveStudyShare>> activeShares() async {
    await _refreshIfNeeded();
    final response = await session.apiClient.get('/v2/study-shares/active');
    final json = response.decodeJson();
    if (json is! Map<String, dynamic> || json['sessions'] is! List) {
      throw const FormatException('Invalid active shares response.');
    }
    return (json['sessions'] as List).map((item) {
      if (item is! Map<String, dynamic> || item['protocol'] != 'v2') {
        throw const FormatException('Invalid session record.');
      }
      return ActiveStudyShare(
        id: item['id'] as String,
        documentUid: item['documentUid'] as String,
        title: item['title'] as String,
        expiresAt: DateTime.parse(item['expiresAt'] as String),
      );
    }).toList();
  }

  /// Appearance is independent from document content revisions.
  Future<void> updateAppearance(
    ActiveStudyShare share, {
    required bool darkMode,
    required PageBackgroundSettings background,
  }) async {
    await _refreshIfNeeded();
    await session.apiClient.putJson('/v2/study-shares/${share.id}/appearance', {
      'darkMode': darkMode,
      'backgroundStyle': background.style.index,
      'backgroundSpacing': background.spacing,
    });
  }

  Future<ActiveStudyShare> extend(ActiveStudyShare share) async {
    await _refreshIfNeeded();
    final response = await session.apiClient.postJson(
      '/v2/study-shares/${share.id}/extend',
      <String, dynamic>{},
    );
    final body = response.decodeJson();
    if (body is! Map<String, dynamic> || body['expiresAt'] is! String) {
      throw const FormatException('Invalid extension response.');
    }
    return share.copyWith(
      expiresAt: DateTime.parse(body['expiresAt'] as String),
    );
  }

  Future<void> end(ActiveStudyShare share) async {
    await _refreshIfNeeded();
    // Revoke access first; slow local saves must never extend guest privileges.
    await session.apiClient.request(
      'DELETE',
      '/v2/study-shares/${share.id}',
      body: const <int>[],
    );
    try {
      await AppSaveCoordinator.instance.flushPending();
      await repository.waitForPendingSaves();
      await v2Runtime.engine.syncNow();
    } catch (_) {
      // Owner data remains in the local repository for subsequent sync.
    }
  }
}

class StudyShareGuestClient {
  StudyShareGuestClient({ApiClient? apiClient})
    : _api = apiClient ?? ApiClient();

  final ApiClient _api;

  Future<Map<String, dynamic>> join(String id, String password) async {
    final response = await _api.postJson('/v2/study-shares/$id/join', {
      'password': password,
    }, authenticated: false);
    final body = response.decodeJson();
    if (body is! Map<String, dynamic> ||
        body['ticket'] is! String ||
        body['title'] is! String ||
        body['protocol'] != 'v2' ||
        body['documentUid'] is! String ||
        (body['documentUid'] as String).isEmpty ||
        body['revision'] is! int) {
      throw const FormatException('Invalid session ticket response.');
    }
    return body;
  }

  Future<Map<String, dynamic>?> appearance(String id, String ticket) async {
    final response = await _api.request(
      'GET',
      '/v2/study-shares/$id/appearance',
      authenticated: false,
      headers: {'Authorization': 'Bearer $ticket'},
    );
    final body = response.decodeJson();
    if (body is! Map<String, dynamic> ||
        (body['appearance'] != null &&
            body['appearance'] is! Map<String, dynamic>)) {
      throw const FormatException('Invalid shared appearance.');
    }
    return body['appearance'] as Map<String, dynamic>?;
  }

  Uri eventsUri(String id) {
    final uri = _api.resolve('/v2/study-shares/$id/events');
    return uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws');
  }

  void close() => _api.close();
}
