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
│   ├── core/                  ← motyw, metryki, platform channels, widgety
│   ├── data/                  ← Isar, backup, sync
│   └── features/
│       ├── library/           ← lista notebooków, foldery, search, sync
│       ├── notebook/          ← modele domeny + repository + ekran "pusty"
│       ├── editor/            ← edytor stronicowy (notebook)
│       └── board/             ← edytor canvas (board, jedna „strona")
├── test/widget_test.dart      ← smoke test: NotesApp pumpuje MaterialApp
├── linux/runner/              ← GTK runner + natywny kanał przycisku rysika
├── pubspec.yaml               ← zależności (Isar, Quill, mlkit, pdfx…)
└── AI_INSTRUCTIONS.md         ← skrót Effective Dart Style
```

## 3. Mapa plików (linijka po linijce)

Format pozycji: `LL: nazwa — krótki opis`. `LL` to numer linii startowej.

---

### `lib/main.dart` (90 linii)
Entry point.
- 10: `_wrappedKeyDataHandler` — oryginalny handler Fluttera opakowany przez
  filtr niepoprawnych pakietów key data.
- 11: `_wrappedPlatformErrorHandler` — poprzedni globalny handler błędów
  platformy, zachowany dla błędów niezwiązanych z key data.
- 15: `_invalidKeyDataFilter` — konsumuje pakiety key data z
  `physical/logical == 0`, żeby nie dochodziły do asercji Fluttera na Linuksie.
- 22: `void main()` — `WidgetsFlutterBinding.ensureInitialized()`, inicjalizuje
  kanał stanu przycisku rysika, instaluje filtr key data, odnawia go po
  `syncKeyboardState()` i przez krótki watchdog startowy, potem `runApp(NotesApp())`.
- 39: `_installInvalidKeyDataFilter()` — idempotentnie instaluje filtr i nie
  owija ponownie własnego handlera.
- 49: `_installInvalidKeyDataErrorFilter()` — instaluje wąski fallback dla
  asercji `HardwareKeyboard`, jeśli Flutter zdąży nadpisać handler.
- 59: `_invalidKeyDataErrorFilter(...)` — wycisza tylko asercję niepoprawnych
  key data, resztę przekazuje poprzedniemu handlerowi błędów.
- 67: `_isInvalidKeyDataAssertion(...)` — rozpoznaje dokładną asercję
  `data.physical != 0 && data.logical != 0` ze stosu `KeyEventManager`.
- 75: `_startKeyDataFilterWatchdog()` — przez ok. godzinę po starcie odnawia
  filtr co 500 ms, bo Flutter potrafi nadpisać `onKeyData` po inicjalizacji
  tekstu na Linuksie.

### `lib/app/notes_app.dart` (12 linii)
- 5: `class NotesApp extends StatelessWidget` — owija aplikację w `AppScope`.

### `lib/app/app_scope.dart` (152 linie) — DI + bootstrap
- 14: `class AppScope` — root scope aplikacji, tworzy `_AppScopeState`.
- 21: `_AppScopeState` — trzyma pojedynczy `_openFuture`, repozytorium,
  backup service, sync service i scheduler backupu.
- 35–43: spinner podczas otwierania Isara.
- 47–63: tworzy/cache'uje `NotebookRepository`, `LocalBackupService`,
  `CloudSyncService` i `_BackupScheduler`; `repository.onChanged` tylko
  planuje backup, nie robi snapshotu natychmiast.
- 65–86: `MultiProvider` z `NotebookRepository`, `LocalBackupService`,
  `LibraryController` (`wasReset`/`freshFile`/`resetReason` z Isara) →
  `MaterialApp(home: LibraryScreen)`.
- 90: `_BackupScheduler` — osobny idle debounce backupu (`8s`), blokada przed
  nakładaniem snapshotów oraz flush przy lifecycle
  `inactive/paused/detached`.

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

### `linux/runner/my_application.cc` (148 linii)
GTK runner dla desktopowego Linuksa.
- 10: `struct _MyApplication` — trzyma argumenty Dart entrypoint.
- 18: `first_frame_cb(...)` — pokazuje okno po pierwszej wyrenderowanej klatce.
- 23: `my_application_activate(...)` — tworzy okno GTK, `FlView`,
  rejestruje pluginy i focusuje widok Fluttera.
- 112: `my_application_shutdown(...)` — cleanup pluginów.
- 121: `my_application_dispose(...)` — zwalnia argumenty Dart entrypoint.

---

### `lib/data/isar/entities/notebook_entity.dart` (84 linii)
Encje Isara (każda zmiana wymaga regeneracji `*.g.dart` i podbicia
`kManualSchemaRevision` w `isar_service.dart`).
- 5: `@collection NotebookEntity` — `id, uid, title, kindIndex, folder,
  createdAt, updatedAt, pages`.
- 18: `@embedded NotePageEntity` — `uid, index, title, isBookmarked,
  legacy indexTabColorValue/indexTabPosition, indexTabs, textBlocks,
  imageBlocks, inkStrokes`.
- 32: `@embedded IndexTabEntity` — `uid, colorValue, position`.
- 39: `@embedded TextBlockEntity` — `text, deltaJson, fontSize, colorValue,
  width, rotation, dx, dy`.
- 52: `@embedded ImageBlockEntity` — `path, ocrText, bytes (List<int>?),
  imageExt, imageMime, width, height, rotation, dx, dy, crop{Left,Top,Right,Bottom}`.
- 71: `@embedded InkStrokeEntity` — `colorValue, width, toolIndex, points`.
- 80: `@embedded InkPointEntity` — `dx, dy, pressure`.

### `lib/data/isar/entities/notebook_entity.g.dart` (6061 linii)
Wygenerowane przez `isar_generator` — **NIE edytuj ręcznie**. Po zmianach w
`notebook_entity.dart` uruchom `dart run build_runner build --delete-conflicting-outputs`.

### `lib/data/isar/isar_service.dart` (142 linii)
- 9: `const int kManualSchemaRevision = 5` — **podbij po zmianie encji**.
  Aktualna rewizja `5` obejmuje listę wielu zakładek indeksujących na stronie.
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

### `lib/data/backup/local_backup_service.dart` (179 linii)
Przyrostowy lokalny backup JSON w `local_backup/`: `manifest.json` +
`notebooks/<uid>.json`; stary `notebooks_latest.json` nadal jest czytany jako
fallback restore.
- 10: `class LocalBackupService(this.repository)`.
- 20: `_backupDir()` — tworzy katalog jeśli brak.
- 29: `_file(name)`.
- 34: `_notebooksDir()` / 42: `_manifestFile()` / 47: `_notebookFile(uid)`.
- 52: `snapshot(items)` — zapisuje tylko zmienione pliki notebooków
  i usuwa pliki notebooków spoza manifestu.
- 95: `hasLatest()` — rozpoznaje nowy manifest albo legacy `notebooks_latest.json`.
- 104: `readLatest()` — preferuje backup przyrostowy, fallback do legacy.
- 112: `_readIncrementalLatest()` / 148: `_readLegacyLatest()`.
- 166: `restoreFromLatest()` — zapisuje wszystkie notebooki do Isara, zwraca count.

### `lib/data/export/notebook_export_service.dart` (578 linii)
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
- 185: `_renderNotebook(...)`.
- 215: `_renderPage(...)` — `dart:ui` canvas, tło papieru, obrazy, tekst, strokes.
- 241: `_paintImages(...)`.
- 272: `_paintTextBlocks(...)` / 286: `_textSpans(block)` — prosty render delty Quill.
- 345: `_paintStrokes(...)` / 381: `_buildInkPath(...)` — render stroke'ów
  z tym samym adaptacyjnym wygładzaniem pen/highlighter co canvas.
- 456: `_pageContentBounds(page)` — obszar eksportu boarda.

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

### `lib/features/notebook/domain/note_page.dart` (71 linii)
- 7: `class NotePage { id, title, textBlocks, imageBlocks, inkStrokes,
  isBookmarked, indexTabs }` + `copyWith`.
- 46: `withoutIndexTab(tabId)` — kopia strony bez konkretnej zakładki indeksującej.
- 53: `class IndexTab { id, color, position }` + `copyWith`.

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

### `lib/features/notebook/data/notebook_repository.dart` (652 linii)
Mostek domena ↔ Isar ↔ JSON.
- 18: `class NotebookRepository(this.isar, {this.onChanged})` — callback po każdym zapisie.
- 26: `lastFetchSkippedCorruptRows` — flaga dla backupu po fallbacku.
- 28: `fetchNotebooks()` — sortowane po `updatedAtDesc`, z fallbackiem.
- 42: `_fetchNotebooksDefensively()` — id-by-id, loguje skipy i usuwa
  nieodczytywalne rekordy.
- 70: `_deleteCorruptRows(ids)` — kasuje uszkodzone rekordy po Isar id.
- 79: `createNotebook({title, folder})` — `NotebookKind.notebook`, 1 strona „Page 1".
- 104: `createBoard({title, folder})` — `NotebookKind.board`, jedna strona „Canvas".
- 131: `getNotebook(uid)`.
- 147: `saveNotebook(notebook)` — migruje
  `ImageBlock.path → bytes` jeśli bytes brak a plik istnieje, potem
  `writeTxn(put)`, woła `onChanged`.
- 205: `deleteNotebook(uid)`.
- 219: `encodeNotebooks(items)` / 223: `decodeNotebooks(items)` — JSON.
- 230–314: mapowanie entity↔domain (`_fromEntity`, `_pageFromEntity`,
  `_toEntity`, `_pageToEntity`).
- 315–410: konwersje per-blok (`_textFrom/ToEntity`, `_imageFrom/ToEntity`,
  `_strokeFrom/ToEntity`).
- 411–616: JSON serializery (`_notebookTo/FromJson`, `_pageTo/FromJson`,
  `_textTo/FromJson`, `_imageTo/FromJson`, `_strokeTo/FromJson`).
- 286: `_indexTabsFromEntity(...)` — lista zakładek + migracja starego pojedynczego pola.
- 473: `_indexTabToJson` / 481: `_indexTabsFromJson` — JSON wielu zakładek + migracja starego backupu.
- 618: `_toolFromIndex(int)` — symetryczne, prosty mapping przez `DrawingTool.values`.
- 626: `_toolToIndex(tool)` — `tool.index`. **Symetria wymagana** —
  zmieniasz jedną, zmieniaj drugą + bump `kManualSchemaRevision`.
- 628: `_bytesFromEntity(List<int>?)`.
- 635: `_bytesToBase64` / 642: `_bytesFromBase64`.

---

### `lib/features/library/presentation/library_controller.dart` (449 linii)
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
- 142: `renameFolder(oldName, newName)` — zapisuje nową nazwę w folderach i
  notebookach przypisanych do folderu.
- 183: `deleteFolder(name)` — usuwa folder i wszystkie notebooki w nim.
- 215: `createNotebook()` / 227: `createBoard()` — używają wybranego folderu
  albo fallbacku `Notes`, zaznaczają i zwracają utworzony element.
- 239: `deleteItem(uid)`.
- 253: `renameItem(uid, title)` — zmienia tytuł notebooka/tablicy i zapisuje repo.
- 279: `selectItem(uid)` — async load z repo, ustawia `_activeNotebook`.
- 291: `selectFolder(folder)`.
- 300: `setSearchQuery(value)`.
- 305: `exportBackup()` — pisze `notatek_backup_<ts>.json` w docs dir.
- 315: `importBackup(path)` — dekoduje + `saveNotebook` per item + reload.
- 329: `selectedItem()` — wybiera active pasujący do id albo item po id.
- 339: `_itemById(uid)`.
- 349: `_firstItemInFolder(folder)`.
- 357: `_selectedItemIsInFolder(folder)`.
- 365: `_targetFolderForNewItem()`.
- 376: `_loadCloudPath`.
- 381: `_loadFolders` / 405: `_saveFolders` (`library_folders.json`).
- 415: `_foldersFile`.
- 420: `_compareFolderNames(a, b)`.
- 428: `_matches(notebook, query)` — title/page title/textBlock/ocrText.

### `lib/features/library/presentation/library_screen.dart` (950 linii)
Trójkolumnowy layout (folders | items | workspace) z resizable pane.
- 16: `class LibraryScreen extends StatefulWidget`.
- 23: `_LibraryScreenState` — stałe layoutu (24–29: `_wideBreakpoint=1100`,
  pane min/max widths, `_resizeHandleWidth=12`).
- 31–33: `_showLeftNavigation`, `_folderPaneWidth=220`, `_itemsPaneWidth=320`.
- 36: `initState` — post-frame `controller.initialize()`.
- 44: `build` — Scaffold + banner resetu + LayoutBuilder.
- 66–181: wide layout (≥1100): folder pane, resize handle, items pane,
  resize handle, workspace + `_LeftZoneToggleTab`.
- 184–209: wąski layout: `_FolderChipBar` na górze + lista items na pełnej szerokości.
- 219: `_toggleLeftNavigation`.
- 226: `_createItem(kind)` — tworzy notebook/tablicę i zwraca nowy element.
- 234: `_createAndSelectItem(kind)` — desktopowe tworzenie z natychmiastowym
  dialogiem nazwy, bez push trasy.
- 243: `_createAndOpenItem(kind)` — tworzy element, pokazuje dialog nazwy
  i otwiera go na wąskim widoku.
- 258: `_promptNewFolder(controller)` — dialog tworzenia folderu.
- 289: `_promptRenameFolder(controller, folder)` — dialog zmiany nazwy folderu.
- 324: `_promptRenameItem(controller, item)` — dialog zmiany nazwy notebooka/tablicy.
- 363: `_confirmDeleteFolder(controller, folder)` — potwierdzenie usunięcia
  folderu razem z zawartością.
- 396: `enum _FolderAction { rename, delete }`.
- 398: `class _FolderListPane` — lista folderów (iconOnly gdy pane < 165px),
  separatory jak w liście notatek, 410–486 iconOnly, 488–527 normalny z menu
  akcji folderu.
- 541: `class _FolderChipBar` — chipy folderów (mobile) z menu akcji folderu.
- 610: `class _LibraryItemsPane` — lista notebooków (empty states 632, 672;
  709–767 iconOnly, 768–835 normalny widok z `LibraryItemCard`).
- 838: `class _LibraryWorkspace` — wybiera `BoardScreen` lub `NotebookScreen`
  na podstawie `item.kind`, owija w `ChangeNotifierProvider<EditorController>`.
- 866: `class _LibraryRoute` — wąski layout (push'owane), `FutureBuilder` do `getNotebook`.
- 892: `enum _CreateAction { notebook, board }`.
- 894: `class _PaneResizeHandle` — pasek do przeciągania szerokości pane.
- 916: `class _LeftZoneToggleTab` — strzałka chevron do collapsowania nawigacji.

### `lib/features/library/presentation/widgets/library_item_card.dart` (132 linie)
- 6: `enum _ItemAction { rename, delete }` — akcje menu kontekstowego elementu biblioteki.
- 8: `class LibraryItemCard extends StatelessWidget` — `ListTile` z ikoną typu
  (`board`/`notebook`), tytułem, podtytułem („Board" lub „N pages"),
  menu `PopupMenuButton` ze zmianą nazwy i usuwaniem; w `iconOnly` pokazuje
  samą ikonę bez tekstów, z tą samą wysokością kratki i wielkością ikony.
- 110: `class _ItemKindIcon` — oprawiona ikonka notatki lub tablicy dla listy
  elementów biblioteki.

---

### `lib/features/notebook/presentation/notebook_screen.dart` (24 linie)
- 8: `class NotebookScreen` — empty state albo bezpośrednio `EditorScreen()`.

### `lib/features/editor/state/editor_actions.dart` (414 linii)
Wszystkie operacje undoowalne. Każda akcja: `apply(page)` + `revert(page)`.
- 8: `abstract class EditorAction`.
- 13: `class AddTextAction(block)`.
- 31: `class AddImageAction(block)`.
- 51: `class AddInkStrokeAction(stroke)`.
- 71: `class RemoveInkStrokesAction({before, after})` — usuwa zbiór strokeów.
- 88: `class UpdateIndexTabAction({before, after})` — ustawia/cofa zakładkę indeksującą.
- 101: `class UpdateTextAction({before, after})`.
- 126: `class DeleteTextAction(block)`.
- 146: `class MoveTextAction({id, from, to})` — `OffsetPosition`.
- 176: `class MoveImageAction({id, from, to})`.
- 206: `class UpdateImageOcrAction({id, ocrText, before})` — `before` to cała
  lista, żeby rollback miał wartość poprzednią.
- 232: `class UpdateImageAction({before, after})` — pozycja/rozmiar/crop/rotation.
- 257: `class DeleteImageAction(block)`.
- 277: `class MoveSelectionAction` - transluje lasso.
- 332: `class DeleteSelectionAction` - usuwa grupę z lasso.
- 379: `class PasteSelectionAction` - duplikuje/wkleja lasso.
- 403: `class OffsetPosition(dx, dy)` — wartościowy odpowiednik `Offset`
  (`fromOffset`, `toOffset`).

### `lib/features/editor/state/editor_controller.dart` (2213 linii)
Mózg edytora. **Najczęściej modyfikowany plik aplikacji.** Trzyma stan stron,
narzędzia, kolory, undo/redo, zoom/pan, schowek elementów.
- 30: `class LassoSelection` - trzyma metadane zaznaczenia lasso
  (bounds dokumentowe, ID elementów, delty).
- 62: `class EditorController extends ChangeNotifier`.
- 63–65: `minViewScale=0.35`, `maxViewScale=4.0`,
  `_inkSaveDebounceDelay=2s`.
- 67: konstruktor — `pages = notebook.pages`, ładuje prefs.
- 73–114: pola — `repository, notebook, _uuid, _imagePicker, pages,
  currentPageIndex, tool, lastEraserTool, lastShapeTool, inkColor,
  inkStrokeWidth, quickColors (3 sloty), recentColors (12),
  _undo/_redoActions, _prefsSaveDebounce, `_notebookSaveDebounce`,
  lastTextFontFamily/Size/Color, activeTextBlockId, activeTextController,
  `_activeTextEditPageIndex/_activeTextEditBefore`, activeImageBlockId,
  lassoSelection,
  `lassoDragDelta` (`ValueNotifier<Offset>` do płynnego dragowania lassa bez
  pełnego `notifyListeners()` na każdy ruch), _elementClipboard,
  _suppressBackgroundTap, viewScale, viewPan,
  _pageWidth/_pageHeight/_pageGap`.
- 116–119: gettery `currentPage`, `canUndo`, `canRedo`, `contentBounds`,
  `layoutPageSize`.
- 123: `dispose()` — domyka aktywną edycję tekstu i timery zapisu.

#### Layout/wiewport
- 133: `updatePageLayout({pageWidth, pageHeight, pageGap})`.
- 148: `setViewTransform({pan?, scale?})`.
- 162: `panBy(delta)`.
- 169: `zoomBy(factor, focalPoint)`.
- 182: `viewportToWorld(offset)` / 187: `worldToViewport(offset)`.

#### Strony
- 191: `pageAt(index)`.
- 195: `_pageExtent` getter (height + gap).
- 197: `_pageOriginForIndex(index)`.
- 204: `_pageIndexForPosition(offset)` — który page index zawiera punkt Y.

#### Lookupy / aktywne elementy
- 215: `findTextBlockById(id)`.
- 226: `findImageBlockById(id)`.
- 237: `_pageIndexContainingTextBlock(id)`.
- 246: `_pageIndexContainingImageBlock(id)`.
- 255: `_ensurePageSelected(pageIndex)`.

#### Per-page entry points (board/notebook → mapują na current page)
Tylko te `*OnPage`, które są realnie wołane z `page_overlay`/`drawing_canvas`.
- 265: `handleTapOnPage(pageIndex, point)`.
- 270: `updateTextBlockContentOnPage(...)` / 280 position /
  289 delete / 294 commitMove.
- 304: `runOcrForImageOnPage`.
- 309: `updateImageBlockPositionOnPage` / 318 cały blok /
  326 OCR text / 331 delete.
- 336: `addInkStrokeOnPage(pageIndex, points, {widthOverride, toolOverride})`.
- 350: `eraseInkStrokesByIdOnPage(pageIndex, ids)`.
- 355: `commitImageMoveOnPage`.
- 365: `finalizeImageMoveOnPage` — **decyduje czy stroke przechodzi
  na inną stronę** (`_moveImageBlockToPage`) czy zostaje (`commitImageMoveOnPage`).
- 382: `commitImageResizeOnPage`.
- 444: `selectWithLasso(points, pageIndex)` — Ray-Casting; stroke'y liczone w
  koordynatach strony, tekst/obrazy w koordynatach dokumentu.
- 544: `updateLassoMove(delta)` — zapisuje bieżące przesunięcie tylko w
  `lassoDragDelta`, bez przebudowy całego controllera.
- 549: `commitLassoMove()` — zatwierdza `lassoDragDelta` jako
  `MoveSelectionAction`, przesuwa bounds i dopiero wtedy robi notify/save.

#### Narzędzia, kolory, prefs
- 391: `setTool(newTool)` — aktualizuje `lastEraserTool` i `lastShapeTool`.
- 406: `setActiveTextBlock(id, controller)` / 419 clear; domyka poprzednią
  sesję tekstową jako jedną akcję undo.
- 425: `setActiveImageBlock(id)` / 439 clear.
- 669: `markTextTap()` / 673: `consumeBackgroundTapSuppression()`.
- 679: `setColor(color)`.
- 686: `setLastTextFontFamily` / 691 size / 696 color.
- 702: `setStrokeWidth(value)`.
- 707: `setQuickColor(index, color)`.
- 716: `_addRecentColor(color)` (cap 12, dedup po ARGB).
- 724: `_loadEditorPrefs()` (`editor_prefs.json`).
- 785: `_schedulePrefsSave()` (debounce 250 ms).
- 792: `_saveEditorPrefs()`.
- 809: `_prefsFile()`.
- 814: `_colorFromHex(value)`.

#### Gesty / undo / redo / strony
- 829: `handleTap(point)` — text vs image vs nic.
- 840: `undo()` / 852: `redo()` — domykają aktywną edycję tekstu przed operacją.
- 867: `addPage()` — nowy `NotePage`, czyści aktywne.
- 880: `deleteLastPage()` — usuwa ostatnią stronę, nie schodzi poniżej jednej strony.
- 894: `_createPage(index)`.
- 906: `_ensurePageCount(working, count)`.
- 912: `setCurrentPage(index)`.
- 927: `toggleBookmark()`.
- 933: `addIndexTab({color, position})` — undoowalnie dopisuje nową zakładkę na bieżącej stronie.
- 929: `updateIndexTab({id, color, position})` — undoowalnie edytuje konkretną zakładkę.
- 952: `clearIndexTab(id)` — undoowalnie usuwa konkretną zakładkę indeksującą.
- 966: `beginIndexTabDrag({pageIndex, id})` — start przeciągania zakładki, zapamiętuje stronę do jednej akcji undo.
- 986: `updateIndexTabDrag({id, position})` — live przesunięcie zakładki góra/dół bez zapisu na każdy ruch.
- 1011: `commitIndexTabDrag()` — kończy przeciąganie i zapisuje jedną akcję undo.

#### Operacje tekstowe (current page)
- 1053: `addTextBlock(position)` — Quill Delta z lastText* defaultami.
- 1079: `addTextBlockFromText(position, text)` — z clipboarda/pliku.
- 1108: `updateTextBlockContent(before, {plainText, deltaJson})` — szybka ścieżka
  wpisywania: aktualizuje `pages` bez
  `notifyListeners()` i debouncuje zapis.
- 1123: `updateTextBlockPosition`.
- 1130: `updateTextBlockWidth`.
- 1137: `deleteTextBlock`.
- 1147: `commitTextMove(id, start, end)`.
- 1161: `commitTextResize(before, after)`.

#### Obrazy / clipboard / wklejanie
- 1169: `addImageBlock(position)` — image picker (galeria).
- 1178: `insertFromFilePicker(position)` — png/jpg/jpeg/pdf/txt; Linux hint o zenity.
- 1212: `insertFromClipboard(position)` — image lub tekst z `super_clipboard`,
  fallback `Clipboard.getData(text/plain)`.
- 1239: `pasteElementOrClipboard(position)` — wkleja zapamiętany
  `_elementClipboard` (Text/Image/Lasso) albo wpada do `insertFromClipboard`.
- 1319: `copyActiveElementToClipboard()` — lasso→wewnętrzny clipboard,
  text→clipboard text+`_elementClipboard`, image→PNG/JPEG.
- 1371: `cutActiveElementToClipboard()` — copy + `deleteActiveElement`.
- 1380: `deleteActiveElement()` — kasuje aktywny tekst lub obraz na właściwej stronie.
- 1405: `copyActiveImageToClipboard()` — wykrywa jpg/jpeg → `Formats.jpeg`, inaczej `png`.
- 1434: `_tryInsertImageFromClipboard(reader, position)` — PNG first, potem JPEG.
- 1451: `_readTextFromClipboard(reader)`.
- 1459: `_readClipboardImageBytes(reader, format)`.
- 1483: `_readStreamBytes(stream)`.
- 1491: `_initialImageBlockSize(sourceSize)` — clampuje do strony (notebook
  używa `_pageWidth/_pageHeight`, board ma stałe 360x520).
- 1511: `_addImageBlockFromBytes(bytes, position, extension)`.
- 1537: `_insertFile(file, position)` — branchuje po rozszerzeniu (png/jpg/pdf/txt).
- 1555: `_addImageBlockFromFile(file, position, {runOcr=true})` — kopiuje plik,
  OCR jeżeli wspierane.
- 1600: `_activateInsertedImage(id)` — switch na tool `edit`, set active image.
- 1608: `_addPdfAsImages(pdfFile, position)` — używa `pdfx` (non-Linux),
  renderuje każdą stronę, zapisuje bytes PNG w `ImageBlock`.
- 1693: `_addPdfAsImagesWithPoppler(pdfFile, position)` — Linux fallback,
  uruchamia `pdftoppm` (`poppler-utils`), zapisuje bytes PNG w `ImageBlock`.
- 1781: `runOcrForImage(block)`.
- 1794: `updateImageBlockPosition` / 1801 size / 1816 OCR text.
- 1826: `restoreImageCache(pageIndex, blockId)` — odtwarza plik z `bytes`, gdy ścieżka znikła.
- 1848: `deleteImageBlock(id)`.

#### Strokes / commits
- 1855: `addInkStroke(points, {widthOverride, toolOverride})` — highlighter
  ma `inkStrokeWidth * 8.0`; zapis do repo jest debounced, żeby szybkie
  odrywanie rysika nie blokowało kolejnego stroke'a na Isar/backup.
- 1878: `eraseInkStrokesById(ids)` — usuwa stroke'i undoowalnie i debouncuje
  zapis.
- 1891: `commitImageMove(id, start, end)`.
- 1905: `commitImageResize(before, after)` — porównuje pos/size/crop/rotation.
- 1919: `_moveImageBlockToPage(fromIdx, toIdx, id, position)`.

#### Helpery
- 1961: `_persistImage(picked)` (XFile→images_cache).
- 1973: `_persistImageFile(file)`.
- 1985: `_persistImageBytes(bytes, filename)`.
- 1996: `_colorToHex(color)`.
- 2001: `_imageSize(file)` — `instantiateImageCodec`.
- 2009: `_runOcr(file)` — mlkit, Latin script.
- 2025: `_isOcrSupported()` — Android/iOS only.
- 2032: `_computeContentBounds()` — bbox stroke + text + image dla widoku.
- 2083: `_applyAction(action)` — domyka aktywną edycję tekstu, push undo,
  clear redo, apply, update page.
- 2091: `_applyActionWithoutNotify(action)` — wariant dla commitowania lassa;
  zmienia `pages` i undo stack bez pośredniego `notifyListeners()`.
- 2101: `_updatePage(page)`.
- 2109: `_replaceTextBlockOnCurrentPage(block, {notify})` — live update tekstu
  bez przebudowy drzewa podczas szybkiego pisania.
- 2123: `_beginTextEdit(blockId)` / 2138: `_commitActiveTextEdit()` /
  2162: `_discardActiveTextEdit()` — grupowanie wielu znaków w jedną akcję undo.
- 2167: `_scheduleSave()` — debouncuje zapis notebooka
  przez `_inkSaveDebounceDelay` po live-edit tekstu i krótkich seriach stroke'ów.
- 2175: `_save()` — wywołuje
  `repository.saveNotebook(notebook.copyWith(pages, updatedAt=now))`.
- 2183–2210: sealed `_ElementClipboardItem` + `_TextElementClipboardItem`
  + `_ImageElementClipboardItem` + `_LassoElementClipboardItem`.

---

### `lib/features/editor/presentation/editor_screen.dart` (2389 linii)
Layout edytora notebooka (stronicowy). Listener gestów, transformacja zoom/pan
strony, przesunięcie kolumny strony, mini-mapa, podgląd skali, podgląd ramki
strony.
- 29: `class EditorScreen extends StatefulWidget`.
- 36: `_EditorScreenState` — stałe (37–51: `_pageGap=26`, paddings,
  footer `Add page`, sensytywności pan/scroll, scale floors, granica kolumny
  podglądu, tolerancja zatrzymania na krawędzi). A4 ratio czytane z
  `AppMetrics.a4HeightRatio`.
- 52–73: pola stanu (ScrollController, GlobalKey canvas, `_pageExtent`,
  `_isViewportNavigating`, aktywny rysik, pending touch navigation, gesty
  multi-touch, `_pageScale=1`, `_pagePan`, `_pageMin/MaxScale`,
  `_pageColumnOffset`, granice przesunięcia kolumny).
- 74: `initState` — `_scrollController.addListener(_handleScroll)`.
- 80: `dispose`.
- 86: `_handleScroll()`.
- 93: `_onPagesScroll(notification, controller)` — synchronizuje bieżącą stronę
  po zakończeniu scrolla; scroll nie tworzy stron automatycznie.
- 108: `_syncCurrentPageToViewport(controller)`.
- 131: `_addPageBelow(controller)` — dodaje stronę przez kontroler bez
  automatycznego przewijania widoku.
- 138: `_syncPageTransformBounds({docWorldSize, fitToWidthScale, viewportSize})`.
- 175: `_syncPageColumnOffsetBounds({basePageLeft})` — clampuje poziome
  przesunięcie kolumny strony do obszaru poza kolumną podglądu.
- 196: `_applyPageColumnPan(deltaX)` — przesuwa kolumnę strony gestem dwoma
  palcami w osi X, z clampem poza kolumną podglądu i tolerancją zatrzymania
  na krawędziach.
- 222: `_snapToPageColumnEdge(offset)` / 232: `_snapPageColumnToEdge(edge)` —
  wygaszają ułamkowe drgania przy limicie przesunięcia.
- 241: `_isNavigationPointerKind(kind)` — touch/trackpad/mouse (NIE pen/stylus).
- 246: `_isStylusPointerKind(kind)`.
- 251: `_onPointerDown(event, docWorldSize, viewportSize)` — pending touch
  navigation przy narzędziach rysowania; gdy rysik jest aktywny, dotyk dłoni
  nie wchodzi w nawigację viewportu.
- 292: `_onPointerMove(...)` — multi-touch pinch/pan; gdy pierwszy dotyk
  przesunie się przed drugim palcem, awansuje go z pending do aktywnych pointerów,
  żeby gest dwoma palcami nadal wystartował bez przypadkowego stroke'a; poziomy
  ruch dwóch palców przesuwa kolumnę strony.
- 366: `_onPointerUpOrCancel(event)`.
- 391: `_startViewportNavigation(docWorldSize, viewportSize)`.
- 417: `_onPointerPanZoomStart(event, ...)` — trackpad scroll wheel.
- 442: `_onPointerPanZoomUpdate(...)`.
- 484: `_onPointerPanZoomEnd(event)`.
- 496: `_onPointerSignal(event, ...)` — `PointerScrollEvent` (myszka).
- 520: `_applyPageTransform({scale, pan, ...})` — aktualizuje `_pageScale/_pagePan`.
- 568: `_clampPagePan({pan, scale, docWorldSize, viewportSize})` — centruje
  dokument w osi, w której po oddaleniu mieści się w viewportcie.
- 604: `_stopViewportNavigation()`.
- 614: `_midpoint(a, b)` / 618: `_distanceBetween` / 622: `_documentHeight`.
- 629: `_visibleDocumentRect({docWorldSize, viewportSize})` — który fragment widać.
- 668: `_pageBoundaryVisibilityInDocument(...)` — liczy widoczne krawędzie strony;
  przy pełnej widoczności strony zwraca wszystkie krawędzie.
- 724: `_visiblePageRange(...)` — wylicza okno renderowanych stron
  jako strona viewportu + jedna powyżej i trzy poniżej, żeby długie notatniki
  nie budowały wszystkich stron naraz.
- 733: `_insertPositionForViewport({...})` — gdzie wstawić blok dla insert toolbara.
- 767: `_handleExport(controller, format)` — eksportuje aktualną notatkę do
  PDF/PNG przez `NotebookExportService`, obsługuje anulowanie dialogu zapisu.
- 825: `_handleDelete(controller)`.
- 829: `_showIndexTabEditor(controller, pageIndex, tabId)` — dialog edycji istniejącej zakładki po dwukliku.
- 978: `_indexTabChannelSlider(...)` — slider RGB w dialogu zakładki.
- 1066: `build(context)` — Scaffold(AppBar=tytuł notebooka+bookmark) + Column
  (EditorToolbar, TextEditToolbar gdy aktywny tekst, InsertToolbar gdy `_isInsertToolbarVisible`,
  LayoutBuilder z głównym canvas: SingleChildScrollView (bez drag-scrolla przy
  narzędziach ink) + poziome przesunięcie kolumny strony + Listener +
  Transform(`_pageScale/_pagePan`) + Stack[tylko widoczne strony
  (DecoratedBox+`_PageFramePainter`), `DocumentPageOverlay`(bg+inactive),
  `DocumentDrawingCanvas`, `DocumentPageOverlay`(active), `_IndexTabsOverlay`]
  + przyciski `Add page` / `Delete page`
  pozycjonowany w przestrzeni dokumentu tuż pod ostatnią stroną); pozycjonuje
  `_ZoomPercentBadge` + `_ProjectMiniMapOverlay`.
- 1494–1540: skróty klawiszowe (Ctrl/Cmd+V/C/X, Delete) → CallbackActions
  (paste/copy/cut/delete) — **wyłączone gdy aktywny TextEditor**.
- 1560: `class _PasteFromClipboardIntent`.
- 1564: `class _IndexTabEditResult` — wynik dialogu edycji zakładki (`save/remove`).
- 1591: `_CopyElementIntent`.
- 1595: `_CutElementIntent`.
- 1599: `_DeleteElementIntent`.
- 1603: `enum _CanvasContextAction { paste }`.
- 1605: `class _BoundaryVisibility` — które krawędzie strony są widoczne.
- 1638: `class _PageRenderRange` — półotwarty zakres stron renderowanych w
  głównym edytorze.
- 1645: `class _PageFramePainter extends CustomPainter` — rysuje pomarańczową
  ramkę aktywnej strony.
- 1720: `class _IndexTabsOverlay` — rysuje wiele kolorowych zakładek; dwuklik otwiera edycję, a długie przytrzymanie pozwala przesuwać zakładkę góra/dół.
- 1830: `class _ZoomPercentBadge` — chip „150%".
- 1860: `class _ProjectMiniMapOverlay extends StatefulWidget` (mini-mapa).
- 1881: `_ProjectMiniMapOverlayState` — synchronizacja widoku + cache miniatur obrazów/PDF.
- 1914: `_precacheMinimapImages()` — dekoduje asynchronicznie `ImageBlock.bytes/path` do `ui.Image`.
- 2011: `_syncMinimapToViewport()`.
- 2045: `_visiblePanelHeight(...)` / 2049: `_contentHeight(...)` — wysokość mini-mapy rośnie z liczbą stron do limitu panelu.
- 2162: `class _ProjectMiniMapPainter` — rysuje strony, content thumbnails,
  zdekodowane miniatury obrazów/PDF oraz paski zakładek, bez podświetlania krawędzi.
- 2362: `class _MiniMapImageCacheEntry` — cache key + zdekodowany obraz mini-mapy.
- 2369: `class _MiniMapViewportOverlayPainter` — rysuje wypełniony prostokąt widoku bez podświetlanych krawędzi.

### `lib/features/editor/presentation/widgets/drawing_canvas.dart` (2446 linii)
Dwie warianty canvasu rysowania. **Notebook używa `DocumentDrawingCanvas`,
board używa `DrawingCanvas`.** Logika prawie zduplikowana — to świadoma decyzja
(różne układy współrzędnych). Oba warianty opóźniają start stroke dla dotyku,
odrzucają duży kontakt dłoni i dają pierwszeństwo aktywnemu rysikowi/myszy.
- 13: `class DrawingCanvas extends StatefulWidget` — board, jedna strona/canvas.
- 33: `class DocumentDrawingCanvas extends StatefulWidget` — notebook,
  N stron pionowo, params `{worldOrigin, pages, pageSize, pageGap,
  allowMultiTouch, interactionEnabled, firstPageIndex, lastPageIndex}`; painter
  renderuje tylko ten zakres, hit-test nadal liczy po pełnym dokumencie.
- 59: `_buildInkPath(...)` / 96: `_shouldSmoothStroke(...)` — wspólne,
  adaptacyjne wygładzanie szybkich stroke'ów pen/highlighter; kształty, lasso
  i gumka zostają odcinkami.
- 116: `_shouldAcceptInkPoint(...)` —
  wspólny filtr punktów pen/highlighter: odrzuca nagłe, boczne skoki kontaktu
  oddalone od dotychczasowego kierunku kreski.
- 134: `_shouldRejectViewportEdgePoint(...)` / 152 `_isNearViewportEdge(...)` —
  ignoruje nienaturalne skoki do samej krawędzi okna programu.
- 163: `_isDiscontinuousInkJump(...)` — wykrywa boczny, daleki skok względem
  ostatniego stabilnego kierunku kreski.
- 192: `_toolForPointerEvent(...)` / 204 `_hasStylusButton(...)` — tymczasowo
  używają ostatniej gumki dla dowolnego przycisku rysika poza kontaktem
  końcówki lub dla `invertedStylus`.

#### `_DrawingCanvasState` (board) — 213–1118
- 248: `build` — `MouseRegion` ustawia natywny kursor `basic` dla
  pen/highlighter, `Listener` z `_onPointerDown/Move/Up/Cancel` +
  `ValueListenableBuilder(controller.lassoDragDelta)` + dwa `CustomPaint` w
  `RepaintBoundary`: zapisane stroke'i i szybki overlay aktywnej kreski.
- 336: `_onPointerDown(event, controller, viewportSize)` — wybiera aktywny pointer;
  dotyk startuje dopiero po progu ruchu, rysik/mysz od razu; przycisk rysika
  ustawia gumkę tylko dla aktywnego stroke'a.
- 426: `_onPointerMove` — dodaje punkty, ewentualnie eraser;
  aktywna kreska używa `_notifyInkChanged()` zamiast pełnego `setState()`.
- 520: `_onPointerUp` — commit stroke przez `controller.addInkStroke`.
- 621: `_onPointerCancel`.
- 635: `_resetCurrent()`.
- 668: `_notifyInkChanged()` — lekki repaint overlayu aktywnej kreski.
- 672: `_activeTool(controller)` — zwraca override z przycisku rysika albo
  aktualne narzędzie controllera.
- 676: `_toWorld(local)`.
- 680: `_shouldAddPoint(offset, tool)` — min odległość + filtr skoków kontaktu.
- 701: `_startSnapTimer(offset)` — po holdzie z czystym kształtem wywołuje `_snapToShape`.
- 711: `_eraseAt(offset, page, controller)`.
- 723: `_resolvedPage(controller)` / 727: `_resolvedPageIndex`.
- 731: `_strokeHitTest(stroke, point, radius)`.
- 750: `_distanceSquaredToSegment(p, a, b)`.
- 763: `_snapToShape()` — wykrywa line/rect/ellipse.
- 821: `_clearSnapHintSoon()`.
- 834: `_isRoughlyStraight(start, end, points)`.
- 858: `_isRoughlyRectangle(points)`.
- 883: `_isRoughlyEllipse(points)`.
- 952: `_findFarthestCorner(points, holdPoint)`.
- 976: `_isInkTool(tool)`.
- 980: `_isSnapTool(tool)` — pen/highlighter snapują, eraser/kształty nie.
- 984: `_usesCustomInkCursor(tool)` — pen/highlighter używają natywnego kursora `basic`.
- 988: `_effectiveStrokeWidth(tool, baseWidth)`.
- 1020: `_squareCorner(start, end)` — wymuszony kwadrat/koło.

#### `_DocumentDrawingCanvasState` (notebook) — 1120–2114
Te same metody co wyżej, ale operują w przestrzeni dokumentu (offset per page).
- 1158: `build` — też nasłuchuje `lassoDragDelta` przy repaint zaznaczonych stroke'ów.
- 1245: `_onPointerDown` / 1356 Move / 1473 Up / 1552 Cancel; lasso w dokumencie
  woła `selectWithLasso`, a przycisk rysika ustawia gumkę tylko dla aktywnego
  stroke'a.
- 1566: `_resetCurrent`.
- 1601: `_notifyInkChanged()` — lekki repaint overlayu aktywnej kreski.
- 1605: `_activeTool(controller)` — zwraca override z przycisku rysika albo
  aktualne narzędzie controllera.
- 1609: `_toWorld(local)`.
- 1634: `_pageOrigin(pageIndex)` / 1644: `_toPageLocal(world, pageIndex)` /
  1652: `_toDocument(pageLocal, pageIndex)` / 1660: `_isInsidePage(pageLocal)`.
- 1667: `_shouldAddPoint(offset, tool)` — min odległość + filtr skoków kontaktu.
- 1688: `_startSnapTimer`.
- 1698: `_eraseAt(localOffset, pageIndex)`.
- 1714: `_strokeHitTest` / 1733: `_distanceSquaredToSegment`.
- 1759: `_snapToShape`.
- 1817: `_clearSnapHintSoon`.
- 1830: `_isRoughlyStraight` / 1854: `_isRoughlyRectangle` / 1879: `_isRoughlyEllipse`.
- 1948: `_findFarthestCorner`.
- 1972: `_isInkTool` / 1976: `_isSnapTool` /
  1980: `_usesCustomInkCursor` / 1984: `_effectiveStrokeWidth`.
- 2016: `_squareCorner`.

#### Paintery
- 2083: `class _InkPainter extends CustomPainter` (board) — rysuje zapisane
  stroke'i i lasso selection; nie odświeża się przy każdym punkcie aktywnej kreski.
- 2174: `class _InkOverlayPainter extends CustomPainter` — lekka warstwa
  aktywnej kreski, snap hint i pozycji gumki, sterowana `ValueNotifier`.
- 2293: `class _DocumentInkPainter extends CustomPainter` (notebook) —
  analogiczny painter zapisanych stroke'ów dla dokumentu; filtruje zakres po
  `firstPageIndex/lastPageIndex`, a zaznaczenie po `selectedPageIndex`.

### `lib/features/editor/presentation/widgets/page_overlay.dart` (1610 linii)
Warstwa interaktywna nad rysunkiem (tekst + obrazy, drag/resize/crop).
- 20: `class PageOverlay extends StatelessWidget` (board, single-page);
  aktywna warstwa przepuszcza gesty lasso mimo `tool.isInk`; przekazuje
  `lassoDragDelta` tylko do elementów zaznaczonych lasso.
- 134: `class DocumentPageOverlay extends StatelessWidget` (notebook, N stron).
  Params `firstPageIndex/lastPageIndex` oraz
  `renderBackground/renderInactive/renderActive` (dwie warstwy w EditorScreen:
  bg+inactive PRZED canvasem, active PONAD).
- 193: `class _TextBlockWidget extends StatefulWidget`.
- 214: `_TextBlockWidgetState` — build/_initQuill/_isOnFrame/_dragHandle/
  _startMove/_updateMove/_endMove + helpery do delty Quill i skróty
  `Ctrl/Cmd+B/I/U`, `Ctrl/Cmd+Shift+7/8/C`; zaznaczenie lasso daje niebieskie
  podświetlenie i przesuwa
  pozycję przez lokalny `ValueListenableBuilder`, bez rebuildowania Quilla.
- 696: `class _ImageBlockWidget extends StatefulWidget`.
- 717: `_ImageBlockWidgetState` — Listener (drag+pinch dwoma palcami=resize),
  `ResizableFrame` z 8 uchwytami, prawy klik → menu kopiowania,
  `_imageChild` (`Image.memory(bytes)` lub `Image.file(path)` z
  `Transform.rotate` + crop `Rect.fromLTRB(cropLeft,cropTop,cropRight,cropBottom)`),
  `_normalizeBlockToImageBounds`, `_startResize`/`_updateResize`/`_endResize`;
  zaznaczenie lasso daje border/shadow i przesuwa tylko `Positioned` przez
  `ValueListenableBuilder`,
  `_cornerDelta`/`_clampSize`/`_cornerPosition`/`_cropOffsetX|Y`.
- 1471: `_LassoSelectionWidget` — niewidzialny hit target do dragowania całego
  zaznaczenia + akcje copy/delete; nie rysuje prostokąta, bounds są dokumentowe,
  widget odejmuje `worldOrigin` strony i śledzi `dragDeltaListenable`.
- 1616: `enum _CropAnchorAxis { left, right, top, bottom }`.
- 1618: `class _CropAnchor`.
- 1625: `enum _ImageContextAction { copy }`.
- 1627: top-level `Offset _globalDeltaToLocalDelta(...)`.

### `lib/features/editor/presentation/widgets/editor_toolbar.dart` (737 linii)
Główny pasek narzędzi nad canvasem (narzędzia, kolory, stroke width, undo/redo,
export).
- 9: `class EditorToolbar extends StatelessWidget`.
- 20: `build` — lewy przewijany segment z narzędziami i stały prawy przycisk
  eksportu.
- 116: `_exportButton()` — popup PDF/PNG wyrównany do prawej strony toolbara.
- 142: `_indexTabButton(context)` — ikonka zakładki; wybór koloru i wysokości w dialogu, dodaje kolejną zakładkę.
- 178: `_actionButton({...})` — generyczny IconButton.
- 190: `_toolButton({...})` — IconButton z aktywnym tłem gdy `tool == ...`.
- 208: `_eraserSelector()` — popup z `eraserBrush`/`eraserStroke`.
- 259: `_shapeSelector()` — popup z liniami/strzałkami/prostokątami/kołami.
- 294: `_selectorMenuButton({...})` — węższy przycisk strzałki dla selektorów.
- 349: `_shapeLabel(tool)`.
- 372: `_colorDot(...)` — kafelek koloru (quickColors + recentColors + picker).
- 408: `_pickColor(...)` — dialog wyboru koloru.
- 520: `_pickIndexTabPosition(...)` — dialog wyboru wysokości zakładki.
- 608: `_channelSlider({...})` — slider R/G/B w pickerze niestandardowym.
- 657: `_toByte(component)`.
- 662: `class _EraserIcon` — klasyczna ikonka gumki z opcjonalnymi błyskotkami.
- 695: `class _EraserIconPainter` — rysuje bazową sylwetkę gumki.

### `lib/features/editor/presentation/widgets/text_edit_toolbar.dart` (533 linie)
Pasek formatowania tekstu (pokazywany gdy aktywny TextBlock).
- 7: `class TextEditToolbar extends StatelessWidget` — bierze `quill.QuillController`
  + `EditorController` + `activeTextBlockId`.
- 38: `build` — bold/italic/underline/strike, font, size, color picker,
  bullet/ordered/checklist, clear formatting, delete.
- 155: `_styleButton({...})`.
- 170: `_listButton({...})`.
- 195: `_fontDropdown(currentFont)`.
- 221: `_sizeDropdown(currentSize)`.
- 247: `_colorPicker(context, currentValue)` — popup z slidersami.
- 283: `_toHex(color)`.
- 416: `_channelSlider({...})`.
- 440: `_toByte(component)`.
- 458: `_applyFormat(attribute, isActive)` — toggle bold/italic/etc.
- 479: `_clearInlineFormatting()` — usuwa inline style z zaznaczenia lub bloku.
- 514: `_storeLastTextStyle(...)` — zapamiętuje preferencje (Quill formatuje
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
- **`_toolFromIndex`/`_toolToIndex`** (repo, [linie 662 i 670](lib/features/notebook/data/notebook_repository.dart#L662))
  są obecnie **symetryczne** (`tool.index` ↔ `DrawingTool.values[index]`).
  Wcześniejsza wersja była dziurawa (gubiła square/circle/triangle/ellipse/
  text/image/edit przy roundtripie) — schema bumpnięty z 1 do 2, żeby wymusić
  auto-wipe. Zmieniasz kolejność `DrawingTool.values`? Albo dodajesz/wycinasz
  wartość pośrodku? Bump `kManualSchemaRevision` ponownie.
- **Save flow**: mutacje w `EditorController` debouncują `_save()` → repo →
  `onChanged` → `_BackupScheduler` → `LocalBackupService.snapshot` po idle.
  Backup jest przyrostowy per notebook (`manifest.json` + `notebooks/<uid>.json`).
- **OCR** działa wyłącznie na Android/iOS
  ([editor_controller.dart:1798](lib/features/editor/state/editor_controller.dart#L1798)).
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
  ([notebook_repository.dart:147](lib/features/notebook/data/notebook_repository.dart#L147))
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
