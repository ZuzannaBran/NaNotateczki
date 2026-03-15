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
  List<Notebook> notebooks = <Notebook>[];
  String? selectedNotebookId;
  String searchQuery = '';
  String? cloudPath;
  DateTime? lastSyncedAt;
  CloudSyncResult? lastSyncResult;

  Future<void> initialize() async {
    await loadNotebooks();
    await _loadCloudPath();
  }

  Future<void> loadNotebooks() async {
    isLoading = true;
    notifyListeners();
    notebooks = await repository.fetchNotebooks();
    if (notebooks.isNotEmpty && selectedNotebookId == null) {
      selectedNotebookId = notebooks.first.uid;
    }
    isLoading = false;
    notifyListeners();
  }

  Future<void> syncNow() async {
    isSyncing = true;
    notifyListeners();
    lastSyncResult = await cloudSyncService.sync(notebooks);
    lastSyncedAt = DateTime.now();
    isSyncing = false;
    await loadNotebooks();
    notifyListeners();
  }

  Future<void> setCloudPath(String path) async {
    await cloudSyncService.setCloudPath(path);
    cloudPath = path;
    notifyListeners();
  }

  List<Notebook> get visibleNotebooks {
    if (searchQuery.isEmpty) {
      return notebooks;
    }
    final query = searchQuery.toLowerCase().trim();
    return notebooks.where((notebook) => _matches(notebook, query)).toList();
  }

  Future<void> createNotebook() async {
    final notebook = await repository.createNotebook();
    notebooks = [notebook, ...notebooks];
    selectedNotebookId = notebook.uid;
    notifyListeners();
  }

  Future<void> deleteNotebook(String uid) async {
    await repository.deleteNotebook(uid);
    notebooks = notebooks.where((item) => item.uid != uid).toList();
    if (selectedNotebookId == uid) {
      selectedNotebookId = notebooks.isEmpty ? null : notebooks.first.uid;
    }
    notifyListeners();
  }

  void selectNotebook(String uid) {
    selectedNotebookId = uid;
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
    final payload = repository.encodeNotebooks(notebooks);
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
    await loadNotebooks();
  }

  Notebook? selectedNotebook() {
    if (selectedNotebookId == null) {
      return null;
    }
    return notebooks.firstWhere(
      (item) => item.uid == selectedNotebookId,
      orElse: () => notebooks.first,
    );
  }

  Future<void> _loadCloudPath() async {
    cloudPath = await cloudSyncService.getCloudPath();
    notifyListeners();
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
