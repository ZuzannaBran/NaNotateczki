import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/error/app_error_log.dart';
import '../../../core/storage/app_save_coordinator.dart';
import '../../../core/storage/text_storage.dart';
import '../../../data/backup/local_backup_service.dart';
import '../../../data/sync/library_v2_operation_service.dart';
import '../../editor/state/ink_color_presets.dart';
import '../../notebook/data/notebook_repository.dart';
import '../../notebook/domain/notebook.dart';
import '../../notebook/domain/notebook_kind.dart';
import '../../planner/state/planner_task.dart';

enum FolderCoverShape { folder, star, heart, flower, sparkle }

class FolderCoverStyle {
  const FolderCoverStyle({
    this.shape = FolderCoverShape.folder,
    this.iconColor,
  });

  final FolderCoverShape shape;
  final Color? iconColor;

  Map<String, Object?> toJson() => {
    'shape': shape.name,
    'iconColor': iconColor?.toARGB32(),
  };

  factory FolderCoverStyle.fromJson(Object? value) {
    if (value is! Map) {
      return const FolderCoverStyle();
    }
    final savedShape = value['shape'];
    final shape = FolderCoverShape.values.firstWhere(
      (entry) => entry.name == savedShape,
      orElse: () => FolderCoverShape.folder,
    );
    final rawColor = value['iconColor'];
    return FolderCoverStyle(
      shape: shape,
      iconColor: rawColor is int ? Color(rawColor) : null,
    );
  }
}

class LibraryController extends ChangeNotifier {
  LibraryController(
    this.repository,
    this.backup, {
    this.wasReset = false,
    this.freshFile = false,
    this.resetReason,
  }) {
    AppSaveCoordinator.instance.register(
      this,
      hasPendingWork: () => _taskSaveDirty || _taskWritesPending > 0,
      flush: flushPlannerTasks,
    );
  }

  final NotebookRepository repository;
  final LocalBackupService backup;
  final bool wasReset;
  final bool freshFile;
  final String? resetReason;
  int autoRestoreCount = 0;
  bool _bannerDismissed = false;
  bool isLoading = false;
  bool _isDisposed = false;
  bool isLoadingSelectedItem = false;
  bool isRecoveringCorruptDocuments = false;
  List<Notebook> items = <Notebook>[];
  String? selectedItemId;
  String selectedFolder = '';
  String searchQuery = '';
  Object? loadError;
  LibraryV2OperationService? _v2LibraryOperations;

  /// Switches the library metadata writer only for a confirmed v2 account.
  void attachV2LibraryOperations(LibraryV2OperationService? service) {
    _v2LibraryOperations = service;
  }

  final Set<String> _folders = <String>{};
  final Map<String, FolderCoverStyle> _folderCovers =
      <String, FolderCoverStyle>{};
  final List<Color> _recentCoverColors = <Color>[];
  final Map<String, List<PlannerTask>> _plannerTasks = {};
  Timer? _taskSaveTimer;
  bool _taskSaveDirty = false;
  int _taskWritesPending = 0;
  Future<void> _lastTaskSave = Future<void>.value();

  List<Color> get recentCoverColors => List.unmodifiable(_recentCoverColors);
  Notebook? _activeNotebook;
  bool _corruptRecoveryDismissed = false;
  int corruptDocumentCount = 0;
  List<Notebook> recoverableCorruptDocuments = <Notebook>[];

  static const String _defaultFolderName = 'Notes';
  static const String _foldersFileName = 'library_folders.json';

  bool get shouldShowResetBanner =>
      (wasReset || (freshFile && autoRestoreCount > 0)) && !_bannerDismissed;

  bool get hasCorruptDocuments => corruptDocumentCount > 0;

  bool get shouldPromptCorruptRecovery =>
      hasCorruptDocuments &&
      recoverableCorruptDocuments.isNotEmpty &&
      !_corruptRecoveryDismissed;

  bool get shouldShowCorruptionBanner =>
      hasCorruptDocuments &&
      !_corruptRecoveryDismissed &&
      !shouldPromptCorruptRecovery;

  void dismissResetBanner() {
    _bannerDismissed = true;
    notifyListeners();
  }

