import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/drift/notes_database.dart';
import '../../../data/sync/api_client.dart';
import '../../../data/sync/shared_edit_conflicts.dart';
import '../../../data/sync/study_share_guest_outbox.dart';
import '../../../data/sync/study_share_service.dart';
import '../../board/presentation/board_screen.dart';
import '../../editor/state/editor_controller.dart';
import '../../notebook/data/notebook_repository.dart';
import '../../notebook/domain/notebook.dart';
import '../../notebook/domain/notebook_kind.dart';
import '../../notebook/presentation/notebook_screen.dart';
import 'study_share_memory_db_stub.dart'
    if (dart.library.js_interop) 'study_share_memory_db_web.dart'
    as guest_db;

/// An independent editor for one invited document, never the user's library.
class StudyShareGuestEditor extends StatefulWidget {
  const StudyShareGuestEditor({
    required this.shareId,
    required this.ticket,
    required this.client,
    required this.updateRevision,
    required this.onEnded,
    super.key,
  });

  final String shareId;
  final String ticket;
  final StudyShareGuestClient client;
  final int updateRevision;
  final VoidCallback onEnded;

  @override
  State<StudyShareGuestEditor> createState() => _StudyShareGuestEditorState();
}

class _StudyShareGuestEditorState extends State<StudyShareGuestEditor> {
  late final StudyShareGuestOutbox _outbox = StudyShareGuestOutbox(
    widget.shareId,
  );
  Future<void> _persistTail = Future<void>.value();
  bool _outboxFailed = false;
  NotesDatabase? _database;
  NotebookRepository? _repository;
  EditorController? _editor;
  Map<String, dynamic>? _base;
  int _revision = 0;
  Timer? _pollTimer;
  Timer? _pushTimer;
  Timer? _remoteRetryTimer;
  SharedStudyDocument? _deferredRemote;
  bool _suppressChanges = false;
  bool _dirty = false;
  bool _sending = false;
  bool _refreshing = false;
  bool _closed = false;
  String? _error;
  String _status = 'Connecting to shared document';

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final document = await widget.client.readDocument(
        widget.shareId,
        widget.ticket,
      );
      if (!mounted) {
        return;
      }
      // The guest's database exists only in memory, never in the
      // account's IndexedDB or in a permanent guest browser profile.
      final database = await guest_db.openSharedGuestDatabase();
      if (!mounted) {
        await database.close();
        return;
      }
      _database = database;
      _repository = NotebookRepository(database, onChanged: (_) => _changed());
      _suppressChanges = true;
      var recovered = false;
      try {
        var notebook = _decode(document.notebook);
        await _repository!.restoreNotebooksAtomically([notebook]);
        _base = document.notebook;
        _revision = document.revision;
        PendingStudyShareEdit? pending;
        try {
          pending = await _outbox.read();
        } catch (error) {
          _outboxFailed = true;
          _error = 'Stored guest edits need manual recovery: $error';
        }
        if (pending != null) {
          if (pending.notebook['uid'] != document.notebook['uid']) {
            throw const FormatException(
              'Recovered edit belongs to another document.',
            );
          }
          notebook = _decode(pending.notebook);
          await _repository!.importNotebooksAtomically([
            notebook,
          ], verifiedRemoteSync: true);
          _base = pending.baseNotebook;
          _revision = pending.baseRevision;
          _dirty = true;
          recovered = true;
        }
        _editor = EditorController(
          repository: _repository!,
          notebook: notebook,
          saveDebounce: const Duration(milliseconds: 20),
        );
      } finally {
        _suppressChanges = false;
      }
      if (!mounted) {
        return;
      }
      _pollTimer = Timer.periodic(
        const Duration(seconds: 15),
        (_) => unawaited(_refresh()),
      );
      setState(() {
        _status = recovered
            ? 'Restored unsent changes · Saving'
            : 'Editing · All changes saved';
      });
      if (recovered) {
        _pushTimer = Timer(
          const Duration(milliseconds: 35),
          () => unawaited(_push()),
        );
      } else {
        // Close the gap between the first read and WebSocket auth.
        unawaited(_refresh());
      }
    } on ApiException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 410) {
        widget.onEnded();
      } else if (mounted) {
        setState(() => _error = error.message);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not open shared editor: $error');
      }
    }
  }

  Notebook _decode(Map<String, dynamic> json) {
    return _repository!.decodeBackupStrict([json]).single;
  }

  void _changed() {
    if (!mounted || _suppressChanges || _closed) {
      return;
    }
    _dirty = true;
    unawaited(_persistPending());
    _pushTimer?.cancel();
    _pushTimer = Timer(
      const Duration(milliseconds: 35),
      () => unawaited(_push()),
    );
    setState(() => _status = 'Unsaved changes');
  }

  Future<void> _persistPending() {
    // Serialized storage writes cannot revert a newer snapshot.
    final task = _persistTail.catchError((Object _) {}).then((_) async {
      if (_repository == null || _base == null) {
        return;
      }
      final notebook = await _repository!.getNotebook(_base!['uid'] as String);
      if (notebook == null) {
        throw StateError('Local guest document is unavailable.');
      }
      await _outbox.write(
        PendingStudyShareEdit(
          baseRevision: _revision,
          baseNotebook: _base!,
          notebook: NotebookRepository.encodeNotebook(notebook),
        ),
      );
      _outboxFailed = false;
    });
    _persistTail = task;
    unawaited(
      task.catchError((Object error) {
        _outboxFailed = true;
        if (mounted) {
          setState(() {
            _error =
                'Browser recovery failed: $error. '
                'Keep this tab open until changes are saved on the server.';
          });
        }
      }),
    );
    return task;
  }

  Future<void> _clearPending() async {
    try {
      await _persistTail;
      if (!_dirty && !_closed) {
        await _outbox.clear();
        _outboxFailed = false;
      }
    } catch (_) {
      // The pending snapshot remains available for manual recovery.
    }
  }

  Future<void> _push() async {
    if (_sending ||
        _refreshing ||
        _closed ||
        !_dirty ||
        _base == null ||
        _repository == null) {
      return;
    }
    _sending = true;
    if (mounted) {
      setState(() => _status = 'Saving changes');
    }
    try {
      await _editor?.flushPendingSaves();
      await _repository!.waitForPendingSaves();
      try {
        await _persistPending();
      } catch (_) {
        // Network transmission is still useful when storage quota is full.
      }
      _dirty = false;
      final original = _base!;
      final notebook = await _repository!.getNotebook(
        original['uid'] as String,
      );
      if (notebook == null) {
        throw StateError('Shared notebook is unavailable.');
      }
      final submitted = NotebookRepository.encodeNotebook(notebook);
      if (jsonEncode(submitted['pages']) == jsonEncode(original['pages'])) {
        await _clearPending();
        if (mounted) {
          setState(() => _status = 'All changes saved');
        }
        return;
      }
      final answer = await widget.client.writeDocument(
        widget.shareId,
        widget.ticket,
        baseRevision: _revision,
        baseNotebook: original,
        notebook: submitted,
      );
      final rejected = hasRejectedSharedEdits(
        original,
        submitted,
        answer.notebook,
      );
      // Even if more input arrived during the request, the next diff must
      // use the authoritative server snapshot, not the submitted one.
      _base = answer.notebook;
      _revision = answer.revision;
      if (rejected) {
        _dirty = true;
        if (mounted) {
          setState(() {
            _error =
                'A concurrent edit took precedence. Your changes '
                'remain in this tab but were not fully saved.';
            _status = 'Changes not saved';
          });
        }
        return;
      }
      if (mounted) {
        setState(() {
          _status = _dirty ? 'Unsaved changes' : 'All changes saved';
          _error = null;
        });
      }
      // The server can merge changes from several participants.
      if (!_dirty &&
          jsonEncode(answer.notebook['pages']) !=
              jsonEncode(submitted['pages'])) {
        await _installRemote(answer);
      }
      await _clearPending();
    } on ApiException catch (error) {
      _dirty = true;
      if (error.statusCode == 401 || error.statusCode == 410) {
        widget.onEnded();
      } else if (mounted) {
        setState(() {
          _error = error.statusCode == 409
              ? 'Another participant changed the same object. '
                    'Your local changes are preserved; resolve the conflict '
                    'before leaving this tab.'
              : error.message;
          _status = 'Changes not saved';
        });
        if (error.statusCode != 409) {
          _retry();
        }
      }
    } catch (error) {
      _dirty = true;
      if (mounted) {
        setState(() {
          _error = '$error';
          _status = 'Changes not saved';
        });
        _retry();
      }
    } finally {
      _sending = false;
      if (_dirty && _error == null && mounted) {
        _pushTimer?.cancel();
        _pushTimer = Timer(
          const Duration(milliseconds: 35),
          () => unawaited(_push()),
        );
      }
    }
  }

  void _retry() {
    if (_closed || !mounted) {
      return;
    }
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(seconds: 3), () => unawaited(_push()));
  }

  Future<void> _refresh() async {
    if (_closed ||
        _sending ||
        _refreshing ||
        _dirty ||
        _repository == null ||
        _editor == null) {
      return;
    }
    _refreshing = true;
    try {
      final latest = await widget.client.readDocument(
        widget.shareId,
        widget.ticket,
      );
      if (latest.revision <= _revision || !mounted || _dirty) {
        return;
      }
      // Flush any text still being edited before changing the controller.
      await _editor!.flushPendingSaves();
      if (_dirty || !mounted) {
        return;
      }
      await _installRemote(latest);
    } on ApiException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 410) {
        widget.onEnded();
      }
    } catch (_) {
      // The next poll will reconcile after reconnect.
    } finally {
      _refreshing = false;
      // A push timer may have fired while the remote read was in flight.
      // Re-arm it so the locally saved edit cannot remain dirty forever.
      if (_dirty && !_sending && !_closed && mounted) {
        _retry();
      }
    }
  }

  Future<void> _installRemote(SharedStudyDocument snapshot) async {
    if (_repository == null || !mounted || _closed) {
      return;
    }
    final editor = _editor;
    if (_dirty || editor == null ||
        !editor.canApplyConfirmedRemoteNotebook) {
      _deferRemote(snapshot);
      return;
    }
    _suppressChanges = true;
    try {
      final updated = _decode(snapshot.notebook);
      await _repository!.importNotebooksAtomically([
        updated,
      ], verifiedRemoteSync: true);
      if (!mounted || _dirty) {
        return;
      }
      // The editor owns the guest's page, pan and zoom. Refresh the pages
      // without disposing it or remounting the board/notebook viewport.
      if (!editor.applyConfirmedRemoteNotebook(updated)) {
        _deferRemote(snapshot);
        return;
      }
      _deferredRemote = null;
      _remoteRetryTimer?.cancel();
      _base = snapshot.notebook;
      _revision = snapshot.revision;
      setState(() {
        _status = 'All changes saved';
        _error = null;
      });
    } finally {
      _suppressChanges = false;
    }
  }

  void _deferRemote(SharedStudyDocument snapshot) {
    if (_closed || !mounted) {
      return;
    }
    final pending = _deferredRemote;
    if (pending == null || snapshot.revision >= pending.revision) {
      _deferredRemote = snapshot;
    }
    _remoteRetryTimer?.cancel();
    _remoteRetryTimer = Timer(const Duration(milliseconds: 150), () {
      final latest = _deferredRemote;
      if (latest != null && mounted && !_closed) {
        unawaited(_installRemote(latest));
      }
    });
  }

  @override
  void didUpdateWidget(covariant StudyShareGuestEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.updateRevision != oldWidget.updateRevision) {
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    _closed = true;
    _pushTimer?.cancel();
    _pollTimer?.cancel();
    _remoteRetryTimer?.cancel();
    final editor = _editor;
    final database = _database;
    final repository = _repository;
    unawaited(() async {
      try {
        await editor?.flushPendingSaves();
        if (repository != null && _base != null) {
          final notebook = await repository.getNotebook(
            _base!['uid'] as String,
          );
          if (notebook != null) {
            final encoded = NotebookRepository.encodeNotebook(notebook);
            if (jsonEncode(encoded['pages']) != jsonEncode(_base!['pages'])) {
              try {
                await _persistPending();
              } catch (_) {
                // Keep any older snapshot if final persistence fails.
              }
              await widget.client.writeDocument(
                widget.shareId,
                widget.ticket,
                baseRevision: _revision,
                baseNotebook: _base!,
                notebook: encoded,
              );
            }
          }
        }
      } catch (_) {
        // A closed or expired guest cannot push further changes.
      } finally {
        editor?.dispose();
        await database?.close();
      }
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editor = _editor;
    if (editor == null) {
      return Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(20),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              Text('Shared editing · $_status'),
              if (_outboxFailed)
                const Text('Browser recovery is currently unavailable.'),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        Expanded(
          child: ChangeNotifierProvider<EditorController>.value(
            value: editor,
            child: editor.notebook.kind == NotebookKind.board
                ? BoardScreen(title: editor.notebook.title)
                : NotebookScreen(title: editor.notebook.title),
          ),
        ),
      ],
    );
  }
}
