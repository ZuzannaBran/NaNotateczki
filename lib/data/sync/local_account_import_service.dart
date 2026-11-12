import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/storage/storage_namespace_manager.dart';
import '../../core/storage/text_storage.dart';
import '../../features/notebook/data/notebook_repository.dart';
import '../../features/planner/state/study_planner_controller.dart';
import '../drift/notes_database.dart';
import 'local_import_plan.dart';

/// Copies one explicitly authorized Local library into the active account.
///
/// Source SQLite and files are only read. A deterministic UID map and durable
/// destination checkpoint make interruption and retry additive, not destructive.
class LocalAccountImportService {
  LocalAccountImportService({
    required this.accountId,
    required this.repository,
    required this.planner,
    required this.isCurrentAccount,
    required this.onLibraryChanged,
  });

  static const checkpointKey = 'local_account_import_v1.json';

  final String accountId;
  final NotebookRepository repository;
  final StudyPlannerController planner;
  final bool Function() isCurrentAccount;
  final Future<void> Function() onLibraryChanged;

  void _requireCurrent() {
    if (!isCurrentAccount()) {
      throw StateError('The account changed during Local import.');
    }
  }

  Future<int> run() async {
    _requireCurrent();
    final namespace = StorageNamespace.local();
    final result = await NotesDatabase.open(
      databaseName: kIsWeb
          ? namespace.webDatabaseName
          : namespace.nativeDatabaseName,
    );
    try {
      if (result.wasReset || result.freshFile) {
        throw StateError(
          'Local SQLite could not be verified as an existing source. '
          'No new account import was started.',
        );
      }
      return await runWithSource(
        sourceRepository: NotebookRepository(result.database),
        localLibraryText: await readStoredTextForNamespace(
          namespace,
          'library_folders.json',
        ),
        localPlannerText: await readStoredTextForNamespace(
          namespace,
          StudyPlannerController.storageKey,
        ),
      );
    } finally {
      await result.database.close();
    }
  }

