import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/drift/notes_database.dart';
import '../../../data/sync/api_client.dart';
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
  NotesDatabase? _database;
  NotebookRepository? _repository;
  EditorController? _editor;
  Map<String, dynamic>? _base;
  int _revision = 0;
  Timer? _pollTimer;
  Timer? _pushTimer;
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
      _repository = NotebookRepository(
        database,
        onChanged: (_) => _changed(),
      );
      _suppressChanges = true;
      try {
        final notebook = _decode(document.notebook);
        await _repository!.restoreNotebooksAtomically([notebook]);
        _editor = EditorController(
          repository: _repository!,
          notebook: notebook,
          saveDebounce: const Duration(milliseconds: 100),
        );
        _base = document.notebook;
        _revision = document.revision;
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
      setState(() => _status = 'Editing · All changes saved');
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
    _pushTimer?.cancel();
    _pushTimer = Timer(
      const Duration(milliseconds: 35),
      () => unawaited(_push()),
    );
    setState(() => _status = 'Unsaved changes');
  }

  Future<void> _push() async {
    if (_sending || _refreshing || _closed || !_dirty ||
        _base == null || _repository == null) {
      return;
    }
    _sending = true;
    _dirty = false;
    if (mounted) {
      setState(() => _status = 'Saving changes');
    }
    try {
      final original = _base!;
      final notebook = await _repository!.getNotebook(
        original['uid'] as String,
      );
      if (notebook == null) {
        throw StateError('Shared notebook is unavailable.');
      }
      final submitted = NotebookRepository.encodeNotebook(notebook);
      if (jsonEncode(submitted['pages']) ==
          jsonEncode(original['pages'])) {
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
      _base = _dirty ? submitted : answer.notebook;
      _revision = answer.revision;
      if (mounted) {
        setState(() {
          _status = 'All changes saved';
          _error = null;
        });
      }
      // The server can merge changes from several participants.
      if (!_dirty &&
          jsonEncode(answer.notebook['pages']) !=
              jsonEncode(submitted['pages'])) {
        await _installRemote(answer);
      }
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
    _pushTimer = Timer(
      const Duration(seconds: 3),
      () => unawaited(_push()),
    );
  }

  Future<void> _refresh() async {
    if (_closed || _sending || _refreshing || _dirty ||
        _repository == null || _editor == null) {
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
    }
  }

  Future<void> _installRemote(SharedStudyDocument snapshot) async {
    if (_repository == null || _dirty || !mounted) {
      return;
    }
    await _editor?.flushPendingSaves();
    if (_dirty || !mounted) {
      return;
    }
    _suppressChanges = true;
    try {
      final updated = _decode(snapshot.notebook);
      _editor?.dispose();
      _editor = null;
      await _repository!.importNotebooksAtomically(
        [updated],
        verifiedRemoteSync: true,
      );
      if (!mounted) {
        return;
      }
      _editor = EditorController(
        repository: _repository!,
        notebook: updated,
        saveDebounce: const Duration(milliseconds: 100),
      );
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
            if (jsonEncode(encoded) != jsonEncode(_base!)) {
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
          padding: const EdgeInsets.symmetric(
            horizontal: 16, vertical: 8,
          ),
          child: Column(
            children: [
              Text('Shared editing · $_status'),
              if (_error != null) Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
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
