import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/storage/active_storage_namespace.dart';
import '../../core/storage/storage_namespace_manager.dart';
import '../../core/storage/text_storage.dart';
import '../drift/notes_database.dart';
import 'operation_protocol.dart';
import 'operation_store.dart';
import 'sync_engine.dart';

/// Read model derived exclusively from the durable v2 library journal.
class LibraryV2Snapshot {
  const LibraryV2Snapshot(this.folderIdsByPath, this.value);

  final Map<String, String> folderIdsByPath;
  final Map<String, dynamic> value;
}

class _LibraryNode {
  final Map<String, dynamic> fields = {};
  final Map<String, List<Object>> versions = {};

  void merge(Map fieldsToMerge, OperationEnvelope operation) {
    final rank = <Object>[
      operation.logicalClock,
      operation.actorId,
      operation.actorSeq,
      operation.operationId,
    ];
    for (final entry in fieldsToMerge.entries) {
      if (entry.key is! String) {
        throw const FormatException('Invalid library field.');
      }
      final name = entry.key as String;
      final previous = versions[name];
      if (previous == null ||
          LibraryV2OperationReducer.compareRank(rank, previous) > 0) {
        versions[name] = rank;
        fields[name] = entry.value;
      }
    }
  }
}

/// Deterministic field-wise LWW with permanent tombstones and graph guards.
///
/// A read-model cache may be lost or interrupted: the operations table is
/// sufficient to reconstruct it without reviving any deleted UID.
class LibraryV2OperationReducer {
  const LibraryV2OperationReducer._();

  static int compareRank(List<Object> a, List<Object> b) {
    for (var index = 0; index < 4; index++) {
      final order = index.isEven
          ? (a[index] as int).compareTo(b[index] as int)
          : (a[index] as String).compareTo(b[index] as String);
      if (order != 0) {
        return order;
      }
    }
    return 0;
  }

  static LibraryV2Snapshot replay(
    Iterable<OperationEnvelope> history, {
    Iterable<int> migratedRecentCoverColors = const [],
  }) {
    final folders = <String, _LibraryNode>{};
    final tasks = <String, _LibraryNode>{};
    final deletedFolders = <String>{};
    final deletedTasks = <String>{};
    final newCoverColors = <(List<Object>, int)>[];

    for (final operation in history) {
      if (operation.documentId != OperationEnvelope.libraryDocumentId) {
        throw const FormatException('Non-library operation in journal.');
      }
      final kind = operation.kind;
      if (kind.target != OperationTarget.folder &&
          kind.target != OperationTarget.task) {
        throw const FormatException('Unsupported library operation.');
      }
      final id = operation.objectId!;
      final isFolder = kind.target == OperationTarget.folder;
      final nodes = isFolder ? folders : tasks;
      final deleted = isFolder ? deletedFolders : deletedTasks;
      final isCreate =
          kind == OperationKind.folderCreate ||
          kind == OperationKind.taskCreate;
      final isDelete =
          kind == OperationKind.folderDelete ||
          kind == OperationKind.taskDelete;
      if (isDelete) {
        if (isFolder &&
            folders.entries.any(
              (entry) =>
                  entry.key != id && entry.value.fields['parentId'] == id,
            )) {
          throw StateError('Folder still contains a child.');
        }
        nodes.remove(id);
        deleted.add(id);
        continue;
      }
      if (deleted.contains(id)) {
        if (isCreate) {
          throw StateError('Deleted library UID cannot be reused.');
        }
        continue;
      }
      if (isCreate && nodes.containsKey(id)) {
        throw StateError('Library UID already exists.');
      }
      if (!isCreate && !nodes.containsKey(id)) {
        throw StateError('Library target has not been created.');
      }
      final key = isCreate ? 'value' : 'properties';
      final raw = operation.payload[key];
      if (raw is! Map || operation.payload.length != 1) {
        throw const FormatException('Invalid library properties.');
      }
      final node = nodes.putIfAbsent(id, _LibraryNode.new);
      node.merge(raw, operation);
      if (isFolder) {
        _validateFolders(folders);
        final cover = raw['cover'];
        final color = cover is Map ? cover['iconColor'] : null;
        final rank = node.versions['cover'];
        if (!operation.actorId.startsWith('v1-cutover:') &&
            color is int &&
            rank?.last == operation.operationId) {
          newCoverColors.add((rank!, color));
        }
      } else if (node.fields['plannerUid'] is! String ||
          (node.fields['plannerUid'] as String).isEmpty) {
        throw const FormatException('Task has no planner identity.');
      }
    }

    final paths = _paths(folders);
    final covers = <String, dynamic>{};
    final colors = <int>[];
    for (final entry in paths.entries) {
      final cover = folders[entry.value]!.fields['cover'];
      if (cover is Map) {
        covers[entry.key] = Map<String, dynamic>.from(cover);
        final color = cover['iconColor'];
        if (color is int && !colors.contains(color)) {
          colors.add(color);
        }
      }
    }
    final tasksByPlanner = <String, List<Map<String, dynamic>>>{};
    for (final entry in tasks.entries) {
      final fields = entry.value.fields;
      final owner = fields['plannerUid'];
      if (owner is! String || owner.isEmpty) {
        throw const FormatException('Task owner is missing.');
      }
      tasksByPlanner.putIfAbsent(owner, () => []).add({
        'id': entry.key,
        'title': fields['title'] ?? '',
        'completed': fields['completed'] ?? false,
        'deadline': fields['deadline'],
        'deadlineHasTime': fields['deadlineHasTime'] ?? false,
        'sortIndex': fields['sortIndex'] ?? 0,
      });
    }
    for (final list in tasksByPlanner.values) {
      list.sort((a, b) {
        final ai = a['sortIndex'];
        final bi = b['sortIndex'];
        if (ai is! int || bi is! int) {
          throw const FormatException('Invalid task order.');
        }
        final order = ai.compareTo(bi);
        return order != 0
            ? order
            : (a['id'] as String).compareTo(b['id'] as String);
      });
      for (final task in list) {
        task.remove('sortIndex');
      }
    }
    newCoverColors.sort((a, b) => compareRank(b.$1, a.$1));
    final recentColors = <int>{
      ...newCoverColors.map((entry) => entry.$2),
      ...migratedRecentCoverColors,
      ...colors,
    }.take(12).toList();
    final folderNames = paths.keys.toList()..sort();
    return LibraryV2Snapshot(Map.unmodifiable(paths), {
      'folders': folderNames,
      'covers': covers,
      'plannerTasks': tasksByPlanner,
      'recentCoverColors': recentColors,
    });
  }

