# PROJECT_MAP.md

Mapa projektu **Notatek / Stylus Notes** (Flutter, `pubspec.yaml::name: program`).
Plik istnieje, żeby agenci AI mogli skakać prosto do interesujących linii zamiast
czytać cały kod. **Zawsze najpierw zajrzyj tutaj, potem czytaj konkretny zakres.**

> Jeżeli edytujesz kod tak, że numeracja linii się zmienia, **zaktualizuj tę mapę
> w tym samym commicie** (przynajmniej pozycje w plikach, których dotyka zmiana).
> Mapa jest deklaratywnym indeksem, nie dokumentem narracyjnym.

---

## 1. Stack i konwencje

- Flutter 3.x + Dart `^3.11.1` (Material 3).
- Lokalna baza: **Isar 3** (`isar`, `isar_flutter_libs`, kodogen w `*_entity.g.dart`).
- State management: **Provider + ChangeNotifier** (brak Bloc/Riverpod).
- Rich text: **flutter_quill** w blokach tekstowych.
- Inne kluczowe paczki: `pdfx`, `image_picker`, `file_picker`,
  `google_mlkit_text_recognition` (OCR tylko Android/iOS), `super_clipboard`,
  `path_provider`, `uuid`.
- Architektura feature-first: `lib/app`, `lib/core`, `lib/data`, `lib/features/{library,notebook,editor,board}`.
- Styl: `dart format`, 80-kolumnowe linie, lowerCamelCase / UpperCamelCase
  (szczegóły: [AI_INSTRUCTIONS.md](AI_INSTRUCTIONS.md)).
- Brak `library` deklaracji, brak prefiksów `k`, prywatne pola zaczynają się od `_`.

## 2. Drzewo katalogów (skrót)

```
NaNotateczki/                  ← główny pakiet Flutter (name: program)
├── lib/
│   ├── main.dart              ← runApp(NotesApp())
│   ├── app/                   ← root widget + DI (Provider)
│   ├── core/                  ← motyw, metryki, reużywalne widgety
│   ├── data/                  ← Isar, backup, sync
│   └── features/
│       ├── library/           ← lista notebooków, foldery, search, sync
│       ├── notebook/          ← modele domeny + repository + ekran "pusty"
│       ├── editor/            ← edytor stronicowy (notebook)
│       └── board/             ← edytor canvas (board, jedna „strona")
├── test/widget_test.dart      ← smoke test: NotesApp pumpuje MaterialApp
├── pubspec.yaml               ← zależności (Isar, Quill, mlkit, pdfx…)
└── AI_INSTRUCTIONS.md         ← skrót Effective Dart Style
```

## 3. Mapa plików (linijka po linijce)

Format pozycji: `LL: nazwa — krótki opis`. `LL` to numer linii startowej.

---

### `lib/main.dart` (17 linii)
Entry point.
- 5: `void main()` — `WidgetsFlutterBinding.ensureInitialized()`, filtruje
  „śmieciowe" zdarzenia klawiatury na Linuxie (drop gdy `physical/logical == 0`),
  potem `runApp(NotesApp())`.

### `lib/app/notes_app.dart` (12 linii)
- 5: `class NotesApp extends StatelessWidget` — owija aplikację w `AppScope`.

### `lib/app/app_scope.dart` (80 linii) — DI + bootstrap
- 14: `class AppScope` — `FutureBuilder<IsarOpenResult>` na `IsarService.open()`.
- 19–26: spinner podczas otwierania Isara.
- 34–47: `runBackup()` — hook wywoływany przez repo (po każdej zmianie),
  pomija snapshot po częściowym odczycie uszkodzonych rekordów Isara.
- 49–54: tworzy `NotebookRepository`, `LocalBackupService`, `CloudSyncService`.
- 56–75: `MultiProvider` z `NotebookRepository`, `LocalBackupService`,
  `LibraryController` (`wasReset`/`freshFile`/`resetReason` z Isara) →
  `MaterialApp(home: LibraryScreen)`.

### `lib/core/theme/app_colors.dart` (18 linii)
- 3: `class AppColors` — stałe: `paper`, `toolbar`, `inkBlack`, `shadow`,
  `divider` + lista `inkPalette` (6 kolorów).

### `lib/core/theme/app_theme.dart` (21 linii)
- 5: `class AppTheme.light()` — Material 3, seed = `inkBlack`, paper background,
  AppBar w `toolbar`.

### `lib/core/theme/app_metrics.dart` (3 linie)
- 1: `class AppMetrics` — stałe metryczne wspólne dla edytora i miniaturek.
  - `a4HeightRatio = 297 / 210` (height/width pojedynczej strony A4).

### `lib/core/widgets/empty_state.dart` (30 linii)
- 3: `class EmptyState` — wycentrowane `title + message`, max width 360.

### `lib/core/widgets/resizable_frame.dart` (179 linii)
- 5: `enum ResizeDirection` (8 kierunków: topLeft…bottomRight).
- 16: `class ResizableFrame extends StatefulWidget` — owija dziecko,
  pokazuje 8 uchwytów gdy `isSelected`.
- 40: `_ResizableFrameState` — z `_activeHandle` do podświetlania.
- 45: `build` — gdy nie wybrany, zwraca samo dziecko; inaczej `Stack` z 8 `_buildHandle`.
- 105: `_buildHandle({alignment, direction, cursor})` — `MouseRegion + GestureDetector` (onLongPress z opóźnieniem),
  liczy delta w lokalnej przestrzeni, animuje skalę uchwytu.
- 172: `_globalToFrameLocal` — `RenderBox.globalToLocal`.

---

### `lib/data/isar/entities/notebook_entity.dart` (74 linii)
Encje Isara (każda zmiana wymaga regeneracji `*.g.dart` i podbicia
`kManualSchemaRevision` w `isar_service.dart`).
- 5: `@collection NotebookEntity` — `id, uid, title, kindIndex, folder,
  createdAt, updatedAt, pages`.
- 17: `@embedded NotePageEntity` — `uid, index, title, isBookmarked,
  textBlocks, imageBlocks, inkStrokes`.
- 28: `@embedded TextBlockEntity` — `text, deltaJson, fontSize, colorValue,
  width, rotation, dx, dy`.
- 41: `@embedded ImageBlockEntity` — `path, ocrText, bytes (List<int>?),
  imageExt, imageMime, width, height, rotation, dx, dy, crop{Left,Top,Right,Bottom}`.