  /// The same import path accepts in-memory repositories in regression tests.
  Future<int> runWithSource({
    required NotebookRepository sourceRepository,
    required String? localLibraryText,
    required String? localPlannerText,
  }) async {
    _requireCurrent();
    final previous = await readStoredText(checkpointKey);
    if (previous != null) {
      final decoded = jsonDecode(previous);
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 1 ||
          decoded['accountId'] != accountId) {
        throw const FormatException('Invalid Local import checkpoint.');
      }
      if (decoded['state'] == 'complete') {
        return 0;
      }
      if (decoded['state'] != 'pending') {
        throw const FormatException('Invalid Local import checkpoint state.');
      }
    }
    final local = await sourceRepository.fetchNotebooks();
    if (sourceRepository.lastFetchSkippedCorruptRows) {
      throw StateError('Unreadable Local documents cannot be imported.');
    }
    final account = await repository.fetchNotebooks();
    if (repository.lastFetchSkippedCorruptRows) {
      throw StateError('Unreadable account documents block Local import.');
    }
    final plan = LocalImportPlan(
      accountId: accountId,
      local: local,
      account: account,
    );
    // v2 cannot yet represent the legacy Planner document kind. Reject the
    // entire batch before writing anything, rather than silently dropping it.
    if (repository.usesAccountOperations &&
        local.any((item) => item.kind.index > 1)) {
      throw UnsupportedError(
        'Planner documents must be migrated after v2 planner cutover.',
      );
    }
    final sourceLibrary = decodeLocalImportMetadata(localLibraryText);
    final sourcePlanner = decodeLocalImportMetadata(localPlannerText);
    if (repository.usesAccountOperations) {
      // Folder, task and planner account operations belong to package 5.
      // Do not mark an import complete when its metadata could never sync.
      final sourceFolders = sourceLibrary['folders'];
      final allFolderPaths = <String>{};
      for (final document in local) {
        var folder = document.folder;
        while (folder.isNotEmpty) {
          allFolderPaths.add(folder);
          final separator = folder.lastIndexOf('/');
          if (separator < 0) {
            break;
          }
          folder = folder.substring(0, separator);
        }
      }
      if ((sourcePlanner['sessions'] is List &&
              (sourcePlanner['sessions'] as List).isNotEmpty) ||
          (sourceLibrary['plannerTasks'] is Map &&
              (sourceLibrary['plannerTasks'] as Map).isNotEmpty) ||
          (sourceLibrary['covers'] is Map &&
              (sourceLibrary['covers'] as Map).isNotEmpty) ||
          (sourceFolders is List &&
              sourceFolders.whereType<String>().any(
                (folder) => !allFolderPaths.contains(folder),
              ))) {
        throw UnsupportedError(
          'Planner, tasks and standalone folder metadata must be '
          'migrated after package 5 enables their v2 synchronization.',
        );
      }
    }
    final destinationLibrary = decodeLocalImportMetadata(
      await readStoredText('library_folders.json'),
    );
    final newStudyEntries = plan.newPlannerEntries(
      local: sourcePlanner,
      accountIds: planner.sessions.map((session) => session.id),
      accountTombstones: planner.syncRecords.entries
          .where((entry) => entry.value['deleted'] == true)
          .map((entry) => entry.key),
    );
    // Validate the planner before writing any document.
    var activeSessions = planner.active == null ? 0 : 1;
    for (final item in newStudyEntries) {
      final entry = StudySession.fromJson(item);
      if (entry.status == StudyStatus.running ||
          entry.status == StudyStatus.paused) {
        activeSessions++;
      }
    }
    if (activeSessions > 1) {
      throw StateError('Local import contains competing active sessions.');
    }
    final remappedLibrary = plan.mergeLibrary(
      local: sourceLibrary,
      account: destinationLibrary,
    );
    final uidMap = {
      for (final entry in plan.documents) entry.source.uid: entry.targetId,
    };
    _requireCurrent();
    await writeStoredText(
      checkpointKey,
      jsonEncode({
        'version': 1,
        'accountId': accountId,
        'state': 'pending',
        'documents': uidMap,
        'pages': {
          for (final entry in plan.documents)
            for (final page in entry.source.pages)
              '${entry.source.uid}/${page.id}': importedLocalUid(
                accountId,
                'page:${entry.source.uid}',
                page.id,
              ),
        },
        'objects': {
          for (final entry in plan.documents)
            for (final page in entry.source.pages) ...{
              for (final block in page.textBlocks)
                '${entry.source.uid}/text/${block.id}': importedLocalUid(
                  accountId,
                  'text:${entry.source.uid}',
                  block.id,
                ),
              for (final block in page.imageBlocks)
                '${entry.source.uid}/image/${block.id}': importedLocalUid(
                  accountId,
                  'image:${entry.source.uid}',
                  block.id,
                ),
              for (final stroke in page.inkStrokes)
                '${entry.source.uid}/ink/${stroke.id}': importedLocalUid(
                  accountId,
                  'ink:${entry.source.uid}',
                  stroke.id,
                ),
            },
        },
      }),
    );
    var inserted = 0;
    for (final entry in plan.documents) {
      _requireCurrent();
      if (await repository.getNotebook(entry.targetId) != null) {
        continue;
      }
      final notebook = await plan.materialize(entry);
      _requireCurrent();
      if (await repository.importLocalNotebook(notebook)) {
        inserted++;
      }
    }
    _requireCurrent();
    if (!repository.usesAccountOperations &&
        jsonEncode(destinationLibrary) != jsonEncode(remappedLibrary)) {
      await writeStoredText(
        'library_folders.json',
        jsonEncode(remappedLibrary),
      );
    }
    await onLibraryChanged();
    _requireCurrent();
    await planner.importLocalEntries(newStudyEntries);
    _requireCurrent();
    for (final entry in plan.documents) {
      if (await repository.getNotebook(entry.targetId) == null) {
        throw StateError('Imported document not found after commit.');
      }
    }
    _requireCurrent();
    await writeStoredText(
      checkpointKey,
      jsonEncode({
        'version': 1,
        'accountId': accountId,
        'state': 'complete',
        'documents': uidMap,
      }),
    );
    return inserted;
  }
}