  static void _validateFolders(Map<String, _LibraryNode> folders) {
    _paths(folders);
  }

  static Map<String, String> _paths(Map<String, _LibraryNode> folders) {
    final resolved = <String, String>{};
    final visiting = <String>{};
    // The server accepts concurrent sibling creations with distinct UIDs.
    // Derive a stable display alias rather than blocking the whole feed.
    final names = <String, String>{};
    final childrenByParent = <String, List<String>>{};
    for (final entry in folders.entries) {
      final parent = entry.value.fields['parentId'];
      final group = parent is String ? parent : '';
      childrenByParent.putIfAbsent(group, () => []).add(entry.key);
    }
    for (final ids in childrenByParent.values) {
      ids.sort();
      final used = <String>{};
      for (final id in ids) {
        final raw = folders[id]!.fields['name'];
        if (raw is! String || raw.isEmpty) {
          throw const FormatException('Missing folder name.');
        }
        var label = raw;
        var attempt = 0;
        while (used.contains(label)) {
          attempt++;
          final suffix = id.substring(0, id.length < 8 ? id.length : 8);
          label = '$raw ($suffix${attempt > 1 ? '-$attempt' : ''})';
        }
        used.add(label);
        names[id] = label;
      }
    }
    String resolve(String id) {
      final node = folders[id];
      if (node == null) {
        throw StateError('Folder parent is missing.');
      }
      if (!visiting.add(id)) {
        throw StateError('Folder hierarchy contains a cycle.');
      }
      try {
        final name = node.fields['name'];
        final parent = node.fields['parentId'];
        if (name is! String ||
            name.trim() != name ||
            name.isEmpty ||
            name.contains('/') ||
            (parent != null && (parent is! String || parent.isEmpty))) {
          throw const FormatException('Invalid folder name or parent.');
        }
        final label = names[id]!;
        final path = parent == null
            ? label
            : resolve(parent as String) + '/' + label;
        return path;
      } finally {
        visiting.remove(id);
      }
    }

    for (final id in folders.keys) {
      final path = resolve(id);
      if (resolved.containsKey(path)) {
        throw StateError('Duplicate folder path.');
      }
      resolved[path] = id;
    }
    return resolved;
  }
}