  void dismissCorruptRecoveryPrompt() {
    _corruptRecoveryDismissed = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    AppSaveCoordinator.instance.unregister(this);
    if (_taskSaveDirty) {
      unawaited(flushPlannerTasks());
    }
    _taskSaveTimer?.cancel();
    super.dispose();
  }

  Future<void> initialize() async {
    await _loadFolders();
    if (_isDisposed) {
      return;
    }
    await loadItems();
    if (_isDisposed) {
      return;
    }
    if (!wasReset && !freshFile && !repository.lastFetchSkippedCorruptRows) {
      await repository.cleanupOrphanedImages(items);
    }
  }

  /// Refreshes folders, covers and tasks after verified account recovery.
  Future<void> reloadFromAccount() async {
    await _loadFolders();
    await loadItems();
  }

  Future<void> loadItems() async {
    if (_isDisposed) {
      return;
    }
    isLoading = true;
    notifyListeners();
    try {
      final loadedItems = await repository.fetchNotebooks();
      items = loadedItems;
      loadError = null;
      await _refreshCorruptRecoveryState();

      if (_v2LibraryOperations == null &&
          items.isEmpty &&
          (wasReset || freshFile) &&
          await backup.hasLatest()) {
        final restore = await backup.restoreFromLatestDetailed();
        autoRestoreCount = restore.restoredCount;
        if (restore.succeeded) {
          if (autoRestoreCount > 0) {
            items = await repository.fetchNotebooks();
            await _refreshCorruptRecoveryState();
          }
          await _loadFolders();
          await repository.completeDatabaseRecovery();
        } else {
          AppErrorLog.instance.record(
            'Database restore was attempted after startup reset, but the '
            'local backup could not be restored safely.',
            null,
            source: 'LibraryController.loadItems(reset_restore_failed)',
          );
        }
      } else if (_v2LibraryOperations == null && items.isEmpty && wasReset) {
        AppErrorLog.instance.record(
          'Database recovery is pending, but no local backup snapshot was '
          'available for automatic restore.',
          null,
          source: 'LibraryController.loadItems(reset_without_backup)',
        );
      }

      if (wasReset && items.isNotEmpty) {
        await repository.completeDatabaseRecovery();
      }

      if (items.isNotEmpty) {
        final folders = folderNames;
        if (folders.isNotEmpty && !folders.contains(selectedFolder)) {
          selectedFolder = folders.first;
        }
        if (!_selectedItemIsInFolder(selectedFolder)) {
          selectedItemId = _firstItemInFolder(selectedFolder)?.uid;
          _activeNotebook = selectedItemId == null
              ? null
              : _itemById(selectedItemId!);
        } else if (selectedItemId != null) {
          _activeNotebook = _itemById(selectedItemId!);
        }
      } else {
        selectedItemId = null;
        _activeNotebook = null;
      }
    } catch (error, stackTrace) {
      loadError = error;
      AppErrorLog.instance.record(
        error,
        stackTrace,
        source: 'LibraryController.loadItems',
      );
    } finally {
      isLoading = false;
      if (!_isDisposed) {
        notifyListeners();
      }
    }
  }

  Future<int> restoreCorruptDocumentsFromBackup() async {
    if (recoverableCorruptDocuments.isEmpty) {
      _corruptRecoveryDismissed = true;
      AppErrorLog.instance.record(
        'Corrupt documents were detected, but no recoverable local backup '
        'copies were found.',
        null,
        source: 'LibraryController.restoreCorruptDocumentsFromBackup(no_candidates)',
      );
      notifyListeners();
      return 0;
    }

    isRecoveringCorruptDocuments = true;
    notifyListeners();

    var restored = 0;
    try {
      for (final notebook in recoverableCorruptDocuments) {
        await repository.saveRecoveredCopy(notebook, reason: 'Recovered');
        restored++;
      }
      _corruptRecoveryDismissed = true;
      items = await repository.fetchNotebooks();
      await _refreshCorruptRecoveryState();
      if (items.isNotEmpty) {
        selectedFolder = folderNames.isEmpty ? '' : folderNames.first;
        if (!_selectedItemIsInFolder(selectedFolder)) {
          selectedItemId = _firstItemInFolder(selectedFolder)?.uid;
        }
        _activeNotebook = selectedItemId == null
            ? null
            : _itemById(selectedItemId!);
      } else {
        selectedItemId = null;
        _activeNotebook = null;
      }
    } catch (e, st) {
      AppErrorLog.instance.record(
        e,
        st,
        source: 'LibraryController.restoreCorruptDocumentsFromBackup',
      );
    } finally {
      if (restored == 0) {
        AppErrorLog.instance.record(
          'Corrupt document recovery finished without restoring any copies.',
          null,
          source: 'LibraryController.restoreCorruptDocumentsFromBackup(empty)',
        );
      }
      isRecoveringCorruptDocuments = false;
      notifyListeners();
    }
    return restored;
  }