- 60: `@embedded InkStrokeEntity` — `colorValue, width, toolIndex, points`.
- 69: `@embedded InkPointEntity` — `dx, dy, pressure`.

### `lib/data/isar/entities/notebook_entity.g.dart` (5574 linii)
Wygenerowane przez `isar_generator` — **NIE edytuj ręcznie**. Po zmianach w
`notebook_entity.dart` uruchom `dart run build_runner build --delete-conflicting-outputs`.

### `lib/data/isar/isar_service.dart` (142 linii)
- 9: `const int kManualSchemaRevision = 2` — **podbij po zmianie encji**.
  Aktualna rewizja `2` została bumpnięta razem z naprawą symetrii
  `_toolFromIndex/_toolToIndex` w `notebook_repository.dart` — pierwsze
  uruchomienie po pull'u wykona auto-wipe bazy.
- 11: `class IsarOpenResult` — `service, wasReset, freshFile, resetReason`.
- 25: `class IsarService(this.isar)`.
- 34: `static Future<IsarOpenResult> open()` — odporne otwieranie: fingerprint
  schematu, wipe+retry na schema mismatch / open failure / smoke test failure.
- 83: `Future<void> close()`.
- 85: `_computeSchemaFingerprint()` — `vN:id1,id2,…`.
- 97: `_readStoredFingerprint(dir)` — `schema_version.txt`.
- 110: `_writeFingerprint`.
- 119: `_wipeDatabaseFiles` — kasuje `default.isar` + `.lock`.
- 132: `_smokeTest` — `notebookEntitys.where().limit(1).findAll()`.

### `lib/data/backup/local_backup_service.dart` (101 linii)
Trzy snapshoty JSON w `local_backup/`: `notebooks_latest/prev1/prev2.json`.
- 10: `class LocalBackupService(this.repository)`.
- 20: `_backupDir()` — tworzy katalog jeśli brak.
- 29: `_file(name)`.
- 34: `snapshot(items)` — rotuje pliki (`prev1→prev2`, `latest→prev1`), zapisuje JSON.
- 62: `hasLatest()`.
- 70: `readLatest()` — czyta `notebooks_latest.json`, dekoduje przez repo.
- 88: `restoreFromLatest()` — zapisuje wszystkie notebooki do Isara, zwraca count.

### `lib/data/export/notebook_export_service.dart` (535 linii)
Eksport notebooków/boardów do wybranej przez użytkownika lokalizacji
(`Documents/exports` jako domyślny katalog dialogu na desktopie).
- 22: `enum NotebookExportFormat { pdf, png }`.
- 35: `class NotebookExportService` — renderuje aktualny model edytora do PNG
  i opakowuje strony w PDF.
- 43: `exportController(controller, format)` — bierze bieżące strony z
  `EditorController`, zwraca `null` po anulowaniu zapisu.
- 54: `exportNotebook(notebook, format, {pageSize})`.
- 77: `_exportPdf(...)` — renderuje strony jako obrazy i zapisuje jeden PDF przez
  systemowy dialog zapisu.
- 104: `_exportPng(...)` — board/jedna strona jako plik przez dialog zapisu,
  notebook wielostronicowy jako folder `page_XX.png` w wybranym katalogu.
- 140: `_saveBytesAs(...)` — `FilePicker.saveFile`, dopisanie rozszerzenia na
  desktopie, przekazanie bytes na Android/iOS.
- 181: `_renderPage(...)` — `dart:ui` canvas, tło papieru, obrazy, tekst, strokes.
- 241: `_paintImages(...)`.
- 272: `_paintTextBlocks(...)` / 286: `_textSpans(block)` — prosty render delty Quill.
- 345: `_paintStrokes(...)`.
- 413: `_pageContentBounds(page)` — obszar eksportu boarda.

### `lib/data/sync/cloud_sync_service.dart` (125 linii)
Folder-based sync (`notatek_cloud.json` we wskazanym folderze).
- 9: `class CloudSyncResult` — `totalNotebooks, uploaded, downloaded`.
- 21: `class CloudSyncService(this.repository)`.
- 29: `getCloudPath()` — czyta `cloud_sync.json`.
- 44: `setCloudPath(path)`.
- 49: `sync(local)` — merguje chmurę i lokalne po `updatedAt`, zapisuje obie strony.
- 77: `_readCloudNotebooks`.
- 89: `_mergeNotebooks` — last-write-wins po `updatedAt`.
- 107: `_countNewer`.
- 121: `_configFile`.

---

### `lib/features/notebook/domain/notebook.dart` (42 linii)
- 4: `class Notebook { uid, title, kind, folder, createdAt, updatedAt, pages }`
  + `copyWith`.

### `lib/features/notebook/domain/notebook_kind.dart` (15 linii)
- 1: `enum NotebookKind { notebook, board }`.
- 6: `extension NotebookKindValue` — `indexValue`, `fromIndex(int) → NotebookKind`
  (safe fallback do `notebook`).

### `lib/features/notebook/domain/note_page.dart` (39 linii)
- 5: `class NotePage { id, title, textBlocks, imageBlocks, inkStrokes, isBookmarked }`
  + `copyWith`.

### `lib/features/notebook/domain/drawing_tool.dart` (36 linii)
- 1: `enum DrawingTool` — pen, highlighter, eraserBrush, eraserStroke,
  line, arrow, rectangle, square, triangle, ellipse, circle, text, image,
  blockArrow, edit.
- 19: `extension DrawingToolX` — `isEraser`, `isShape`, `isInk`
  (uwaga: `isInk` true dla pen/highlighter/eraserów/wszystkich kształtów).

### `lib/features/notebook/domain/ink_stroke.dart` (53 linii)
- 5: `class InkStroke { id, points, color, width, tool }` + `copyWith`.
- 37: `class InkPoint { dx, dy, pressure }` + `fromOffset` + `toOffset`.

### `lib/features/notebook/domain/text_block.dart` (45 linii)
- 3: `class TextBlock { id, text, deltaJson?, position, fontSize, color,
  width, rotation }` + `copyWith`.

### `lib/features/notebook/domain/image_block.dart` (70 linii)
- 4: `class ImageBlock { id, path, ocrText, position, width, height, bytes?,
  imageExt?, imageMime?, rotation, cropLeft/Top/Right/Bottom }` + `copyWith`
  (crop domyślnie 0/0/1/1).

