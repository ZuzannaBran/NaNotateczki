import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../features/notebook/data/notebook_repository.dart';
import '../../features/notebook/domain/notebook.dart';

class CloudSyncResult {
  CloudSyncResult({
    required this.totalNotebooks,
    required this.uploaded,
    required this.downloaded,
  });

  final int totalNotebooks;
  final int uploaded;
  final int downloaded;
}

class CloudSyncService {
  CloudSyncService(this.repository);

  final NotebookRepository repository;

  static const String _configFileName = 'cloud_sync.json';
  static const String _cloudFileName = 'notatek_cloud.json';

  Future<String?> getCloudPath() async {
    final file = await _configFile();
    if (!await file.exists()) {
      return null;
    }
    final data = jsonDecode(await file.readAsString());
    if (data is Map<String, dynamic>) {
      final path = data['path'];
      if (path is String && path.isNotEmpty) {
        return path;
      }
    }
    return null;
  }

  Future<void> setCloudPath(String path) async {
    final file = await _configFile();
    await file.writeAsString(jsonEncode({'path': path}));
  }

  Future<CloudSyncResult> sync(List<Notebook> local) async {
    final path = await getCloudPath();
    if (path == null || path.isEmpty) {
      throw Exception('Cloud folder not configured.');
    }
    final cloudDir = Directory(path);
    if (!await cloudDir.exists()) {
      await cloudDir.create(recursive: true);
    }

    final cloudFile = File('${cloudDir.path}/$_cloudFileName');
    final cloudNotebooks = await _readCloudNotebooks(cloudFile);
    final merged = _mergeNotebooks(local, cloudNotebooks);

    for (final notebook in merged) {
      await repository.saveNotebook(notebook);
    }

    final payload = repository.encodeNotebooks(merged);
    await cloudFile.writeAsString(jsonEncode(payload));

    return CloudSyncResult(
      totalNotebooks: merged.length,
      uploaded: _countNewer(local, cloudNotebooks),
      downloaded: _countNewer(cloudNotebooks, local),
    );
  }

  Future<List<Notebook>> _readCloudNotebooks(File file) async {
    if (!await file.exists()) {
      return <Notebook>[];
    }
    final content = await file.readAsString();
    final data = jsonDecode(content);
    if (data is! List<dynamic>) {
      return <Notebook>[];
    }
    return repository.decodeNotebooks(data);
  }

  List<Notebook> _mergeNotebooks(List<Notebook> local, List<Notebook> cloud) {
    final Map<String, Notebook> merged = {
      for (final notebook in cloud) notebook.uid: notebook,
    };
    for (final notebook in local) {
      final existing = merged[notebook.uid];
      if (existing == null) {
        merged[notebook.uid] = notebook;
        continue;
      }
      merged[notebook.uid] = notebook.updatedAt.isAfter(existing.updatedAt)
          ? notebook
          : existing;
    }
    return merged.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  int _countNewer(List<Notebook> source, List<Notebook> target) {
    final Map<String, Notebook> map = {
      for (final notebook in target) notebook.uid: notebook,
    };
    var count = 0;
    for (final notebook in source) {
      final existing = map[notebook.uid];
      if (existing == null || notebook.updatedAt.isAfter(existing.updatedAt)) {
        count++;
      }
    }
    return count;
  }

  Future<File> _configFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_configFileName');
  }
}