  List<Notebook> get visibleItems {
    final folderFiltered = items
        .where((item) => item.folder == selectedFolder)
        .toList();
    if (searchQuery.isEmpty) {
      return folderFiltered;
    }
    final query = searchQuery.toLowerCase().trim();
    return folderFiltered
        .where((notebook) => _matches(notebook, query))
        .toList();
  }

  List<String> get folderNames {
    final names = <String>{
      ..._folders,
      ...items
          .map((item) => item.folder)
          .map((name) => name.trim())
          .where((name) => name.trim().isNotEmpty),
    };
    for (final path in names.toList()) {
      var parent = parentFolderOf(path);
      while (parent != null) {
        names.add(parent);
        parent = parentFolderOf(parent);
      }
    }
    final list = names.toList()..sort(_compareFolderNames);
    return list;
  }

  String folderLabel(String path) => path.split('/').last;

  String? parentFolderOf(String path) {
    final separator = path.lastIndexOf('/');
    return separator < 0 ? null : path.substring(0, separator);
  }

  List<String> childFoldersOf(String? parent) =>
      folderNames.where((path) => parentFolderOf(path) == parent).toList();

  bool isInFolderTree(String folder, String root) =>
      folder == root || folder.startsWith('$root/');

  FolderCoverStyle folderCoverFor(String name) =>
      _folderCovers[name] ?? const FolderCoverStyle();

  Future<void> updateFolderCover(String folder, FolderCoverStyle cover) async {
    if (!folderNames.contains(folder)) {
      return;
    }
    await _v2LibraryOperations?.updateCover(
      folder,
      Map<String, dynamic>.from(cover.toJson()),
    );
    _folderCovers[folder] = cover;
    if (cover.iconColor case final Color selectedColor) {
      _recentCoverColors.removeWhere(
        (color) => color.toARGB32() == selectedColor.toARGB32(),
      );
      _recentCoverColors.insert(0, selectedColor);
      if (_recentCoverColors.length > 12) {
        _recentCoverColors.removeRange(12, _recentCoverColors.length);
      }
      await SharedRecentColors.record(selectedColor);
    }
    await _saveFolders();
    notifyListeners();
  }

  Future<String?> createFolder(String name, {String? parent}) async {
    final trimmed = name.trim();
    final parentPath = parent?.trim();
    if (trimmed.isEmpty ||
        trimmed.contains('/') ||
        (parentPath != null && !folderNames.contains(parentPath))) {
      return null;
    }
    final path = parentPath == null ? trimmed : '$parentPath/$trimmed';
    if (folderNames.contains(path)) {
      return null;
    }
    final v2 = _v2LibraryOperations;
    if (v2 != null) {
      await v2.createFolder(path);
    }
    _folders.add(path);
    selectedFolder = path;
    selectedItemId = _firstItemInFolder(path)?.uid;
    _activeNotebook = selectedItemId == null
        ? null
        : _itemById(selectedItemId!);
    await _saveFolders();
    notifyListeners();
    return path;
  }

