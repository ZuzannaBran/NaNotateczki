import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

/// An isolated set of database, assets, preferences and operation queues.
///
/// The root account profile and credentials are deliberately not stored here.
enum StorageNamespaceKind { local, account, share }

class StorageNamespace {
  const StorageNamespace._(this.kind, this.relativePath);

  factory StorageNamespace.local() =>
      const StorageNamespace._(StorageNamespaceKind.local, 'local');

  factory StorageNamespace.account(String userId) => StorageNamespace._(
    StorageNamespaceKind.account,
    'accounts/${_digest(userId)}',
  );

  factory StorageNamespace.share(String shareId, String guestActorId) =>
      StorageNamespace._(
        StorageNamespaceKind.share,
        'shares/${_digest('$shareId:$guestActorId')}',
      );

  final StorageNamespaceKind kind;
  final String relativePath;

  /// Use this with NotesDatabase.open(databaseName: ...).
  String get nativeDatabaseName => '$relativePath/notes.sqlite';

  /// IndexedDB databases must never share a name across account identities.
  String get webDatabaseName =>
      'nanotateczki_${relativePath.replaceAll('/', '_')}';

  /// Native files are relative to Application Support/data. Web keys use
  /// the same prefix in localStorage, without sharing the legacy keys.
  String fileKey(String name) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\')) {
      throw ArgumentError.value(name, 'name', 'Invalid storage file name');
    }
    return '$relativePath/$name';
  }

  String get imageDirectory => '$relativePath/images';
  String get backupDirectory => '$relativePath/local_backup';

  static String _digest(String identity) {
    if (identity.trim().isEmpty || identity.length > 512) {
      throw ArgumentError.value(identity, 'identity', 'Invalid identity');
    }
    return sha256.convert(utf8.encode(identity)).toString().substring(0, 40);
  }

  @override
  bool operator ==(Object other) =>
      other is StorageNamespace &&
      kind == other.kind &&
      relativePath == other.relativePath;

  @override
  int get hashCode => Object.hash(kind, relativePath);
}

/// A serial switch fence. Network callbacks must capture [generation] and
/// verify [accepts] before applying changes to a newly selected account.
///
/// The caller owns service shutdown, transaction flush and database opening.
/// In particular, this class does not automatically migrate legacy data.
class StorageNamespaceManager {
  StorageNamespaceManager({StorageNamespace? initial})
    : _current = initial ?? StorageNamespace.local();

  StorageNamespace _current;
  int _generation = 0;
  bool _active = true;
  Future<void> _tail = Future<void>.value();

  StorageNamespace get current => _current;
  int get generation => _generation;
  bool get isActive => _active;

  bool accepts(StorageNamespace namespace, int expectedGeneration) =>
      _active && _current == namespace && _generation == expectedGeneration;

  Future<void> switchTo(
    StorageNamespace next, {
    required Future<void> Function() stopAndFlush,
    required Future<void> Function(StorageNamespace) open,
  }) {
    final result = _tail.then((_) async {
      if (_current == next && _active) {
        return;
      }
      // On failure stay fenced off: the old database may already be closed.
      _active = false;
      _generation++;
      await stopAndFlush();
      await open(next);
      _current = next;
      _active = true;
      _generation++;
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