### `lib/features/notebook/data/notebook_repository.dart` (580 linii)
Mostek domena ↔ Isar ↔ JSON.
- 18: `class NotebookRepository(this.isar, {this.onChanged})` — callback po każdym zapisie.
- 26: `lastFetchSkippedCorruptRows` — flaga dla backupu po fallbacku.
- 28: `fetchNotebooks()` — sortowane po `updatedAtDesc`, z fallbackiem.
- 42: `_fetchNotebooksDefensively()` — id-by-id, loguje skipy i usuwa
  nieodczytywalne rekordy.
- 70: `_deleteCorruptRows(ids)` — kasuje uszkodzone rekordy po Isar id.
- 79: `createNotebook({title, folder})` — `NotebookKind.notebook`, 1 strona „Page 1".
- 104: `createBoard({title, folder})` — `NotebookKind.board`, jedna strona „Canvas".
- 129: `getNotebook(uid)`.
- 145: `saveNotebook(notebook)` — migruje `ImageBlock.path → bytes` jeśli
  bytes brak a plik istnieje, potem `writeTxn(put)`, woła `onChanged`.
- 203: `deleteNotebook(uid)`.
- 217: `encodeNotebooks(items)` / 221: `decodeNotebooks(items)` — JSON.
- 228–278: mapowanie entity↔domain (`_fromEntity`, `_pageFromEntity`,
  `_toEntity`, `_pageToEntity`).
- 280–374: konwersje per-blok (`_textFrom/ToEntity`, `_imageFrom/ToEntity`,
  `_strokeFrom/ToEntity`).
- 376–544: JSON serializery (`_notebookTo/FromJson`, `_pageTo/FromJson`,
  `_textTo/FromJson`, `_imageTo/FromJson`, `_strokeTo/FromJson`).
- 546: `_toolFromIndex(int)` — symetryczne, prosty mapping przez `DrawingTool.values`.
- 554: `_toolToIndex(tool)` — `tool.index`. **Symetria wymagana** —
  zmieniasz jedną, zmieniaj drugą + bump `kManualSchemaRevision`.
- 556: `_bytesFromEntity(List<int>?)`.
- 563: `_bytesToBase64` / 570: `_bytesFromBase64`.

---

### `lib/features/library/presentation/library_controller.dart` (402 linie)
ChangeNotifier — stan ekranu Biblioteki.
- 12: `class LibraryController extends ChangeNotifier` — repo, cloud, backup,
  flagi `wasReset/freshFile/resetReason`.
- 28–44: pola: `autoRestoreCount, isLoading, isSyncing, isLoadingSelectedItem,
  items, selectedItemId, selectedFolder='', searchQuery, cloudPath,
  lastSyncedAt, lastSyncResult, _folders, _activeNotebook`,
  `_defaultFolderName`, `_foldersFileName`.
- 46: `shouldShowResetBanner` getter.
- 49: `dismissResetBanner()`.
- 54: `initialize()` — `_loadFolders` → `loadItems` → `_loadCloudPath`.
- 60: `loadItems()` — pobiera, auto-restore z backupu jeśli pusto a był reset,
  ustawia wybrany folder/item.
- 86: `syncNow()`.
- 96: `setCloudPath(path)`.
- 102: `visibleItems` getter — filtr folderem + searchem.
- 115: `folderNames` getter — `_folders ∪ items.folder`, sortowane
  alfabetycznie bez względu na wielkość liter.
- 127: `createFolder(name)`.
- 139: `renameFolder(oldName, newName)` — zapisuje nową nazwę w folderach i
  notebookach przypisanych do folderu.
- 177: `deleteFolder(name)` — usuwa folder i wszystkie notebooki w nim.
- 206: `createNotebook()` / 216: `createBoard()` — używają wybranego folderu
  albo fallbacku `Notes`.
- 226: `deleteItem(uid)`.
- 235: `selectItem(uid)` — async load z repo, ustawia `_activeNotebook`.
- 247: `selectFolder(folder)`.
- 253: `setSearchQuery(value)`.
- 258: `exportBackup()` — pisze `notatek_backup_<ts>.json` w docs dir.
- 268: `importBackup(path)` — dekoduje + `saveNotebook` per item + reload.
- 282: `selectedItem()` — wybiera active lub by id.
- 292: `_itemById(uid)`.
- 302: `_firstItemInFolder(folder)`.
- 310: `_selectedItemIsInFolder(folder)`.
- 318: `_targetFolderForNewItem()`.
- 329: `_loadCloudPath`.
- 334: `_loadFolders` / 358: `_saveFolders` (`library_folders.json`).
- 368: `_foldersFile`.
- 373: `_compareFolderNames(a, b)`.
- 381: `_matches(notebook, query)` — title/page title/textBlock/ocrText.

### `lib/features/library/presentation/library_screen.dart` (842 linie)
Trójkolumnowy layout (folders | items | workspace) z resizable pane.
- 16: `class LibraryScreen extends StatefulWidget`.
- 23: `_LibraryScreenState` — stałe layoutu (24–29: `_wideBreakpoint=1100`,
  pane min/max widths, `_resizeHandleWidth=12`).
- 31–33: `_showLeftNavigation`, `_folderPaneWidth=220`, `_itemsPaneWidth=320`.
- 35: `_textScaleForPane({width,minWidth,maxWidth,minScale,maxScale})`.
- 49: `initState` — post-frame `controller.initialize()`.
- 57: `build` — Scaffold + banner resetu + LayoutBuilder.
- 80–198: wide layout (≥1100): folder pane, resize handle, items pane,
  resize handle, workspace + `_LeftZoneToggleTab`.
- 200–225: wąski layout: `_FolderChipBar` na górze + lista items na pełnej szerokości.
- 245: `_toggleLeftNavigation`.
- 252: `_promptNewFolder(controller)` — dialog tworzenia folderu.
- 283: `_promptRenameFolder(controller, folder)` — dialog zmiany nazwy folderu.
- 318: `_confirmDeleteFolder(controller, folder)` — potwierdzenie usunięcia
  folderu razem z zawartością.
- 351: `enum _FolderAction { rename, delete }`.
- 344: `class _FolderListPane` — lista folderów (iconOnly gdy pane < 165px),
  separatory jak w liście notatek, 361–407 iconOnly, 409–484 normalny z menu
  akcji folderu.