  Future<String?> renameFolder(String oldName, String newName) async {
    final oldPath = oldName.trim();
    final trimmed = newName.trim();
    if (oldPath.isEmpty ||
        trimmed.isEmpty ||
        trimmed.contains('/') ||
        !folderNames.contains(oldPath)) {
      return null;
    }
    final parent = parentFolderOf(oldPath);
    final nextPath = parent == null ? trimmed : '$parent/$trimmed';
    if (oldPath == nextPath) {
      return oldPath;
    }
    if (folderNames.any(
      (path) =>
          !isInFolderTree(path, oldPath) && isInFolderTree(path, nextPath),
    )) {
      return null;
    }

    String relocate(String path) => nextPath + path.substring(oldPath.length);

    final updatedItems = <Notebook>[];
    Future<void> relocateDocuments() async {
      for (final item in items) {
        if (!isInFolderTree(item.folder, oldPath)) {
          updatedItems.add(item);
          continue;
        }
        final updated = await repository.updateNotebookMetadata(
          item.uid,
          folder: relocate(item.folder),
        );
        if (updated == null && _v2LibraryOperations != null) {
          throw StateError('V2 folder rename lost a document.');
        }
        updatedItems.add(updated ?? item);
      }
    }

    final v2 = _v2LibraryOperations;
    if (v2 == null) {
      await relocateDocuments();
    } else {
      try {
        await v2.renameFolder(
          oldPath,
          nextPath,
          updateDocuments: relocateDocuments,
        );
      } catch (_) {
        // Clear cached projections from a failed nested journal transaction.
        await repository.fetchNotebooks();
        rethrow;
      }
    }
    items = updatedItems;
    final updatedFolders = _folders
        .map((path) => isInFolderTree(path, oldPath) ? relocate(path) : path)
        .toSet();
    _folders
      ..clear()
      ..addAll(updatedFolders);
    final updatedCovers = <String, FolderCoverStyle>{
      for (final entry in _folderCovers.entries)
        (isInFolderTree(entry.key, oldPath) ? relocate(entry.key) : entry.key):
            entry.value,
    };
    _folderCovers
      ..clear()
      ..addAll(updatedCovers);
    if (isInFolderTree(selectedFolder, oldPath)) {
      selectedFolder = relocate(selectedFolder);
    }
    if (_activeNotebook != null &&
        isInFolderTree(_activeNotebook!.folder, oldPath)) {
      _activeNotebook = _itemById(_activeNotebook!.uid);
    }
    if (!_selectedItemIsInFolder(selectedFolder)) {
      selectedItemId = _firstItemInFolder(selectedFolder)?.uid;
      _activeNotebook = selectedItemId == null
          ? null
          : _itemById(selectedItemId!);
    }
    await _saveFolders();
    notifyListeners();
    return nextPath;
  }

  bool canMoveFolderToFolder(String source, String targetParent) {
    final sourcePath = source.trim();
    final targetPath = targetParent.trim();
    if (!folderNames.contains(sourcePath) ||
        !folderNames.contains(targetPath) ||
        sourcePath == targetPath ||
        parentFolderOf(sourcePath) == targetPath ||
        isInFolderTree(targetPath, sourcePath)) {
      return false;
    }
    final destination = '$targetPath/${folderLabel(sourcePath)}';
    return !folderNames.any(
      (path) =>
          !isInFolderTree(path, sourcePath) &&
          isInFolderTree(path, destination),
    );
  }

  Future<String?> moveFolderToFolder(String source, String targetParent) async {
    final sourcePath = source.trim();
    final targetPath = targetParent.trim();
    if (!canMoveFolderToFolder(sourcePath, targetPath)) {
      return null;
    }
    final destination = '$targetPath/${folderLabel(sourcePath)}';
    String relocate(String path) =>
        destination + path.substring(sourcePath.length);

    final updatedItems = <Notebook>[];
    final v2 = _v2LibraryOperations;
    var missingDocument = false;
    Future<void> relocateDocuments() async {
      for (final item in items) {
        if (!isInFolderTree(item.folder, sourcePath)) {
          updatedItems.add(item);
          continue;
        }
        final updated = await repository.updateNotebookMetadata(
          item.uid,
          folder: relocate(item.folder),
        );
        if (updated == null) {
          if (v2 != null) {
            throw StateError('V2 folder move lost a document.');
          }
          missingDocument = true;
          return;
        }
        updatedItems.add(updated);
      }
    }

    if (v2 == null) {
      await relocateDocuments();
      if (missingDocument) {
        return null;
      }
    } else {
      try {
        await v2.moveFolder(
          sourcePath,
          targetPath,
          updateDocuments: relocateDocuments,
        );
      } catch (_) {
        await repository.fetchNotebooks();
        rethrow;
      }
    }
    items = updatedItems;
    final updatedFolders = _folders
        .map((path) => isInFolderTree(path, sourcePath) ? relocate(path) : path)
        .toSet();
    _folders
      ..clear()
      ..addAll(updatedFolders);
    final updatedCovers = <String, FolderCoverStyle>{
      for (final entry in _folderCovers.entries)
        (isInFolderTree(entry.key, sourcePath)
                ? relocate(entry.key)
                : entry.key):
            entry.value,
    };
    _folderCovers
      ..clear()
      ..addAll(updatedCovers);
    if (isInFolderTree(selectedFolder, sourcePath)) {
      selectedFolder = relocate(selectedFolder);
    }
    if (_activeNotebook != null &&
        isInFolderTree(_activeNotebook!.folder, sourcePath)) {
      _activeNotebook = _itemById(_activeNotebook!.uid);
    }
    if (!_selectedItemIsInFolder(selectedFolder)) {
      selectedItemId = _firstItemInFolder(selectedFolder)?.uid;
      _activeNotebook = selectedItemId == null
          ? null
          : _itemById(selectedItemId!);
    }
    await _saveFolders();
    notifyListeners();
    return destination;
  }

