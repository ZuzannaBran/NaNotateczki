import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:drift/drift.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show TextEditingController;
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_quill/quill_delta.dart' as quill_delta;
import 'package:flutter_quill_delta_from_html/flutter_quill_delta_from_html.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:uuid/uuid.dart';

import '../../../core/input/ink_activity_tracker.dart';
import '../../../core/storage/app_data_directory.dart';
import '../../../core/storage/app_save_coordinator.dart';
import '../../../core/storage/text_storage.dart';
import '../../../data/sync/editor_history_checkpoint.dart';
import '../../../data/sync/editor_history_notebook_codec.dart';
import '../../../data/sync/editor_history_store.dart';
import '../../../data/sync/operation_protocol.dart';
import '../../../data/sync/share_text_edit_adapter.dart';
import '../../notebook/data/notebook_repository.dart';
import '../../notebook/domain/drawing_tool.dart';
import '../../notebook/domain/image_block.dart';
import '../../notebook/domain/ink_spatial_index.dart';
import '../../notebook/domain/ink_stroke.dart';
import '../../notebook/domain/note_page.dart';
import '../../notebook/domain/notebook.dart';
import '../../notebook/domain/notebook_kind.dart';
import '../../notebook/domain/text_block.dart';
import 'editor_actions.dart';
import 'editor_operation_bridge.dart';
import 'editor_v2_operation_writer.dart';
import 'input_mode.dart';
import 'ink_color_presets.dart';
import 'page_background.dart';
import 'quill_paste_plan.dart';
import 'quill_style_patch.dart';

class _EditorHistoryEntry {
  const _EditorHistoryEntry(this.pageId, this.action);

  final String pageId;
  final EditorAction action;
}

class _V2HistoryEntry {
  const _V2HistoryEntry(
    this.before,
    this.after,
    this.operationId, {
    required this.stored,
  });

  _V2HistoryEntry.recovered(StoredEditorGesture gesture)
    : before = null,
      after = null,
      operationId = gesture.operationId,
      stored = gesture;

  final Notebook? before;
  final Notebook? after;
  final String operationId;
  final StoredEditorGesture stored;
}

class _V2TextGesture {
  _V2TextGesture(this.before);

  final Notebook before;
  String? lastOperationId;
}

class _V2GestureCheckpoint {
  const _V2GestureCheckpoint(this.target, this.textGesture, this.recordHistory);

  final Notebook target;
  final _V2TextGesture? textGesture;
  final bool recordHistory;
}

class LassoSelection {
  LassoSelection({
    required this.pageIndex,
    required this.bounds,
    required this.strokeIds,
    required this.textBlockIds,
    required this.imageBlockIds,
    this.delta = Offset.zero,
  });

  final int pageIndex;
  final Rect bounds;
  final List<String> strokeIds;
  final List<String> textBlockIds;
  final List<String> imageBlockIds;
  final Offset delta;

  LassoSelection copyWith({Offset? delta, Rect? bounds}) {
    return LassoSelection(
      pageIndex: pageIndex,
      bounds: bounds ?? this.bounds,
      strokeIds: strokeIds,
      textBlockIds: textBlockIds,
      imageBlockIds: imageBlockIds,
      delta: delta ?? this.delta,
    );
  }

  bool get isEmpty =>
      strokeIds.isEmpty && textBlockIds.isEmpty && imageBlockIds.isEmpty;
}

bool _sameInkStrokeIds(List<InkStroke> a, List<InkStroke> b) {
  return listEquals(
    a.map((stroke) => stroke.id).toList(),
    b.map((stroke) => stroke.id).toList(),
  );
}

class EditorController extends ChangeNotifier {
  static const double minViewScale = 0.25;
  static const double maxViewScale = 4.0;
  static const Duration defaultSaveDebounce = Duration(seconds: 2);

  EditorController({
    required this.repository,
    required this.notebook,
    this.saveDebounce = defaultSaveDebounce,
    this.operationWriter,
    EditorHistoryNotebookCodec? historyCodec,
  }) {
    if (historyCodec != null &&
        (operationWriter == null ||
            !identical(
              historyCodec.projector.database,
              operationWriter!.projector.database,
            ))) {
      throw ArgumentError('History and editor must share one SQLite DB.');
    }
    if (operationWriter != null &&
        !identical(repository.database, operationWriter!.projector.database)) {
      throw ArgumentError('Editor and v2 journal must share one SQLite DB.');
    }
    if (notebook.kind == NotebookKind.planner) {
      throw UnsupportedError('Planner items do not use the drawing editor.');
    }
    if (operationWriter != null) {
      repository.registerOperationWriter(notebook.uid);
    }
    pages = notebook.pages;
    _v2PersistedNotebook = notebook;
    currentPageIndex = 0;
    if (operationWriter != null) {
      _v2HistoryRecovering = true;
      _v2HistoryStore = EditorHistoryStore(operationWriter!.syncEngine.store);
      final projector = operationWriter!.projector;
      _v2HistoryCodec = historyCodec ?? EditorHistoryNotebookCodec(projector);
      _v2HistoryReady = _restoreV2History();
    }
    AppSaveCoordinator.instance.register(
      this,
      hasPendingWork: () => _hasPendingSaveWork,
      flush: flushPendingSaves,
    );
    preferencesReady = _loadEditorPrefs();
  }

  /// Completes after startup preferences and their migrations have been read.
  late final Future<void> preferencesReady;
  final NotebookRepository repository;
  final EditorV2OperationWriter? operationWriter;
  Notebook notebook;
  late Notebook _v2PersistedNotebook;
  EditorHistoryStore? _v2HistoryStore;
  EditorHistoryNotebookCodec? _v2HistoryCodec;
  Future<void>? _v2HistoryReady;
  bool _v2HistoryRecovering = false;
  Object? _v2HistoryLoadError;

  /// Resolves after the local actor's history has been verified and loaded.
  Future<void> get historyReady => _v2HistoryReady ?? Future<void>.value();

  Future<void>? _v2SaveTail;
  Future<void>? _v2HistoryTail;
  bool _v2HistoryCommitting = false;
  final List<_V2HistoryEntry> _v2Undo = [];
  final List<_V2HistoryEntry> _v2Redo = [];
  final List<_V2GestureCheckpoint> _v2GestureCheckpoints = [];
  Duration saveDebounce;
  final Uuid _uuid = const Uuid();
  final ImagePicker _imagePicker = ImagePicker();

  late List<NotePage> pages;
  int currentPageIndex = 0;
  DrawingTool tool = DrawingTool.pen;
  DrawingTool lastEraserTool = DrawingTool.eraserBrush;
  DrawingTool lastShapeTool = DrawingTool.line;
  PointerInputMode pointerInputMode = PointerInputMode.off;
  bool stylusButtonsEnabled = true;
  bool scratchEraseEnabled = true;
  PageBackgroundSettings defaultNotebookBackground =
      const PageBackgroundSettings();
  PageBackgroundSettings defaultBoardBackground =
      const PageBackgroundSettings();
  Color penColor = InkColorPreset.blue.colors[0];
  Color get highlighterColor => penColor;
  Color get inkColor => penColor;
  double inkStrokeWidth = 2.5;
  final List<Color> quickColors = List.of(InkColorPreset.blue.colors);
  final List<Color> recentColors = <Color>[];

  final List<_EditorHistoryEntry> _undoActions = <_EditorHistoryEntry>[];
  final List<_EditorHistoryEntry> _redoActions = <_EditorHistoryEntry>[];
  final Map<String, ValueNotifier<int>> _inkPageRevisions =
      <String, ValueNotifier<int>>{};
  final ValueNotifier<int> inkRevision = ValueNotifier<int>(0);
  final ValueNotifier<int> historyRevision = ValueNotifier<int>(0);
  final ValueNotifier<PageBackgroundSettings> backgroundSettingsListenable =
      ValueNotifier(const PageBackgroundSettings());
  final Map<String, PageBackgroundSettings> _localBackgrounds =
      <String, PageBackgroundSettings>{};
  final Set<NotebookKind> _dirtyBackgroundDefaultKinds = <NotebookKind>{};
  final Set<String> _dirtyLocalBackgroundIds = <String>{};
  Timer? _prefsSaveDebounce;
  Future<void>? _activePrefsSave;
  Timer? _notebookSaveDebounce;
  final Set<String> _dirtyPageIds = <String>{};
  final Map<String, Set<String>> _expectedRemovedIdsByPage = {};
  final Set<String> _expectedRemovedPageIds = {};
  bool _fullSavePending = false;
  bool _integritySaveBlocked = false;
  bool _isDisposed = false;
  bool _v2DocumentDeleted = false;

  String? lastTextFontFamily;
  double lastTextFontSize = 18.0;
  Color lastTextColor = const Color(0xFF1E1E1E);

  String? activeTextBlockId;
  quill.QuillController? activeTextController;
  TextEditingController? _hudTextController;
  String? _hudTextBlockId;
  ({String blockId, String deltaJson, TextSelection selection})? _quillHandoff;

  TextEditingController? get activeHudTextController =>
      operationWriter != null &&
          activeTextController == null &&
          activeTextBlockId == _hudTextBlockId &&
          tool == DrawingTool.text
      ? _hudTextController
      : null;

  /// Borrows the mounted HUD controller; its widget retains ownership.
  void bindHudTextController(String blockId, TextEditingController controller) {
    if (_isDisposed || operationWriter == null) {
      return;
    }
    _hudTextBlockId = blockId;
    _hudTextController = controller;
  }

  void unbindHudTextController(
    String blockId,
    TextEditingController controller,
  ) {
    if (_hudTextBlockId == blockId &&
        identical(_hudTextController, controller)) {
      _hudTextBlockId = null;
      _hudTextController = null;
    }
  }

  bool hasQuillHandoff(String blockId) =>
      activeTextBlockId == blockId && _quillHandoff?.blockId == blockId;

  /// Consumes the caret only for the exact Delta that replaced the HUD.
  TextSelection? takeQuillHandoff(String blockId, String? deltaJson) {
    final handoff = _quillHandoff;
    if (handoff == null || handoff.blockId != blockId) {
      return null;
    }
    _quillHandoff = null;
    return activeTextBlockId == blockId && handoff.deltaJson == deltaJson
        ? handoff.selection
        : null;
  }

  int? _activeTextEditPageIndex;
  TextBlock? _activeTextEditBefore;
  _V2TextGesture? _activeV2TextGesture;
  String? activeImageBlockId;
  String? activeShapeStrokeId;
  int? activeShapePageIndex;
  DrawingTool? _toolBeforeShapeEdit;
  LassoSelection? lassoSelection;
  final ValueNotifier<Offset> lassoDragDelta = ValueNotifier(Offset.zero);
  final ValueNotifier<ImageBlock?> imageTransformPreview =
      ValueNotifier<ImageBlock?>(null);
  _ElementClipboardItem? _elementClipboard;
  bool _suppressBackgroundTap = false;
  double viewScale = 1.0;
  Offset viewPan = Offset.zero;
  bool _isObjectTransformActive = false;
  double _pageWidth = 0.0;
  double _pageHeight = 0.0;
  double _pageGap = 0.0;

  NotePage get currentPage => pages[currentPageIndex];

  bool get canUndo => operationWriter == null
      ? _undoActions.isNotEmpty
      : !_integritySaveBlocked &&
            (_v2Undo.isNotEmpty ||
                _fullSavePending ||
                _dirtyPageIds.isNotEmpty ||
                _activeTextEditBefore != null);
  bool get canRedo => operationWriter == null
      ? _redoActions.isNotEmpty
      : !_integritySaveBlocked &&
            _v2Redo.isNotEmpty &&
            !_fullSavePending &&
            _dirtyPageIds.isEmpty &&
            _activeTextEditBefore == null;
  bool get allowsFingerDrawing => pointerInputMode.allowsFingerDrawing;
  bool get isObjectTransformActive => _isObjectTransformActive;
  bool get isActiveImageEdit =>
      tool == DrawingTool.edit && activeImageBlockId != null;
  bool get isCanvasNavigationLocked =>
      _isObjectTransformActive || isActiveImageEdit;
  bool _isActiveImageMultiTouch = false;
  bool get isActiveImageMultiTouch => _isActiveImageMultiTouch;

  void setActiveImageMultiTouch(bool value) {
    _isActiveImageMultiTouch = value;
  }

  PageBackgroundSettings get currentBackgroundSettings {
    return _localBackgrounds[notebook.uid] ??
        defaultBackgroundSettingsForKind(notebook.kind);
  }

  Rect get contentBounds => _computeContentBounds();
  Size get layoutPageSize => Size(_pageWidth, _pageHeight);
  double get layoutPageGap => _pageGap;

  ValueListenable<int> inkRevisionForPage(String pageId) {
    return _inkPageRevisions.putIfAbsent(pageId, () => ValueNotifier<int>(0));
  }

  bool get isV2DocumentDeleted => _v2DocumentDeleted;

  bool get canApplyConfirmedRemoteNotebook =>
      !_isDisposed &&
      !_v2DocumentDeleted &&
      !_integritySaveBlocked &&
      !_hasPendingSaveWork &&
      !repository.hasPendingSaves &&
      activeTextBlockId == null &&
      !_isObjectTransformActive &&
      !InkActivityTracker.instance.hasActiveContacts;

  /// Updates confirmed document content without changing local navigation.
  ///
  /// The caller must apply the server snapshot to the repository first.
  /// Never replace work that is still being edited or saved.
  bool applyConfirmedRemoteNotebook(Notebook incoming) {
    if (incoming.uid != notebook.uid) {
      throw ArgumentError('Remote notebook UID does not match the editor.');
    }
    if (operationWriter != null || !canApplyConfirmedRemoteNotebook) {
      return false;
    }
    final selectedPageId = currentPage.id;
    notebook = incoming;
    pages = incoming.pages;
    final matchingPage = pages.indexWhere((page) => page.id == selectedPageId);
    currentPageIndex = matchingPage < 0
        ? currentPageIndex.clamp(0, pages.length - 1).toInt()
        : matchingPage;
    // Undo history belongs to the previous revision, not the new one.
    _undoActions.clear();
    _redoActions.clear();
    _notifyHistoryChanged();
    for (final page in pages) {
      _touchInkPageRevision(page.id);
    }
    notifyListeners();
    return true;
  }

  /// Applies confirmed metadata without replacing the pages or viewport.
  bool applyConfirmedV2DocumentMetadata({
    required String title,
    required String folder,
  }) {
    if (operationWriter == null) {
      throw StateError('Metadata patches require a v2 editor.');
    }
    if (title.isEmpty || folder.isEmpty) {
      throw ArgumentError('Document metadata cannot be empty.');
    }
    if (!canApplyConfirmedRemoteNotebook) {
      return false;
    }
    notebook = notebook.copyWith(title: title, folder: folder);
    _v2PersistedNotebook = _v2PersistedNotebook.copyWith(
      title: title,
      folder: folder,
    );
    _v2Undo.clear();
    _v2Redo.clear();
    _undoActions.clear();
    _redoActions.clear();
    _notifyHistoryChanged();
    notifyListeners();
    return true;
  }

  /// Prevents a committed remote tombstone from being overwritten locally.
  bool applyConfirmedV2DocumentDeletion() {
    if (operationWriter == null) {
      throw StateError('Document deletion patches require a v2 editor.');
    }
    if (_v2DocumentDeleted) {
      return true;
    }
    if (!canApplyConfirmedRemoteNotebook) {
      return false;
    }
    _v2DocumentDeleted = true;
    _v2Undo.clear();
    _v2Redo.clear();
    _undoActions.clear();
    _redoActions.clear();
    _notifyHistoryChanged();
    notifyListeners();
    return true;
  }

  /// Updates only one committed page in a migrated v2 editor.
  ///
  /// No snapshot writer, history action, scroll or zoom is created here.
  /// A busy editor rejects the patch so SyncEngine can retry the delivery.
  bool applyConfirmedV2PagePatch({
    required String pageId,
    NotePage? page,
    int? pageIndex,
  }) {
    if (operationWriter == null) {
      throw StateError('A v2 page patch requires operation-mode editing.');
    }
    if (pageId.isEmpty || (page != null && page.id != pageId)) {
      throw ArgumentError('Invalid v2 page patch identity.');
    }
    if (!canApplyConfirmedRemoteNotebook) {
      return false;
    }
    final previous = pages.indexWhere((entry) => entry.id == pageId);
    final updated = List<NotePage>.from(pages);
    if (page == null) {
      if (previous < 0) {
        return true;
      }
      if (updated.length <= 1) {
        throw StateError('Cannot remove the final notebook page.');
      }
      updated.removeAt(previous);
    } else if (previous >= 0) {
      updated[previous] = page;
    } else {
      if (pageIndex == null || pageIndex < 0 || pageIndex > updated.length) {
        throw ArgumentError('New v2 pages require a valid insertion index.');
      }
      updated.insert(pageIndex, page);
    }
    final selectedId = currentPage.id;
    pages = updated;
    notebook = notebook.copyWith(pages: updated);
    _v2PersistedNotebook = notebook;
    final selected = updated.indexWhere((entry) => entry.id == selectedId);
    currentPageIndex = selected < 0
        ? currentPageIndex.clamp(0, updated.length - 1).toInt()
        : selected;
    _undoActions.clear();
    _redoActions.clear();
    _v2Undo.clear();
    _v2Redo.clear();
    _notifyHistoryChanged();
    _touchInkPageRevision(pageId);
    notifyListeners();
    return true;
  }