- 487: `class _FolderChipBar` — chipy folderów (mobile) z menu akcji folderu.
- 556: `class _LibraryItemsPane` — lista notebooków (empty states 575, 615;
  655–727 normalny widok z `LibraryItemCard`).
- 730: `class _LibraryWorkspace` — wybiera `BoardScreen` lub `NotebookScreen`
  na podstawie `item.kind`, owija w `ChangeNotifierProvider<EditorController>`.
- 758: `class _LibraryRoute` — wąski layout (push'owane), `FutureBuilder` do `getNotebook`.
- 784: `enum _CreateAction { notebook, board }`.
- 786: `class _PaneResizeHandle` — pasek do przeciągania szerokości pane.
- 808: `class _LeftZoneToggleTab` — strzałka chevron do collapsowania nawigacji.

### `lib/features/library/presentation/widgets/library_item_card.dart` (108 linii)
- 6: `class LibraryItemCard extends StatelessWidget` — `ListTile` z ikoną typu
  (`board`/`notebook`), tytułem, podtytułem („Board" lub „N pages"),
  `IconButton(delete)`.
- 86: `class _ItemKindIcon` — oprawiona ikonka notatki lub tablicy dla listy
  elementów biblioteki.

---

### `lib/features/notebook/presentation/notebook_screen.dart` (24 linie)
- 8: `class NotebookScreen` — empty state albo bezpośrednio `EditorScreen()`.

### `lib/features/editor/state/editor_actions.dart` (401 linii)
Wszystkie operacje undoowalne. Każda akcja: `apply(page)` + `revert(page)`.
- 8: `abstract class EditorAction`.
- 13: `class AddTextAction(block)`.
- 31: `class AddImageAction(block)`.
- 51: `class AddInkStrokeAction(stroke)`.
- 71: `class RemoveInkStrokesAction({before, after})` — usuwa zbiór strokeów.
- 88: `class UpdateTextAction({before, after})`.
- 113: `class DeleteTextAction(block)`.
- 133: `class MoveTextAction({id, from, to})` — `OffsetPosition`.
- 163: `class MoveImageAction({id, from, to})`.
- 193: `class UpdateImageOcrAction({id, ocrText, before})` — `before` to cała
  lista, żeby rollback miał wartość poprzednią.
- 219: `class UpdateImageAction({before, after})` — pozycja/rozmiar/crop/rotation.
- 244: `class DeleteImageAction(block)`.
- 264: `class MoveSelectionAction` - transluje lasso.
- 319: `class DeleteSelectionAction` - usuwa grupę z lasso.
- 366: `class PasteSelectionAction` - duplikuje/wkleja lasso.
- 390: `class OffsetPosition(dx, dy)` — wartościowy odpowiednik `Offset`
  (`fromOffset`, `toOffset`).

### `lib/features/editor/state/editor_controller.dart` (1973 linii)
Mózg edytora. **Najczęściej modyfikowany plik aplikacji.** Trzyma stan stron,
narzędzia, kolory, undo/redo, zoom/pan, schowek elementów.
- 30: `class LassoSelection` - trzyma metadane zaznaczenia lasso
  (bounds dokumentowe, ID elementów, delty).
- 62: `class EditorController extends ChangeNotifier`.
- 31–32: `minViewScale=0.35`, `maxViewScale=4.0`.
- 34: konstruktor — `pages = notebook.pages`, ładuje prefs.
- 40–76: pola — `repository, notebook, _uuid, _imagePicker, pages,
  currentPageIndex, tool, lastEraserTool, lastShapeTool, inkColor,
  inkStrokeWidth, quickColors (3 sloty), recentColors (12),
  _undo/_redoActions, _prefsSaveDebounce, lastTextFontFamily/Size/Color,
  activeTextBlockId, activeTextController, activeImageBlockId, lassoSelection,
  `lassoDragDelta` (`ValueNotifier<Offset>` do płynnego dragowania lassa bez
  pełnego `notifyListeners()` na każdy ruch), _elementClipboard,
  _suppressBackgroundTap, viewScale, viewPan,
  _pageWidth/_pageHeight/_pageGap`.
- 111–116: gettery `currentPage`, `canUndo`, `canRedo`, `contentBounds`,
  `layoutPageSize`.

#### Layout/wiewport
- 84: `updatePageLayout({pageWidth, pageHeight, pageGap})`.
- 99: `setViewTransform({pan?, scale?})`.
- 113: `panBy(delta)`.
- 120: `zoomBy(factor, focalPoint)`.
- 133: `viewportToWorld(offset)` / 138: `worldToViewport(offset)`.

#### Strony
- 142: `pageAt(index)`.
- 146: `_pageExtent` getter (height + gap).
- 148: `_pageOriginForIndex(index)`.
- 155: `_pageIndexForPosition(offset)` — który page index zawiera punkt Y.

#### Lookupy / aktywne elementy
- 166: `findTextBlockById(id)`.
- 177: `findImageBlockById(id)`.
- 188: `_pageIndexContainingTextBlock(id)`.
- 197: `_pageIndexContainingImageBlock(id)`.
- 206: `_ensurePageSelected(pageIndex)`.

#### Per-page entry points (board/notebook → mapują na current page)
Tylko te `*OnPage`, które są realnie wołane z `page_overlay`/`drawing_canvas`.
- 216: `handleTapOnPage(pageIndex, point)`.
- 221: `updateTextBlockContentOnPage(...)` / 231 position /
  240 delete / 245 commitMove.
- 255: `runOcrForImageOnPage`.
- 260: `updateImageBlockPositionOnPage` / 269 cały blok /
  277 OCR text / 282 delete.
- 287: `addInkStrokeOnPage(pageIndex, points, {widthOverride, toolOverride})`.
- 301: `eraseInkStrokesByIdOnPage(pageIndex, ids)`.
- 306: `commitImageMoveOnPage`.
- 316: `finalizeImageMoveOnPage` — **decyduje czy stroke przechodzi
  na inną stronę** (`_moveImageBlockToPage`) czy zostaje (`commitImageMoveOnPage`).
- 333: `commitImageResizeOnPage`.
- 422: `selectWithLasso(points, pageIndex)` — Ray-Casting; stroke'y liczone w
  koordynatach strony, tekst/obrazy w koordynatach dokumentu.
- 522: `updateLassoMove(delta)` — zapisuje bieżące przesunięcie tylko w
  `lassoDragDelta`, bez przebudowy całego controllera.
- 527: `commitLassoMove()` — zatwierdza `lassoDragDelta` jako
  `MoveSelectionAction`, przesuwa bounds i dopiero wtedy robi notify/save.

#### Narzędzia, kolory, prefs
- 342: `setTool(newTool)` — aktualizuje `lastEraserTool` i `lastShapeTool`.
- 356: `setActiveTextBlock(id, controller)` / 363 clear.
- 369: `setActiveImageBlock(id)` / 378 clear.
- 383: `markTextTap()` / 387: `consumeBackgroundTapSuppression()`.
- 393: `setColor(color)`.
- 400: `setLastTextFontFamily` / 405 size / 410 color.
- 416: `setStrokeWidth(value)`.
- 421: `setQuickColor(index, color)`.
- 430: `_addRecentColor(color)` (cap 12, dedup po ARGB).
- 438: `_loadEditorPrefs()` (`editor_prefs.json`).
- 499: `_schedulePrefsSave()` (debounce 250 ms).
- 506: `_saveEditorPrefs()`.
- 523: `_prefsFile()`.
- 528: `_colorFromHex(value)`.

#### Gesty / undo / redo / strony
- 543: `handleTap(point)` — text vs image vs nic.
- 554: `undo()` / 565: `redo()`.
- 576: `addPage()` — nowy `NotePage`, czyści aktywne.
- 588: `_createPage(index)`.
- 599: `_ensurePageCount(working, count)`.
- 605: `setCurrentPage(index)`.
- 619: `toggleBookmark()`.

#### Operacje tekstowe (current page)
- 625: `addTextBlock(position)` — Quill Delta z lastText* defaultami.
- 651: `addTextBlockFromText(position, text)` — z clipboarda/pliku.
- 680: `updateTextBlockContent(before, {plainText, deltaJson})`.
- 691: `updateTextBlockPosition`.
- 698: `updateTextBlockWidth`.
- 705: `deleteTextBlock`.
- 712: `commitTextMove(id, start, end)`.
- 726: `commitTextResize(before, after)`.

#### Obrazy / clipboard / wklejanie
- 734: `addImageBlock(position)` — image picker (galeria).
- 743: `insertFromFilePicker(position)` — png/jpg/jpeg/pdf/txt; Linux hint o zenity.
- 777: `insertFromClipboard(position)` — image lub tekst z `super_clipboard`,
  fallback `Clipboard.getData(text/plain)`.
- 1063: `pasteElementOrClipboard(position)` — wkleja zapamiętany
  `_elementClipboard` (Text/Image/Lasso) albo wpada do `insertFromClipboard`.
- 1142: `copyActiveElementToClipboard()` — lasso→wewnętrzny clipboard,
  text→clipboard text+`_elementClipboard`, image→PNG/JPEG.
- 856: `cutActiveElementToClipboard()` — copy + `deleteActiveElement`.
- 865: `deleteActiveElement()` — kasuje aktywny tekst lub obraz na właściwej stronie.
- 884: `copyActiveImageToClipboard()` — wykrywa jpg/jpeg → `Formats.jpeg`, inaczej `png`.
- 913: `_tryInsertImageFromClipboard(reader, position)` — PNG first, potem JPEG.
- 930: `_readTextFromClipboard(reader)`.
- 938: `_readClipboardImageBytes(reader, format)`.
- 962: `_readStreamBytes(stream)`.
- 970: `_initialImageBlockSize(sourceSize)` — clampuje do strony (notebook
  używa `_pageWidth/_pageHeight`, board ma stałe 360x520).
- 990: `_addImageBlockFromBytes(bytes, position, extension)`.
- 1016: `_insertFile(file, position)` — branchuje po rozszerzeniu (png/jpg/pdf/txt).
- 1034: `_addImageBlockFromFile(file, position, {runOcr=true})` — kopiuje plik,
  OCR jeżeli wspierane.
- 1079: `_activateInsertedImage(id)` — switch na tool `edit`, set active image.
- 1431: `_addPdfAsImages(pdfFile, position)` — używa `pdfx` (non-Linux),
  renderuje każdą stronę, zapisuje bytes PNG w `ImageBlock`.
- 1516: `_addPdfAsImagesWithPoppler(pdfFile, position)` — Linux fallback,
  uruchamia `pdftoppm` (`poppler-utils`), zapisuje bytes PNG w `ImageBlock`.
- 1254: `runOcrForImage(block)`.
- 1267: `updateImageBlockPosition` / 1274 size / 1289 OCR text.
- 1649: `restoreImageCache(pageIndex, blockId)` — odtwarza plik z `bytes`, gdy ścieżka znikła.
- 1321: `deleteImageBlock(id)`.

#### Strokes / commits
- 1328: `addInkStroke(points, {widthOverride, toolOverride})` — highlighter
  ma `inkStrokeWidth * 8.0`.
- 1351: `eraseInkStrokesById(ids)`.
- 1364: `commitImageMove(id, start, end)`.
- 1378: `commitImageResize(before, after)` — porównuje pos/size/crop/rotation.
- 1392: `_moveImageBlockToPage(fromIdx, toIdx, id, position)`.

#### Helpery
- 1784: `_persistImage(picked)` (XFile→images_cache).
- 1796: `_persistImageFile(file)`.
- 1808: `_persistImageBytes(bytes, filename)`.
- 1819: `_colorToHex(color)`.
- 1824: `_imageSize(file)` — `instantiateImageCodec`.
- 1832: `_runOcr(file)` — mlkit, Latin script.
- 1848: `_isOcrSupported()` — Android/iOS only.
- 1855: `_computeContentBounds()` — bbox stroke + text + image dla widoku.
- 1906: `_applyAction(action)` — push undo, clear redo, apply, update page.
- 1919: `_applyActionWithoutNotify(action)` — wariant dla commitowania lassa;
  zmienia `pages` i undo stack bez pośredniego `notifyListeners()`.
- 1929: `_updatePage(page)`.
- 1959–1972: sealed `_ElementClipboardItem` + `_TextElementClipboardItem`
  + `_ImageElementClipboardItem` + `_LassoElementClipboardItem`.
- 1571: `_save()` — `repository.saveNotebook(notebook.copyWith(pages, updatedAt=now))`.
- 1577–1591: sealed `_ElementClipboardItem` + `_TextElementClipboardItem`
  + `_ImageElementClipboardItem`.

---

### `lib/features/editor/presentation/editor_screen.dart` (1760 linii)
Layout edytora notebooka (stronicowy). Listener gestów, transformacja zoom/pan
strony, mini-mapa, podgląd skali, podgląd ramki strony.
- 27: `class EditorScreen extends StatefulWidget`.
- 34: `_EditorScreenState` — stałe (35–45: `_pageGap=26`, paddings, sensytywności
  pan/scroll, scale floors). A4 ratio czytane z `AppMetrics.a4HeightRatio`.
- 47–69: pola stanu (ScrollController, GlobalKey canvas, `_isAutoAddingPage`,
  `_pageExtent`, `_isViewportNavigating`, pending touch navigation, gesty
  multi-touch, `_pageScale=1`, `_pagePan`, `_pageMin/MaxScale`).
- 68: `initState` — `_scrollController.addListener(_handleScroll)`.
- 74: `dispose`.
- 80: `_handleScroll()`.
- 87: `_onPagesScroll(notification, controller)` — auto-add page przy końcu.
- 119: `_syncCurrentPageToViewport(controller)`.
- 142: `_tryAutoAddPage(metrics, controller)` — throttled przez `_lastAutoAddAt`.
- 181: `_syncPageTransformBounds({docWorldSize, fitToWidthScale, viewportSize})`.
- 218: `_isNavigationPointerKind(kind)` — touch/trackpad/mouse (NIE pen/stylus).
- 225: `_onPointerDown(event, docWorldSize, viewportSize)` — pending touch
  navigation przy narzędziach rysowania, żeby dłoń nie przesuwała canvasa.
- 255: `_onPointerMove(...)` — multi-touch pinch/pan.
- 317: `_onPointerUpOrCancel(event)`.
- 338: `_startViewportNavigation(docWorldSize, viewportSize)`.
- 364: `_onPointerPanZoomStart(event, ...)` — trackpad scroll wheel.
- 389: `_onPointerPanZoomUpdate(...)`.
- 431: `_onPointerPanZoomEnd(event)`.
- 443: `_onPointerSignal(event, ...)` — `PointerScrollEvent` (myszka).
- 467: `_applyPageTransform({scale, pan, ...})` — aktualizuje `_pageScale/_pagePan`.
- 519: `_clampPagePan({pan, scale, docWorldSize, viewportSize})`.
- 553: `_stopViewportNavigation()`.
- 563: `_midpoint(a, b)` / 567: `_distanceBetween` / 571: `_documentHeight`.
- 578: `_visibleDocumentRect({docWorldSize, viewportSize})` — który fragment widać.
- 659: `_insertPositionForViewport({...})` — gdzie wstawić blok dla insert toolbara.
- 693: `_handleExport(controller, format)` — eksportuje aktualną notatkę do
  PDF/PNG przez `NotebookExportService`, obsługuje anulowanie dialogu zapisu.
- 751: `_handleDelete(controller)`.
- 817: `build(context)` — Scaffold(AppBar=tytuł notebooka+bookmark) + Column
  (EditorToolbar, TextEditToolbar gdy aktywny tekst, InsertToolbar gdy `_isInsertToolbarVisible`,
  LayoutBuilder z głównym canvas: SingleChildScrollView + Listener +
  Transform(`_pageScale/_pagePan`) + Stack[strony (DecoratedBox+`_PageFramePainter`),
  `DocumentPageOverlay`(bg+inactive), `DocumentDrawingCanvas`,
  `DocumentPageOverlay`(active)]); pozycjonuje `_ZoomPercentBadge` + `_ProjectMiniMapOverlay`.
- 1037–1086: skróty klawiszowe (Ctrl/Cmd+V/C/X, Delete) → CallbackActions
  (paste/copy/cut/delete) — **wyłączone gdy aktywny TextEditor**.
- 1185: `class _PasteFromClipboardIntent`.
- 1189: `_CopyElementIntent`.
- 1193: `_CutElementIntent`.
- 1197: `_DeleteElementIntent`.
- 1201: `enum _CanvasContextAction { paste }`.
- 1203: `class _BoundaryVisibility` — które krawędzie strony są widoczne.
- 1236: `class _PageFramePainter extends CustomPainter` — rysuje pomarańczową
  ramkę aktywnej strony.
- 1311: `class _ZoomPercentBadge` — chip „150%".
- 1341: `class _ProjectMiniMapOverlay extends StatefulWidget` (mini-mapa).
- 1364: `_ProjectMiniMapOverlayState`.
- 1390: `_syncMinimapToViewport()`.
- 1526: `class _ProjectMiniMapPainter` — rysuje strony, content thumbnails.
- 1705: `class _MiniMapViewportOverlayPainter` — rysuje prostokąt widoku.

### `lib/features/editor/presentation/widgets/drawing_canvas.dart` (2177 linii)
Dwie warianty canvasu rysowania. **Notebook używa `DocumentDrawingCanvas`,
board używa `DrawingCanvas`.** Logika prawie zduplikowana — to świadoma decyzja
(różne układy współrzędnych). Oba warianty opóźniają start stroke dla dotyku,
odrzucają duży kontakt dłoni i dają pierwszeństwo aktywnemu rysikowi/myszy.
- 14: `class DrawingCanvas extends StatefulWidget` — board, jedna strona/canvas.
- 34: `class DocumentDrawingCanvas extends StatefulWidget` — notebook,
  N stron pionowo, params `{worldOrigin, pages, pageSize, pageGap,
  allowMultiTouch, interactionEnabled}`.

#### `_DrawingCanvasState` (board) — 56–896
- 78: `build` — `Listener` z `_onPointerDown/Move/Up/Cancel` +
  `ValueListenableBuilder(controller.lassoDragDelta)` + `CustomPaint(_InkPainter)`.
- 146: `_onPointerDown(event, controller)` — wybiera aktywny pointer;
  dotyk startuje dopiero po progu ruchu, rysik/mysz od razu.
- 224: `_onPointerMove` — dodaje punkty, ewentualnie eraser.
- 312: `_onPointerUp` — commit stroke przez `controller.addInkStroke`.
- 411: `_onPointerCancel`.
- 425: `_resetCurrent()`.
- 455: `_toWorld(local)`.
- 459: `_shouldAddPoint(offset)` — min odległość.
- 484: `_startSnapTimer(offset)` — po holdzie z czystym kształtem wywołuje `_snapToShape`.
- 494: `_eraseAt(offset, page, controller)`.
- 506: `_resolvedPage(controller)` / 510: `_resolvedPageIndex`.
- 514: `_strokeHitTest(stroke, point, radius)`.
- 533: `_distanceSquaredToSegment(p, a, b)`.
- 546: `_snapToShape()` — wykrywa line/rect/ellipse.
- 604: `_clearSnapHintSoon()`.
- 617: `_isRoughlyStraight(start, end, points)`.
- 641: `_isRoughlyRectangle(points)`.
- 666: `_isRoughlyEllipse(points)`.
- 735: `_findFarthestCorner(points, holdPoint)`.
- 759: `_isInkTool(tool)`.
- 763: `_isSnapTool(tool)` — pen/highlighter snapują, eraser/kształty nie.
- 767: `_effectiveStrokeWidth(tool, baseWidth)`.
- 799: `_squareCorner(start, end)` — wymuszony kwadrat/koło.

#### `_DocumentDrawingCanvasState` (notebook) — 899–1834
Te same metody co wyżej, ale operują w przestrzeni dokumentu (offset per page).
- 924: `build` — też nasłuchuje `lassoDragDelta` przy repaint zaznaczonych stroke'ów.
- 989: `_onPointerDown` / 1089 Move / 1206 Up / 1282 Cancel; lasso w dokumencie
  woła `selectWithLasso` zamiast zapisywać obrys jako stroke.
- 1296: `_resetCurrent`.
- 1328: `_toWorld(local)`.
- 1353: `_pageOrigin(pageIndex)` / 1363: `_toPageLocal(world, pageIndex)` /
  1371: `_toDocument(pageLocal, pageIndex)` / 1379: `_isInsidePage(pageLocal)`.
- 1386: `_shouldAddPoint`.
- 1411: `_startSnapTimer`.
- 1421: `_eraseAt(localOffset, pageIndex)`.
- 1437: `_strokeHitTest` / 1456 `_distanceSquaredToSegment`.
- 1482: `_snapToShape`.
- 1540: `_clearSnapHintSoon`.
- 1553: `_isRoughlyStraight` / 1577 `_isRoughlyRectangle` / 1602 `_isRoughlyEllipse`.
- 1671: `_findFarthestCorner`.
- 1695: `_isInkTool` / 1699 `_isSnapTool` / 1703 `_effectiveStrokeWidth`.
- 1735: `_squareCorner`.

#### Paintery
- 1835: `class _InkPainter extends CustomPainter` (board) — obsługuje
  `selectedStrokeIds` + `selectionDelta`; `_drawStroke` rysuje niebieskie
  podświetlenie zaznaczonego stroke'a i przesuwa go wizualnie podczas drag.
- 1996: `class _DocumentInkPainter extends CustomPainter` (notebook) —
  analogicznie dla dokumentu; filtruje zaznaczenie po `selectedPageIndex`.

### `lib/features/editor/presentation/widgets/page_overlay.dart` (1546 linii)
Warstwa interaktywna nad rysunkiem (tekst + obrazy, drag/resize/crop).
- 20: `class PageOverlay extends StatelessWidget` (board, single-page);
  aktywna warstwa przepuszcza gesty lasso mimo `tool.isInk`; przekazuje
  `lassoDragDelta` tylko do elementów zaznaczonych lasso.
- 134: `class DocumentPageOverlay extends StatelessWidget` (notebook, N stron).
  Params `renderBackground/renderInactive/renderActive` (dwie warstwy w
  EditorScreen: bg+inactive PRZED canvasem, active POnad).
- 185: `class _TextBlockWidget extends StatefulWidget`.
- 206: `_TextBlockWidgetState` — build/_initQuill/_isOnFrame/_dragHandle/
  _startMove/_updateMove/_endMove + helpery do delty Quill; zaznaczenie lasso
  daje niebieskie podświetlenie i przesuwa pozycję przez lokalny
  `ValueListenableBuilder`, bez rebuildowania Quilla.
- 632: `class _ImageBlockWidget extends StatefulWidget`.
- 653: `_ImageBlockWidgetState` — Listener (drag+pinch dwoma palcami=resize),
  `ResizableFrame` z 8 uchwytami, prawy klik → menu kopiowania,
  `_imageChild` (`Image.memory(bytes)` lub `Image.file(path)` z
  `Transform.rotate` + crop `Rect.fromLTRB(cropLeft,cropTop,cropRight,cropBottom)`),
  `_normalizeBlockToImageBounds`, `_startResize`/`_updateResize`/`_endResize`;
  zaznaczenie lasso daje border/shadow i przesuwa tylko `Positioned` przez
  `ValueListenableBuilder`,
  `_cornerDelta`/`_clampSize`/`_cornerPosition`/`_cropOffsetX|Y`.
- 1361: `enum _CropAnchorAxis { left, right, top, bottom }`.
- 1363: `class _CropAnchor`.
- 1370: `enum _ImageContextAction { copy }`.
- 1374: `_LassoSelectionWidget` — niewidzialny hit target do dragowania całego
  zaznaczenia + akcje copy/delete; nie rysuje prostokąta, bounds są dokumentowe,
  widget odejmuje `worldOrigin` strony i śledzi `dragDeltaListenable`.
- 1530: top-level `Offset _globalDeltaToLocalDelta(...)`.

### `lib/features/editor/presentation/widgets/editor_toolbar.dart` (524 linie)
Główny pasek narzędzi nad canvasem (narzędzia, kolory, stroke width, undo/redo,
export).
- 8: `class EditorToolbar extends StatelessWidget`.
- 20: `build` — lewy przewijany segment z narzędziami i stały prawy przycisk
  eksportu.
- 113: `_exportButton()` — popup PDF/PNG wyrównany do prawej strony toolbara.
- 139: `_actionButton({...})` — generyczny IconButton.
- 156: `_toolButton({...})` — IconButton z aktywnym tłem gdy `tool == ...`.
- 172: `_eraserSelector()` — popup z `eraserBrush`/`eraserStroke`.
- 225: `_shapeSelector()` — popup z liniami/strzałkami/prostokątami/kołami.
- 299: `_shapeLabel(tool)`.
- 322: `_colorDot(...)` — kafelek koloru (quickColors + recentColors + picker).
- 470: `_channelSlider({...})` — slider R/G/B w pickerze niestandardowym.
- 519: `_toByte(component)`.

### `lib/features/editor/presentation/widgets/text_edit_toolbar.dart` (457 linii)
Pasek formatowania tekstu (pokazywany gdy aktywny TextBlock).
- 7: `class TextEditToolbar extends StatelessWidget` — bierze `quill.QuillController`
  + `EditorController` + `activeTextBlockId`.
- 38: `build` — bold/italic/underline/strike, font, size, color picker.
- 114: `_styleButton({...})`.
- 128: `_fontDropdown(currentFont)`.
- 154: `_sizeDropdown(currentSize)`.
- 180: `_colorPicker(context, currentValue)` — popup z slidersami.
- 216: `_toHex(color)`.
- 349: `_channelSlider({...})`.
- 373: `_toByte(component)`.
- 402: `_applyFormat(attribute, isActive)` — toggle bold/italic/etc.
- 433: `_storeLastTextStyle(...)` — zapamiętuje preferencje (Quill formatuje
  natychmiast, controller też trzyma kopię w `lastText*`).

---

### `lib/features/board/presentation/board_screen.dart` (770 linii)
Edytor canvas (kind=board): jedna „strona" o nieograniczonych granicach,
swobodne rozmieszczanie + zoom/pan z trackpada/touch.
- 24: `class BoardScreen extends StatefulWidget`.
- 31: `_BoardScreenState`.
- 48: `_buildBoardRect(controller, viewportSize)` — content bounds + padding.
- 68: `_onPointerDown` / 96 Move / 150 Up/Cancel — pending touch navigation
  przy narzędziach rysowania, żeby dłoń nie przesuwała boarda.
- 175: `_startViewportNavigation(controller)`.
- 193: `_onPointerPanZoomStart(event, controller)` / 213 Update / 252 End.
- 267: `_onPointerSignal(event, controller)` — myszka kółkiem zoom.
- 302: `_stopViewportNavigation(controller)`.
- 312: `_midpoint(a, b)` / 316 `_distanceBetween`.
- 320: `_isNavigationPointerKind(kind)`.
- 325: `_boardInsertPosition(controller, viewportSize)` — gdzie wstawić nowy element.
- 349: `_handleExport(controller, format)` — eksportuje tablicę do PDF/PNG,
  obsługuje anulowanie dialogu zapisu.
- 407: `_handleDelete(controller)`.
- 464: `build` — Scaffold(AppBar tytuł boarda+bookmark) + Column(EditorToolbar,
  TextEditToolbar opcjonalnie, Stack(Transform pan/zoom
  z DrawingCanvas i PageOverlay, `_BoardZoomControls` pozycjonowane).
- 689: `enum _BoardContextAction { paste }`.
- 691: `_PasteFromClipboardIntent` / 695 Copy / 699 Cut / 703 Delete (te same
  intent klasy co w editor_screen ale lokalne).
- 707: `class _BoardZoomControls` — przyciski +/–/fit/reset zoom.

---

### `test/widget_test.dart` (20 linii)
Smoke test: `NotesApp` pumpuje `MaterialApp` + jeden `CircularProgressIndicator`
(bo `IsarService.open()` jeszcze biegnie).

## 4. Kluczowe konwencje, na które agent musi uważać

- **Schemat Isar**: każda zmiana w `notebook_entity.dart` wymaga regeneracji
  `*.g.dart` (`dart run build_runner build --delete-conflicting-outputs`)
  i podbicia `kManualSchemaRevision` w
  [isar_service.dart:9](lib/data/isar/isar_service.dart#L9). Brak podbicia →
  aplikacja zrobi auto-wipe i pokaże banner reset.
- **`_toolFromIndex`/`_toolToIndex`** (repo, [linie 526 i 534](lib/features/notebook/data/notebook_repository.dart#L526))
  są obecnie **symetryczne** (`tool.index` ↔ `DrawingTool.values[index]`).
  Wcześniejsza wersja była dziurawa (gubiła square/circle/triangle/ellipse/
  text/image/edit przy roundtripie) — schema bumpnięty z 1 do 2, żeby wymusić
  auto-wipe. Zmieniasz kolejność `DrawingTool.values`? Albo dodajesz/wycinasz
  wartość pośrodku? Bump `kManualSchemaRevision` ponownie.
- **Save flow**: każda mutacja w `EditorController` woła `_save()` → repo →
  `onChanged` → `LocalBackupService.snapshot` (3 rotujące się pliki w
  `local_backup/`). Zachowaj ten łańcuch.
- **OCR** działa wyłącznie na Android/iOS
  ([editor_controller.dart:1539](lib/features/editor/state/editor_controller.dart#L1539)).
  Na desktopie kod zwraca komunikat, nie wyrzuca wyjątku.
- **PDF na Linuxie** używa `pdftoppm` (poppler-utils), reszta — `pdfx`.
- **DrawingCanvas vs DocumentDrawingCanvas**: NIE konsoliduj bez planu —
  różnią się układem współrzędnych (board: world = page, notebook: world = document).
- **Undo/redo** trzyma listy `EditorAction`. Każda nowa mutacja, która powinna
  być cofalna, MUSI dodać `EditorAction` w
  [editor_actions.dart](lib/features/editor/state/editor_actions.dart) i wołać
  `_applyAction` zamiast bezpośrednio modyfikować strony.
- **Aktywny element**: `activeTextBlockId` i `activeImageBlockId` są wzajemnie
  wykluczające się (setter jednego czyści drugi). Skróty klawiszowe (Ctrl+C/V/X/Del)
  są wyłączone gdy aktywny jest TextEditor
  ([editor_screen.dart:1037](lib/features/editor/presentation/editor_screen.dart#L1037)).
- **Migracja `path → bytes`** w `saveNotebook`
  ([notebook_repository.dart:131](lib/features/notebook/data/notebook_repository.dart#L131))
  jest jednokierunkowa — gdy istnieje plik a brak bytes, ładuje bytes.
  Pozwala to przeżyć kasowanie cache.

## 5. Skrypty / przydatne komendy

```bash
flutter pub get
flutter run                                # uruchomienie aplikacji
dart format lib test                       # formatowanie
dart analyze                               # analiza statyczna
dart run build_runner build --delete-conflicting-outputs   # regen Isar
flutter test                               # smoke test
```

Zależności systemowe (Linux): `zenity` (file picker), `poppler-utils` (PDF).