  Future<void> deleteFolder(String name) async {
    final path = name.trim();
    if (path.isEmpty || !folderNames.contains(path)) {
      return;
    }
    final affected = items
        .where((item) => isInFolderTree(item.folder, path))
        .toList();
    final v2 = _v2LibraryOperations;
    if (v2 == null) {
      for (final item in affected) {
        await repository.deleteNotebook(item.uid);
        _plannerTasks.remove(item.uid);
      }
    } else {
      Future<void> deleteDocuments() async {
        for (final item in affected) {
          await repository.deleteNotebook(item.uid);
          await v2.deletePlannerTasks(item.uid, refresh: false);
        }
      }

      try {
        await v2.deleteTree(path, deleteDocuments: deleteDocuments);
      } catch (_) {
        await repository.fetchNotebooks();
        rethrow;
      }
      for (final item in affected) {
        _plannerTasks.remove(item.uid);
      }
    }
    final deletedIds = affected.map((item) => item.uid).toSet();
    items = items.where((item) => !deletedIds.contains(item.uid)).toList();
    _folders.removeWhere((folder) => isInFolderTree(folder, path));
    _folderCovers.removeWhere((folder, _) => isInFolderTree(folder, path));
    if (isInFolderTree(selectedFolder, path)) {
      final parent = parentFolderOf(path);
      selectedFolder = parent != null && folderNames.contains(parent)
          ? parent
          : (folderNames.isEmpty ? '' : folderNames.first);
    }
    if (_activeNotebook != null && deletedIds.contains(_activeNotebook!.uid)) {
      _activeNotebook = null;
    }
    if (!_selectedItemIsInFolder(selectedFolder)) {
      selectedItemId = _firstItemInFolder(selectedFolder)?.uid;
      _activeNotebook = selectedItemId == null
          ? null
          : _itemById(selectedItemId!);
    }
    await _saveFolders();
    notifyListeners();
  }

  List<PlannerTask> plannerTasks(String uid) {
    final tasks = _plannerTasks[uid] ?? const <PlannerTask>[];
    return List.unmodifiable([
      ...tasks.where((task) => !task.completed),
      ...tasks.where((task) => task.completed),
    ]);
  }

  Future<PlannerTask> addPlannerTask(String uid) async {
    if (!items.any(
      (item) => item.uid == uid && item.kind == NotebookKind.planner,
    )) {
      throw ArgumentError.value(uid, 'uid', 'Planner not found');
    }
    final task = PlannerTask(id: const Uuid().v4(), title: '');
    final tasks = _plannerTasks.putIfAbsent(uid, () => <PlannerTask>[]);
    await _v2LibraryOperations?.createTask(
      uid,
      Map<String, dynamic>.from(task.toJson()),
      tasks.length,
    );
    tasks.add(task);
    notifyListeners();
    if (_v2LibraryOperations == null) {
      _schedulePlannerTaskSave();
    }
    return task;
  }

  Future<void> updatePlannerTask(
    String uid,
    String taskId, {
    String? title,
    bool? completed,
    DateTime? deadline,
    bool clearDeadline = false,
    bool? deadlineHasTime,
  }) async {
    final list = _plannerTasks[uid];
    if (list == null) {
      return;
    }
    final index = list.indexWhere((task) => task.id == taskId);
    if (index < 0) {
      return;
    }
    final updated = list[index].copyWith(
      title: title,
      completed: completed,
      deadline: deadline,
      clearDeadline: clearDeadline,
      deadlineHasTime: deadlineHasTime,
    );
    await _v2LibraryOperations?.updateTask(
      taskId,
      Map<String, dynamic>.from(updated.toJson()),
    );
    list[index] = updated;
    notifyListeners();
    if (_v2LibraryOperations == null) {
      _schedulePlannerTaskSave();
    }
  }