/// Journals each folder/task mutation in @library, never a JSON snapshot.
///
/// The library_folders.json file is a disposable compatibility read-model.
/// It is regenerated from SQLite on startup and after remote commits.
class LibraryV2OperationService {
  LibraryV2OperationService({required this.engine, required this.accountId});

  final SyncEngine engine;
  final String accountId;
  Future<void> _refreshTail = Future<void>.value();

  NotesDatabase get _database => engine.store.database;

  void _requireNamespace() {
    if (ActiveStorageNamespace.current != StorageNamespace.account(accountId)) {
      throw StateError('Library v2 belongs to another account.');
    }
  }

  Future<List<OperationEnvelope>> _history() async {
    final rows = await _database
        .customSelect(
          'SELECT envelope_json FROM operations WHERE document_id = ? '
          'ORDER BY rowid',
          variables: [
            const Variable<String>(OperationEnvelope.libraryDocumentId),
          ],
        )
        .get();
    return [
      for (final row in rows)
        OperationEnvelope.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(row.read<String>('envelope_json')) as Map,
          ),
        ),
    ];
  }

  Future<LibraryV2Snapshot> snapshot() async {
    _requireNamespace();
    final marker = await _database
        .customSelect(
          "SELECT name FROM sqlite_master WHERE name = 'legacy_v1_projection_cutover'",
        )
        .getSingleOrNull();
    var colors = const <int>[];
    if (marker != null) {
      final archived = await _database
          .customSelect(
            'SELECT library_json FROM legacy_v1_projection_cutover '
            'WHERE account_id = ?',
            variables: [Variable<String>(accountId)],
          )
          .getSingleOrNull();
      final raw = archived?.readNullable<String>('library_json');
      if (raw != null) {
        final library = jsonDecode(raw);
        if (library is Map && library['recentCoverColors'] is List) {
          colors = (library['recentCoverColors'] as List)
              .whereType<int>()
              .toList();
        }
      }
    }
    return LibraryV2OperationReducer.replay(
      await _history(),
      migratedRecentCoverColors: colors,
    );
  }

  /// Invoked inside the journal transaction before an envelope is appended.
  Future<void> apply(OperationEnvelope operation) async {
    _requireNamespace();
    LibraryV2OperationReducer.replay([...await _history(), operation]);
  }

  Future<void> refreshReadModel() {
    final refresh = _refreshTail.then((_) async {
      final state = await snapshot();
      _requireNamespace();
      await writeStoredText('library_folders.json', jsonEncode(state.value));
    });
    _refreshTail = refresh.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return refresh;
  }

  /// Converts safe legacy folder/task deltas without treating a cached
  /// v1 snapshot as authoritative over a newer v2 journal.
  Future<void> replayLegacyMetadata({
    required Object? base,
    required Object? local,
    required Object? cutover,
    required Set<String> protectedFolders,
    required Future<void> Function(List<String>) onCommitted,
  }) async {
    _requireNamespace();
    final state = await snapshot();
    final before = _LegacyLibraryMetadata.parse(base);
    final desired = _LegacyLibraryMetadata.parse(local);
    final atCutover = _LegacyLibraryMetadata.parse(cutover);
    final current = _LegacyLibraryMetadata.parse(state.value);
    final conflicts = <String>[];
    final drafts = <LocalOperationDraft>[];
    // A device without a receipt cannot tell a local addition from an old
    // copy of a deletion. Keep that delta for explicit recovery.
    if (base == null && cutover != null) {
      await engine.writeLocalBatch(
        documentId: OperationEnvelope.libraryDocumentId,
        operations: const [],
        apply: apply,
        onCommittedInTransaction: (_) async {
          _requireNamespace();
          await onCommitted([
            'No acknowledged v1 library baseline on this device.',
          ]);
        },
      );
      return;
    }
    final folderIds = {...state.folderIdsByPath};
    final deletedPaths = <String>{};
    const equals = DeepCollectionEquality();

    void add(OperationKind kind, String id, Map<String, dynamic> payload) {
      drafts.add(
        LocalOperationDraft(kind: kind, objectId: id, payload: payload),
      );
    }

    String? parentOf(String path) {
      final slash = path.lastIndexOf('/');
      return slash < 0 ? null : path.substring(0, slash);
    }

    final desiredPaths = desired.folders.toList()
      ..sort((a, b) => a.length.compareTo(b.length));
    final changedSinceCutover = <String>{};
    for (final op in await _history()) {
      if (op.kind.target == OperationTarget.folder &&
          !op.actorId.startsWith('v1-cutover:')) {
        changedSinceCutover.add(op.objectId!);
      }
    }
    for (final path in desiredPaths) {
      if (folderIds.containsKey(path) || before.folders.contains(path)) {
        continue;
      }
      if (atCutover.folders.contains(path)) {
        conflicts.add('Folder changed or deleted remotely: $path');
        continue;
      }
      final parent = parentOf(path);
      if (parent != null && !folderIds.containsKey(parent)) {
        conflicts.add('Missing parent for folder: $path');
        continue;
      }
      final id = const Uuid().v5(
        Namespace.url.value,
        jsonEncode(['legacy-folder-delta', accountId, path]),
      );
      if (await engine.store.isTombstoned(
        OperationEnvelope.libraryDocumentId,
        'folder',
        id,
      )) {
        conflicts.add('Folder identity was already deleted: $path');
        continue;
      }
      folderIds[path] = id;
      add(OperationKind.folderCreate, id, {
        'value': {'name': path.split('/').last, 'parentId': folderIds[parent]},
      });
    }
    if (base != null) {
      final removals = before.folders.difference(desired.folders).toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      for (final path in removals) {
        final id = folderIds[path];
        if (id == null) {
          continue;
        }
        if (changedSinceCutover.contains(id) ||
            !atCutover.folders.contains(path) ||
            protectedFolders.any((p) => p == path || p.startsWith('$path/')) ||
            folderIds.keys.any((p) => p.startsWith('$path/')) ||
            !equals.equals(before.covers[path], current.covers[path])) {
          conflicts.add('Folder removal needs review: $path');
          continue;
        }
        add(OperationKind.folderDelete, id, const {});
        deletedPaths.add(path);
        folderIds.remove(path);
      }
    }
    for (final path in {...before.covers.keys, ...desired.covers.keys}) {
      if (deletedPaths.contains(path)) {
        continue;
      }
      final old = before.covers[path];
      final next = desired.covers[path];
      final actual = current.covers[path];
      if (equals.equals(old, next) || equals.equals(actual, next)) {
        continue;
      }
      final id = folderIds[path];
      if (id == null || !equals.equals(old, actual)) {
        conflicts.add('Folder cover changed concurrently: $path');
        continue;
      }
      add(OperationKind.folderSet, id, {
        'properties': {'cover': next},
      });
    }

    for (final id in {...before.tasks.keys, ...desired.tasks.keys}) {
      final old = before.tasks[id];
      final next = desired.tasks[id];
      final actual = current.tasks[id];
      if (equals.equals(old, next) || equals.equals(next, actual)) {
        continue;
      }
      if (next == null) {
        if (equals.equals(old, actual)) {
          add(OperationKind.taskDelete, id, const {});
        } else {
          conflicts.add('Task removal conflicts with a remote edit: $id');
        }
        continue;
      }
      if (old == null) {
        if (actual != null ||
            atCutover.tasks.containsKey(id) ||
            await wasTaskDeleted(id)) {
          conflicts.add('Task identity was used or deleted remotely: $id');
        } else {
          final planner = next['plannerUid'];
          final max = current.tasks.values
              .where((task) => task['plannerUid'] == planner)
              .fold<int>(-1, (n, task) {
                final rank = task['sortIndex'] as int;
                return rank > n ? rank : n;
              });
          add(OperationKind.taskCreate, id, {
            'value': {
              ...next,
              'sortIndex': max + 1 + (next['sortIndex'] as int),
            },
          });
        }
        continue;
      }
      if (actual == null) {
        conflicts.add('Task was removed remotely: $id');
        continue;
      }
      final changes = <String, dynamic>{};
      for (final key in next.keys) {
        if (equals.equals(old[key], next[key]) ||
            equals.equals(actual[key], next[key])) {
          continue;
        }
        if (!equals.equals(old[key], actual[key])) {
          conflicts.add('Task field changed concurrently: $id/$key');
        } else {
          changes[key] = next[key];
        }
      }
      if (changes.isNotEmpty) {
        add(OperationKind.taskSet, id, {'properties': changes});
      }
    }
    await engine.writeLocalBatch(
      documentId: OperationEnvelope.libraryDocumentId,
      operations: drafts,
      apply: apply,
      onCommittedInTransaction: (_) async {
        _requireNamespace();
        await onCommitted(conflicts);
      },
    );
  }

  Future<void> _commit(
    OperationKind kind,
    String id,
    Map<String, dynamic> payload, {
    bool refresh = true,
  }) async {
    _requireNamespace();
    await engine.writeLocal(
      documentId: OperationEnvelope.libraryDocumentId,
      kind: kind,
      objectId: id,
      payload: payload,
      apply: apply,
    );
    if (refresh) {
      await refreshReadModel();
    }
  }

  /// Relocates a subtree and its document metadata in one SQLite commit.
  ///
  /// A failed document write rolls back the folder envelope, all earlier
  /// document envelopes, their projections and the pending outbox rows.
  /// The compatibility read model is refreshed only after that commit.
  Future<void> _commitRelocation(
    OperationKind kind,
    String id,
    Map<String, dynamic> payload,
    Future<void> Function()? updateDocuments,
  ) async {
    if (updateDocuments == null) {
      await _commit(kind, id, payload);
      return;
    }
    try {
      await _database.transaction(() async {
        await _commit(kind, id, payload, refresh: false);
        await updateDocuments();
      });
    } finally {
      await refreshReadModel();
    }
  }

  /// Registers a parent inferred from an existing document folder path.
  /// Pending operations have durable IDs so retries never duplicate a node.
  Future<void> ensureFolderPath(String path) async {
    if (path.isEmpty) {
      return;
    }
    final segments = path.split('/');
    for (var count = 1; count <= segments.length; count++) {
      final parentPath = segments.take(count).join('/');
      final state = await snapshot();
      if (state.folderIdsByPath.containsKey(parentPath)) {
        continue;
      }
      final parent = count == 1
          ? null
          : state.folderIdsByPath[segments.take(count - 1).join('/')];
      if (count > 1 && parent == null) {
        throw StateError('Implicit folder parent is missing.');
      }
      await _commit(OperationKind.folderCreate, const Uuid().v4(), {
        'value': {'name': segments[count - 1], 'parentId': parent},
      });
    }
  }

  Future<void> createFolder(String path) async {
    final separator = path.lastIndexOf('/');
    if (separator >= 0) {
      await ensureFolderPath(path.substring(0, separator));
    }
    final state = await snapshot();
    if (state.folderIdsByPath.containsKey(path)) {
      throw StateError('Folder already exists.');
    }
    final name = separator < 0 ? path : path.substring(separator + 1);
    final parentPath = separator < 0 ? null : path.substring(0, separator);
    final parent = parentPath == null
        ? null
        : state.folderIdsByPath[parentPath];
    if (parentPath != null && parent == null) {
      throw StateError('Folder parent is missing.');
    }
    await _commit(OperationKind.folderCreate, const Uuid().v4(), {
      'value': {'name': name, 'parentId': parent},
    });
  }

  Future<void> renameFolder(
    String path,
    String nextPath, {
    Future<void> Function()? updateDocuments,
  }) async {
    await ensureFolderPath(path);
    final state = await snapshot();
    final id = state.folderIdsByPath[path];
    if (id == null || state.folderIdsByPath.containsKey(nextPath)) {
      throw StateError('Folder rename collides or is missing.');
    }
    await _commitRelocation(OperationKind.folderSet, id, {
      'properties': {'name': nextPath.split('/').last},
    }, updateDocuments);
  }

  Future<void> moveFolder(
    String path,
    String targetParent, {
    Future<void> Function()? updateDocuments,
  }) async {
    await ensureFolderPath(path);
    await ensureFolderPath(targetParent);
    final state = await snapshot();
    final id = state.folderIdsByPath[path];
    final parent = state.folderIdsByPath[targetParent];
    if (id == null ||
        parent == null ||
        targetParent == path ||
        targetParent.startsWith(path + '/')) {
      throw StateError('Folder move would create a cycle.');
    }
    await _commitRelocation(OperationKind.folderMove, id, {
      'properties': {'parentId': parent},
    }, updateDocuments);
  }

  Future<void> updateCover(String path, Map<String, dynamic> cover) async {
    await ensureFolderPath(path);
    final state = await snapshot();
    final id = state.folderIdsByPath[path];
    if (id == null) {
      throw StateError('Folder is missing.');
    }
    await _commit(OperationKind.folderSet, id, {
      'properties': {'cover': cover},
    });
  }

  Future<void> deleteTree(
    String root, {
    Future<void> Function()? deleteDocuments,
  }) async {
    await ensureFolderPath(root);
    final state = await snapshot();
    final children =
        state.folderIdsByPath.keys
            .where((path) => path == root || path.startsWith(root + '/'))
            .toList()
          ..sort((a, b) => b.length.compareTo(a.length));
    if (children.isEmpty) {
      throw StateError('Folder is missing.');
    }
    Future<void> deleteFolders() async {
      await engine.writeLocalBatch(
        documentId: OperationEnvelope.libraryDocumentId,
        operations: [
          for (final path in children)
            LocalOperationDraft(
              kind: OperationKind.folderDelete,
              objectId: state.folderIdsByPath[path],
              payload: const {},
            ),
        ],
        apply: apply,
      );
    }

    if (deleteDocuments == null) {
      await deleteFolders();
      await refreshReadModel();
      return;
    }
    try {
      await _database.transaction(() async {
        await deleteDocuments();
        await deleteFolders();
      });
    } finally {
      // Refresh the compatibility view from the final committed/rolled-back
      // journal, never from an intermediate subtree deletion.
      await refreshReadModel();
    }
  }

  /// Deleted imported tasks must never be recreated with the same UID.
  Future<bool> wasTaskDeleted(String id) async {
    _requireNamespace();
    return engine.store.isTombstoned(
      OperationEnvelope.libraryDocumentId,
      'task',
      id,
    );
  }

  Future<void> createTask(
    String plannerUid,
    Map<String, dynamic> task,
    int sortIndex,
  ) async {
    final id = task['id'];
    if (id is! String || id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'Task ID is required.');
    }
    await _commit(OperationKind.taskCreate, id, {
      'value': {...task, 'plannerUid': plannerUid, 'sortIndex': sortIndex},
    });
  }

  Future<void> updateTask(String id, Map<String, dynamic> task) async {
    final fields = Map<String, dynamic>.from(task)..remove('id');
    await _commit(OperationKind.taskSet, id, {'properties': fields});
  }

  Future<void> deleteTask(String id) async {
    await _commit(OperationKind.taskDelete, id, const {});
  }

  Future<void> deletePlannerTasks(
    String plannerUid, {
    bool refresh = true,
  }) async {
    final state = await snapshot();
    final tasks = state.value['plannerTasks'] as Map<String, dynamic>;
    final list = tasks[plannerUid];
    if (list is! List || list.isEmpty) {
      return;
    }
    await engine.writeLocalBatch(
      documentId: OperationEnvelope.libraryDocumentId,
      operations: [
        for (final task in list)
          LocalOperationDraft(
            kind: OperationKind.taskDelete,
            objectId: (task as Map)['id'] as String,
            payload: const {},
          ),
      ],
      apply: apply,
    );
    if (refresh) {
      await refreshReadModel();
    }
  }
}

