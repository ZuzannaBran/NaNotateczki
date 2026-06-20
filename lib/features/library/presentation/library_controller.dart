import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/error/app_error_log.dart';
import '../../../data/backup/local_backup_service.dart';
import '../../../data/sync/cloud_sync_service.dart';
import '../../notebook/data/notebook_repository.dart';
import '../../notebook/domain/notebook.dart';

class LibraryController extends ChangeNotifier {
  LibraryController(
    this.repository,
    this.cloudSyncService,
    this.backup, {
    this.wasReset = false,
    this.freshFile = false,
    this.resetReason,
  });

  final NotebookRepository repository;
  final CloudSyncService cloudSyncService;
  final LocalBackupService backup;
  final bool wasReset;
  final bool freshFile;
  final String? resetReason;
  int autoRestoreCount = 0;
  bool _bannerDismissed = false;
  bool isLoading = false;
  bool isSyncing = false;
  bool isLoadingSelectedItem = false;
  bool isRecoveringCorruptDocuments = false;
  List<Notebook> items = <Notebook>[];
  String? selectedItemId;
  String selectedFolder = '';
  String searchQuery = '';
  String? cloudPath;
  DateTime? lastSyncedAt;
  CloudSyncResult? lastSyncResult;
  Object? loadError;
  final Set<String> _folders = <String>{};
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

  Future<void> initialize() async {
    await _loadFolders();
    await loadItems();
    await _loadCloudPath();
  }