  /// Applies both sides of a committed v2 move as one UI mutation.
  ///
  /// The pages are read from the durable SQLite projection after commit.
  /// No intermediate frame can display only the deletion or the insertion.
  bool applyConfirmedV2PageMovePatch({
    required NotePage source,
    required NotePage destination,
  }) {
    if (operationWriter == null) {
      throw StateError('A v2 move patch requires operation-mode editing.');
    }
    if (source.id.isEmpty ||
        destination.id.isEmpty ||
        source.id == destination.id) {
      throw ArgumentError('A v2 move requires two distinct page IDs.');
    }
    if (!canApplyConfirmedRemoteNotebook) {
      return false;
    }
    final sourceIndex = pages.indexWhere((page) => page.id == source.id);
    final destinationIndex = pages.indexWhere(
      (page) => page.id == destination.id,
    );
    if (sourceIndex < 0 || destinationIndex < 0) {
      throw StateError('V2 move pages have changed since SQLite commit.');
    }
    final updated = List<NotePage>.from(pages);
    updated[sourceIndex] = source;
    updated[destinationIndex] = destination;
    pages = updated;
    notebook = notebook.copyWith(pages: updated);
    _v2PersistedNotebook = notebook;
    _undoActions.clear();
    _redoActions.clear();
    _v2Undo.clear();
    _v2Redo.clear();
    _notifyHistoryChanged();
    _touchInkPageRevision(source.id);
    _touchInkPageRevision(destination.id);
    notifyListeners();
    return true;
  }

  /// Displays one committed v2 Share object delta without remounting the editor.
  ///
  /// The caller must persist the matching operation in the same transaction
  /// as its SQLite projection before invoking this method. No local write,
  /// undo entry, viewport change or whole-notebook import occurs here.
  bool applyConfirmedShareObjectPatch({
    required String pageId,
    required String objectId,
    InkStroke? stroke,
    TextBlock? text,
    ImageBlock? image,
    bool deleted = false,
    int? sortIndex,
  }) {
    if (objectId.isEmpty || pageId.isEmpty) {
      throw ArgumentError('Share object IDs must be nonempty.');
    }
    final supplied =
        (stroke == null ? 0 : 1) +
        (text == null ? 0 : 1) +
        (image == null ? 0 : 1);
    if (supplied != (deleted ? 0 : 1) ||
        (stroke != null && stroke.id != objectId) ||
        (text != null && text.id != objectId) ||
        (image != null && image.id != objectId)) {
      throw ArgumentError('Expected exactly one matching object or deletion.');
    }
    if (sortIndex != null && (sortIndex < 0 || deleted)) {
      throw ArgumentError('Object order requires a nonnegative index.');
    }
    if (!canApplyConfirmedRemoteNotebook ||
        activeImageBlockId == objectId ||
        (lassoSelection?.strokeIds.contains(objectId) ?? false) ||
        (lassoSelection?.textBlockIds.contains(objectId) ?? false) ||
        (lassoSelection?.imageBlockIds.contains(objectId) ?? false)) {
      return false;
    }
    final index = pages.indexWhere((page) => page.id == pageId);
    if (index < 0) {
      return false;
    }
    final current = pages[index];
    final previousInkIndex = current.inkStrokes.indexWhere(
      (entry) => entry.id == objectId,
    );
    final hasInk = stroke != null || previousInkIndex >= 0;
    final inkStrokes = [
      for (final entry in current.inkStrokes)
        if (entry.id != objectId) entry,
    ];
    if (stroke != null) {
      // A color/geometry update must not silently bring the stroke to front.
      // Only an explicit layer operation is allowed to move it.
      final index =
          sortIndex ??
          (previousInkIndex < 0 ? inkStrokes.length : previousInkIndex);
      inkStrokes.insert(index.clamp(0, inkStrokes.length).toInt(), stroke);
    }
    final previousTextIndex = current.textBlocks.indexWhere(
      (entry) => entry.id == objectId,
    );
    final textBlocks = [
      for (final entry in current.textBlocks)
        if (entry.id != objectId) entry,
    ];
    if (text != null) {
      final index =
          sortIndex ??
          (previousTextIndex < 0 ? textBlocks.length : previousTextIndex);
      textBlocks.insert(index.clamp(0, textBlocks.length).toInt(), text);
    }
    final previousImageIndex = current.imageBlocks.indexWhere(
      (entry) => entry.id == objectId,
    );
    final imageBlocks = [
      for (final entry in current.imageBlocks)
        if (entry.id != objectId) entry,
    ];
    if (image != null) {
      final index =
          sortIndex ??
          (previousImageIndex < 0 ? imageBlocks.length : previousImageIndex);
      imageBlocks.insert(index.clamp(0, imageBlocks.length).toInt(), image);
    }
    final next = current.copyWith(
      inkStrokes: inkStrokes,
      textBlocks: textBlocks,
      imageBlocks: imageBlocks,
    );
    pages = [
      for (var i = 0; i < pages.length; i++)
        if (i == index) next else pages[i],
    ];
    notebook = notebook.copyWith(pages: pages);
    if (operationWriter != null) {
      // Remote projection is already durable. Do not re-emit its patch as
      // a new local operation during the next editor save.
      _v2PersistedNotebook = notebook;
    }
    // A remote operation invalidates local inverse snapshots.
    _undoActions.clear();
    _redoActions.clear();
    _v2Undo.clear();
    _v2Redo.clear();
    _notifyHistoryChanged();
    if (hasInk) {
      _touchInkPageRevision(pageId);
    }
    if (!hasInk || notebook.kind != NotebookKind.board) {
      notifyListeners();
    }
    return true;
  }

  NotePage? pageById(String pageId) {
    for (final page in pages) {
      if (page.id == pageId) {
        return page;
      }
    }
    return null;
  }

  PageBackgroundSettings defaultBackgroundSettingsForKind(NotebookKind kind) {
    return switch (kind) {
      NotebookKind.notebook => defaultNotebookBackground,
      NotebookKind.board => defaultBoardBackground,
      NotebookKind.planner => throw UnsupportedError(
        'Planner items do not use page background settings.',
      ),
    };
  }

  bool get _hasPendingSaveWork =>
      _v2HistoryRecovering ||
      _prefsSaveDebounce != null ||
      _activePrefsSave != null ||
      _notebookSaveDebounce != null ||
      _v2SaveTail != null ||
      _v2HistoryTail != null ||
      _v2GestureCheckpoints.isNotEmpty ||
      _fullSavePending ||
      _dirtyPageIds.isNotEmpty ||
      _activeTextEditBefore != null;