class _LegacyLibraryMetadata {
  const _LegacyLibraryMetadata(this.folders, this.covers, this.tasks);

  final Set<String> folders;
  final Map<String, dynamic> covers;
  final Map<String, Map<String, dynamic>> tasks;

  static _LegacyLibraryMetadata parse(Object? raw) {
    if (raw == null) {
      return const _LegacyLibraryMetadata({}, {}, {});
    }
    final value = raw is List ? {'folders': raw} : raw;
    if (value is! Map || value['folders'] is! List) {
      throw const FormatException('Invalid legacy library snapshot.');
    }
    final paths = (value['folders'] as List).cast<String>().toSet();
    final covers = Map<String, dynamic>.from(value['covers'] as Map? ?? {});
    paths.addAll(covers.keys);
    for (final path in paths.toList()) {
      final parts = path.split('/');
      if (parts.any((item) => item.isEmpty || item.trim() != item)) {
        throw const FormatException('Invalid legacy folder path.');
      }
      for (var i = 1; i < parts.length; i++) {
        paths.add(parts.take(i).join('/'));
      }
    }
    final tasks = <String, Map<String, dynamic>>{};
    final byPlanner = Map<String, dynamic>.from(
      value['plannerTasks'] as Map? ?? {},
    );
    for (final entry in byPlanner.entries) {
      final items = entry.value as List;
      for (var i = 0; i < items.length; i++) {
        final task = items[i] as Map;
        final uid = task['id'];
        if (uid is! String ||
            uid.isEmpty ||
            tasks.containsKey(uid) ||
            task['title'] is! String) {
          throw const FormatException('Invalid legacy task identity or title.');
        }
        tasks[uid] = {
          'plannerUid': entry.key,
          'title': task['title'],
          'completed': task['completed'] == true,
          'deadline': task['deadline'],
          'deadlineHasTime': task['deadlineHasTime'] == true,
          'sortIndex': i,
        };
      }
    }
    return _LegacyLibraryMetadata(paths, covers, tasks);
  }
}
