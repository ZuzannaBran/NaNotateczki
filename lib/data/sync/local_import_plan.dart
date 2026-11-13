import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../features/editor/state/editor_operation_bridge.dart';
import '../../features/notebook/domain/image_block.dart';
import '../../features/notebook/domain/notebook.dart';
import '../../features/notebook/domain/note_page.dart';

/// Stable, account-scoped identity for retries of an explicit Local import.
String importedLocalUid(String accountId, String type, String sourceId) {
  if (accountId.isEmpty || type.isEmpty || sourceId.isEmpty) {
    throw ArgumentError('Local import identities must not be empty.');
  }
  final bytes = sha256
      .convert(utf8.encode(jsonEncode([accountId, type, sourceId])))
      .bytes
      .take(16)
      .toList();
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

Map<String, dynamic> decodeLocalImportMetadata(String? content) {
  if (content == null) {
    return <String, dynamic>{};
  }
  final decoded = jsonDecode(content);
  if (decoded is Map<String, dynamic>) {
    return decoded;
  }
  if (decoded is List) {
    return <String, dynamic>{'folders': decoded};
  }
  throw const FormatException('Invalid Local import metadata.');
}

class LocalImportDocument {
  const LocalImportDocument({
    required this.source,
    required this.targetId,
    required this.title,
    required this.exists,
  });

  final Notebook source;
  final String targetId;
  final String title;
  final bool exists;
}

/// Builds a deterministic, additive transfer without mutating either store.
class LocalImportPlan {
  LocalImportPlan({
    required this.accountId,
    required List<Notebook> local,
    required List<Notebook> account,
  }) {
    final targetIds = {for (final item in account) item.uid};
    final titles = {
      for (final item in account) _titleKey(item.folder, item.title),
    };
    final sources = <String>{};
    for (final notebook in local) {
      if (!sources.add(notebook.uid)) {
        throw StateError('Duplicate Local document UID.');
      }
      final targetId = documentUid(notebook.uid);
      if (targetIds.contains(targetId)) {
        documents.add(
          LocalImportDocument(
            source: notebook,
            targetId: targetId,
            title: notebook.title,
            exists: true,
          ),
        );
        continue;
      }
      var title = notebook.title;
      if (titles.contains(_titleKey(notebook.folder, title))) {
        var suffix = 1;
        while (titles.contains(
          _titleKey(notebook.folder, '${notebook.title} ($suffix)'),
        )) {
          suffix++;
        }
        title = '${notebook.title} ($suffix)';
      }
      titles.add(_titleKey(notebook.folder, title));
      documents.add(
        LocalImportDocument(
          source: notebook,
          targetId: targetId,
          title: title,
          exists: false,
        ),
      );
    }
  }

  final String accountId;
  final List<LocalImportDocument> documents = [];
  String documentUid(String sourceId) =>
      importedLocalUid(accountId, 'document', sourceId);

  static String _titleKey(String folder, String title) =>
      '${folder.toLowerCase()}\u0000${title.toLowerCase()}';

  /// Fresh pages and objects prevent accidental aliasing with another user.
  /// Every image/PDF is copied as bytes, never as a Local filesystem path.
  Future<Notebook> materialize(LocalImportDocument entry) async {
    final source = entry.source;
    final pages = <NotePage>[];
    for (final page in source.pages) {
      final images = <ImageBlock>[];
      for (final image in page.imageBlocks) {
        final original = image.bytes;
        final Uint8List bytes;
        if (original != null && original.isNotEmpty) {
          bytes = Uint8List.fromList(original);
        } else {
          if (kIsWeb || image.path.isEmpty) {
            throw StateError('Local media has no recoverable bytes.');
          }
          bytes = await File(image.path).readAsBytes();
        }
        if (bytes.isEmpty) {
          throw StateError('Local media is empty.');
        }
        // The source file extension must survive clearing the Local path:
        // the v2 asset uploader uses it when mediaType was not persisted.
        final extension = (image.imageExt ?? image.path.split('.').last)
            .toLowerCase();
        images.add(
          image.copyWith(
            id: importedLocalUid(accountId, 'image:${source.uid}', image.id),
            path: '',
            bytes: bytes,
            imageExt: extension.isEmpty ? null : extension,
          ),
        );
      }
      for (final block in page.textBlocks) {
        // An embed cannot be safely copied without its verified asset bytes.
        if (EditorOperationBridge.quillEmbeds(block.deltaJson).isNotEmpty) {
          throw UnsupportedError(
            'Local Quill embeds require verified asset migration.',
          );
        }
      }
      pages.add(
        page.copyWith(
          id: importedLocalUid(accountId, 'page:${source.uid}', page.id),
          textBlocks: [
            for (final block in page.textBlocks)
              block.copyWith(
                id: importedLocalUid(accountId, 'text:${source.uid}', block.id),
              ),
          ],
          imageBlocks: images,
          inkStrokes: [
            for (final stroke in page.inkStrokes)
              stroke.copyWith(
                id: importedLocalUid(accountId, 'ink:${source.uid}', stroke.id),
              ),
          ],
        ),
      );
    }
    return source.copyWith(
      uid: entry.targetId,
      title: entry.title,
      pages: pages,
    );
  }

  /// The destination's covers, recent colors and existing tasks win.
  Map<String, dynamic> mergeLibrary({
    required Map<String, dynamic> local,
    required Map<String, dynamic> account,
  }) {
    final folders = <String>{
      if (account['folders'] is List)
        ...(account['folders'] as List).whereType<String>(),
      if (local['folders'] is List)
        ...(local['folders'] as List).whereType<String>(),
      for (final document in documents) document.source.folder,
    };
    final covers = <String, dynamic>{
      if (account['covers'] is Map)
        ...Map<String, dynamic>.from(account['covers'] as Map),
    };
    if (local['covers'] is Map) {
      for (final pair in (local['covers'] as Map).entries) {
        if (pair.key is String) {
          covers.putIfAbsent(pair.key as String, () => pair.value);
        }
      }
    }
    final tasks = <String, dynamic>{
      if (account['plannerTasks'] is Map)
        ...Map<String, dynamic>.from(account['plannerTasks'] as Map),
    };
    final sourceTasks = local['plannerTasks'];
    if (sourceTasks is Map) {
      for (final item in documents) {
        final list = sourceTasks[item.source.uid];
        if (list is! List) {
          continue;
        }
        final existing = (tasks[item.targetId] as List?) ?? [];
        final byId = <String, dynamic>{
          for (final raw in existing)
            if (raw is Map && raw['id'] is String) raw['id'] as String: raw,
        };
        for (final raw in list) {
          if (raw is! Map || raw['id'] is! String) {
            throw const FormatException('Invalid imported planner task.');
          }
          final id = importedLocalUid(
            accountId,
            'task:${item.source.uid}',
            raw['id'] as String,
          );
          byId.putIfAbsent(id, () => {...raw, 'id': id});
        }
        tasks[item.targetId] = byId.values.toList();
      }
    }
    return {
      ...account,
      'folders': folders.toList()..sort(),
      'covers': covers,
      'plannerTasks': tasks,
      'recentCoverColors': account['recentCoverColors'] ?? <int>[],
    };
  }

  /// Add only source entries not already copied or deleted on the account.
  List<Map<String, dynamic>> newPlannerEntries({
    required Map<String, dynamic> local,
    required Iterable<String> accountIds,
    required Iterable<String> accountTombstones,
  }) {
    final known = {...accountIds, ...accountTombstones};
    final source = local['sessions'];
    if (source == null) {
      return [];
    }
    if (source is! List) {
      throw const FormatException('Invalid Local study planner.');
    }
    final result = <Map<String, dynamic>>[];
    for (final raw in source) {
      if (raw is! Map<String, dynamic> ||
          raw['id'] is! String ||
          (raw['id'] as String).isEmpty) {
        throw const FormatException('Invalid Local study entry.');
      }
      final originalId = raw['id'] as String;
      final newId = importedLocalUid(accountId, 'study', originalId);
      if (!known.add(newId)) {
        continue;
      }
      result.add({
        ...raw,
        'id': newId,
        if (raw['seriesId'] is String)
          'seriesId': importedLocalUid(
            accountId,
            'study',
            raw['seriesId'] as String,
          ),
      });
    }
    return result;
  }
}