  Future<void> removePlannerTask(String uid, String taskId) async {
    final list = _plannerTasks[uid];
    if (list == null) {
      return;
    }
    if (!list.any((task) => task.id == taskId)) {
      return;
    }
    await _v2LibraryOperations?.deleteTask(taskId);
    list.removeWhere((task) => task.id == taskId);
    notifyListeners();
    if (_v2LibraryOperations == null) {
      _schedulePlannerTaskSave();
    }
  }

  void _schedulePlannerTaskSave() {
    _taskSaveDirty = true;
    _taskSaveTimer?.cancel();
    _taskSaveTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(flushPlannerTasks());
    });
  }

  Future<void> flushPlannerTasks() async {
    _taskSaveTimer?.cancel();
    _taskSaveTimer = null;
    if (_taskSaveDirty) {
      _taskSaveDirty = false;
      _taskWritesPending++;
      _lastTaskSave = _saveFolders().whenComplete(() {
        _taskWritesPending--;
      });
    }
    await _lastTaskSave;
  }

  Future<Notebook> createPlanner() async {
    final planner = await repository.createPlanner(
      folder: _targetFolderForNewItem(),
    );
    items = [planner, ...items];
    selectedFolder = planner.folder;
    selectedItemId = planner.uid;
    _activeNotebook = planner;
    notifyListeners();
    return planner;
  }

  Future<Notebook> createNotebook() async {
    final notebook = await repository.createNotebook(
      folder: _targetFolderForNewItem(),
    );
    items = [notebook, ...items];
    selectedFolder = notebook.folder;
    selectedItemId = notebook.uid;
    _activeNotebook = notebook;
    notifyListeners();
    return notebook;
  }

  Future<Notebook> createBoard() async {
    final board = await repository.createBoard(
      folder: _targetFolderForNewItem(),
    );
    items = [board, ...items];
    selectedFolder = board.folder;
    selectedItemId = board.uid;
    _activeNotebook = board;
    notifyListeners();
    return board;
  }

  Future<void> deleteItem(String uid) async {
    await repository.deleteNotebook(uid);
    await _v2LibraryOperations?.deletePlannerTasks(uid);
    if (_plannerTasks.remove(uid) != null) {
      await _saveFolders();
    }
    items = items.where((item) => item.uid != uid).toList();
    if (selectedItemId == uid) {
      selectedItemId = _firstItemInFolder(selectedFolder)?.uid;
      _activeNotebook = selectedItemId == null
          ? null
          : _itemById(selectedItemId!);
    } else if (_activeNotebook?.uid == uid) {
      _activeNotebook = null;
    }
    notifyListeners();
  }

  Future<void> renameItem(String uid, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      return;
    }

    final existing = _itemById(uid);
    if (existing == null || existing.title == trimmed) {
      return;
    }

    final updated = await repository.updateNotebookMetadata(
      uid,
      title: trimmed,
    );
    if (updated == null) {
      return;
    }
    items = [
      for (final item in items)
        if (item.uid == uid) updated else item,
    ];
    if (_activeNotebook?.uid == uid) {
      _activeNotebook = updated;
    }
    notifyListeners();
  }

  Future<bool> moveItemToFolder(String uid, String folder) async {
    final targetFolder = folder.trim();
    final original = _itemById(uid);
    if (original == null ||
        original.folder == targetFolder ||
        !folderNames.contains(targetFolder)) {
      return false;
    }

    final updated = await repository.updateNotebookMetadata(
      uid,
      folder: targetFolder,
    );
    if (updated == null) {
      return false;
    }

    items = [
      for (final item in items)
        if (item.uid == uid) updated else item,
    ];
    if (selectedItemId == uid) {
      selectedFolder = targetFolder;
    }
    if (_activeNotebook?.uid == uid) {
      _activeNotebook = updated;
    }
    notifyListeners();
    return true;
  }

  Future<void> selectItem(String uid) async {
    final cached = _itemById(uid);
    if (cached != null) {
      selectedFolder = cached.folder;
    }
    selectedItemId = uid;
    isLoadingSelectedItem = true;
    _activeNotebook = null;
    notifyListeners();

    final fresh = await repository.getNotebook(uid);
    _activeNotebook = fresh ?? _itemById(uid);
    isLoadingSelectedItem = false;
    notifyListeners();
  }

  void selectFolder(String folder) {
    selectedFolder = folder;
    selectedItemId = _firstItemInFolder(folder)?.uid;
    _activeNotebook = selectedItemId == null
        ? null
        : _itemById(selectedItemId!);
    notifyListeners();
  }

  void setSearchQuery(String value) {
    searchQuery = value;
    notifyListeners();
  }

  Future<String> exportBackup() async {
    final current = await repository.fetchNotebooks();
    if (repository.lastFetchSkippedCorruptRows) {
      throw StateError(
        'Cannot export while unreadable notebook data is present.',
      );
    }
    final dir = await getApplicationDocumentsDirectory();
    final file = File(
      '${dir.path}/notatek_backup_'
      '${DateTime.now().microsecondsSinceEpoch}.json',
    );
    final temporary = File('${file.path}.tmp');
    final payload = repository.encodePortableBackup(
      current,
      folders: folderNames,
      plannerTasks: {
        for (final entry in _plannerTasks.entries)
          entry.key: entry.value.map((task) => task.toJson()).toList(),
      },
    );
    try {
      await temporary.writeAsString(jsonEncode(payload), flush: true);
      await temporary.rename(file.path);
    } catch (_) {
      if (await temporary.exists()) {
        await temporary.delete();
      }
      rethrow;
    }
    return file.path;
  }

  Future<void> importBackup(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('Backup file not found.');
    }
    final content = await file.readAsString();
    final decoded = repository.decodePortableBackup(jsonDecode(content));
    final recoveredTasks = <String, List<PlannerTask>>{};
    for (final entry in decoded.plannerTasks.entries) {
      final entries = entry.value;
      if (entries is! List) {
        throw const FormatException('Malformed planner task backup.');
      }
      final tasks = entries.map(PlannerTask.fromJson).toList();
      if (tasks.any((task) => task == null)) {
        throw const FormatException('Malformed planner task entry.');
      }
      recoveredTasks[entry.key] = tasks.cast<PlannerTask>();
    }
    await repository.importNotebooksAtomically(decoded.notebooks);
    _plannerTasks.addAll(recoveredTasks);
    _folders.addAll(decoded.folders);
    await _saveFolders();
    await loadItems();
  }

  Notebook? selectedItem() {
    if (_activeNotebook != null && _activeNotebook!.uid == selectedItemId) {
      return _activeNotebook;
    }
    if (selectedItemId == null) {
      return null;
    }
    return _itemById(selectedItemId!);
  }

  Notebook? _itemById(String uid) {
    for (final item in items) {
      if (item.uid == uid) {
        return item;
      }
    }
    return null;
  }

  Notebook? _firstItemInFolder(String folder) {
    final folderItems = items.where((item) => item.folder == folder).toList();
    if (folderItems.isEmpty) {
      return null;
    }
    return folderItems.first;
  }

  bool _selectedItemIsInFolder(String folder) {
    final uid = selectedItemId;
    if (uid == null) {
      return false;
    }
    return items.any((item) => item.uid == uid && item.folder == folder);
  }

  String _targetFolderForNewItem() {
    if (selectedFolder.trim().isNotEmpty) {
      return selectedFolder;
    }
    final folders = folderNames;
    if (folders.isNotEmpty) {
      return folders.first;
    }
    return _defaultFolderName;
  }

  Future<void> _loadFolders() async {
    try {
      final content = await readStoredText(_foldersFileName);
      if (content == null) {
        return;
      }
      final decoded = jsonDecode(content);
      final savedFolders = decoded is List
          ? decoded
          : decoded is Map
          ? decoded['folders']
          : null;
      if (savedFolders is! List) {
        return;
      }
      _folders
        ..clear()
        ..addAll(
          savedFolders
              .whereType<String>()
              .map((item) => item.trim())
              .where((item) => item.isNotEmpty),
        );
      _folderCovers.clear();
      _recentCoverColors.clear();
      _plannerTasks.clear();
      if (decoded is Map && decoded['plannerTasks'] is Map) {
        final savedTasks = decoded['plannerTasks'] as Map;
        for (final entry in savedTasks.entries) {
          if (entry.key is! String || entry.value is! List) {
            continue;
          }
          final restored = (entry.value as List)
              .map(PlannerTask.fromJson)
              .whereType<PlannerTask>()
              .toList();
          _plannerTasks[entry.key as String] = restored;
        }
      }
      if (decoded is Map && decoded['recentCoverColors'] is List) {
        _recentCoverColors.addAll(
          (decoded['recentCoverColors'] as List)
              .whereType<int>()
              .take(12)
              .map((value) => Color(value)),
        );
      }
      if (decoded is Map && decoded['covers'] is Map) {
        final covers = decoded['covers'] as Map;
        for (final entry in covers.entries) {
          if (entry.key is String) {
            _folderCovers[entry.key as String] = FolderCoverStyle.fromJson(
              entry.value,
            );
          }
        }
      }
    } catch (e) {
      debugPrint('LibraryController._loadFolders failed: $e');
    }
  }

  Future<void> _saveFolders() async {
    final v2 = _v2LibraryOperations;
    if (v2 != null) {
      await v2.refreshReadModel();
      repository.onChanged?.call(const <NotebookRepositoryChange>[]);
      return;
    }
    try {
      final names = _folders.toList()..sort(_compareFolderNames);
      final payload = <String, Object?>{
        'folders': names,
        'recentCoverColors': _recentCoverColors
            .map((color) => color.toARGB32())
            .toList(),
        'covers': {
          for (final entry in _folderCovers.entries)
            entry.key: entry.value.toJson(),
        },
        'plannerTasks': {
          for (final entry in _plannerTasks.entries)
            entry.key: entry.value.map((task) => task.toJson()).toList(),
        },
      };
      await writeStoredText(_foldersFileName, jsonEncode(payload));
      repository.onChanged?.call(const <NotebookRepositoryChange>[]);
    } catch (e) {
      debugPrint('LibraryController._saveFolders failed: $e');
    }
  }

  int _compareFolderNames(String a, String b) {
    final lowerCompare = a.toLowerCase().compareTo(b.toLowerCase());
    if (lowerCompare != 0) {
      return lowerCompare;
    }
    return a.compareTo(b);
  }

  bool _matches(Notebook notebook, String query) {
    if (notebook.title.toLowerCase().contains(query)) {
      return true;
    }
    if (_plannerTasks[notebook.uid]?.any(
          (task) => task.title.toLowerCase().contains(query),
        ) ??
        false) {
      return true;
    }
    for (final page in notebook.pages) {
      if (page.title.toLowerCase().contains(query)) {
        return true;
      }
      for (final block in page.textBlocks) {
        if (block.text.toLowerCase().contains(query)) {
          return true;
        }
      }
      for (final block in page.imageBlocks) {
        if (block.ocrText.toLowerCase().contains(query)) {
          return true;
        }
      }
    }
    return false;
  }

  Future<void> _refreshCorruptRecoveryState() async {
    corruptDocumentCount = repository.lastCorruptNotebookCount;
    recoverableCorruptDocuments = <Notebook>[];
    if (!repository.lastFetchSkippedCorruptRows) {
      return;
    }

    final corruptUids = repository.lastCorruptNotebookIds.toSet();
    final recoverable = <Notebook>[];
    for (final uid in corruptUids) {
      final backupNotebooks = await backup.readLatest(requiredUids: {uid});
      for (final item in backupNotebooks) {
        if (item.uid == uid) {
          recoverable.add(item);
          break;
        }
      }
    }
    recoverableCorruptDocuments = recoverable
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    AppErrorLog.instance.record(
      'Detected $corruptDocumentCount unreadable notebook rows. '
      'Backup candidates: ${recoverableCorruptDocuments.length}.',
      null,
      source: 'LibraryController._refreshCorruptRecoveryState',
    );
    if (recoverableCorruptDocuments.isEmpty) {
      AppErrorLog.instance.record(
        'Unreadable notebook rows were detected, but the local backup did not '
        'contain any missing document candidates to restore.',
        null,
        source:
            'LibraryController._refreshCorruptRecoveryState(no_backup_match)',
      );
    }
  }
}
