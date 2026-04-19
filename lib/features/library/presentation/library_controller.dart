import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../../data/sync/cloud_sync_service.dart';
import '../../notebook/data/notebook_repository.dart';
import '../../notebook/domain/notebook.dart';

class LibraryController extends ChangeNotifier {
  LibraryController(this.repository, this.cloudSyncService);

  final NotebookRepository repository;
  final CloudSyncService cloudSyncService;
  bool isLoading = false;
  bool isSyncing = false;
  List<Notebook> items = <Notebook>[];
  String? selectedItemId;
  String selectedFolder = 'Inbox';
  String searchQuery = '';
  String? cloudPath;
  DateTime? lastSyncedAt;
  CloudSyncResult? lastSyncResult;
  final Set<String> _folders = <String>{};

  static const String _foldersFileName = 'library_folders.json';

  Future<void> initialize() async {
    await _loadFolders();
    await loadItems();
    await _loadCloudPath();
  }

  Future<void> loadItems() async {
    isLoading = true;
    notifyListeners();
    items = await repository.fetchNotebooks();
    if (items.isNotEmpty) {
      final folders = folderNames;
      if (folders.isNotEmpty) {
        selectedFolder = folders.first;
      }
      selectedItemId ??= _firstItemInFolder(selectedFolder)?.uid;
    }
    isLoading = false;
    notifyListeners();
  }

  Future<void> syncNow() async {
    isSyncing = true;
    notifyListeners();
    lastSyncResult = await cloudSyncService.sync(items);
    lastSyncedAt = DateTime.now();
    isSyncing = false;
    await loadItems();
    notifyListeners();
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
          .where((name) => name.trim().isNotEmpty),
      'Inbox',
    };
    final list = names.toList()..sort();
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
    await _saveFolders();
    notifyListeners();
  }

  Future<void> createNotebook() async {
    final notebook = await repository.createNotebook(folder: selectedFolder);
    items = [notebook, ...items];
    selectedItemId = notebook.uid;
    notifyListeners();
  }

  Future<void> createBoard() async {
    final board = await repository.createBoard(folder: selectedFolder);
    items = [board, ...items];
    selectedItemId = board.uid;
    notifyListeners();
  }

  Future<void> deleteItem(String uid) async {
    await repository.deleteNotebook(uid);
    items = items.where((item) => item.uid != uid).toList();
    if (selectedItemId == uid) {
      selectedItemId = _firstItemInFolder(selectedFolder)?.uid;
    }
    notifyListeners();
  }

  void selectItem(String uid) {
    selectedItemId = uid;
    notifyListeners();
  }

  void selectFolder(String folder) {
    selectedFolder = folder;
    selectedItemId = _firstItemInFolder(folder)?.uid;
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
    if (selectedItemId == null) {
      return null;
    }
    return items.firstWhere(
      (item) => item.uid == selectedItemId,
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
          decoded.whereType<String>().map((item) => item.trim()).where(
                (item) => item.isNotEmpty,
              ),
        );
    } catch (_) {}
  }

  Future<void> _saveFolders() async {
    try {
      final file = await _foldersFile();
      final payload = _folders.toList()..sort();
      await file.writeAsString(jsonEncode(payload));
    } catch (_) {}
  }

  Future<File> _foldersFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_foldersFileName');
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
}
