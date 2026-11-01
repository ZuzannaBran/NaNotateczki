import 'dart:typed_data';

import '../../core/storage/app_save_coordinator.dart';
import '../../features/notebook/data/notebook_repository.dart';
import 'account_session_controller.dart';
import 'api_client.dart';
import 'live_web_sync_service.dart';

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

  ActiveStudyShare copyWith({DateTime? expiresAt}) => ActiveStudyShare(
    id: id,
    documentUid: documentUid,
    title: title,
    expiresAt: expiresAt ?? this.expiresAt,
  );

  String get link => Uri.base.replace(
    path: '/share/' + id,
    query: null,
    fragment: null,
  ).toString();
}

/// Sharing does not transfer ownership of the original notebook.
class StudyShareService {
  StudyShareService({
    required this.session,
    required this.liveSync,
    required this.repository,
  });

  final AccountSessionController session;
  final LiveWebSyncService liveSync;
  final NotebookRepository repository;

  Future<void> _refreshIfNeeded() async {
    if (!session.isSignedIn) {
      throw StateError('Sign in before sharing a document.');
    }
    final expires = session.accessExpiresAt;
    if (expires == null ||
        expires.isBefore(DateTime.now().toUtc().add(const Duration(minutes: 1)))) {
      await session.refresh();
    }
  }

  /// Refuse closure when the last changes have not reached the owner's account.
  Future<void> ensureSavedOnAccount(String uid) async {
    await _refreshIfNeeded();
    if (!liveSync.isStarted) {
      throw StateError(
        'Enable Web live synchronization in Account settings first.',
      );
    }
    await AppSaveCoordinator.instance.flushPending();
    await repository.waitForPendingSaves();
    if (await repository.getNotebook(uid) == null) {
      throw StateError('The source document is no longer available.');
    }
    await liveSync.syncNow();
    if (liveSync.lastError != null || liveSync.hasPendingChanges) {
      throw StateError(
        'The document is not saved on your account yet. Retry synchronization.',
      );
    }
  }

  Future<ActiveStudyShare> create({
    required String documentUid,
    required String title,
    required String password,
  }) async {
    await ensureSavedOnAccount(documentUid);
    final response = await session.apiClient.postJson('/v1/study-shares', {
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

  Future<void> publish(ActiveStudyShare share, Uint8List png) async {
    await _refreshIfNeeded();
    await session.apiClient.request(
      'PUT',
      '/v1/study-shares/' + share.id + '/frame',
      body: png,
      headers: {'Content-Type': 'image/png'},
    );
  }

  Future<ActiveStudyShare> extend(ActiveStudyShare share) async {
    await _refreshIfNeeded();
    final response = await session.apiClient.postJson(
      '/v1/study-shares/' + share.id + '/extend',
      <String, dynamic>{},
    );
    final body = response.decodeJson();
    if (body is! Map<String, dynamic> || body['expiresAt'] is! String) {
      throw const FormatException('Invalid extension response.');
    }
    return share.copyWith(expiresAt: DateTime.parse(body['expiresAt'] as String));
  }

  Future<void> end(ActiveStudyShare share) async {
    await ensureSavedOnAccount(share.documentUid);
    await session.apiClient.request(
      'DELETE',
      '/v1/study-shares/' + share.id,
      body: const <int>[],
    );
  }
}

class StudyShareGuestClient {
  StudyShareGuestClient() : _api = ApiClient();

  final ApiClient _api;

  Future<Map<String, dynamic>> join(String id, String password) async {
    final response = await _api.postJson(
      '/v1/study-shares/' + id + '/join',
      {'password': password},
      authenticated: false,
    );
    final body = response.decodeJson();
    if (body is! Map<String, dynamic> ||
        body['ticket'] is! String ||
        body['title'] is! String ||
        body['revision'] is! int) {
      throw const FormatException('Invalid session ticket response.');
    }
    return body;
  }

  Future<Uint8List> frame(String id, String ticket) async {
    final response = await _api.request(
      'GET',
      '/v1/study-shares/' + id + '/frame',
      authenticated: false,
      headers: {'Authorization': 'Bearer ' + ticket},
    );
    return response.bodyBytes;
  }

  Uri eventsUri(String id) {
    final uri = _api.resolve('/v1/study-shares/' + id + '/events');
    return uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws');
  }

  void close() => _api.close();
}