  Future<void> loadItems() async {
    isLoading = true;
    notifyListeners();
    try {
      final loadedItems = await repository.fetchNotebooks();
      items = loadedItems;
      loadError = null;
      await _refreshCorruptRecoveryState();

      if (items.isEmpty &&
          (wasReset || freshFile) &&
          await backup.hasLatest()) {
        autoRestoreCount = await backup.restoreFromLatest();
        if (autoRestoreCount > 0) {
          items = await repository.fetchNotebooks();
          await _refreshCorruptRecoveryState();
        } else {
          AppErrorLog.instance.record(
            'Database restore was attempted after startup reset, but no '
            'documents were restored from the local backup.',
            null,
            source: 'LibraryController.loadItems(reset_restore_empty)',
          );
        }
      } else if (items.isEmpty && (wasReset || freshFile)) {
        AppErrorLog.instance.record(
          'Database reset/fresh start detected, but no local backup snapshot '
          'was available for restore.',
          null,
          source: 'LibraryController.loadItems(reset_without_backup)',
        );
      }

      if (items.isNotEmpty) {
        final folders = folderNames;
        if (folders.isNotEmpty) {
          selectedFolder = folders.first;
        }
        selectedItemId ??= _firstItemInFolder(selectedFolder)?.uid;
        if (_activeNotebook == null && selectedItemId != null) {
          _activeNotebook = _itemById(selectedItemId!);
        }
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
      notifyListeners();
    }
  }

  Future<int> restoreCorruptDocumentsFromBackup() async {
    if (recoverableCorruptDocuments.isEmpty) {
      _corruptRecoveryDismissed = true;
      AppErrorLog.instance.record(
        'Corrupt documents were detected, but no recoverable local backup '
        'copies were found.',
        null,
        source:
            'LibraryController.restoreCorruptDocumentsFromBackup(no_candidates)',
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
        selectedItemId ??= _firstItemInFolder(selectedFolder)?.uid;
        _activeNotebook = selectedItemId == null
            ? null
            : _itemById(selectedItemId!);
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

  Future<void> syncNow() async {
    isSyncing = true;
    notifyListeners();
    try {
      lastSyncResult = await cloudSyncService.sync(items);
      lastSyncedAt = DateTime.now();
      await loadItems();
    } finally {
      isSyncing = false;
      notifyListeners();
    }
  }

  Future<void> setCloudPath(String path) async {
    await cloudSyncService.setCloudPath(path);
    cloudPath = path;
    notifyListeners();
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
    final list = names.toList()..sort(_compareFolderNames);
    return list;
  }

  Future<void> createFolder(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return;
    }
    _folders.add(trimmed);
    selectedFolder = trimmed;
    selectedItemId = _firstItemInFolder(trimmed)?.uid;
    _activeNotebook = selectedItemId == null
        ? null
        : _itemById(selectedItemId!);
    await _saveFolders();
    notifyListeners();
  }

  Future<void> renameFolder(String oldName, String newName) async {
    final trimmedOldName = oldName.trim();
    final trimmedNewName = newName.trim();
    if (trimmedOldName.isEmpty ||
        trimmedNewName.isEmpty ||
        trimmedOldName == trimmedNewName) {
      return;
    }

    _folders
      ..remove(trimmedOldName)
      ..add(trimmedNewName);
    final updatedItems = <Notebook>[];
    for (final item in items) {
      if (item.folder != trimmedOldName) {
        updatedItems.add(item);
        continue;
      }

      final updated = await repository.updateNotebookMetadata(
        item.uid,
        folder: trimmedNewName,
      );
      updatedItems.add(updated ?? item);
    }

    items = updatedItems;
    if (selectedFolder == trimmedOldName) {
      selectedFolder = trimmedNewName;
    }
    if (_activeNotebook?.folder == trimmedOldName) {
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
  }

  Future<void> deleteFolder(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return;
    }

    _folders.remove(trimmed);
    for (final item in items) {
      if (item.folder != trimmed) {
        continue;
      }

      await repository.deleteNotebook(item.uid);
    }

    items = items.where((item) => item.folder != trimmed).toList();
    if (selectedFolder == trimmed) {
      selectedFolder = folderNames.isEmpty ? '' : folderNames.first;
    }
    if (_activeNotebook?.folder == trimmed) {
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

  Future<void> selectItem(String uid) async {
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
    final dir = await getApplicationDocumentsDirectory();
    final file = File(
      '${dir.path}/notatek_backup_${DateTime.now().millisecondsSinceEpoch}.json',
    );
    final payload = repository.encodeNotebooks(items);
    await file.writeAsString(jsonEncode(payload));
    return file.path;
  }

  Future<void> importBackup(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('Backup file not found.');
    }
    final content = await file.readAsString();
    final data = jsonDecode(content) as List<dynamic>;
    final decoded = repository.decodeNotebooks(data);
    for (final notebook in decoded) {
      await repository.saveNotebook(notebook);
    }
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
    if (items.isEmpty) {
      return null;
    }
    return items.firstWhere(
      (item) => item.uid == uid,
      orElse: () => items.first,
    );
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

  Future<void> _loadCloudPath() async {
    cloudPath = await cloudSyncService.getCloudPath();
    notifyListeners();
  }

  Future<void> _loadFolders() async {
    try {
      final file = await _foldersFile();
      if (!await file.exists()) {
        return;
      }
      final content = await file.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is! List) {
        return;
      }
      _folders
        ..clear()
        ..addAll(
          decoded
              .whereType<String>()
              .map((item) => item.trim())
              .where((item) => item.isNotEmpty),
        );
    } catch (e) {
      debugPrint('LibraryController._loadFolders failed: $e');
    }
  }

  Future<void> _saveFolders() async {
    try {
      final file = await _foldersFile();
      final payload = _folders.toList()..sort(_compareFolderNames);
      await file.writeAsString(jsonEncode(payload));
    } catch (e) {
      debugPrint('LibraryController._saveFolders failed: $e');
    }
  }

  Future<File> _foldersFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_foldersFileName');
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

    final backupNotebooks = await backup.readLatest();
    final existingUids = items.map((item) => item.uid).toSet();
    final corruptUids = repository.lastCorruptNotebookIds.toSet();
    recoverableCorruptDocuments =
        backupNotebooks
            .where(
              (item) =>
                  !existingUids.contains(item.uid) ||
                  corruptUids.contains(item.uid),
            )
            .toList()
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
