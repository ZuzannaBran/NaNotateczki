import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../core/storage/storage_namespace_manager.dart';
import '../../core/storage/text_storage.dart';

import '../../features/planner/state/study_planner_controller.dart';
import 'account_session_controller.dart';
import 'api_client.dart';
import 'planner_revision_ledger.dart';

/// Reconciles per-entry account calendar state including offline deletions.
class PlannerSyncService {
  PlannerSyncService({
    required this.apiClient,
    required this.session,
    required this.planner,
  });

  final ApiClient apiClient;
  final AccountSessionController session;
  final StudyPlannerController planner;

  Future<void>? _running;
  bool _resyncRequested = false;
  bool _stopped = false;
  String? lastError;

  void stop() {
    _stopped = true;
    lastError = null;
  }

  /// Join an in-flight planner request before changing account credentials.
  Future<void> stopAndDrain() async {
    stop();
    try {
      await _running;
    } catch (_) {
      // A rejected, already cancelled request must not unblock old writes.
    }
  }

  Future<void> syncNow() {
    final previous = _running;
    if (previous != null) {
      _resyncRequested = true;
      return previous;
    }
    _stopped = false;
    final operation = _reconcile();
    _running = operation;
    return operation.whenComplete(() {
      if (identical(_running, operation)) {
        _running = null;
      }
    });
  }

  Future<void> _reconcile() async {
    do {
      _resyncRequested = false;
      try {
        await _syncPass();
        lastError = null;
      } on ApiException catch (error) {
        if (error.statusCode != 401 || !session.isSignedIn) {
          lastError = error.toString();
          rethrow;
        }
        await session.refresh();
        await _syncPass();
        lastError = null;
      } catch (error) {
        lastError = error.toString();
        rethrow;
      }
    } while (_resyncRequested && !_stopped && session.isSignedIn);
  }

  Future<void> _syncPass() async {
    final user = session.userId;
    if (user == null || !session.isSignedIn || !planner.isLoaded || _stopped) {
      return;
    }
    await planner.flush();
    final namespace = StorageNamespace.account(user);
    final ledgerKey = namespace.fileKey('planner_revisions.json');
    final text = await readStoredText(ledgerKey);
    final ledger = PlannerRevisionLedger.fromJson(
      text == null ? null : jsonDecode(text),
    );
    final remote = <String, Map<String, dynamic>>{};
    String? after;
    do {
      final response = await apiClient.get(
        '/v2/planner/entries',
        query: after == null ? null : {'after': after},
      );
      if (_stopped || session.userId != user) {
        return;
      }
      final decoded = response.decodeJson();
      if (decoded is! Map<String, dynamic> || decoded['entries'] is! List) {
        throw const FormatException('Invalid revision planner response');
      }
      for (final item in decoded['entries'] as List) {
        if (item is! Map<String, dynamic> || item['id'] is! String) {
          throw const FormatException('Invalid revision planner entry');
        }
        remote[item['id'] as String] = item;
      }
      final next = decoded['next'];
      if (next != null && (next is! String || next == after)) {
        throw const FormatException('Invalid revision planner cursor');
      }
      after = next as String?;
    } while (after != null);

    final local = planner.syncRecords;
    final ids = {...local.keys, ...remote.keys}.toList()..sort();
    for (final id in ids) {
      if (_stopped || session.userId != user || !session.isSignedIn) {
        return;
      }
      final source = local[id];
      final server = remote[id];
      final decision = ledger.decide(id: id, local: source, remote: server);
      switch (decision) {
        case PlannerSyncDecision.unchanged:
          if (server != null) {
            ledger.acknowledge(server);
            await writeStoredText(ledgerKey, ledger.encode());
          }
          break;
        case PlannerSyncDecision.adoptRemote:
          if (server == null) {
            throw StateError('Missing authoritative planner record: $id');
          }
          if (server['deleted'] == true &&
              source != null &&
              source['deleted'] != true &&
              (ledger[id] == null ||
                  ledger[id]!.signature !=
                      PlannerRevisionLedger.signature(source))) {
            // Preserve an unsent local edit before applying the tombstone.
            await _archivePlannerDeletion(namespace, id, source);
          }
          if (_stopped || session.userId != user) {
            return;
          }
          planner.applyRemoteRecords([server], revisionAuthoritative: true);
          await planner.flush();
          ledger.acknowledge(server);
          await writeStoredText(ledgerKey, ledger.encode());
          break;
        case PlannerSyncDecision.sendLocal:
          if (source == null) {
            throw StateError('Missing local planner record: $id');
          }
          final expected = server?['revision'] as int? ?? 0;
          final signature = PlannerRevisionLedger.signature(source);
          final operationId = const Uuid().v5(
            Namespace.url.value,
            'planner:$user:$id:$expected:$signature',
          );
          final answer = await apiClient
              .putJson('/v2/planner/entries/${Uri.encodeComponent(id)}', {
                'operationId': operationId,
                'expectedRevision': expected,
                'deleted': source['deleted'],
                'entry': source['entry'],
              });
          if (_stopped || session.userId != user) {
            return;
          }
          final accepted = answer.decodeJson();
          if (accepted is! Map<String, dynamic> ||
              accepted['id'] != id ||
              accepted['revision'] is! int) {
            throw const FormatException('Invalid planner CAS acknowledgment');
          }
          ledger.acknowledge(accepted);
          await writeStoredText(ledgerKey, ledger.encode());
          final latest = planner.syncRecords[id];
          if (latest != null &&
              PlannerRevisionLedger.signature(latest) == signature) {
            planner.applyRemoteRecords([accepted], revisionAuthoritative: true);
            await planner.flush();
          }
          break;
        case PlannerSyncDecision.conflict:
          throw StateError(
            'Concurrent planner edit for $id. Local changes were preserved.',
          );
      }
    }
  }

  static Future<void> _archivePlannerDeletion(
    StorageNamespace namespace,
    String id,
    Map<String, dynamic> source,
  ) async {
    final key = namespace.fileKey('planner_conflicts.json');
    final prior = await readStoredText(key);
    final records = prior == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(prior) as Map);
    final signature = PlannerRevisionLedger.signature(source);
    records['$id:$signature'] = source;
    await writeStoredText(key, jsonEncode(records));
  }
}