  Future<void> flushPendingSaves() async {
    if (_isDisposed) {
      await repository.waitForPendingSaves();
      return;
    }
    _commitActiveTextEdit();
    _notebookSaveDebounce?.cancel();
    _notebookSaveDebounce = null;

    if (_prefsSaveDebounce != null) {
      _prefsSaveDebounce?.cancel();
      _prefsSaveDebounce = null;
      await _queueEditorPrefsSave();
    } else {
      final activePrefsSave = _activePrefsSave;
      if (activePrefsSave != null) {
        await activePrefsSave;
      }
    }

    await repository.waitForPendingSaves();
    if (operationWriter != null) {
      await historyReady;
      // The v2 journal and its projection commit together; no legacy writer
      // is allowed to run on the same document during flush or shutdown.
      await _v2HistoryTail;
      await _v2SaveTail;
      if (_fullSavePending || _dirtyPageIds.isNotEmpty) {
        await _saveV2();
      }
      await _v2SaveTail;
      if (_integritySaveBlocked ||
          _fullSavePending ||
          _dirtyPageIds.isNotEmpty) {
        throw const DataIntegrityProtectionException(
          'Editor v2 changes were not durably committed.',
        );
      }
      return;
    }
    if (_integritySaveBlocked) {
      throw const DataIntegrityProtectionException(
        'Notebook save is blocked by data integrity protection.',
      );
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_fullSavePending) {
        await _save();
      } else if (_dirtyPageIds.isNotEmpty) {
        await _saveDirtyPages();
      }
      await repository.waitForPendingSaves();
      if (_integritySaveBlocked) {
        throw const DataIntegrityProtectionException(
          'Notebook save is blocked by data integrity protection.',
        );
      }
      if (!_fullSavePending && _dirtyPageIds.isEmpty) {
        return;
      }
    }
    throw StateError('Editor save did not settle before application exit.');
  }

  @override
  void dispose() {
    _commitActiveTextEdit();
    AppSaveCoordinator.instance.unregister(this);
    if (_prefsSaveDebounce != null) {
      _prefsSaveDebounce?.cancel();
      _prefsSaveDebounce = null;
      unawaited(_queueEditorPrefsSave());
    }
    if (_notebookSaveDebounce != null ||
        _fullSavePending ||
        _dirtyPageIds.isNotEmpty) {
      unawaited(_save());
    }
    if (operationWriter != null) {
      final lastCommit = _v2SaveTail;
      if (lastCommit == null) {
        repository.unregisterOperationWriter(notebook.uid);
      } else {
        unawaited(
          lastCommit.whenComplete(
            () => repository.unregisterOperationWriter(notebook.uid),
          ),
        );
      }
    }
    _isDisposed = true;
    imageTransformPreview.dispose();
    lassoDragDelta.dispose();
    inkRevision.dispose();
    historyRevision.dispose();
    backgroundSettingsListenable.dispose();
    for (final revision in _inkPageRevisions.values) {
      revision.dispose();
    }
    super.dispose();
  }

  void updatePageLayout({
    required double pageWidth,
    required double pageHeight,
    required double pageGap,
  }) {
    if (_pageWidth == pageWidth &&
        _pageHeight == pageHeight &&
        _pageGap == pageGap) {
      return;
    }
    _pageWidth = pageWidth;
    _pageHeight = pageHeight;
    _pageGap = pageGap;
  }

  void beginObjectTransform() {
    if (_isObjectTransformActive) {
      return;
    }
    _isObjectTransformActive = true;
    notifyListeners();
  }

  void endObjectTransform() {
    if (!_isObjectTransformActive) {
      return;
    }
    _isObjectTransformActive = false;
    if (_isDisposed) {
      return;
    }
    final binding = SchedulerBinding.instance;
    binding.addPostFrameCallback((_) {
      if (!_isDisposed) {
        notifyListeners();
      }
    });
    binding.ensureVisualUpdate();
  }

  void setViewTransform({Offset? pan, double? scale}) {
    if (isCanvasNavigationLocked) {
      return;
    }
    final targetScale = (scale ?? viewScale)
        .clamp(minViewScale, maxViewScale)
        .toDouble();
    final targetPan = pan ?? viewPan;
    final changed = targetScale != viewScale || targetPan != viewPan;
    if (!changed) {
      return;
    }
    viewScale = targetScale;
    viewPan = targetPan;
    notifyListeners();
  }

  void panBy(Offset delta) {
    if (delta == Offset.zero) {
      return;
    }
    setViewTransform(pan: viewPan + delta);
  }

  void zoomBy(double factor, {required Offset focalPoint}) {
    if (factor == 1.0) {
      return;
    }
    final currentScale = viewScale <= 0 ? 1.0 : viewScale;
    final worldAtFocal = (focalPoint - viewPan) / currentScale;
    final targetScale = (currentScale * factor)
        .clamp(minViewScale, maxViewScale)
        .toDouble();
    final targetPan = focalPoint - (worldAtFocal * targetScale);
    setViewTransform(scale: targetScale, pan: targetPan);
  }

  Offset viewportToWorld(Offset viewportPoint) {
    final safeScale = viewScale <= 0 ? 1.0 : viewScale;
    return (viewportPoint - viewPan) / safeScale;
  }

  Offset worldToViewport(Offset worldPoint) {
    return worldPoint * viewScale + viewPan;
  }

  NotePage pageAt(int index) {
    return pages[index];
  }

  double get _pageExtent => _pageHeight + _pageGap;

  Offset _pageOriginForIndex(int index) {
    if (_pageExtent <= 0) {
      return Offset.zero;
    }
    return Offset(0, _pageExtent * index);
  }

  int _pageIndexForPosition(Offset position) {
    if (pages.isEmpty) {
      return 0;
    }
    if (_pageExtent <= 0) {
      return currentPageIndex;
    }
    final raw = (position.dy / _pageExtent).floor();
    return raw.clamp(0, pages.length - 1);
  }

  TextBlock? findTextBlockById(String id) {
    for (final page in pages) {
      for (final block in page.textBlocks) {
        if (block.id == id) {
          return block;
        }
      }
    }
    return null;
  }

  ImageBlock? findImageBlockById(String id) {
    for (final page in pages) {
      for (final block in page.imageBlocks) {
        if (block.id == id) {
          return block;
        }
      }
    }
    return null;
  }

  int? _pageIndexContainingTextBlock(String id) {
    for (var i = 0; i < pages.length; i++) {
      if (pages[i].textBlocks.any((item) => item.id == id)) {
        return i;
      }
    }
    return null;
  }

  int? _pageIndexContainingImageBlock(String id) {
    for (var i = 0; i < pages.length; i++) {
      if (pages[i].imageBlocks.any((item) => item.id == id)) {
        return i;
      }
    }
    return null;
  }

  void _ensurePageSelected(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= pages.length) {
      return;
    }
    if (pageIndex == currentPageIndex) {
      return;
    }
    setCurrentPage(pageIndex);
  }

  void _ensureInsertPageSelected(Offset position) {
    _ensurePageSelected(_pageIndexForPosition(position));
  }

  Future<String?> handleTapOnPage(int pageIndex, Offset point) async {
    _ensurePageSelected(pageIndex);
    return handleTap(point);
  }

  void updateTextBlockContentOnPage(
    int pageIndex,
    TextBlock before, {
    required String plainText,
    required String deltaJson,
  }) {
    _ensurePageSelected(pageIndex);
    updateTextBlockContent(before, plainText: plainText, deltaJson: deltaJson);
  }

  void updateTextBlockPositionOnPage(
    int pageIndex,
    String id,
    Offset position,
  ) {
    _ensurePageSelected(pageIndex);
    updateTextBlockPosition(id, position);
  }

  void updateTextBlockOnPage(int pageIndex, TextBlock block) {
    _ensurePageSelected(pageIndex);
    _replaceTextBlockOnCurrentPage(block, notify: true);
  }

  void deleteTextBlockOnPage(int pageIndex, String id) {
    _ensurePageSelected(pageIndex);
    deleteTextBlock(id);
  }

  void commitTextMoveOnPage(
    int pageIndex,
    String id,
    Offset start,
    Offset end,
  ) {
    _ensurePageSelected(pageIndex);
    commitTextMove(id, start, end);
  }

  void commitTextUpdateOnPage(
    int pageIndex,
    TextBlock before,
    TextBlock after,
  ) {
    _ensurePageSelected(pageIndex);
    commitTextUpdate(before, after);
  }

  void updateImageBlockPositionOnPage(
    int pageIndex,
    String id,
    Offset position,
  ) {
    _ensurePageSelected(pageIndex);
    updateImageBlockPosition(id, position);
  }

  void updateImageBlockOnPage(int pageIndex, ImageBlock block) {
    _ensurePageSelected(pageIndex);
    final updated = currentPage.imageBlocks
        .map((item) => item.id == block.id ? block : item)
        .toList();
    _updatePage(currentPage.copyWith(imageBlocks: updated));
  }

  void deleteImageBlockOnPage(int pageIndex, String id) {
    _ensurePageSelected(pageIndex);
    deleteImageBlock(id);
  }

  String? addInkStrokeOnPage(
    int pageIndex,
    List<InkPoint> points, {
    double? widthOverride,
    DrawingTool? toolOverride,
    Color? colorOverride,
  }) {
    _ensurePageSelected(pageIndex);
    return addInkStroke(
      points,
      widthOverride: widthOverride,
      toolOverride: toolOverride,
      colorOverride: colorOverride,
    );
  }

  void eraseInkStrokesByIdOnPage(int pageIndex, Set<String> ids) {
    _ensurePageSelected(pageIndex);
    eraseInkStrokesById(ids);
  }

  void replaceInkStrokesOnPage(int pageIndex, List<InkStroke> strokes) {
    _ensurePageSelected(pageIndex);
    replaceInkStrokes(strokes);
  }

  void commitImageMoveOnPage(
    int pageIndex,
    String id,
    Offset start,
    Offset end,
  ) {
    _ensurePageSelected(pageIndex);
    commitImageMove(id, start, end);
  }

  void finalizeImageMoveOnPage(
    int pageIndex,
    String id,
    Offset start,
    Offset end,
  ) {
    if (start == end) {
      return;
    }
    final targetIndex = _pageIndexForPosition(end);
    if (targetIndex == pageIndex || _pageExtent <= 0) {
      commitImageMoveOnPage(pageIndex, id, start, end);
      return;
    }
    _moveImageBlockToPage(pageIndex, targetIndex, id, start, end);
  }

  void commitImageResizeOnPage(
    int pageIndex,
    ImageBlock before,
    ImageBlock after,
  ) {
    _ensurePageSelected(pageIndex);
    commitImageResize(before, after);
  }

  void setTool(DrawingTool newTool) {
    activeShapeStrokeId = null;
    activeShapePageIndex = null;
    _toolBeforeShapeEdit = null;
    tool = newTool;
    if (newTool.isEraser) {
      lastEraserTool = newTool;
      _schedulePrefsSave();
    }
    if (newTool.isShape) {
      lastShapeTool = newTool;
    }
    if (tool != DrawingTool.text) {
      clearActiveTextBlock();
    }
    if (newTool != DrawingTool.edit) {
      clearImageTransformPreview();
      activeImageBlockId = null;
      _isActiveImageMultiTouch = false;
    }
    lassoSelection = null;
    notifyListeners();
  }

  void startShapeEdit(int pageIndex, String strokeId) {
    final shape = shapeStrokeOnPage(pageIndex, strokeId);
    if (shape == null || !shape.tool.isShape) {
      return;
    }
    final previousTool = _toolBeforeShapeEdit ?? tool;
    setTool(DrawingTool.edit);
    _toolBeforeShapeEdit = previousTool;
    activeShapePageIndex = pageIndex;
    activeShapeStrokeId = strokeId;
    notifyListeners();
  }

  void finishShapeEdit() {
    final previousTool = _toolBeforeShapeEdit;
    if (previousTool == null) {
      return;
    }
    setTool(previousTool);
  }

  InkStroke? shapeStrokeOnPage(int pageIndex, String id) {
    if (pageIndex < 0 || pageIndex >= pages.length) {
      return null;
    }
    for (final stroke in pages[pageIndex].inkStrokes) {
      if (stroke.id == id) {
        return stroke;
      }
    }
    return null;
  }

  void previewShapeStrokeOnPage(int pageIndex, InkStroke stroke) {
    if (shapeStrokeOnPage(pageIndex, stroke.id) == null) {
      return;
    }
    _ensurePageSelected(pageIndex);
    _updatePage(
      currentPage.copyWith(
        inkStrokes: [
          for (final item in currentPage.inkStrokes)
            if (item.id == stroke.id) stroke else item,
        ],
      ),
    );
    _touchInkPageRevision(currentPage.id);
  }

  void commitShapeStrokeOnPage(
    int pageIndex,
    InkStroke before,
    InkStroke after,
  ) {
    if (before.id != after.id ||
        listEquals(
          before.points.map((point) => point.toOffset()).toList(),
          after.points.map((point) => point.toOffset()).toList(),
        )) {
      return;
    }
    _ensurePageSelected(pageIndex);
    _applyInkAction(UpdateInkStrokeAction(before: before, after: after));
    _scheduleSave();
  }

  void setActiveTextBlock(String? blockId, quill.QuillController? controller) {
    if (blockId != activeTextBlockId) {
      _commitActiveTextEdit();
    }
    activeTextBlockId = blockId;
    activeTextController = controller;
    activeImageBlockId = null;
    if (blockId != null) {
      _beginTextEdit(blockId);
    }
    notifyListeners();
  }

  void commitActiveTextEdit() {
    _commitActiveTextEdit();
  }

  void clearActiveTextBlock() {
    _commitActiveTextEdit();
    activeTextBlockId = null;
    activeTextController = null;
    notifyListeners();
  }

  void setActiveImageBlock(String? blockId) {
    if (blockId != null && tool != DrawingTool.edit) {
      return;
    }
    if (activeImageBlockId != blockId) {
      clearImageTransformPreview();
    }
    activeImageBlockId = blockId;
    _isActiveImageMultiTouch = false;
    if (blockId != null) {
      _commitActiveTextEdit();
      activeTextBlockId = null;
      activeTextController = null;
    }
    notifyListeners();
  }

  void clearLassoSelection() {
    if (lassoSelection != null) {
      lassoSelection = null;
      lassoDragDelta.value = Offset.zero;
      notifyListeners();
    }
  }

  void selectWithLasso(List<Offset> points, int pageIndex) {
    if (points.length < 3) {
      clearLassoSelection();
      return;
    }

    _ensurePageSelected(pageIndex);
    final page = pages[pageIndex];
    final pageOrigin = _pageOriginForIndex(pageIndex);
    final documentPoints = points.map((point) => point + pageOrigin).toList();
    final selectedStrokes = <String>[];
    final selectedTextBlocks = <String>[];
    final selectedImages = <String>[];

    bool isInsidePath(Offset point, List<Offset> path) {
      var inside = false;
      for (var i = 0, j = path.length - 1; i < path.length; j = i++) {
        final xi = path[i].dx, yi = path[i].dy;
        final xj = path[j].dx, yj = path[j].dy;
        final intersect =
            ((yi > point.dy) != (yj > point.dy)) &&
            (point.dx < (xj - xi) * (point.dy - yi) / (yj - yi) + xi);
        if (intersect) inside = !inside;
      }
      return inside;
    }

    bool isInsidePagePath(Offset point) => isInsidePath(point, points);
    bool isInsideDocumentPath(Offset point) {
      return isInsidePath(point, documentPoints);
    }

    bool rectTouchesDocumentPath(Rect rect) {
      final pointsToTest = [
        rect.center,
        rect.topLeft,
        rect.topRight,
        rect.bottomLeft,
        rect.bottomRight,
      ];
      return pointsToTest.any(isInsideDocumentPath);
    }

    var lassoMinX = points.first.dx;
    var lassoMinY = points.first.dy;
    var lassoMaxX = lassoMinX;
    var lassoMaxY = lassoMinY;
    for (var index = 1; index < points.length; index++) {
      final point = points[index];
      lassoMinX = math.min(lassoMinX, point.dx);
      lassoMinY = math.min(lassoMinY, point.dy);
      lassoMaxX = math.max(lassoMaxX, point.dx);
      lassoMaxY = math.max(lassoMaxY, point.dy);
    }
    final inkCandidates = inkSpatialIndexFor(
      page.inkStrokes,
    ).query(Rect.fromLTRB(lassoMinX, lassoMinY, lassoMaxX, lassoMaxY));
    for (final s in inkCandidates) {
      final isSelectedInk =
          !s.tool.isEraser &&
          s.points.any((p) => isInsidePagePath(Offset(p.dx, p.dy)));
      if (isSelectedInk) {
        selectedStrokes.add(s.id);
      }
    }

    for (final t in page.textBlocks) {
      final estimatedHeight = math.max(44.0, t.fontSize * 2.8);
      final rect = Rect.fromLTWH(
        t.position.dx,
        t.position.dy,
        t.width,
        estimatedHeight,
      );
      if (rectTouchesDocumentPath(rect)) selectedTextBlocks.add(t.id);
    }

    for (final i in page.imageBlocks) {
      final rect = Rect.fromLTWH(
        i.position.dx,
        i.position.dy,
        i.width,
        i.height,
      );
      if (rectTouchesDocumentPath(rect)) selectedImages.add(i.id);
    }

    if (selectedStrokes.isEmpty &&
        selectedTextBlocks.isEmpty &&
        selectedImages.isEmpty) {
      clearLassoSelection();
      return;
    }

    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in documentPoints) {
      if (p.dx < minX) minX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > maxY) maxY = p.dy;
    }

    lassoSelection = LassoSelection(
      pageIndex: pageIndex,
      bounds: Rect.fromLTRB(minX, minY, maxX, maxY),
      strokeIds: selectedStrokes,
      textBlockIds: selectedTextBlocks,
      imageBlockIds: selectedImages,
    );
    lassoDragDelta.value = Offset.zero;

    activeTextBlockId = null;
    activeImageBlockId = null;
    notifyListeners();
  }

  void updateLassoMove(Offset delta) {
    if (lassoSelection == null) return;
    lassoDragDelta.value = delta;
  }

  void commitLassoMove() {
    final sel = lassoSelection;
    final delta = lassoDragDelta.value;
    if (sel == null || delta == Offset.zero) return;
    _ensurePageSelected(sel.pageIndex);

    final action = MoveSelectionAction(
      strokeIds: sel.strokeIds,
      textBlockIds: sel.textBlockIds,
      imageBlockIds: sel.imageBlockIds,
      delta: OffsetPosition.fromOffset(delta),
    );

    _applyActionWithoutNotify(action);

    lassoSelection = sel.copyWith(
      bounds: sel.bounds.shift(delta),
      delta: Offset.zero,
    );
    lassoDragDelta.value = Offset.zero;
    notifyListeners();
    _save();
  }

  void deleteLassoSelection() {
    final sel = lassoSelection;
    if (sel == null) return;
    _ensurePageSelected(sel.pageIndex);

    final page = pages[sel.pageIndex];
    final strokes = page.inkStrokes
        .where((s) => sel.strokeIds.contains(s.id))
        .toList();
    final texts = page.textBlocks
        .where((t) => sel.textBlockIds.contains(t.id))
        .toList();
    final images = page.imageBlocks
        .where((i) => sel.imageBlockIds.contains(i.id))
        .toList();

    if (strokes.isEmpty && texts.isEmpty && images.isEmpty) return;

    final action = DeleteSelectionAction(
      deletedStrokes: strokes,
      deletedTextBlocks: texts,
      deletedImageBlocks: images,
    );
    _applyAction(action);
    clearLassoSelection();
    _save();
  }

  void setImageTransformPreview(ImageBlock block) {
    if (_isDisposed || block.id != activeImageBlockId) {
      return;
    }
    imageTransformPreview.value = block;
  }

  void clearImageTransformPreview() {
    if (!_isDisposed && imageTransformPreview.value != null) {
      imageTransformPreview.value = null;
    }
  }

  void clearActiveImageBlock() {
    clearImageTransformPreview();
    activeImageBlockId = null;
    _isActiveImageMultiTouch = false;
    notifyListeners();
  }

  void markTextTap() {
    _suppressBackgroundTap = true;
  }

  bool consumeBackgroundTapSuppression() {
    final value = _suppressBackgroundTap;
    _suppressBackgroundTap = false;
    return value;
  }

  void setColor(Color newColor) {
    penColor = newColor;
    _addRecentColor(newColor);
    _schedulePrefsSave();
    notifyListeners();
  }

  void setLastTextFontFamily(String? family) {
    lastTextFontFamily = family;
    _schedulePrefsSave();
  }

  void setLastTextFontSize(double size) {
    lastTextFontSize = size;
    _schedulePrefsSave();
  }

  void setLastTextColor(Color color) {
    lastTextColor = color;
    _addRecentColor(color);
    _schedulePrefsSave();
  }

  void setStrokeWidth(double value) {
    inkStrokeWidth = value;
    _schedulePrefsSave();
    notifyListeners();
  }

  void setPointerInputMode(PointerInputMode mode) {
    if (pointerInputMode == mode) {
      return;
    }
    pointerInputMode = mode;
    _schedulePrefsSave();
    notifyListeners();
  }

  void setStylusButtonsEnabled(bool enabled) {
    if (stylusButtonsEnabled == enabled) {
      return;
    }
    stylusButtonsEnabled = enabled;
    _schedulePrefsSave();
    notifyListeners();
  }

  void setScratchEraseEnabled(bool enabled) {
    if (scratchEraseEnabled == enabled) {
      return;
    }
    scratchEraseEnabled = enabled;
    _schedulePrefsSave();
    notifyListeners();
  }

  void setDefaultBackgroundSettings(
    NotebookKind kind,
    PageBackgroundSettings settings,
  ) {
    switch (kind) {
      case NotebookKind.notebook:
        defaultNotebookBackground = settings;
      case NotebookKind.board:
        defaultBoardBackground = settings;
      case NotebookKind.planner:
        throw UnsupportedError(
          'Planner items do not use page background settings.',
        );
    }
    _dirtyBackgroundDefaultKinds.add(kind);
    if (kind == notebook.kind && !_localBackgrounds.containsKey(notebook.uid)) {
      backgroundSettingsListenable.value = settings;
    }
    _schedulePrefsSave();
    notifyListeners();
  }

  /// Applies the host's background without persisting guest preferences.
  void applySharedBackgroundSettings(PageBackgroundSettings settings) {
    final current = currentBackgroundSettings;
    if (current.style == settings.style &&
        current.spacing == settings.spacing) {
      return;
    }
    _localBackgrounds[notebook.uid] = settings;
    backgroundSettingsListenable.value = settings;
  }

  void setCurrentBackgroundSettings(PageBackgroundSettings settings) {
    final previous = currentBackgroundSettings;
    if (_localBackgrounds.containsKey(notebook.uid) &&
        previous.style == settings.style &&
        previous.spacing == settings.spacing) {
      return;
    }
    _localBackgrounds[notebook.uid] = settings;
    _dirtyLocalBackgroundIds.add(notebook.uid);
    _schedulePrefsSave();
    backgroundSettingsListenable.value = settings;
  }

  /// Replaces the three shared swatches and selects their first color.
  void applyInkColorPreset(InkColorPreset preset) {
    final colors = preset.colors;
    quickColors
      ..clear()
      ..addAll(colors);
    penColor = colors[0];
    _schedulePrefsSave();
    notifyListeners();
  }

  void setQuickColor(int index, Color newColor) {
    if (index < 0 || index >= quickColors.length) {
      return;
    }
    quickColors[index] = newColor;
    setColor(newColor);
    _schedulePrefsSave();
  }

  void _addRecentColor(Color color) {
    recentColors.removeWhere((item) => item.toARGB32() == color.toARGB32());
    recentColors.insert(0, color);
    if (recentColors.length > 12) {
      recentColors.removeRange(12, recentColors.length);
    }
    unawaited(SharedRecentColors.record(color));
  }

  Future<void> _loadEditorPrefs() async {
    try {
      final raw = await readStoredText('editor_prefs.json');
      if (raw == null) {
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      final penHex = decoded['penColor']?.toString();
      final highlighterHex = decoded['highlighterColor']?.toString();
      final lastTextHex = decoded['lastTextColor']?.toString();
      final lastFont = decoded['lastTextFontFamily']?.toString();
      final lastSize = decoded['lastTextFontSize'];
      final strokeWidth = decoded['inkStrokeWidth'];
      final eraserToolIndex = decoded['lastEraserTool'];
      final inputModeIndex = decoded['pointerInputMode'];
      final stylusButtons = decoded['stylusButtonsEnabled'];
      final scratchErase = decoded['scratchEraseEnabled'];
      final backgroundDefaults = decoded['backgroundDefaults'];
      final localBackgrounds = decoded['localBackgrounds'];
      final quick = decoded['quickColors'];
      final recent = decoded['recentColors'];

      final penParsed = _colorFromHex(penHex);
      final highlighterParsed = _colorFromHex(highlighterHex);
      penColor = penParsed ?? highlighterParsed ?? penColor;
      final shouldPersistDrawingColorDefaults =
          penParsed == null || highlighterParsed == null;
      final textParsed = _colorFromHex(lastTextHex);
      if (textParsed != null) {
        lastTextColor = textParsed;
      }
      if (lastFont != null && lastFont.isNotEmpty) {
        lastTextFontFamily = lastFont;
      }
      final sizeParsed = lastSize is num ? lastSize.toDouble() : null;
      if (sizeParsed != null) {
        lastTextFontSize = sizeParsed;
      }
      final strokeWidthParsed = strokeWidth is num
          ? strokeWidth.toDouble()
          : null;
      if (strokeWidthParsed != null && strokeWidthParsed > 0) {
        inkStrokeWidth = strokeWidthParsed;
      }
      final eraserToolParsed = _eraserToolFromIndex(eraserToolIndex);
      if (eraserToolParsed != null) {
        lastEraserTool = eraserToolParsed;
      }
      pointerInputMode = pointerInputModeFromIndex(inputModeIndex);
      if (stylusButtons is bool) {
        stylusButtonsEnabled = stylusButtons;
      }
      if (scratchErase is bool) {
        scratchEraseEnabled = scratchErase;
      }
      if (backgroundDefaults is Map) {
        if (!_dirtyBackgroundDefaultKinds.contains(NotebookKind.notebook)) {
          defaultNotebookBackground = PageBackgroundSettings.fromJson(
            backgroundDefaults[backgroundPrefsKeyForKind(
              NotebookKind.notebook,
            )],
          );
        }
        if (!_dirtyBackgroundDefaultKinds.contains(NotebookKind.board)) {
          defaultBoardBackground = PageBackgroundSettings.fromJson(
            backgroundDefaults[backgroundPrefsKeyForKind(NotebookKind.board)],
          );
        }
      }
      if (localBackgrounds is Map) {
        if (_dirtyLocalBackgroundIds.isEmpty) {
          _localBackgrounds.clear();
        }
        for (final entry in localBackgrounds.entries) {
          if (entry.key is! String) {
            continue;
          }
          final key = entry.key as String;
          if (_dirtyLocalBackgroundIds.contains(key)) {
            continue;
          }
          _localBackgrounds[key] = PageBackgroundSettings.fromJson(entry.value);
        }
      }
      var migratedQuickColors = false;
      if (quick is List) {
        final mapped = quick
            .map((item) => _colorFromHex(item?.toString()))
            .whereType<Color>()
            .toList();
        const lastReleasePresets = <InkColorPreset, List<Color>>{
          InkColorPreset.blue: [
            Color(0xFF263042),
            Color(0xFF354E6B),
            Color(0xFF889BB0),
          ],
          InkColorPreset.green: [
            Color(0xFF273526),
            Color(0xFF45624E),
            Color(0xFFC0CFB2),
          ],
        };
        const previousGreenPreset = <InkColorPreset, List<Color>>{
          InkColorPreset.green: [
            Color(0xFF394931),
            Color(0xFF74866F),
            Color(0xFF9BAE96),
          ],
        };
        const newestPresets = <InkColorPreset, List<Color>>{
          InkColorPreset.blue: [
            Color(0xFF1A2130),
            Color(0xFF6A8AB9),
            Color(0xFF8AAAD1),
          ],
          InkColorPreset.pink: [
            Color(0xFF3A212B),
            Color(0xFFB66D86),
            Color(0xFFCE8DA8),
          ],
          InkColorPreset.green: [
            Color(0xFF1F3027),
            Color(0xFF73AF8E),
            Color(0xFF99C2A8),
          ],
        };
        const recentPresets = <InkColorPreset, List<Color>>{
          InkColorPreset.blue: [
            Color(0xFF1A2130),
            Color(0xFFACBED8),
            Color(0xFFDEE7F2),
          ],
          InkColorPreset.pink: [
            Color(0xFF3A212B),
            Color(0xFFDAB5C2),
            Color(0xFFF2E1E8),
          ],
          InkColorPreset.green: [
            Color(0xFF1F3027),
            Color(0xFFB0D2BF),
            Color(0xFFE4EFE8),
          ],
        };
        const lastPresets = <InkColorPreset, List<Color>>{
          InkColorPreset.blue: [
            Color(0xFF1A2130),
            Color(0xFF7798C0),
            Color(0xFFACBED8),
          ],
          InkColorPreset.pink: [
            Color(0xFF3A212B),
            Color(0xFFA9788A),
            Color(0xFFDAB5C2),
          ],
          InkColorPreset.green: [
            Color(0xFF1F3027),
            Color(0xFF76A58D),
            Color(0xFFB0D2BF),
          ],
        };
        const previousPresets = <InkColorPreset, List<Color>>{
          InkColorPreset.blue: [
            Color(0xFF1A2130),
            Color(0xFF3A4E6F),
            Color(0xFF4B6493),
          ],
          InkColorPreset.pink: [
            Color(0xFF3A212B),
            Color(0xFF6C3C4D),
            Color(0xFF8E5066),
          ],
          InkColorPreset.green: [
            Color(0xFF1F3027),
            Color(0xFF476E5E),
            Color(0xFF5D927D),
          ],
        };
        const earlierPresets = <InkColorPreset, List<Color>>{
          InkColorPreset.blue: [
            Color(0xFF2A3851),
            Color(0xFFA1B2CE),
            Color(0xFFD0D8E7),
          ],
          InkColorPreset.pink: [
            Color(0xFF583240),
            Color(0xFFCCA4B2),
            Color(0xFFE9D8DE),
          ],
          InkColorPreset.green: [
            Color(0xFF2C443A),
            Color(0xFF9BBFB0),
            Color(0xFFD0E1DA),
          ],
        };
        InkColorPreset? previousPreset;
        List<Color>? previousColors;
        for (final entry in [
          ...lastReleasePresets.entries,
          ...previousGreenPreset.entries,
          ...newestPresets.entries,
          ...recentPresets.entries,
          ...lastPresets.entries,
          ...previousPresets.entries,
          ...earlierPresets.entries,
        ]) {
          if (mapped.length == 3 &&
              mapped[0] == entry.value[0] &&
              mapped[1] == entry.value[1] &&
              mapped[2] == entry.value[2]) {
            previousPreset = entry.key;
            previousColors = entry.value;
            break;
          }
        }
        final isLegacyDefaults =
            mapped.length == 3 &&
            mapped[0] == const Color(0xFF1E1E1E) &&
            mapped[1] == const Color(0xFFD32F2F) &&
            mapped[2] == const Color(0xFF2E7D32);
        if (previousPreset != null && previousColors != null) {
          migratedQuickColors = true;
          quickColors
            ..clear()
            ..addAll(previousPreset.colors);
          if (penParsed != null) {
            final index = previousColors.indexOf(penParsed);
            if (index != -1) {
              penColor = previousPreset.colors[index];
            }
          }
          if (penParsed == null && highlighterParsed != null) {
            final index = previousColors.indexOf(highlighterParsed);
            if (index != -1) {
              penColor = previousPreset.colors[index];
            }
          }
        } else if (isLegacyDefaults) {
          migratedQuickColors = true;
          if (penParsed == const Color(0xFF1E2A40)) {
            penColor = InkColorPreset.blue.colors[0];
          }
          if (penParsed == null &&
              highlighterParsed == const Color(0xFF536783)) {
            penColor = InkColorPreset.blue.colors[0];
          }
        } else if (mapped.isNotEmpty) {
          quickColors
            ..clear()
            ..addAll(mapped);
        }
      }
      final sharedRecent = await SharedRecentColors.load();
      final legacyRecent = recent is List
          ? recent
                .map((item) => _colorFromHex(item?.toString()))
                .whereType<Color>()
                .toList()
          : <Color>[];
      final mergedRecent = SharedRecentColors.merge(
        recentColors,
        sharedRecent.isNotEmpty ? sharedRecent : legacyRecent,
      );
      recentColors
        ..clear()
        ..addAll(mergedRecent);
      if (shouldPersistDrawingColorDefaults || migratedQuickColors) {
        _schedulePrefsSave();
      }
      backgroundSettingsListenable.value = currentBackgroundSettings;
      notifyListeners();
    } catch (e) {
      debugPrint('EditorController._loadEditorPrefs failed: $e');
    }
  }

  void _schedulePrefsSave() {
    _prefsSaveDebounce?.cancel();
    _prefsSaveDebounce = Timer(const Duration(milliseconds: 250), () {
      _prefsSaveDebounce = null;
      unawaited(_queueEditorPrefsSave());
    });
  }

  Future<void> _queueEditorPrefsSave() {
    final previous = _activePrefsSave ?? Future<void>.value();
    late final Future<void> next;
    next = previous.then((_) => _saveEditorPrefs()).whenComplete(() {
      if (identical(_activePrefsSave, next)) {
        _activePrefsSave = null;
      }
    });
    _activePrefsSave = next;
    return next;
  }

  Future<void> _saveEditorPrefs() async {
    try {
      final existing = await _readEditorPrefs();
      final dirtyBackgroundDefaultKinds = Set<NotebookKind>.of(
        _dirtyBackgroundDefaultKinds,
      );
      final dirtyLocalBackgroundIds = Set<String>.of(_dirtyLocalBackgroundIds);
      final payload = <String, dynamic>{
        'inkColor': _colorToHex(penColor),
        'penColor': _colorToHex(penColor),
        'highlighterColor': _colorToHex(penColor),
        'quickColors': quickColors.map(_colorToHex).toList(),
        'recentColors': recentColors.map(_colorToHex).toList(),
        'lastTextColor': _colorToHex(lastTextColor),
        'lastTextFontFamily': lastTextFontFamily,
        'lastTextFontSize': lastTextFontSize,
        'inkStrokeWidth': inkStrokeWidth,
        'lastEraserTool': lastEraserTool.index,
        'pointerInputMode': pointerInputMode.index,
        'stylusButtonsEnabled': stylusButtonsEnabled,
        'scratchEraseEnabled': scratchEraseEnabled,
        'backgroundDefaults': _mergedBackgroundDefaults(
          existing['backgroundDefaults'],
          dirtyBackgroundDefaultKinds,
        ),
        'localBackgrounds': _mergedLocalBackgrounds(
          existing['localBackgrounds'],
          dirtyLocalBackgroundIds,
        ),
      };
      await writeStoredText('editor_prefs.json', jsonEncode(payload));
      _dirtyBackgroundDefaultKinds.removeAll(dirtyBackgroundDefaultKinds);
      _dirtyLocalBackgroundIds.removeAll(dirtyLocalBackgroundIds);
    } catch (e) {
      debugPrint('EditorController._saveEditorPrefs failed: $e');
    }
  }

  Future<Map<String, dynamic>> _readEditorPrefs() async {
    try {
      final content = await readStoredText('editor_prefs.json');
      if (content == null) {
        return <String, dynamic>{};
      }
      final decoded = jsonDecode(content);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (e) {
      debugPrint('EditorController._readEditorPrefs failed: $e');
      return <String, dynamic>{};
    }
  }

  Map<String, dynamic> _mergedBackgroundDefaults(
    Object? existingValue,
    Set<NotebookKind> dirtyKinds,
  ) {
    final merged = <String, dynamic>{};
    if (existingValue is Map) {
      for (final entry in existingValue.entries) {
        if (entry.key is String) {
          merged[entry.key as String] = entry.value;
        }
      }
    }

    for (final kind in const [NotebookKind.notebook, NotebookKind.board]) {
      final key = backgroundPrefsKeyForKind(kind);
      if (dirtyKinds.contains(kind) || !merged.containsKey(key)) {
        merged[key] = defaultBackgroundSettingsForKind(kind).toJson();
      }
    }
    return merged;
  }

  Map<String, dynamic> _mergedLocalBackgrounds(
    Object? existingValue,
    Set<String> dirtyIds,
  ) {
    final merged = <String, dynamic>{};
    if (existingValue is Map) {
      for (final entry in existingValue.entries) {
        if (entry.key is String) {
          merged[entry.key as String] = entry.value;
        }
      }
    }

    if (merged.isEmpty && dirtyIds.isEmpty) {
      return _localBackgrounds.map(
        (key, value) => MapEntry(key, value.toJson()),
      );
    }
    for (final id in dirtyIds) {
      final settings = _localBackgrounds[id];
      if (settings != null) {
        merged[id] = settings.toJson();
      }
    }
    return merged;
  }

  DrawingTool? _eraserToolFromIndex(Object? value) {
    if (value is! int || value < 0 || value >= DrawingTool.values.length) {
      return null;
    }
    final parsed = DrawingTool.values[value];
    return parsed.isEraser ? parsed : null;
  }

  Color? _colorFromHex(String? value) {
    if (value == null) {
      return null;
    }
    final normalized = value.replaceAll('#', '').trim();
    if (normalized.length != 6) {
      return null;
    }
    final parsed = int.tryParse(normalized, radix: 16);
    if (parsed == null) {
      return null;
    }
    return Color(0xFF000000 | parsed);
  }

  Future<String?> handleTap(Offset point) async {
    if (tool == DrawingTool.text) {
      addTextBlock(point);
      return null;
    }
    if (tool == DrawingTool.image) {
      return addImageBlock(point);
    }
    return null;
  }

  void undo() {
    if (operationWriter != null) {
      _queueV2History(undo: true);
      return;
    }
    _commitActiveTextEdit();
    if (_undoActions.isEmpty) {
      return;
    }
    final entry = _undoActions.removeLast();
    final action = entry.action;
    if (action is MoveImageBetweenPagesAction) {
      _applyCrossPageImageMove(action, undo: true);
      _redoActions.add(entry);
      _notifyHistoryChanged();
      notifyListeners();
      _save();
      return;
    }
    final index = pages.indexWhere((page) => page.id == entry.pageId);
    if (index < 0) {
      _undoActions.clear();
      _redoActions.clear();
      _notifyHistoryChanged();
      return;
    }
    final before = pages[index];
    final updated = action.revert(before);
    _recordExpectedRemovals(action, before, updated, undo: true);
    _redoActions.add(entry);
    _notifyHistoryChanged();
    // Reuse normal navigation cleanup for active overlays and selections.
    setCurrentPage(index);
    _updatePage(updated);
    if (action is UpdateInkStrokeAction) {
      _touchInkPageRevision(updated.id);
    }
    _save();
  }

  void redo() {
    if (operationWriter != null) {
      _queueV2History(undo: false);
      return;
    }
    _commitActiveTextEdit();
    if (_redoActions.isEmpty) {
      return;
    }
    final entry = _redoActions.removeLast();
    final action = entry.action;
    if (action is MoveImageBetweenPagesAction) {
      _applyCrossPageImageMove(action, undo: false);
      _undoActions.add(entry);
      _notifyHistoryChanged();
      notifyListeners();
      _save();
      return;
    }
    final index = pages.indexWhere((page) => page.id == entry.pageId);
    if (index < 0) {
      _undoActions.clear();
      _redoActions.clear();
      _notifyHistoryChanged();
      return;
    }
    final before = pages[index];
    final updated = action.apply(before);
    _recordExpectedRemovals(action, before, updated);
    _undoActions.add(entry);
    _notifyHistoryChanged();
    // Reuse normal navigation cleanup for active overlays and selections.
    setCurrentPage(index);
    _updatePage(updated);
    if (action is UpdateInkStrokeAction) {
      _touchInkPageRevision(updated.id);
    }
    _save();
  }

  /// Queues inverse edits behind any in-flight local v2 batch.
  ///
  /// Each inverse is a new durable operation; no old tombstoned identity is
  /// resurrected. Failed inverses leave both the UI and the history intact.
  void _queueV2History({required bool undo}) {
    if (_isDisposed) {
      return;
    }
    final previous = _v2HistoryTail ?? Future<void>.value();
    late final Future<void> next;
    next = previous
        .then((_) => _applyV2History(undo: undo))
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint(
            'EditorController v2 history blocked: '
            '$error\\n$stackTrace',
          );
        })
        .whenComplete(() {
          if (identical(_v2HistoryTail, next)) {
            _v2HistoryTail = null;
          }
        });
    _v2HistoryTail = next;
  }

  Future<void> _applyV2History({required bool undo}) async {
    if (InkActivityTracker.instance.hasActiveContacts) {
      return;
    }
    _commitActiveTextEdit();
    await historyReady;
    if (_v2HistoryLoadError != null) {
      throw StateError('Cannot undo with invalid local history.');
    }
    await _v2SaveTail;
    if (_fullSavePending || _dirtyPageIds.isNotEmpty) {
      await _saveV2();
    }
    if (_integritySaveBlocked) {
      throw StateError('Cannot undo an uncommitted editor change.');
    }
    final source = undo ? _v2Undo : _v2Redo;
    if (source.isEmpty) {
      return;
    }
    final entry = source.last;
    final original = _v2PersistedNotebook;
    final desired = undo
        ? entry.before ??
              await _v2HistoryCodec!.decode(
                entry.stored.before,
                documentId: notebook.uid,
              )
        : entry.after ??
              await _v2HistoryCodec!.decode(
                entry.stored.after,
                documentId: notebook.uid,
              );
    final restoration = _reidentifyV2RestoredObjects(
      current: original,
      desired: desired,
    );
    final restored = restoration.notebook;
    final visibleBeforeCommit = pages;
    _v2HistoryCommitting = true;
    late final bool hasCommitted;
    List<_V2HistoryEntry>? nextUndo;
    List<_V2HistoryEntry>? nextRedo;
    EditorHistoryCheckpoint? checkpoint;
    try {
      final committed = await operationWriter!.writeNotebookChange(
        before: original,
        after: restored,
        revertsOperationId: entry.operationId,
        onCommittedInTransaction: (operations) async {
          final changed = operations.isNotEmpty;
          nextUndo = [
            for (final item in _v2Undo)
              changed ? _remapV2HistoryEntry(item, restoration) : item,
          ];
          nextRedo = [
            for (final item in _v2Redo)
              changed ? _remapV2HistoryEntry(item, restoration) : item,
          ];
          final source = undo ? nextUndo! : nextRedo!;
          final destination = undo ? nextRedo! : nextUndo!;
          final moved = source.removeLast();
          destination.add(
            changed
                ? _remapV2HistoryEntry(moved, (
                    notebook: restored,
                    pages: const <String, String>{},
                    objects: const <String, String>{},
                  ), operationId: operations.last.operationId)
                : moved,
          );
          checkpoint = await _persistV2History(
            operations,
            undo: nextUndo!,
            redo: nextRedo!,
          );
        },
      );
      hasCommitted = committed.isNotEmpty;
      _installV2History(checkpoint, nextUndo!, nextRedo!);
    } finally {
      _v2HistoryCommitting = false;
    }
    if (!hasCommitted) {
      _notifyHistoryChanged();
      return;
    }
    _v2PersistedNotebook = restored;
    notebook = restored;
    if (!identical(pages, visibleBeforeCommit)) {
      // A new gesture arrived during the inverse write. Preserve its
      // optimistic state instead of silently replacing it with the inverse.
      _integritySaveBlocked = true;
      _fullSavePending = true;
      _dirtyPageIds.addAll(pages.map((page) => page.id));
      _notifyHistoryChanged();
      notifyListeners();
      return;
    }
    final selectedId = currentPage.id;
    pages = restored.pages;
    final selected = pages.indexWhere((page) => page.id == selectedId);
    currentPageIndex = selected < 0
        ? currentPageIndex.clamp(0, pages.length - 1).toInt()
        : selected;
    activeTextBlockId = null;
    activeTextController = null;
    activeImageBlockId = null;
    lassoSelection = null;
    _undoActions.clear();
    _redoActions.clear();
    _fullSavePending = false;
    _dirtyPageIds.clear();
    _expectedRemovedIdsByPage.clear();
    _expectedRemovedPageIds.clear();
    _notifyHistoryChanged();
    for (final page in pages) {
      _touchInkPageRevision(page.id);
    }
    notifyListeners();
  }

  Future<void> _restoreV2History() async {
    try {
      final checkpoint = await _v2HistoryStore!.load(
        documentId: notebook.uid,
        ownerId: operationWriter!.syncEngine.actorIdForDocument(notebook.uid),
      );
      if (_isDisposed || checkpoint == null) {
        return;
      }
      _v2Undo
        ..clear()
        ..addAll(checkpoint.undo.map(_V2HistoryEntry.recovered));
      _v2Redo
        ..clear()
        ..addAll(checkpoint.redo.map(_V2HistoryEntry.recovered));
      _notifyHistoryChanged();
    } catch (error, stackTrace) {
      _v2HistoryLoadError = error;
      _integritySaveBlocked = true;
      debugPrint(
        'EditorController v2 history recovery blocked: $error\n$stackTrace',
      );
    } finally {
      _v2HistoryRecovering = false;
    }
  }

  /// Runs inside the same SQLite transaction as the journal projection.
  Future<EditorHistoryCheckpoint?> _persistV2History(
    List<OperationEnvelope> operations, {
    required List<_V2HistoryEntry> undo,
    required List<_V2HistoryEntry> redo,
  }) async {
    if (operations.isEmpty && undo.isEmpty && redo.isEmpty) {
      return null;
    }
    final database = operationWriter!.projector.database;
    final head = operations.isNotEmpty
        ? operations.last.operationId
        : (await database
                  .customSelect(
                    'SELECT operation_id FROM operations WHERE document_id = ? '
                    'ORDER BY rowid DESC LIMIT 1',
                    variables: [Variable<String>(notebook.uid)],
                  )
                  .getSingleOrNull())
              ?.read<String>('operation_id');
    if (head == null) {
      return null;
    }
    final keepUndo = List<_V2HistoryEntry>.of(undo);
    final keepRedo = List<_V2HistoryEntry>.of(redo);
    while (keepUndo.length + keepRedo.length >
        EditorHistoryCheckpoint.maximumGestures) {
      if (keepUndo.isNotEmpty) {
        keepUndo.removeAt(0);
      } else {
        keepRedo.removeAt(0);
      }
    }
    final requested = EditorHistoryCheckpoint(
      documentId: notebook.uid,
      ownerId: operationWriter!.syncEngine.actorIdForDocument(notebook.uid),
      headOperationId: head,
      undo: [for (final item in keepUndo) item.stored],
      redo: [for (final item in keepRedo) item.stored],
    );
    final fitted = requested.fitToByteBudget();
    await _v2HistoryStore!.save(fitted);
    return fitted;
  }

  void _installV2History(
    EditorHistoryCheckpoint? checkpoint,
    List<_V2HistoryEntry> undo,
    List<_V2HistoryEntry> redo,
  ) {
    if (checkpoint == null) {
      return;
    }
    _v2Undo
      ..clear()
      ..addAll(undo.skip(undo.length - checkpoint.undo.length));
    _v2Redo
      ..clear()
      ..addAll(redo.skip(redo.length - checkpoint.redo.length));
  }

  _V2HistoryEntry _remapV2HistoryEntry(
    _V2HistoryEntry entry,
    ({
      Notebook notebook,
      Map<String, String> pages,
      Map<String, String> objects,
    })
    restoration, {
    String? operationId,
  }) {
    final codec = _v2HistoryCodec!;
    final stored = StoredEditorGesture(
      before: codec.remapIdentities(
        entry.stored.before,
        documentId: notebook.uid,
        pageIds: restoration.pages,
        objectIds: restoration.objects,
      ),
      after: codec.remapIdentities(
        entry.stored.after,
        documentId: notebook.uid,
        pageIds: restoration.pages,
        objectIds: restoration.objects,
      ),
      operationId: operationId ?? entry.operationId,
    );
    return _V2HistoryEntry(
      entry.before == null
          ? null
          : _remapV2HistoryNotebook(entry.before!, restoration),
      entry.after == null
          ? null
          : _remapV2HistoryNotebook(entry.after!, restoration),
      stored.operationId,
      stored: stored,
    );
  }

  ({Notebook notebook, Map<String, String> pages, Map<String, String> objects})
  _reidentifyV2RestoredObjects({
    required Notebook current,
    required Notebook desired,
  }) {
    final pageIds = {for (final page in current.pages) page.id};
    final objectIds = <String>{
      for (final page in current.pages)
        ...page.inkStrokes.map((item) => item.id),
      for (final page in current.pages)
        ...page.textBlocks.map((item) => item.id),
      for (final page in current.pages)
        ...page.imageBlocks.map((item) => item.id),
    };
    final restoredPages = <String, String>{};
    final restoredObjects = <String, String>{};
    String restoredId(String id) =>
        objectIds.contains(id) ? id : restoredObjects.putIfAbsent(id, _uuid.v4);
    final restored = desired.copyWith(
      pages: [
        for (final page in desired.pages)
          page.copyWith(
            id: pageIds.contains(page.id)
                ? page.id
                : restoredPages.putIfAbsent(page.id, _uuid.v4),
            inkStrokes: [
              for (final stroke in page.inkStrokes)
                stroke.copyWith(id: restoredId(stroke.id)),
            ],
            textBlocks: [
              for (final block in page.textBlocks)
                block.copyWith(id: restoredId(block.id)),
            ],
            imageBlocks: [
              for (final block in page.imageBlocks)
                block.copyWith(id: restoredId(block.id)),
            ],
          ),
      ],
    );
    return (notebook: restored, pages: restoredPages, objects: restoredObjects);
  }

  Notebook _remapV2HistoryNotebook(
    Notebook snapshot,
    ({
      Notebook notebook,
      Map<String, String> pages,
      Map<String, String> objects,
    })
    restoration,
  ) {
    if (restoration.pages.isEmpty && restoration.objects.isEmpty) {
      return snapshot;
    }
    return snapshot.copyWith(
      pages: [
        for (final page in snapshot.pages)
          page.copyWith(
            id: restoration.pages[page.id] ?? page.id,
            inkStrokes: [
              for (final stroke in page.inkStrokes)
                restoration.objects.containsKey(stroke.id)
                    ? stroke.copyWith(id: restoration.objects[stroke.id])
                    : stroke,
            ],
            textBlocks: [
              for (final block in page.textBlocks)
                restoration.objects.containsKey(block.id)
                    ? block.copyWith(id: restoration.objects[block.id])
                    : block,
            ],
            imageBlocks: [
              for (final block in page.imageBlocks)
                restoration.objects.containsKey(block.id)
                    ? block.copyWith(id: restoration.objects[block.id])
                    : block,
            ],
          ),
      ],
    );
  }

  void addPage() {
    _commitActiveTextEdit();
    final nextIndex = pages.length + 1;
    final page = _createPage(nextIndex);
    pages = [...pages, page];
    currentPageIndex = pages.length - 1;
    activeTextBlockId = null;
    activeTextController = null;
    activeImageBlockId = null;
    _captureV2Gesture();
    _save();
    notifyListeners();
  }

  void deleteLastPage() {
    _commitActiveTextEdit();
    if (pages.length <= 1) {
      return;
    }
    final removedPageId = pages.last.id;
    bool referencesRemovedPage(_EditorHistoryEntry entry) {
      final action = entry.action;
      return entry.pageId == removedPageId ||
          (action is MoveImageBetweenPagesAction &&
              (action.fromPageId == removedPageId ||
                  action.toPageId == removedPageId));
    }

    _undoActions.removeWhere(referencesRemovedPage);
    _redoActions.removeWhere(referencesRemovedPage);
    _notifyHistoryChanged();
    _expectedRemovedPageIds.add(removedPageId);
    pages = pages.take(pages.length - 1).toList();
    currentPageIndex = currentPageIndex.clamp(0, pages.length - 1).toInt();
    activeTextBlockId = null;
    activeTextController = null;
    activeImageBlockId = null;
    _captureV2Gesture();
    _save();
    notifyListeners();
  }

  NotePage _createPage(int index) {
    return NotePage(
      id: _uuid.v4(),
      title: 'Page $index',
      textBlocks: <TextBlock>[],
      imageBlocks: <ImageBlock>[],
      inkStrokes: <InkStroke>[],
      isBookmarked: false,
    );
  }

  void _ensurePageCount(List<NotePage> working, int count) {
    while (working.length < count) {
      working.add(_createPage(working.length + 1));
    }
  }

  void setCurrentPage(int index) {
    if (index < 0 || index >= pages.length) {
      return;
    }
    if (currentPageIndex == index) {
      return;
    }
    if (activeShapeStrokeId != null) {
      finishShapeEdit();
    }
    _commitActiveTextEdit();
    activeTextBlockId = null;
    activeTextController = null;
    activeImageBlockId = null;
    currentPageIndex = index;
    notifyListeners();
  }

  void toggleBookmark() {
    final page = currentPage.copyWith(isBookmarked: !currentPage.isBookmarked);
    _updatePage(page);
    _save();
  }

  void addTextBlock(Offset position) {
    final baseSize = lastTextFontSize;
    final baseColor = lastTextColor;
    final delta = quill_delta.Delta()
      ..insert('Text', <String, dynamic>{
        'size': baseSize.toInt().toString(),
        'color': _colorToHex(baseColor),
        if (lastTextFontFamily != null) 'font': lastTextFontFamily,
      })
      ..insert('\n');
    final doc = quill.Document.fromDelta(delta);
    final block = TextBlock(
      id: _uuid.v4(),
      text: 'Text',
      deltaJson: jsonEncode(doc.toDelta().toJson()),
      position: position,
      fontSize: baseSize,
      color: baseColor,
      width: 240,
    );
    _applyAction(AddTextAction(block));
    setTool(DrawingTool.edit);
    setActiveTextBlock(block.id, null);
    _save();
  }

  void addTextBlockFromText(Offset position, String text) {
    final baseSize = lastTextFontSize;
    final baseColor = lastTextColor;
    final normalized = text.trimRight();
    final delta = quill_delta.Delta();
    if (normalized.isNotEmpty) {
      delta.insert(normalized, <String, dynamic>{
        'size': baseSize.toInt().toString(),
        'color': _colorToHex(baseColor),
        if (lastTextFontFamily != null) 'font': lastTextFontFamily,
      });
    }
    delta.insert('\n');
    final doc = quill.Document.fromDelta(delta);
    final block = TextBlock(
      id: _uuid.v4(),
      text: normalized,
      deltaJson: jsonEncode(doc.toDelta().toJson()),
      position: position,
      fontSize: baseSize,
      color: baseColor,
      width: 260,
    );
    _applyAction(AddTextAction(block));
    setTool(DrawingTool.edit);
    setActiveTextBlock(block.id, null);
    _save();
  }

  /// Prepares new inline media for Quill's next normal text mutation.
  String prepareInlineAsset({
    required String blockId,
    required Uint8List bytes,
    required String embedType,
  }) {
    final writer = operationWriter;
    if (writer == null ||
        _isDisposed ||
        _v2DocumentDeleted ||
        activeTextBlockId != blockId ||
        _pageIndexContainingTextBlock(blockId) == null) {
      throw StateError('Inline imports require an active v2 text block.');
    }
    final asset = writer.stageQuillAsset(
      documentId: notebook.uid,
      bytes: bytes,
      embedType: embedType,
    );
    return 'asset:${asset.assetId}';
  }

  /// Owns rich paste so rejected or stale content cannot delete the selection.
  Future<bool> pasteQuillHtml({
    required String blockId,
    required Future<String?> Function() readHtml,
    Future<String?> Function()? readPlainText,
    bool Function()? canPaste,
  }) => _replaceQuillSelection(
    blockId: blockId,
    canInsert: canPaste,
    readPlan: (target, current) async {
      final clipboardSource = target ?? quill.QuillController.basic();
      final copiedText = clipboardSource.pastePlainText;
      final copiedDelta =
          jsonDecode(jsonEncode(clipboardSource.pasteDelta.toJson())) as List;
      if (target == null) {
        clipboardSource.dispose();
      }
      final plain = readPlainText == null ? null : await readPlainText();
      if (!current()) {
        return null;
      }
      if (plain != null &&
          copiedText.isNotEmpty &&
          plain == copiedText &&
          copiedDelta.isNotEmpty) {
        return QuillPastePlan.fromDelta(copiedDelta);
      }
      final html = await readHtml();
      if (!current() || html == null || html.trim().isEmpty) {
        return null;
      }
      if (html.length > QuillPastePlan.maximumBytes * 3 + 65536) {
        throw const FormatException('Rich clipboard content is too large.');
      }
      return QuillPastePlan.fromDelta(HtmlToDelta().convert(html).toJson());
    },
  );

  /// Inserts verified media at the captured Quill selection, without rendering
  /// PDF pages into unrelated canvas objects or writing before the text gesture.
  Future<bool> insertQuillFile({
    required String blockId,
    Future<Uint8List?> Function()? readBytes,
    bool Function()? canInsert,
  }) => _replaceQuillSelection(
    blockId: blockId,
    canInsert: canInsert,
    readPlan: (_, current) async {
      final bytes = readBytes == null
          ? await _pickQuillFile(current)
          : await readBytes();
      if (!current() || bytes == null) {
        return null;
      }
      return QuillPastePlan.fromMediaBytes(bytes);
    },
  );

  Future<Uint8List?> _pickQuillFile(bool Function() current) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'pdf'],
      withData: kIsWeb,
    );
    if (!current() || result == null) {
      return null;
    }
    if (result.files.length != 1) {
      throw const FormatException('Select a single inline file.');
    }
    final picked = result.files.single;
    if (picked.size <= 0 || picked.size > QuillPastePlan.maximumBytes) {
      throw const FormatException('Invalid inline file size.');
    }
    // Some native pickers provide bytes without a path as well.
    if (picked.bytes != null) {
      return picked.bytes;
    }
    if (kIsWeb) {
      throw const FormatException('Selected file is not accessible.');
    }
    final path = picked.path;
    if (path == null || path.isEmpty) {
      throw const FormatException('Selected file is not accessible.');
    }
    final file = File(path);
    final length = await file.length();
    if (!current()) {
      return null;
    }
    if (length <= 0 || length > QuillPastePlan.maximumBytes) {
      throw const FormatException('Invalid inline file size.');
    }
    return file.readAsBytes();
  }

  Future<bool> _replaceQuillSelection({
    required String blockId,
    required Future<QuillPastePlan?> Function(
      quill.QuillController? target,
      bool Function() current,
    )
    readPlan,
    bool Function()? canInsert,
  }) async {
    final writer = operationWriter;
    if (writer == null) {
      return false;
    }
    final target = activeTextController;
    final hud = target == null ? activeHudTextController : null;
    final pageIndex = _pageIndexContainingTextBlock(blockId);
    if (_isDisposed ||
        _v2DocumentDeleted ||
        (target == null && hud == null) ||
        target?.readOnly == true ||
        activeTextBlockId != blockId ||
        pageIndex == null) {
      return true;
    }
    final pageId = pages[pageIndex].id;
    final selection = target?.selection ?? hud!.selection;
    final beforeDelta = target == null
        ? null
        : jsonEncode(target.document.toDelta().toJson());
    final beforeHud = hud?.value;
    final beforeModel = findTextBlockById(blockId)!.deltaJson;
    if (!selection.isValid ||
        (target != null
            ? selection.end >= target.document.length
            : selection.end > beforeHud!.text.length)) {
      return true;
    }
    bool current() {
      if (_isDisposed ||
          _v2DocumentDeleted ||
          canInsert?.call() == false ||
          !identical(activeTextController, target) ||
          activeTextBlockId != blockId ||
          target?.readOnly == true ||
          (target != null
              ? target.selection != selection
              : !identical(activeHudTextController, hud) ||
                    hud!.value != beforeHud)) {
        return false;
      }
      final index = _pageIndexContainingTextBlock(blockId);
      return index != null &&
          pages[index].id == pageId &&
          findTextBlockById(blockId)?.deltaJson == beforeModel &&
          (target == null ||
              jsonEncode(target.document.toDelta().toJson()) == beforeDelta);
    }

    if (!current()) {
      return true;
    }
    final plan = await readPlan(target, current);
    if (!current()) {
      return true;
    }
    if (plan == null) {
      return false;
    }
    if (plan.characterCount == 0) {
      return true;
    }
    final document =
        target?.document ??
        quill.Document.fromJson(
          beforeModel == null
              ? [
                  {'insert': '${beforeHud!.text}\n'},
                ]
              : jsonDecode(beforeModel) as List,
        );
    final beforeText = document.toPlainText();
    bool splitsSurrogate(int offset) =>
        offset > 0 &&
        offset < beforeText.length &&
        beforeText.codeUnitAt(offset - 1) >= 0xD800 &&
        beforeText.codeUnitAt(offset - 1) <= 0xDBFF &&
        beforeText.codeUnitAt(offset) >= 0xDC00 &&
        beforeText.codeUnitAt(offset) <= 0xDFFF;
    if (splitsSurrogate(selection.start) || splitsSurrogate(selection.end)) {
      throw const FormatException('Text selection splits a Unicode character.');
    }
    if (hud != null &&
        beforeText != '${beforeHud!.text}\n' &&
        !(beforeText.startsWith(beforeHud.text) &&
            beforeText.substring(beforeHud.text.length).trim().isEmpty)) {
      throw const FormatException('HUD text differs from its rich document.');
    }
    final selected = beforeText.substring(selection.start, selection.end);
    if (beforeText.runes.length -
            selected.runes.length +
            plan.characterCount +
            2 * plan.embedCount >
        ShareTextEditAdapter.maxCodePoints) {
      throw const FormatException(
        'Rich paste exceeds the text operation budget.',
      );
    }
    var totalBytes = plan.importedByteLength;
    for (final entry in plan.existingAssets.entries) {
      final receipt = await writer.verifyQuillAssetReference(
        documentId: notebook.uid,
        assetId: entry.key,
        embedType: entry.value,
        byteLimit: QuillPastePlan.maximumBytes - totalBytes,
      );
      if (!current()) {
        return true;
      }
      totalBytes += receipt['sizeBytes'] as int;
    }
    if (!current()) {
      return true;
    }
    final ready = quill_delta.Delta.fromJson(
      plan.materialize(
        (bytes, type) =>
            prepareInlineAsset(blockId: blockId, bytes: bytes, embedType: type),
      ),
    );
    final editing =
        target ??
        quill.QuillController(document: document, selection: selection);
    try {
      editing.replaceText(
        selection.start,
        selection.end - selection.start,
        ready,
        TextSelection.collapsed(offset: selection.start + ready.length),
      );
      if (target == null) {
        final deltaJson = jsonEncode(editing.document.toDelta().toJson());
        _commitActiveTextEdit();
        updateTextBlockContentOnPage(
          pageIndex,
          findTextBlockById(blockId)!,
          plainText: editing.document.toPlainText(),
          deltaJson: deltaJson,
        );
        _commitActiveTextEdit();
        _quillHandoff = (
          blockId: blockId,
          deltaJson: deltaJson,
          selection: editing.selection,
        );
        notifyListeners();
      }
    } finally {
      if (target == null) {
        editing.dispose();
      }
    }
    return true;
  }

  void updateTextBlockContent(
    TextBlock before, {
    required String plainText,
    required String deltaJson,
  }) {
    final normalizedText = plainText.trimRight();
    final after = before.copyWith(text: normalizedText, deltaJson: deltaJson);
    if (before.text == after.text && before.deltaJson == after.deltaJson) {
      return;
    }
    _beginTextEdit(before.id);
    _replaceTextBlockOnCurrentPage(after, notify: false);
    _scheduleSave();
  }

  void updateActiveTextStyle({
    String? targetBlockId,
    String? fontFamily,
    bool clearFontFamily = false,
    double? fontSize,
    Color? color,
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strike,
    String? alignment,
    bool clearDecorations = false,
  }) {
    final blockId = targetBlockId ?? activeTextBlockId;
    if (blockId == null) {
      return;
    }

    _commitActiveTextEdit();
    final pageIndex = _pageIndexContainingTextBlock(blockId);
    if (pageIndex == null) {
      return;
    }
    final before = pages[pageIndex].textBlocks
        .where((item) => item.id == blockId)
        .firstOrNull;
    if (before == null) {
      return;
    }

    final inline = _textInlineAttributes(before.deltaJson);
    final paragraph = _textParagraphAttributes(before.deltaJson);

    if (clearDecorations) {
      inline.remove('bold');
      inline.remove('italic');
      inline.remove('underline');
      inline.remove('strike');
    }
    if (clearFontFamily) {
      inline.remove('font');
    } else if (fontFamily != null) {
      inline['font'] = fontFamily;
    }

    void setFlag(String key, bool? value) {
      if (value == null) {
        return;
      }
      if (value) {
        inline[key] = true;
      } else {
        inline.remove(key);
      }
    }

    setFlag('bold', bold);
    setFlag('italic', italic);
    setFlag('underline', underline);
    setFlag('strike', strike);

    final nextFontSize = fontSize ?? before.fontSize;
    final nextColor = color ?? before.color;
    inline['size'] = nextFontSize.round().toString();
    inline['color'] = _colorToHex(nextColor);

    if (alignment != null) {
      if (alignment == 'left') {
        paragraph.remove('align');
      } else {
        paragraph['align'] = alignment;
      }
    }

    final after = before.copyWith(
      fontSize: nextFontSize,
      color: nextColor,
      deltaJson: operationWriter != null && before.deltaJson != null
          ? patchQuillStyle(
              before.deltaJson!,
              inlineChanges: {
                if (clearDecorations)
                  for (final key in ['bold', 'italic', 'underline', 'strike'])
                    key: null,
                if (clearFontFamily)
                  'font': null
                else if (fontFamily != null)
                  'font': fontFamily,
                if (fontSize != null) 'size': nextFontSize.round().toString(),
                if (color != null) 'color': _colorToHex(nextColor),
                if (bold != null) 'bold': bold ? true : null,
                if (italic != null) 'italic': italic ? true : null,
                if (underline != null) 'underline': underline ? true : null,
                if (strike != null) 'strike': strike ? true : null,
              },
              paragraphChanges: {
                if (alignment != null)
                  'align': alignment == 'left' ? null : alignment,
              },
            )
          : _buildTextDeltaJson(
              before.text,
              inline: inline,
              paragraph: paragraph,
            ),
    );

    commitTextUpdateOnPage(pageIndex, before, after);

    if (clearFontFamily) {
      setLastTextFontFamily(null);
    } else if (fontFamily != null) {
      setLastTextFontFamily(fontFamily);
    }
    if (fontSize != null) {
      setLastTextFontSize(fontSize);
    }
    if (color != null) {
      setLastTextColor(color);
    }
    if (activeTextBlockId == blockId) {
      _beginTextEdit(blockId);
    }
  }

  void updateTextBlockPosition(String id, Offset position) {
    final updated = currentPage.textBlocks
        .map((item) => item.id == id ? item.copyWith(position: position) : item)
        .toList();
    _updatePage(currentPage.copyWith(textBlocks: updated));
  }

  void updateTextBlockWidth(String id, double width) {
    final updated = currentPage.textBlocks
        .map((item) => item.id == id ? item.copyWith(width: width) : item)
        .toList();
    _updatePage(currentPage.copyWith(textBlocks: updated));
  }

  void deleteTextBlock(String id) {
    final block = currentPage.textBlocks.firstWhere((item) => item.id == id);
    if (activeTextBlockId == id && operationWriter == null) {
      _discardActiveTextEdit();
    }
    _applyAction(DeleteTextAction(block));
    clearActiveTextBlock();
    _save();
  }

  void commitTextMove(String id, Offset start, Offset end) {
    if (start == end) {
      return;
    }
    _applyAction(
      MoveTextAction(
        id: id,
        from: OffsetPosition.fromOffset(start),
        to: OffsetPosition.fromOffset(end),
      ),
    );
    _save();
  }

  void commitTextResize(TextBlock before, TextBlock after) {
    if (before.width == after.width) {
      return;
    }
    _applyAction(UpdateTextAction(before: before, after: after));
    _save();
  }

  void commitTextUpdate(TextBlock before, TextBlock after) {
    if (before.text == after.text &&
        before.deltaJson == after.deltaJson &&
        before.position == after.position &&
        before.fontSize == after.fontSize &&
        before.color == after.color &&
        before.width == after.width &&
        before.rotation == after.rotation) {
      return;
    }
    _applyAction(UpdateTextAction(before: before, after: after));
    _save();
  }

  Future<String?> addImageBlock(Offset position) async {
    final picked = await _imagePicker.pickImage(source: ImageSource.gallery);
    if (picked == null) {
      return null;
    }
    _ensureInsertPageSelected(position);
    if (kIsWeb) {
      final extension = picked.name.split('.').last.toLowerCase();
      return _addImageBlockFromBytes(
        await picked.readAsBytes(),
        position,
        extension,
      );
    }
    return _addImageBlockFromFile(File(picked.path), position);
  }

  Future<String?> insertFromFilePicker(Offset position) async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'pdf', 'txt'],
        withData: kIsWeb,
      );
    } catch (e) {
      debugPrint('EditorController.insertFromFilePicker: picker failed: $e');
      if (defaultTargetPlatform == TargetPlatform.linux) {
        return 'Missing "zenity". Install it: sudo apt-get install zenity.';
      }
      return 'File picker failed to open.';
    }
    if (result == null) {
      return null;
    }
    final pickedFile = result.files.single;
    if (kIsWeb) {
      final bytes = pickedFile.bytes;
      if (bytes == null || bytes.isEmpty) {
        return 'Selected file is not accessible.';
      }
      final extension = pickedFile.extension?.toLowerCase();
      _ensureInsertPageSelected(position);
      if (extension == 'png' || extension == 'jpg' || extension == 'jpeg') {
        return _addImageBlockFromBytes(bytes, position, extension!);
      }
      if (extension == 'txt') {
        addTextBlockFromText(position, utf8.decode(bytes));
        return null;
      }
      if (extension == 'pdf') {
        return _addPdfBytesAsImages(bytes, position);
      }
      return 'Unsupported file type.';
    }
    final path = pickedFile.path;
    if (path == null || path.isEmpty) {
      return 'Selected file is not accessible.';
    }
    try {
      _ensureInsertPageSelected(position);
      return await _insertFile(File(path), position);
    } on PlatformNotSupportedException {
      return 'PDF rendering is not supported on this platform.';
    } on MissingPluginException {
      return 'PDF renderer plugin is missing for this platform.';
    } catch (e) {
      debugPrint('EditorController.insertFromFilePicker: insert failed: $e');
      return 'Failed to insert file.';
    }
  }

  Future<String?> insertFromClipboard(Offset position) async {
    _ensureInsertPageSelected(position);
    final clipboard = SystemClipboard.instance;
    if (clipboard != null) {
      final reader = await clipboard.read();
      final imageInserted = await _tryInsertImageFromClipboard(
        reader,
        position,
      );
      if (imageInserted) {
        return null;
      }
      final text = await _readTextFromClipboard(reader);
      if (text != null && text.trim().isNotEmpty) {
        addTextBlockFromText(position, text);
        return null;
      }
    }

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final fallbackText = data?.text;
    if (fallbackText == null || fallbackText.trim().isEmpty) {
      return 'Clipboard is empty. Use Attach file for images or PDFs.';
    }
    addTextBlockFromText(position, fallbackText);
    return null;
  }

  Future<String?> pasteElementOrClipboard(Offset position) async {
    final clipboardItem = _elementClipboard;
    if (clipboardItem == null) {
      return insertFromClipboard(position);
    }

    switch (clipboardItem) {
      case _TextElementClipboardItem(:final block):
        _ensureInsertPageSelected(position);
        final pasted = block.copyWith(id: _uuid.v4(), position: position);
        _applyAction(AddTextAction(pasted));
        setTool(DrawingTool.edit);
        setActiveTextBlock(pasted.id, null);
        _save();
        return null;
      case _ImageElementClipboardItem(:final block):
        _ensureInsertPageSelected(position);
        final pasted = block.copyWith(id: _uuid.v4(), position: position);
        _applyAction(AddImageAction(pasted));
        _activateInsertedImage(pasted.id);
        _save();
        return null;
      case _LassoElementClipboardItem(
        :final strokes,
        :final textBlocks,
        :final imageBlocks,
        :final bounds,
        :final pageIndex,
      ):
        final targetPageIndex = _pageIndexForPosition(position);
        _ensurePageSelected(targetPageIndex);
        final delta = position - bounds.topLeft;
        final sourceOrigin = _pageOriginForIndex(pageIndex);
        final targetOrigin = _pageOriginForIndex(targetPageIndex);
        final newStrokes = strokes
            .map(
              (s) => s.copyWith(
                id: _uuid.v4(),
                points: s.points
                    .map(
                      (p) => InkPoint(
                        dx: p.dx + sourceOrigin.dx + delta.dx - targetOrigin.dx,
                        dy: p.dy + sourceOrigin.dy + delta.dy - targetOrigin.dy,
                        pressure: p.pressure,
                      ),
                    )
                    .toList(),
              ),
            )
            .toList();
        final newTextBlocks = textBlocks
            .map(
              (t) => t.copyWith(id: _uuid.v4(), position: t.position + delta),
            )
            .toList();
        final newImageBlocks = imageBlocks
            .map(
              (i) => i.copyWith(id: _uuid.v4(), position: i.position + delta),
            )
            .toList();

        _applyAction(
          PasteSelectionAction(
            strokes: newStrokes,
            textBlocks: newTextBlocks,
            imageBlocks: newImageBlocks,
          ),
        );

        setTool(DrawingTool.edit);
        lassoSelection = LassoSelection(
          pageIndex: targetPageIndex,
          bounds: bounds.shift(delta),
          strokeIds: newStrokes.map((s) => s.id).toList(),
          textBlockIds: newTextBlocks.map((t) => t.id).toList(),
          imageBlockIds: newImageBlocks.map((i) => i.id).toList(),
        );
        lassoDragDelta.value = Offset.zero;
        _save();
        return null;
    }
  }

  Future<String?> copyActiveElementToClipboard() async {
    final sel = lassoSelection;
    if (sel != null && !sel.isEmpty) {
      final page = pages[sel.pageIndex];
      final strokes = page.inkStrokes
          .where((s) => sel.strokeIds.contains(s.id))
          .toList();
      final texts = page.textBlocks
          .where((t) => sel.textBlockIds.contains(t.id))
          .toList();
      final images = page.imageBlocks
          .where((i) => sel.imageBlockIds.contains(i.id))
          .toList();

      _elementClipboard = _LassoElementClipboardItem(
        strokes: strokes,
        textBlocks: texts,
        imageBlocks: images,
        bounds: sel.bounds.shift(sel.delta),
        pageIndex: sel.pageIndex,
      );
      return null;
    }

    final textId = activeTextBlockId;
    if (textId != null) {
      final block = findTextBlockById(textId);
      if (block == null) {
        return 'Selected text is no longer available.';
      }
      _elementClipboard = _TextElementClipboardItem(block);
      await Clipboard.setData(ClipboardData(text: block.text));
      return null;
    }

    final imageId = activeImageBlockId;
    if (imageId != null) {
      final block = findImageBlockById(imageId);
      if (block == null) {
        return 'Selected image is no longer available.';
      }
      _elementClipboard = _ImageElementClipboardItem(block);
      final imageMessage = await copyActiveImageToClipboard();
      if (imageMessage == 'Image file not found.') {
        return imageMessage;
      }
      return null;
    }

    return 'Select text or image to copy.';
  }

  Future<String?> cutActiveElementToClipboard() async {
    final message = await copyActiveElementToClipboard();
    if (message != null) {
      return message;
    }
    deleteActiveElement();
    return null;
  }

  void deleteActiveElement() {
    final sel = lassoSelection;
    if (sel != null && !sel.isEmpty) {
      deleteLassoSelection();
      return;
    }

    final textId = activeTextBlockId;
    if (textId != null) {
      final pageIndex = _pageIndexContainingTextBlock(textId);
      if (pageIndex != null) {
        deleteTextBlockOnPage(pageIndex, textId);
      }
      return;
    }

    final imageId = activeImageBlockId;
    if (imageId != null) {
      final pageIndex = _pageIndexContainingImageBlock(imageId);
      if (pageIndex != null) {
        deleteImageBlockOnPage(pageIndex, imageId);
      }
    }
  }

  Future<String?> copyActiveImageToClipboard() async {
    final id = activeImageBlockId;
    if (id == null) {
      return 'Select an image to copy.';
    }
    final block = findImageBlockById(id);
    if (block == null) {
      return 'Selected image is no longer available.';
    }
    final file = File(block.path);
    if (!await file.exists()) {
      return 'Image file not found.';
    }
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      return 'Clipboard is not available.';
    }
    final bytes = await file.readAsBytes();
    final item = DataWriterItem();
    final lower = block.path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      item.add(Formats.jpeg(bytes));
    } else {
      item.add(Formats.png(bytes));
    }
    await clipboard.write([item]);
    return null;
  }

  Future<bool> _tryInsertImageFromClipboard(
    ClipboardReader reader,
    Offset position,
  ) async {
    final pngBytes = await _readClipboardImageBytes(reader, Formats.png);
    if (pngBytes != null && pngBytes.isNotEmpty) {
      await _addImageBlockFromBytes(pngBytes, position, 'png');
      return true;
    }
    final jpegBytes = await _readClipboardImageBytes(reader, Formats.jpeg);
    if (jpegBytes != null && jpegBytes.isNotEmpty) {
      await _addImageBlockFromBytes(jpegBytes, position, 'jpg');
      return true;
    }
    return false;
  }

  Future<String?> _readTextFromClipboard(ClipboardReader reader) async {
    if (!reader.canProvide(Formats.plainText)) {
      return null;
    }
    final text = await reader.readValue(Formats.plainText);
    return text is String ? text : null;
  }

  Future<Uint8List?> _readClipboardImageBytes(
    ClipboardReader reader,
    SimpleFileFormat format,
  ) async {
    if (!reader.canProvide(format)) {
      return null;
    }
    final completer = Completer<Uint8List?>();
    reader.getFile(format, (file) async {
      try {
        final bytes = await _readStreamBytes(file.getStream());
        if (!completer.isCompleted) {
          completer.complete(bytes);
        }
      } catch (e) {
        debugPrint('EditorController._readClipboardImageBytes failed: $e');
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      }
    });
    return completer.future;
  }

  Future<Uint8List> _readStreamBytes(Stream<Uint8List> stream) async {
    final chunks = <int>[];
    await for (final chunk in stream) {
      chunks.addAll(chunk);
    }
    return Uint8List.fromList(chunks);
  }

  Size _initialImageBlockSize(Size sourceSize) {
    final sourceWidth = sourceSize.width > 0 ? sourceSize.width : 1.0;
    final sourceHeight = sourceSize.height > 0 ? sourceSize.height : 1.0;
    final sourceAspect = sourceWidth / sourceHeight;
    final maxWidth = notebook.kind == NotebookKind.notebook
        ? (_pageWidth > 0 ? _pageWidth : 260.0)
        : 360.0;
    final maxHeight = notebook.kind == NotebookKind.notebook
        ? (_pageHeight > 0 ? _pageHeight : 420.0)
        : 520.0;
    final pageAspect = maxWidth / maxHeight;
    if (!sourceAspect.isFinite || sourceAspect <= 0 || !pageAspect.isFinite) {
      return const Size(260, 260);
    }
    if (sourceAspect >= pageAspect) {
      return Size(maxWidth, maxWidth / sourceAspect);
    }
    return Size(maxHeight * sourceAspect, maxHeight);
  }

  Uint8List? _freezeV2ImageBytes(Uint8List bytes) {
    if (operationWriter == null) {
      return null;
    }
    if (bytes.isEmpty || bytes.length > QuillPastePlan.maximumBytes) {
      throw const FormatException('Invalid image size for v2 history.');
    }
    return Uint8List.fromList(bytes);
  }

  Future<Uint8List?> _readV2ImageBytes(File file) async {
    if (operationWriter == null) {
      return null;
    }
    final size = await file.length();
    if (size <= 0 || size > QuillPastePlan.maximumBytes) {
      throw const FormatException('Invalid image size for v2 history.');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length != size) {
      throw const FormatException('Image changed while being read.');
    }
    return bytes;
  }

  Future<String?> _addImageBlockFromBytes(
    Uint8List bytes,
    Offset position,
    String extension,
  ) async {
    bytes = _freezeV2ImageBytes(bytes) ?? bytes;
    if (kIsWeb) {
      final size = await _imageSizeFromBytes(bytes);
      final initialSize = _initialImageBlockSize(size);
      final normalizedExtension = extension == 'jpeg' ? 'jpg' : extension;
      final block = ImageBlock(
        id: _uuid.v4(),
        path: '',
        ocrText: '',
        position: position,
        width: initialSize.width,
        height: initialSize.height,
        bytes: bytes,
        imageExt: normalizedExtension,
        imageMime: normalizedExtension == 'jpg'
            ? 'image/jpeg'
            : 'image/$normalizedExtension',
      );
      _applyAction(AddImageAction(block));
      _activateInsertedImage(block.id);
      _save();
      return null;
    }
    final filename = 'clip_${DateTime.now().millisecondsSinceEpoch}.$extension';
    final file = await _persistImageBytes(bytes, filename);
    final size = operationWriter == null
        ? await _imageSize(file)
        : await _imageSizeFromBytes(bytes);
    final initialSize = _initialImageBlockSize(size);
    final block = ImageBlock(
      id: _uuid.v4(),
      path: file.path,
      bytes: operationWriter == null ? null : bytes,
      ocrText: '',
      position: position,
      width: initialSize.width,
      height: initialSize.height,
      imageExt: extension,
      imageMime: extension == 'jpg' || extension == 'jpeg'
          ? 'image/jpeg'
          : 'image/$extension',
    );
    _applyAction(AddImageAction(block));
    _activateInsertedImage(block.id);
    _save();
    return null;
  }

  Future<String?> _insertFile(File file, Offset position) async {
    final path = file.path.toLowerCase();
    if (path.endsWith('.png') ||
        path.endsWith('.jpg') ||
        path.endsWith('.jpeg')) {
      return _addImageBlockFromFile(file, position);
    }
    if (path.endsWith('.pdf')) {
      return _addPdfAsImages(file, position);
    }
    if (path.endsWith('.txt')) {
      final content = await file.readAsString();
      addTextBlockFromText(position, content);
      return null;
    }
    return 'Unsupported file type.';
  }

  Future<String?> _addImageBlockFromFile(File file, Offset position) async {
    final persisted = await _persistImageFile(file);
    final bytes = await _readV2ImageBytes(persisted);
    final size = bytes == null
        ? await _imageSize(persisted)
        : await _imageSizeFromBytes(bytes);
    final initialSize = _initialImageBlockSize(size);
    final extension = file.path.split('.').last.toLowerCase();
    String mime = 'image/jpeg';
    if (extension == 'png') {
      mime = 'image/png';
    } else if (extension == 'gif') {
      mime = 'image/gif';
    } else if (extension == 'webp') {
      mime = 'image/webp';
    }
    final block = ImageBlock(
      id: _uuid.v4(),
      path: persisted.path,
      bytes: bytes,
      ocrText: '',
      position: position,
      width: initialSize.width,
      height: initialSize.height,
      imageExt: extension,
      imageMime: mime,
    );
    _applyAction(AddImageAction(block));
    _activateInsertedImage(block.id);
    _save();
    return null;
  }

  void _activateInsertedImage(String id) {
    tool = DrawingTool.edit;
    activeImageBlockId = id;
    activeTextBlockId = null;
    activeTextController = null;
    notifyListeners();
  }

  Future<String?> _addPdfAsImages(File pdfFile, Offset position) async {
    if (Platform.isLinux) {
      return _addPdfAsImagesWithPoppler(pdfFile, position);
    }
    try {
      final document = await PdfDocument.openFile(pdfFile.path);
      return await _addPdfDocumentAsImages(document, position);
    } on PlatformNotSupportedException {
      return 'PDF rendering is not supported on this platform.';
    } on MissingPluginException {
      return 'PDF renderer plugin is missing for this platform.';
    } catch (e) {
      debugPrint('EditorController._addPdfAsImages failed: $e');
      return 'Failed to render PDF.';
    }
  }

  Future<String?> _addPdfBytesAsImages(Uint8List bytes, Offset position) async {
    try {
      final document = await PdfDocument.openData(bytes);
      return await _addPdfDocumentAsImages(
        document,
        position,
        storeInline: true,
      );
    } on PlatformNotSupportedException {
      return 'PDF rendering is not supported by this browser.';
    } on MissingPluginException {
      return 'PDF renderer is unavailable in this browser.';
    } catch (e) {
      debugPrint('EditorController._addPdfBytesAsImages failed: $e');
      return 'Failed to render PDF.';
    }
  }

  Future<String?> _addPdfDocumentAsImages(
    PdfDocument document,
    Offset position, {
    bool storeInline = false,
  }) async {
    try {
      final pageExtent = _pageExtent;
      final basePageIndex = _pageIndexForPosition(position);
      final localOffset = notebook.kind == NotebookKind.board
          ? position
          : Offset.zero;
      final additions = <int, List<ImageBlock>>{};
      var pageOffset = 0.0;
      for (var pageIndex = 1; pageIndex <= document.pagesCount; pageIndex++) {
        final page = await document.getPage(pageIndex);
        final render = await page.render(
          width: page.width * 2,
          height: page.height * 2,
          format: PdfPageImageFormat.png,
        );
        await page.close();
        if (render == null) {
          continue;
        }
        final frozenBytes = _freezeV2ImageBytes(render.bytes);
        final file = storeInline
            ? null
            : await _persistImageBytes(
                frozenBytes ?? render.bytes,
                'pdf_${DateTime.now().millisecondsSinceEpoch}_$pageIndex.png',
              );
        final renderWidth = (render.width ?? page.width).toDouble();
        final renderHeight = (render.height ?? page.height).toDouble();
        final size = Size(renderWidth, renderHeight);
        final targetWidth = notebook.kind == NotebookKind.notebook
            ? (_pageWidth > 0 ? _pageWidth : 260.0)
            : 260.0;
        final targetHeight = notebook.kind == NotebookKind.notebook
            ? (_pageHeight > 0 ? _pageHeight : 420.0)
            : targetWidth * (size.width == 0 ? 1.0 : size.height / size.width);
        final targetIndex = notebook.kind == NotebookKind.board
            ? basePageIndex
            : basePageIndex + (pageIndex - 1);
        final targetOrigin = notebook.kind == NotebookKind.board
            ? Offset.zero
            : (pageExtent <= 0
                  ? Offset.zero
                  : _pageOriginForIndex(targetIndex));
        final targetPosition = notebook.kind == NotebookKind.board
            ? localOffset + Offset(0, pageOffset)
            : targetOrigin + localOffset;
        final block = ImageBlock(
          id: _uuid.v4(),
          path: file?.path ?? '',
          ocrText: '',
          position: targetPosition,
          width: targetWidth,
          height: notebook.kind == NotebookKind.notebook
              ? targetHeight
              : targetHeight.clamp(80, 520).toDouble(),
          imageExt: 'png',
          imageMime: 'image/png',
          bytes: frozenBytes ?? (storeInline ? render.bytes : null),
        );
        additions.putIfAbsent(targetIndex, () => <ImageBlock>[]).add(block);
        if (notebook.kind == NotebookKind.board) {
          pageOffset += block.height + 12;
        }
      }
      _appendImageBlocksOnPages(additions);
      _save();
      return null;
    } finally {
      await document.close();
    }
  }

  Future<String?> _addPdfAsImagesWithPoppler(
    File pdfFile,
    Offset position,
  ) async {
    final tempDir = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final prefix = '${tempDir.path}/pdf_$stamp';
    final test = await Process.run('pdftoppm', ['-h']);
    if (test.exitCode != 0) {
      return 'Missing "pdftoppm". Install: sudo apt-get install poppler-utils.';
    }
    final result = await Process.run('pdftoppm', [
      '-png',
      '-r',
      '144',
      pdfFile.path,
      prefix,
    ]);
    if (result.exitCode != 0) {
      return 'Failed to render PDF pages.';
    }
    final dir = Directory(tempDir.path);
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where(
              (file) =>
                  file.path.startsWith(prefix) && file.path.endsWith('.png'),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) {
      return 'No PDF pages were rendered.';
    }
    final pageExtent = _pageExtent;
    final basePageIndex = _pageIndexForPosition(position);
    final localOffset = notebook.kind == NotebookKind.board
        ? position
        : Offset.zero;
    final additions = <int, List<ImageBlock>>{};
    var pageOffset = 0.0;
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final size = await _imageSize(file);
      final targetWidth = notebook.kind == NotebookKind.notebook
          ? (_pageWidth > 0 ? _pageWidth : 260.0)
          : 260.0;
      final targetHeight = notebook.kind == NotebookKind.notebook
          ? (_pageHeight > 0 ? _pageHeight : 420.0)
          : targetWidth * (size.width == 0 ? 1.0 : size.height / size.width);
      final targetIndex = notebook.kind == NotebookKind.board
          ? basePageIndex
          : basePageIndex + i;
      final targetOrigin = notebook.kind == NotebookKind.board
          ? Offset.zero
          : (pageExtent <= 0 ? Offset.zero : _pageOriginForIndex(targetIndex));
      final targetPosition = notebook.kind == NotebookKind.board
          ? localOffset + Offset(0, pageOffset)
          : targetOrigin + localOffset;
      final persisted = await _persistImageFile(file);
      final bytes = await _readV2ImageBytes(persisted);
      final block = ImageBlock(
        id: _uuid.v4(),
        path: persisted.path,
        bytes: bytes,
        ocrText: '',
        position: targetPosition,
        width: targetWidth,
        height: notebook.kind == NotebookKind.notebook
            ? targetHeight
            : targetHeight.clamp(80, 520).toDouble(),
        imageExt: 'png',
        imageMime: 'image/png',
      );
      additions.putIfAbsent(targetIndex, () => <ImageBlock>[]).add(block);
      if (notebook.kind == NotebookKind.board) {
        pageOffset += block.height + 12;
      }
    }
    _appendImageBlocksOnPages(additions);
    _save();
    return null;
  }

  void _appendImageBlocksOnPages(Map<int, List<ImageBlock>> additions) {
    if (additions.isEmpty) {
      return;
    }
    final workingPages = List<NotePage>.from(pages);
    final maxPageIndex = additions.keys.reduce((a, b) => a > b ? a : b);
    _ensurePageCount(workingPages, maxPageIndex + 1);
    pages = [
      for (var i = 0; i < workingPages.length; i++)
        if (additions[i] case final blocks?)
          workingPages[i].copyWith(
            imageBlocks: [...workingPages[i].imageBlocks, ...blocks],
          )
        else
          workingPages[i],
    ];
    notifyListeners();
  }

  void updateImageBlockPosition(String id, Offset position) {
    final updated = currentPage.imageBlocks
        .map((item) => item.id == id ? item.copyWith(position: position) : item)
        .toList();
    _updatePage(currentPage.copyWith(imageBlocks: updated));
  }

  void updateImageBlockSize(
    String id, {
    required double width,
    required double height,
  }) {
    final updated = currentPage.imageBlocks
        .map(
          (item) => item.id == id
              ? item.copyWith(width: width, height: height)
              : item,
        )
        .toList();
    _updatePage(currentPage.copyWith(imageBlocks: updated));
  }

  Future<void> restoreImageCache(int pageIndex, String blockId) async {
    final currentBlockPageIndex = _pageIndexContainingImageBlock(blockId);
    if (currentBlockPageIndex == null) {
      return;
    }
    _ensurePageSelected(currentBlockPageIndex);
    final block = pages[currentBlockPageIndex].imageBlocks
        .where((b) => b.id == blockId)
        .firstOrNull;
    if (block == null || block.bytes == null) return;

    if (block.path.isNotEmpty && File(block.path).existsSync()) return;

    final extension = block.imageExt ?? 'png';
    final filename =
        'restored_${block.id}_${DateTime.now().millisecondsSinceEpoch}.$extension';
    final file = await _persistImageBytes(block.bytes!, filename);

    final updatedBlock = block.copyWith(
      path: file.path,
      clearBytes: operationWriter == null,
    );
    final updated = pages[currentBlockPageIndex].imageBlocks
        .map((item) => item.id == blockId ? updatedBlock : item)
        .toList();
    _updatePage(pages[currentBlockPageIndex].copyWith(imageBlocks: updated));
    if (operationWriter == null) {
      _save();
    }
  }

  void deleteImageBlock(String id) {
    final block = currentPage.imageBlocks.firstWhere((item) => item.id == id);
    _applyAction(DeleteImageAction(block));
    clearActiveImageBlock();
    _save();
  }

  String? addInkStroke(
    List<InkPoint> points, {
    double? widthOverride,
    DrawingTool? toolOverride,
    Color? colorOverride,
  }) {
    if (points.isEmpty) {
      return null;
    }
    final strokeTool = toolOverride ?? tool;
    if (strokeTool.isEraser) {
      throw StateError('Eraser tools cannot be persisted as ink strokes.');
    }
    final baseWidth = strokeTool == DrawingTool.highlighter
        ? inkStrokeWidth * 8.0
        : inkStrokeWidth;
    final stroke = InkStroke(
      id: _uuid.v4(),
      points: points,
      color: colorOverride ?? inkColor,
      width: widthOverride ?? baseWidth,
      tool: strokeTool,
    );
    _applyInkAction(AddInkStrokeAction(stroke));
    _scheduleSave();
    return stroke.id;
  }

  void eraseInkStrokesById(Set<String> ids) {
    if (ids.isEmpty) {
      return;
    }
    final action = DeleteInkStrokesAction.fromStrokes(
      currentPage.inkStrokes,
      ids,
    );
    if (action.isEmpty) {
      return;
    }
    _applyInkAction(action);
    _scheduleSave();
  }

  void replaceInkStrokes(List<InkStroke> strokes) {
    final before = List<InkStroke>.from(currentPage.inkStrokes);
    if (_sameInkStrokeIds(before, strokes)) {
      return;
    }
    _applyInkAction(RemoveInkStrokesAction(before: before, after: strokes));
    _scheduleSave();
  }

  String createInkStrokeId() => _uuid.v4();

  void commitImageMove(String id, Offset start, Offset end) {
    if (start == end) {
      return;
    }
    _applyAction(
      MoveImageAction(
        id: id,
        from: OffsetPosition.fromOffset(start),
        to: OffsetPosition.fromOffset(end),
      ),
    );
    _save();
  }

  void commitImageResize(ImageBlock before, ImageBlock after) {
    if (before.position == after.position &&
        before.width == after.width &&
        before.height == after.height &&
        before.rotation == after.rotation &&
        before.cropLeft == after.cropLeft &&
        before.cropTop == after.cropTop &&
        before.cropRight == after.cropRight &&
        before.cropBottom == after.cropBottom) {
      return;
    }
    _applyAction(UpdateImageAction(before: before, after: after));
    _save();
  }

  void _moveImageBlockToPage(
    int fromPageIndex,
    int toPageIndex,
    String id,
    Offset start,
    Offset end,
  ) {
    if (fromPageIndex < 0 ||
        fromPageIndex >= pages.length ||
        toPageIndex < 0 ||
        toPageIndex >= pages.length ||
        fromPageIndex == toPageIndex) {
      return;
    }
    final sourcePage = pages[fromPageIndex];
    final imageIndex = sourcePage.imageBlocks.indexWhere(
      (item) => item.id == id,
    );
    if (imageIndex == -1) {
      return;
    }
    final image = sourcePage.imageBlocks[imageIndex];
    _applyAction(
      MoveImageBetweenPagesAction(
        fromPageId: sourcePage.id,
        toPageId: pages[toPageIndex].id,
        originalIndex: imageIndex,
        before: image.copyWith(position: start),
        after: image.copyWith(position: end),
      ),
    );
    _save();
  }

  Future<File> _persistImageFile(File source) async {
    final extension = source.path.split('.').last.toLowerCase();
    final safeExtension = RegExp(r'^[a-z0-9]+$').hasMatch(extension)
        ? extension
        : 'png';
    final imagesDir = await _imagesDir();
    final target = File('${imagesDir.path}/img_${_uuid.v4()}.$safeExtension');
    final bytes = operationWriter == null
        ? await source.readAsBytes()
        : (await _readV2ImageBytes(source))!;
    await target.writeAsBytes(bytes, flush: true);
    return target;
  }

  Future<File> _persistImageBytes(Uint8List bytes, String filename) async {
    final extension = filename.split('.').last.toLowerCase();
    final safeExtension = RegExp(r'^[a-z0-9]+$').hasMatch(extension)
        ? extension
        : 'png';
    final imagesDir = await _imagesDir();
    final target = File('${imagesDir.path}/img_${_uuid.v4()}.$safeExtension');
    await target.writeAsBytes(bytes, flush: true);
    return target;
  }

  Future<Directory> _imagesDir() async {
    final dir = Directory(await getAppDataPath());
    final imagesDir = Directory('${dir.path}/images');
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }
    return imagesDir;
  }

  Map<String, dynamic> _textInlineAttributes(String? deltaJson) {
    if (deltaJson == null || deltaJson.trim().isEmpty) {
      return <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(deltaJson);
      if (decoded is! List) {
        return <String, dynamic>{};
      }
      for (final raw in decoded) {
        if (raw is! Map) {
          continue;
        }
        final op = Map<String, dynamic>.from(raw);
        final insert = op['insert'];
        if (insert is! String || insert.replaceAll('\n', '').isEmpty) {
          continue;
        }
        final attributes = op['attributes'];
        return attributes is Map
            ? Map<String, dynamic>.from(attributes)
            : <String, dynamic>{};
      }
    } catch (_) {
      return <String, dynamic>{};
    }
    return <String, dynamic>{};
  }

  Map<String, dynamic> _textParagraphAttributes(String? deltaJson) {
    if (deltaJson == null || deltaJson.trim().isEmpty) {
      return <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(deltaJson);
      if (decoded is! List) {
        return <String, dynamic>{};
      }
      for (final raw in decoded) {
        if (raw is! Map) {
          continue;
        }
        final op = Map<String, dynamic>.from(raw);
        final insert = op['insert'];
        if (insert is! String || !insert.contains('\n')) {
          continue;
        }
        final attributes = op['attributes'];
        return attributes is Map
            ? Map<String, dynamic>.from(attributes)
            : <String, dynamic>{};
      }
    } catch (_) {
      return <String, dynamic>{};
    }
    return <String, dynamic>{};
  }

  String _buildTextDeltaJson(
    String text, {
    required Map<String, dynamic> inline,
    required Map<String, dynamic> paragraph,
  }) {
    final operations = <Map<String, dynamic>>[];
    final lines = text.replaceAll('\r', '').split('\n');
    for (final line in lines) {
      if (line.isNotEmpty) {
        operations.add(<String, dynamic>{
          'insert': line,
          if (inline.isNotEmpty)
            'attributes': Map<String, dynamic>.from(inline),
        });
      }
      operations.add(<String, dynamic>{
        'insert': '\n',
        if (paragraph.isNotEmpty)
          'attributes': Map<String, dynamic>.from(paragraph),
      });
    }
    return jsonEncode(operations);
  }

  String _colorToHex(Color color) {
    final value = color.toARGB32().toRadixString(16).padLeft(8, '0');
    return '#${value.substring(2)}';
  }

  Future<Size> _imageSize(File file) async {
    return _imageSizeFromBytes(await file.readAsBytes());
  }

  Future<Size> _imageSizeFromBytes(Uint8List bytes) async {
    final codec = await instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    return Size(image.width.toDouble(), image.height.toDouble());
  }

  Rect _computeContentBounds() {
    Rect? bounds;

    for (final stroke in currentPage.inkStrokes) {
      if (stroke.points.isEmpty) {
        continue;
      }
      var minX = stroke.points.first.dx;
      var minY = stroke.points.first.dy;
      var maxX = minX;
      var maxY = minY;
      for (final point in stroke.points) {
        minX = math.min(minX, point.dx);
        minY = math.min(minY, point.dy);
        maxX = math.max(maxX, point.dx);
        maxY = math.max(maxY, point.dy);
      }
      final extra = math.max(8.0, stroke.width * 0.5 + 4.0);
      final rect = Rect.fromLTRB(
        minX - extra,
        minY - extra,
        maxX + extra,
        maxY + extra,
      );
      bounds = bounds == null ? rect : bounds.expandToInclude(rect);
    }

    for (final block in currentPage.textBlocks) {
      final estimatedHeight = math.max(44.0, block.fontSize * 2.8);
      final rect = Rect.fromLTWH(
        block.position.dx,
        block.position.dy,
        block.width,
        estimatedHeight,
      );
      bounds = bounds == null ? rect : bounds.expandToInclude(rect);
    }

    for (final block in currentPage.imageBlocks) {
      final rect = Rect.fromLTWH(
        block.position.dx,
        block.position.dy,
        block.width,
        block.height,
      );
      bounds = bounds == null ? rect : bounds.expandToInclude(rect);
    }

    return bounds ?? const Rect.fromLTWH(-600, -600, 1200, 1200);
  }

  void _applyAction(EditorAction action) {
    _commitActiveTextEdit();
    if (action is MoveImageBetweenPagesAction) {
      _applyCrossPageImageMove(action, undo: false);
      _undoActions.add(_EditorHistoryEntry(currentPage.id, action));
      _redoActions.clear();
      _notifyHistoryChanged();
      _captureV2Gesture();
      notifyListeners();
      return;
    }
    final before = currentPage;
    final updated = action.apply(before);
    _recordExpectedRemovals(action, before, updated);
    _undoActions.add(_EditorHistoryEntry(currentPage.id, action));
    _redoActions.clear();
    _notifyHistoryChanged();
    _updatePage(updated);
    _captureV2Gesture();
  }

  void _applyCrossPageImageMove(
    MoveImageBetweenPagesAction action, {
    required bool undo,
  }) {
    pages = undo ? action.revertPages(pages) : action.applyPages(pages);
    final pageId = undo ? action.fromPageId : action.toPageId;
    currentPageIndex = pages.indexWhere((page) => page.id == pageId);
    activeTextBlockId = null;
    activeTextController = null;
    activeImageBlockId = action.blockId;
  }

  void _applyInkAction(EditorAction action) {
    _commitActiveTextEdit();
    final before = currentPage;
    final updated = action.apply(before);
    _recordExpectedRemovals(action, before, updated);
    _undoActions.add(_EditorHistoryEntry(currentPage.id, action));
    _redoActions.clear();
    _notifyHistoryChanged();
    pages = [
      for (var i = 0; i < pages.length; i++)
        if (i == currentPageIndex) updated else pages[i],
    ];
    _touchInkPageRevision(updated.id);
    _captureV2Gesture();
  }

  void _touchInkPageRevision(String pageId) {
    final pageRevision = _inkPageRevisions.putIfAbsent(
      pageId,
      () => ValueNotifier<int>(0),
    );
    pageRevision.value++;
    inkRevision.value++;
    if (notebook.kind == NotebookKind.board) {
      notifyListeners();
    }
  }

  void _notifyHistoryChanged() {
    historyRevision.value++;
  }

  void _applyActionWithoutNotify(EditorAction action) {
    final before = currentPage;
    final updated = action.apply(before);
    _recordExpectedRemovals(action, before, updated);
    _undoActions.add(_EditorHistoryEntry(currentPage.id, action));
    _redoActions.clear();
    _notifyHistoryChanged();
    pages = [
      for (var i = 0; i < pages.length; i++)
        if (i == currentPageIndex) updated else pages[i],
    ];
    _captureV2Gesture();
  }

  void _recordExpectedRemovals(
    EditorAction action,
    NotePage before,
    NotePage after, {
    bool undo = false,
  }) {
    final deliberate = undo
        ? action is AddInkStrokeAction ||
              action is AddImageAction ||
              action is AddTextAction ||
              action is PasteSelectionAction
        : action is DeleteInkStrokesAction ||
              action is RemoveInkStrokesAction ||
              action is DeleteImageAction ||
              action is DeleteTextAction ||
              action is DeleteSelectionAction;
    if (!deliberate) {
      return;
    }
    final previous = <String>{
      for (final ink in before.inkStrokes) 'ink:${ink.id}',
      for (final image in before.imageBlocks) 'image:${image.id}',
      for (final text in before.textBlocks) 'text:${text.id}',
    };
    final remaining = <String>{
      for (final ink in after.inkStrokes) 'ink:${ink.id}',
      for (final image in after.imageBlocks) 'image:${image.id}',
      for (final text in after.textBlocks) 'text:${text.id}',
    };
    final removed = previous.difference(remaining);
    if (removed.isNotEmpty) {
      _expectedRemovedIdsByPage
          .putIfAbsent(before.id, () => {})
          .addAll(removed);
    }
  }

  Map<String, Set<String>> _pendingExpectedRemovals(Set<String> pageIds) {
    return {
      for (final pageId in pageIds)
        if (_expectedRemovedIdsByPage.containsKey(pageId))
          pageId: Set<String>.of(_expectedRemovedIdsByPage[pageId]!),
    };
  }

  void _clearSavedExpectedRemovals(Map<String, Set<String>> expectedRemoved) {
    for (final entry in expectedRemoved.entries) {
      final pending = _expectedRemovedIdsByPage[entry.key];
      pending?.removeAll(entry.value);
      if (pending != null && pending.isEmpty) {
        _expectedRemovedIdsByPage.remove(entry.key);
      }
    }
  }

  void _updatePage(NotePage page) {
    pages = [
      for (var i = 0; i < pages.length; i++)
        if (i == currentPageIndex) page else pages[i],
    ];
    notifyListeners();
  }

  void _replaceTextBlockOnCurrentPage(TextBlock block, {required bool notify}) {
    final updated = currentPage.textBlocks
        .map((item) => item.id == block.id ? block : item)
        .toList();
    final page = currentPage.copyWith(textBlocks: updated);
    pages = [
      for (var i = 0; i < pages.length; i++)
        if (i == currentPageIndex) page else pages[i],
    ];
    if (notify) {
      notifyListeners();
    }
  }

  void _beginTextEdit(String blockId) {
    if (_activeTextEditBefore?.id == blockId) {
      return;
    }
    _commitActiveTextEdit();
    final pageIndex = _pageIndexContainingTextBlock(blockId);
    if (pageIndex == null) {
      return;
    }
    final block = pages[pageIndex].textBlocks.firstWhere(
      (item) => item.id == blockId,
    );
    _activeTextEditPageIndex = pageIndex;
    _activeTextEditBefore = block;
    if (operationWriter != null) {
      _activeV2TextGesture = _V2TextGesture(
        notebook.copyWith(pages: List<NotePage>.of(pages)),
      );
    }
  }

  void _commitActiveTextEdit() {
    final pageIndex = _activeTextEditPageIndex;
    final before = _activeTextEditBefore;
    final textGesture = _activeV2TextGesture;
    _discardActiveTextEdit();
    if (pageIndex == null || before == null) {
      return;
    }
    if (pageIndex < 0 || pageIndex >= pages.length) {
      return;
    }
    final after = pages[pageIndex].textBlocks
        .where((item) => item.id == before.id)
        .firstOrNull;
    if (after == null) {
      return;
    }
    if (before.text == after.text && before.deltaJson == after.deltaJson) {
      if (textGesture != null) {
        _captureV2Gesture(textGesture: textGesture, recordHistory: false);
        _scheduleSave(pageId: pages[pageIndex].id);
      }
      return;
    }
    _undoActions.add(
      _EditorHistoryEntry(
        pages[pageIndex].id,
        UpdateTextAction(before: before, after: after),
      ),
    );
    _redoActions.clear();
    _captureV2Gesture(textGesture: textGesture);
    _scheduleSave(pageId: pages[pageIndex].id);
  }

  void _discardActiveTextEdit() {
    _activeTextEditPageIndex = null;
    _activeTextEditBefore = null;
    _activeV2TextGesture = null;
  }

  /// Completes an opt-in image upload after its receipt and bytes have
  /// already been verified and staged outside the SQLite transaction.
  ///
  /// Re-queues a failed local gesture without using a legacy snapshot writer.
  void registerVerifiedImageAsset({
    required String imageId,
    required VerifiedEditorAsset asset,
  }) {
    final writer = operationWriter;
    if (writer == null || _isDisposed) {
      throw StateError('Only an active v2 editor can register image assets.');
    }
    final matching = [
      for (final page in pages)
        if (page.imageBlocks.any((image) => image.id == imageId)) page.id,
    ];
    if (matching.length != 1) {
      throw StateError('Verified image has no unique page in this editor.');
    }
    writer.registerVerifiedAsset(
      documentId: notebook.uid,
      objectId: imageId,
      asset: asset,
    );
    _scheduleSave(pageId: matching.single);
  }

  void _scheduleSave({String? pageId}) {
    _integritySaveBlocked = false;
    final dirtyPageId = pageId ?? currentPage.id;
    _dirtyPageIds.add(dirtyPageId);
    _armSaveTimer();
  }

  void _armSaveTimer() {
    if (_isDisposed) {
      return;
    }
    _notebookSaveDebounce?.cancel();
    _notebookSaveDebounce = Timer(saveDebounce, () {
      _notebookSaveDebounce = null;
      // A shared session sends each committed stroke without the normal
      // two-second ink cooldown. Never save while a contact is still down.
      final ink = InkActivityTracker.instance;
      if (ink.hasActiveContacts ||
          (saveDebounce >= defaultSaveDebounce && ink.isBusy)) {
        _armSaveTimer();
        return;
      }
      unawaited(_fullSavePending ? _save() : _saveDirtyPages());
    });
  }

  /// Keeps each completed action independent of the next debounce period.
  void _captureV2Gesture({
    _V2TextGesture? textGesture,
    bool recordHistory = true,
  }) {
    if (operationWriter == null || _isDisposed || _v2DocumentDeleted) {
      return;
    }
    _v2GestureCheckpoints.add(
      _V2GestureCheckpoint(
        notebook.copyWith(
          pages: List<NotePage>.of(pages),
          updatedAt: DateTime.now(),
        ),
        textGesture,
        recordHistory,
      ),
    );
  }

  /// Serializes v2 writes without ever invoking snapshot repository saves.
  ///
  /// The committed baseline advances only after the SQLite transaction.
  /// Another gesture during an active transaction queues a fresh comparison
  /// against that baseline, so it cannot overwrite a newer page revision.
  Future<void> _saveV2() {
    _notebookSaveDebounce?.cancel();
    _notebookSaveDebounce = null;
    _fullSavePending = true;
    final previous = _v2SaveTail ?? Future<void>.value();
    // Undo/Redo may be awaiting a remote asset upload. A normal save must
    // never prepare drafts against the pre-inverse SQLite baseline.
    final activeInverse = _v2HistoryCommitting ? _v2HistoryTail : null;
    late final Future<void> next;
    next = previous
        .then((_) async {
          await historyReady;
          if (_v2HistoryLoadError != null) {
            _integritySaveBlocked = true;
            _fullSavePending = true;
            return;
          }
          if (activeInverse != null) {
            await activeInverse;
          }
          final savedPages = pages;
          final textEditInProgress = _activeTextEditBefore != null;
          final activeTextGesture = _activeV2TextGesture;
          final proposed = notebook.copyWith(
            pages: savedPages,
            updatedAt: DateTime.now(),
          );
          try {
            if (_v2DocumentDeleted) {
              throw StateError('A deleted v2 notebook cannot be edited.');
            }
            Future<void> persist(
              Notebook target, {
              _V2TextGesture? textGesture,
              bool recordHistory = true,
            }) async {
              final baseline = _v2PersistedNotebook;
              List<_V2HistoryEntry>? nextUndo;
              List<_V2HistoryEntry>? nextRedo;
              EditorHistoryCheckpoint? checkpoint;
              final committed = await operationWriter!.writeNotebookChange(
                before: baseline,
                after: target,
                onCommittedInTransaction: (operations) async {
                  nextUndo = List<_V2HistoryEntry>.of(_v2Undo);
                  nextRedo = List<_V2HistoryEntry>.of(_v2Redo);
                  final operationId = operations.isNotEmpty
                      ? operations.last.operationId
                      : textGesture?.lastOperationId;
                  if (recordHistory && operationId != null) {
                    try {
                      final before = textGesture?.before ?? baseline;
                      final storedBefore = await _v2HistoryCodec!.encode(
                        before,
                      );
                      final storedAfter = await _v2HistoryCodec!.encode(target);
                      nextUndo!.add(
                        _V2HistoryEntry(
                          before,
                          target,
                          operationId,
                          stored: StoredEditorGesture(
                            before: storedBefore,
                            after: storedAfter,
                            operationId: operationId,
                          ),
                        ),
                      );
                      nextRedo!.clear();
                    } on EditorHistoryBudgetExceeded {
                      // A huge notebook may exceed the inverse metadata cap.
                      // Do not roll back its real content or retain stale
                      // history that could undo an unrecorded newer change.
                      nextUndo!.clear();
                      nextRedo!.clear();
                    }
                  }
                  checkpoint = await _persistV2History(
                    operations,
                    undo: nextUndo!,
                    redo: nextRedo!,
                  );
                },
              );
              _v2PersistedNotebook = target;
              if (textGesture != null && committed.isNotEmpty) {
                textGesture.lastOperationId = committed.last.operationId;
              }
              _installV2History(checkpoint, nextUndo!, nextRedo!);
              if (recordHistory &&
                  (committed.isNotEmpty ||
                      textGesture?.lastOperationId != null)) {
                _undoActions.clear();
                _redoActions.clear();
                _notifyHistoryChanged();
              }
            }

            final gestures = List<_V2GestureCheckpoint>.of(
              _v2GestureCheckpoints,
            );
            for (final gesture in gestures) {
              await persist(
                gesture.target,
                textGesture: gesture.textGesture,
                recordHistory: gesture.recordHistory,
              );
              _v2GestureCheckpoints.removeAt(0);
            }
            // A later gesture during I/O must not be overwritten by this save.
            if (identical(pages, savedPages)) {
              await persist(
                proposed,
                textGesture: activeTextGesture,
                recordHistory: !textEditInProgress,
              );
            }
            _integritySaveBlocked = false;
            if (identical(pages, savedPages) && _v2GestureCheckpoints.isEmpty) {
              _fullSavePending = false;
              _dirtyPageIds.clear();
              _expectedRemovedIdsByPage.clear();
              _expectedRemovedPageIds.clear();
            }
            if (!_isDisposed) {
              _notifyHistoryChanged();
            }
          } catch (error, stackTrace) {
            // Never fall back to saveNotebook after a failed v2 batch. Leave
            // optimistic state dirty and block shutdown until it can be saved.
            _integritySaveBlocked = true;
            _fullSavePending = true;
            if (!_isDisposed) {
              _notifyHistoryChanged();
            }
            debugPrint('EditorController._saveV2 blocked: $error\n$stackTrace');
          }
        })
        .whenComplete(() {
          if (identical(_v2SaveTail, next)) {
            _v2SaveTail = null;
          }
        });
    _v2SaveTail = next;
    return next;
  }

  Future<void> _saveDirtyPages() async {
    if (operationWriter != null) {
      await _saveV2();
      return;
    }
    if (_dirtyPageIds.isEmpty) {
      return;
    }
    _integritySaveBlocked = false;
    final pageIds = Set<String>.of(_dirtyPageIds);
    _dirtyPageIds.removeAll(pageIds);
    final expectedRemoved = _pendingExpectedRemovals(pageIds);
    final updated = notebook.copyWith(pages: pages, updatedAt: DateTime.now());
    try {
      final saved = await repository.saveNotebookPages(
        updated,
        pageIds,
        expectedRemovedIdsByPage: expectedRemoved,
      );
      if (saved) {
        _clearSavedExpectedRemovals(expectedRemoved);
      }
      if (!saved) {
        _dirtyPageIds.addAll(pageIds);
        _armSaveTimer();
      }
    } on DataIntegrityProtectionException catch (error, stackTrace) {
      _dirtyPageIds.addAll(pageIds);
      _integritySaveBlocked = true;
      debugPrint(
        'EditorController._saveDirtyPages blocked: $error\n$stackTrace',
      );
      return;
    } catch (error, stackTrace) {
      _dirtyPageIds.addAll(pageIds);
      debugPrint(
        'EditorController._saveDirtyPages failed: $error\n$stackTrace',
      );
      _armSaveTimer();
    }
  }

  Future<void> _save() async {
    if (operationWriter != null) {
      await _saveV2();
      return;
    }
    _integritySaveBlocked = false;
    _notebookSaveDebounce?.cancel();
    _notebookSaveDebounce = null;
    _fullSavePending = true;
    final savedPages = pages;
    final expectedRemoved = _pendingExpectedRemovals({
      for (final page in savedPages) page.id,
    });
    final expectedRemovedPages = Set<String>.of(_expectedRemovedPageIds);
    final updated = notebook.copyWith(
      pages: savedPages,
      updatedAt: DateTime.now(),
    );
    try {
      final saved = await repository.saveNotebook(
        updated,
        preserveMetadata: true,
        expectedRemovedIdsByPage: expectedRemoved,
        expectedRemovedPageIds: expectedRemovedPages,
      );
      if (saved) {
        _clearSavedExpectedRemovals(expectedRemoved);
        _expectedRemovedPageIds.removeAll(expectedRemovedPages);
      }
      if (saved && identical(pages, savedPages)) {
        _fullSavePending = false;
        _dirtyPageIds.clear();
        return;
      }
    } on DataIntegrityProtectionException catch (error, stackTrace) {
      _integritySaveBlocked = true;
      debugPrint('EditorController._save blocked: $error\n$stackTrace');
      return;
    } catch (error, stackTrace) {
      debugPrint('EditorController._save failed: $error\n$stackTrace');
    }
    _armSaveTimer();
  }
}

sealed class _ElementClipboardItem {
  const _ElementClipboardItem();
}

class _TextElementClipboardItem extends _ElementClipboardItem {
  const _TextElementClipboardItem(this.block);

  final TextBlock block;
}

class _ImageElementClipboardItem extends _ElementClipboardItem {
  const _ImageElementClipboardItem(this.block);

  final ImageBlock block;
}

class _LassoElementClipboardItem extends _ElementClipboardItem {
  const _LassoElementClipboardItem({
    required this.strokes,
    required this.textBlocks,
    required this.imageBlocks,
    required this.bounds,
    required this.pageIndex,
  });

  final List<InkStroke> strokes;
  final List<TextBlock> textBlocks;
  final List<ImageBlock> imageBlocks;
  final Rect bounds;
  final int pageIndex;
}
