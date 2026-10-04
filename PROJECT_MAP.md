# PROJECT_MAP.md

Skrócony indeks projektu **Notatek / Stylus Notes** (`pubspec.yaml`:
`name: program`). Stan sprawdzony względem repozytorium 2026-10-02.

Mapa służy do wyboru pliku i zakresu linii przed czytaniem kodu. Zawiera
publiczne punkty wejścia, ważne prywatne granice i pułapki; nie kataloguje
każdego helpera. Numery oznaczają linie startowe.

Po zmianie kodu, która przesuwa te granice, zaktualizuj opis i numery w tej
mapie. Każdy nowy plik w `lib/` musi dostać tu własny wpis.

## 1. Architektura w skrócie

- Flutter / Dart `^3.11.1`, Material 3.
- Stan: Provider + ChangeNotifier; bez Bloc/Riverpod.
- Dane: Drift + SQLite; web używa SQLite WASM/IndexedDB.
- Tekst: `flutter_quill`; obrazy/PDF: `image_picker`, `file_picker`, `pdfx`.
- OCR: `google_mlkit_text_recognition`, tylko Android/iOS.
- Główny przepływ:
  `main` → `AppScope` → `LibraryController` → `EditorController` →
  `NotebookRepository` → Drift.
- Po zapisie repozytorium planuje przyrostowy lokalny backup. Backup czeka na
  bezczynność rysika i może przerwać worker po wznowieniu pisania.
- `features/editor` obsługuje wspólny model notebooka i boarda; różnią się
  ekranem oraz układem współrzędnych canvasu.

```text
lib/
├── main.dart                    start i globalna obsługa błędów
├── app/                         bootstrap, DI, backup scheduler
├── core/                        motyw, wejście, storage, diagnostyka, widgety
├── data/                        Drift, backup, eksport i synchronizacja
└── features/
    ├── library/                 foldery i lista dokumentów
    ├── notebook/                domena, repozytorium, ekran notebooka
    ├── editor/                  stan i UI edytora
    └── board/                   ekran nieskończonej tablicy
```

## 2. Start i aplikacja

### `lib/main.dart` (157 linii)

Start aplikacji, globalne logowanie błędów i linuksowy filtr błędnych zdarzeń
klawiatury.

- 33: `main`; 44: `_runApp`; 65–142: handlery błędów i watchdog key data.

### `lib/app/notes_app.dart` (12 linii)

Root widget przekazujący sterowanie do scope aplikacji.

- 5: `NotesApp`.

### `lib/app/app_scope.dart` (463 linii)

Otwiera bazę, buduje serwisy/Providery, nakłada zapisany kolor akcentu bez
przebudowywania `MaterialApp` i planuje backup po zapisie. Scheduler robi
kopię po 2 s bezczynności, wymusza próbę po maksymalnie 30 s ciągłych zmian
i ponawia przejściowy błąd backupu po 30 s.

- 21: `AppScope`;
  28: `_AppScopeState`;
  136:
  `_BackupStatusOverlay`;
  197:
  `_StartupErrorScreen`;
  273: `_BackupScheduler`.

## 3. Core

### Motyw

- `lib/core/theme/app_colors.dart` (54): paleta aplikacji
  i wybieralne kolory akcentu. 3:
  `AppAccentColor`; 39:
  `AppColors`.
- `lib/core/theme/app_metrics.dart` (3): współdzielone metryki A4.
  1: `AppMetrics`.
- `lib/core/theme/app_theme.dart` (23): konfiguracja jasnego
  Material 3 z wybieralnym akcentem i stałym kolorem powierzchni.
  5: `AppTheme`.

### Wejście i preferencje

- `lib/core/input/app_preferences_controller.dart` (129): globalny
  tryb urządzenia i kolor akcentu zapisane w `app_prefs.json`; akcent jest
  zapisywany nazwą enuma z obsługą starszego indeksu.
  8: `DeviceInputMode`;
  27:
  `AppPreferencesController`.
- `lib/core/input/ink_activity_tracker.dart` (35): globalnie śledzi kontakt
  rysika i okres wyciszenia używany przez zapis/backup.
  3: `InkActivityTracker`.
- `lib/core/input/soft_keyboard.dart` (22): prosi o klawiaturę ekranową w
  trybie tablet.
  7: `requestSoftKeyboardForFocus`.
- `lib/core/input/stylus_button_state.dart` (42): stan przycisku rysika i
  Apple Pencil double tap przez platform channel.
  6: `StylusButtonState`; 17: `initialize`; 25: `_handleMethodCall`.

### Storage i diagnostyka

- `lib/core/storage/text_storage.dart` (2): conditional export IO/web.
- `lib/core/storage/text_storage_io.dart` (82): małe pliki tekstowe w
  dokumentach aplikacji; odczyty czekają na trwający zapis, a zapisy są serializowane per plik i atomowe przez
  `.tmp`/`.previous` z odzyskiem po przerwanym zapisie.
  8: `readStoredText`; 17: `writeStoredText`.
- `lib/core/storage/text_storage_web.dart` (9): odpowiednik w `localStorage`.
  3: `readStoredText`; 7: `writeStoredText`.
- `lib/core/error/app_error_log.dart` (161): trwały bufor błędów z ostatnich
  3 dni.
  8: `AppErrorLog`; 106: `AppErrorLogEntry`.
- `lib/core/diagnostics/data_integrity_log.dart` (225): indeks podejrzanych
  zapisów i ścieżek do pełnych archiwów.
  8: `DataIntegrityLog`; 91: `DataIntegrityIncident`.
- `lib/core/diagnostics/optimization_log.dart` (347): przefiltrowane logi
  wolnych stroke'ów i backupów.
  9: `OptimizationLog`; 274: `OptimizationLogEntry`.
- `lib/core/diagnostics/frame_timing_tracker.dart` (132): agreguje Flutter
  `FrameTiming` dla logów ink/backup.
  3: `FrameTimingTracker`; 89: `FrameTimingSummary`.
- `lib/core/diagnostics/board_scene_perf_tracker.dart` (153): debugowy pomiar
  build/paint warstw boarda.
  3: `BoardScenePerfTracker`; 80: `BoardScenePerfSummary`.

### Widgety

- `lib/core/widgets/empty_state.dart` (30): wspólny pusty stan.
  3: `EmptyState`.
- `lib/core/widgets/resizable_frame.dart` (200): ramka z ośmioma uchwytami
  resize.
  5: `ResizeDirection`; 16: `ResizableFrame`;
  40: `_ResizableFrameState`.

## 4. Warstwa danych

### Drift

### `lib/data/drift/notes_database.dart` (345 linii)

Schemat SQLite i bezpieczne otwieranie bazy z trzema próbami. Start sprawdza
`PRAGMA quick_check` i `PRAGMA foreign_key_check`; po potwierdzonej korupcji lub naruszeniu integralności natywna baza jest
zachowywana jako plik `.corrupt_*`, a aplikacja
otwiera świeżą bazę, aby lokalny recovery mógł odtworzyć dane.

- 9: `NotebookRows`; 21: `PageRows`;
  34: `IndexTabRows`; 44: `TextBlockRows`;
  61: `ImageBlockRows`; 84: `InkStrokeRows`.
- 97: `DatabaseOpenResult`;
  111: `DatabaseOpenStage`;
  113: `DatabaseOpenException`;
  147: `NotesDatabase`.
- 154: `NotesDatabase.open`;
  232: kontrola integralności;
  256: `schemaVersion` (`1`);
  259: `migration`.

- `lib/data/drift/notes_database_connection.dart` (2): conditional export
  natywnego lub webowego połączenia.
- `lib/data/drift/notes_database_connection_io.dart` (196): SQLite w katalogu
  dokumentów przez `NativeDatabase.createInBackground`.
  7: `NotesDatabaseConnection`; 14: `openNotesDatabaseConnection`.
- `lib/data/drift/notes_database_connection_web.dart` (41): SQLite WASM z
  trwałym IndexedDB.
  6: `NotesDatabaseConnection`; 13: `openNotesDatabaseConnection`.
- `lib/data/drift/notes_database.g.dart` (6075): kod wygenerowany przez Drift;
  nie czytaj ani nie edytuj ręcznie.

### Backup, eksport i synchronizacja

### `lib/data/backup/local_backup_service.dart` (1426 linii)

Przyrostowy, serializowany backup z atomowym `manifest.json`, checksumami SHA-256 plików i całego manifestu (v4) i plikami
notebooków nazwanymi zawartością. Do pięciu poprzednich manifestów jest
trzymanych w `local_backup/history/`; wskazują na te same niezmienne pliki.
Przed i po serializacji natywny backup sprawdza, czy każdy obraz nadal ma
dostępne bajty; wyścig z usunięciem pliku nie może utrwalić kopii bez obrazu; brak obrazu nie zastępuje
ostatniej poprawnej kopii. Odczyt obsługuje manifesty v1/v2/v3/v4, odrzuca niekompletny lub niespójny
snapshot i próbuje kolejno starsze wersje. Manifest przechowuje też listę folderów biblioteki, w tym foldery puste; uszkodzenie samego pliku folderów nie blokuje backupu notebooków. Web przechowuje pełny snapshot w `localStorage`.

- 15: `LocalBackupService`; 90: `snapshot`; 280: `hasLatest`;
  430: `readLatest`; 545: `restoreFromLatest`.
- 695: anulowalny worker serializacji.
- 792: `BackupSnapshotInterrupted`; 796: `BackupValidationException`;
  807: `BackupDataException`; 818: `BackupSnapshotReport`;
  869: `NotebookBackupReport`.

### `lib/data/backup/backup_eraser_flattening.dart` (270 linii)

Stosuje gumki do wcześniejszych stroke'ów przed backupem i usuwa stroke'i
gumki z payloadu.

- 9: `flattenErasersForBackup`; 48: `_applyBrushEraser`;
  72: `_applyAreaEraser`; 95: `_splitStroke`; 148–265: geometria.

### `lib/data/export/notebook_export_service.dart` (679 linii)

Renderuje notebook/board do PNG lub PDF i zapisuje przez systemowy dialog.

- 24: `NotebookExportFormat`; 26: `NotebookExportFormatLabel`;
  37: `NotebookExportService`; 44: `exportController`;
  61: `exportNotebook`; 674: `_RenderedPage`.

### `lib/data/sync/cloud_sync_service.dart` (136 linii)

Synchronizacja last-write-wins przez `notatek_cloud.json` we wskazanym
folderze; remis timestampów wygrywa lokalny snapshot.

- 10: `CloudSyncResult`; 22: `CloudSyncService`; 30: `getCloudPath`;
  48: `setCloudPath`; 56: `sync`; 100: `mergeNotebooks`.

## 5. Domena notebooka i repozytorium

### Modele

- `lib/features/notebook/domain/notebook.dart` (42): dokument i jego strony.
  4: `Notebook`.
- `lib/features/notebook/domain/notebook_kind.dart` (12): notebook lub board
  oraz bezpieczny zapis indeksu.
  1: `NotebookKind`; 3: `NotebookKindValue`.
- `lib/features/notebook/domain/note_page.dart` (71): zawartość strony i wiele
  zakładek indeksujących.
  7: `NotePage`; 53: `IndexTab`.
- `lib/features/notebook/domain/drawing_tool.dart` (43): enum narzędzi i
  klasyfikacja eraser/shape/ink.
  1: `DrawingTool`; 21: `DrawingToolX`.
- `lib/features/notebook/domain/ink_stroke.dart` (49): stroke i punkt z
  naciskiem.
  5: `InkStroke`; 37: `InkPoint`.
- `lib/features/notebook/domain/ink_spatial_index.dart` (125): cache'owany
  indeks siatkowy kandydatów do hit-testu.
  14: `inkSpatialIndexFor`; 24: `InkSpatialIndex`.
- `lib/features/notebook/domain/text_block.dart` (45): blok Quill z pozycją,
  stylem, szerokością i rotacją.
  3: `TextBlock`.
- `lib/features/notebook/domain/image_block.dart` (71): obraz, OCR, crop,
  rotacja oraz legacy inline bytes.
  4: `ImageBlock`.

### `lib/features/notebook/data/notebook_repository.dart` (2298 linii)

Most domena ↔ Drift ↔ JSON, z kolejką zapisu per UID i ochroną przed
podejrzaną utratą danych. Recovery zapisuje cały batch atomowo i preferuje
bajty obrazów z backupu nad istniejącymi ścieżkami. Ręczny eksport używa
koperty z checksumą SHA-256 i zachowuje także puste foldery.

- 22: `DataIntegrityIncidentHandler`; 29: `NotebookRepository`.
- 60: `fetchNotebooks`; 110: `saveRecoveredCopy`;
  124: `restoreNotebooksAtomically`; 178: `archiveNotebookBeforeDelete`.
- 159: `createNotebook`; 185: `createBoard`; 211: `getNotebook`.
- 238: `saveNotebook`; 268: `saveNotebookPages`;
  476: `updateNotebookMetadata`; 740: `deleteNotebook`.
- 521: `_persistInlineImages`; 595: `_protectSuspiciousOverwrite`;
  646: `_recordDataIntegrityIncident`.
- 756–763: publiczne kodowanie/dekodowanie JSON.
- 1394: `_toolFromIndex`; 1402: `_toolToIndex` — muszą pozostać symetryczne.
- 1447: `DataIntegrityProtectionException`.

### `lib/features/notebook/presentation/notebook_screen.dart` (24 linie)

Wybiera pusty stan albo właściwy `EditorScreen`.

- 8: `NotebookScreen`.

## 6. Biblioteka

### `lib/features/library/presentation/library_controller.dart` (640 linie)

Stan folderów, listy dokumentów, wyszukiwania, syncu, importu i recovery. Zapis folderów uruchamia scheduler backupu także wtedy, gdy zmieniają się wyłącznie puste foldery. Sprzątanie osieroconych obrazów działa tylko przy normalnym starcie istniejącej, zdrowej bazy.

- 14: `LibraryController`; 78: `initialize`; 84: `loadItems`;
  140: `restoreCorruptDocumentsFromBackup`; 193: `syncNow`.
- 237–365: tworzenie/zmiana/usuwanie folderów i dokumentów.
- 393: `selectItem`; 405: `selectFolder`; 414: `setSearchQuery`.
- 419: `exportBackup`; 429: `importBackup`; 443: `selectedItem`.

### `lib/features/library/presentation/library_screen.dart` (1025 linii)

Układ foldery | dokumenty | workspace oraz dialogi CRUD/recovery. Szeroki
layout blokuje minimalną szerokość zamiast przełączać się na kompakt; poniżej
progu używa poziomego scrolla, co działa tak samo na wszystkich platformach.
Próg wynika z geometrii edytora: overview, strona 820 px i równe marginesy
56 px po lewej od strony oraz po prawej.

- 17: `LibraryScreen`; 24: `_LibraryScreenState`; 28: `_wideBreakpoint`;
  53: główny `build`.
- 285–408: tworzenie, zmiana nazw, usuwanie i dialog recovery.
- 479: `_NameInputDialog`; 552: `_FolderListPane`;
  695: `_LibraryItemsPane`.
- 927: `_LibraryWorkspace`; 957: `_PaneResizeHandle`;
  979: `_LeftZoneToggleTab`.

### `lib/features/library/presentation/widgets/library_item_card.dart` (132 linie)

Karta notebooka/boarda z menu zmiany nazwy i usuwania.

- 8: `LibraryItemCard`; 110: `_ItemKindIcon`.

## 7. Stan edytora

### `lib/features/editor/state/editor_actions.dart` (414 linii)

Akcje undo/redo; każda implementuje `apply(page)` i `revert(page)`.

- 8: `EditorAction`.
- 13–88: dodawanie tekstu/obrazu/ink, usuwanie stroke'ów i zakładki.
- 101–255: update/delete/move tekstu i obrazu.
- 275: `MoveSelectionAction`; 331: `DeleteSelectionAction`;
  367: `PasteSelectionAction`; 403: `OffsetPosition`.

### `lib/features/editor/state/input_mode.dart` (30 linii)

Tryb zezwalający lub zabraniający rozpoczynania kreski palcem.

- 1: `PointerInputMode`; 3: `PointerInputModeX`;
  25: `pointerInputModeFromIndex`.

### `lib/features/editor/state/page_background.dart` (69 linii)

Model tła Plain/Grid/Lines i jego serializacja.

- 3: `PageBackgroundStyle`; 5: `PageBackgroundStyleX`;
  15: `PageBackgroundSettings`; 64: `backgroundPrefsKeyForKind`.

### `lib/features/editor/state/editor_controller.dart` (3353 linii)

Centralny `ChangeNotifier`: strony, narzędzia, undo/redo, zaznaczenie, media,
preferencje, viewport i zapis.

- 35: `LassoSelection`; 74: `EditorController`.
- 205–263: layout i transformacje viewportu.
- 341–477: operacje `*OnPage` używane przez canvasy/overlaye.
- 486–870: narzędzia, aktywne elementy, lasso i preferencje.
- 1140–1324: undo/redo, strony, bookmarki i index tabs.
- 1351–1467: operacje tekstowe.
- 1481–1750: import oraz clipboard.
- 2182–2330: OCR, obrazy i ink; 2449: `supportsOcr`.
- 2502: `_applyAction`; 2511: `_applyInkAction`;
  2613: `_scheduleSave`; 2634: `_saveDirtyPages`; 2656: `_save`.

## 8. UI edytora

### `lib/features/editor/presentation/editor_screen.dart` (2647 linie)

Wielostronicowy edytor notebooka: viewport, wirtualizowane strony, canvasy,
zakładki, minimapa, skróty i import/eksport. Strona zachowuje logiczną
szerokość 820 px, a węższe okno skaluje cały dokument bez reflow tekstu.
Overview ma zarezerwowany lewy pas, a kolumna strony jest kotwiczona do
stałego prawego marginesu 56 px. Clip viewportu ma wyłącznie wizualny bleed,
aby nie obcinać prawej ramki i cienia strony.

- 33: `EditorScreen`; 40: `_EditorScreenState`.
- 41: `_logicalPageWidth`; 84: `_effectivePageScale` — skala okna pomnożona
  przez zoom użytkownika.
- 196–598: gesty pan/zoom i transformacje; 704: zakres widocznych stron.
- 764–863: busy overlay, import/eksport/clipboard i index tabs.
- 1157: `_buildTransformedDocumentLayer` rozkłada warstwy w logicznym
  rozmiarze 820 px przed skalowaniem, żeby viewport nie obcinał prawej
  krawędzi.
- 1183: główny `build`; 1225: responsywna skala dopasowania;
  1264: wspólna macierz `pageTransform`.
- 1457–1488: tło/inactive `DocumentPageOverlay`, `DocumentDrawingCanvas`
  i active `DocumentPageOverlay` we wspólnej przestrzeni transformacji.
- 1622–1665: skróty klawiszowe; 1697: `_PageViewportClipper`.
- 1799: `_PageFramePainter`; 1874: `_IndexTabsOverlay`;
  2014: `_ProjectMiniMapOverlay`; 2364: `_ProjectMiniMapPainter`.

### `lib/features/editor/presentation/editor_settings_screen.dart` (672 linie)

Ustawienia wejścia, kompaktowego wyboru koloru akcentu, tła oraz podgląd logów
błędów, integralności i wydajności.

- 16:
  `EditorSettingsScreen`;
  242:
  `_showErrorsDialog`;
  324:
  `_showDataIntegrityDialog`;
  411:
  `_showOptimizationDialog`;
  497:
  `_AccentColorSection`;
  609:
  `_BackgroundSection`.

### Widgety edytora

- `lib/features/editor/presentation/widgets/busy_overlay.dart` (18): blokujący
  spinner długiej operacji. 3: `BusyOverlay`.
- `lib/features/editor/presentation/widgets/page_background_paint.dart` (123):
  render i preview tła. 6: `PageBackgroundPaint`;
  36: `PageBackgroundPreview`; 64: `_PageBackgroundPainter`.
- `lib/features/editor/presentation/widgets/editor_toolbar.dart` (929): główny
  toolbar narzędzi, kolorów, gumek, kształtów, tła i eksportu.
  11: `EditorToolbar`; 215: dialog tła; 346: selektor gumki;
  410: selektor kształtu; 822: `_EraserIcon`.
- `lib/features/editor/presentation/widgets/text_edit_toolbar.dart` (545):
  formatowanie aktywnego bloku Quill.
  7: `TextEditToolbar`; 38: `build`; 458–533: formatowanie i listy.

### `lib/features/editor/presentation/widgets/drawing_canvas.dart` (4322 linie)

Dwa świadomie osobne canvasy ink, wspólna geometria, gumki, scratch erase,
lasso, handoff aktywnej kreski i pomiary wydajności.

- 45: `_InkPerfLog`; 260–483: cache/LOD/geometria.
- 584–873: częściowe wymazywanie i rozpoznanie scratch erase.
- 886: `DrawingCanvas` (board, world = page).
- 908: `DocumentDrawingCanvas` (notebook, world = document).
- 1134–2424: `_DrawingCanvasState`; 2425–3911:
  `_DocumentDrawingCanvasState`.
- 3912: `_InkPainter`; 3970: `_InkOverlayPainter`;
  4223: `_InkPageLayer`; 4269: `_PageInkPainter`.

### `lib/features/editor/presentation/widgets/page_overlay.dart` (2492 linie)

Interaktywna warstwa tekstu, obrazów i lassa nad ink; osobne warianty boarda
i dokumentu. Operuje wyłącznie w logicznych współrzędnych strony/dokumentu;
responsywną skalę nadaje wspólny rodzic w `EditorScreen`, nie poszczególne
bloki overlayu.

- 27: `PageOverlay`; 165: `DocumentPageOverlay`.
- 224: `_TextBlockWidget`; 247: `_TextBlockWidgetState`.
- 1039: `_ImageBlockWidget`; 1060: `_ImageBlockWidgetState`.
- 2108: `_editOcr`; 2182: `_OcrTextDialog`;
  2281: `_LassoSelectionWidget`; 2435: `_LassoActionButton`.

## 9. Board

### `lib/features/board/presentation/board_screen.dart` (941 linii)

Jednostronicowa, swobodna tablica z pan/zoom, wspólnym kontrolerem i
warstwami tła/canvasu/overlayu.

- 29: `BoardScreen`; 36: `_BoardScreenState`.
- 57: `_buildBoardRect`; 75–360: obsługa pointerów i viewportu.
- 403–446: import, eksport i busy overlay; 555: główny `build`.
- 822: `_BoardPaintProbe`; 839: `_RenderBoardPaintProbe`;
  878: `_BoardZoomControls`.

## 10. Platformy, web i testy

- `linux/runner/my_application.cc` (301): GTK runner i kanał przycisku rysika.
  10: `_MyApplication`; 65–134: zdarzenia rysika;
  153: `my_application_activate`.
- `ios/Runner/SceneDelegate.swift` (45): Apple Pencil double tap.
  4: `SceneDelegate`; 16: `installPencilInteraction`;
  33: `pencilInteractionDidTap`.
- `web/drift_worker.dart` (5): źródło workera Drift. 3: `main`.
- `web/drift_worker.dart.js`: skompilowany worker.
- `web/sqlite3.wasm`: binarium SQLite dla web.

Testy pokrywają repozytorium i ochronę danych, backup, sync, flattening gumki,
indeks ink, benchmark renderowania, gesty tekstu, resize oraz start aplikacji:

- `test/notebook_repository_test.dart` (992)
- `test/local_backup_service_test.dart` (932)
- `test/backup_eraser_flattening_test.dart` (109)
- `test/cloud_sync_service_test.dart` (24)
- `test/library_controller_test.dart` (33)
- `test/library_screen_responsive_layout_test.dart` (49)
- `test/ink_spatial_index_test.dart` (49)
- `test/ink_render_benchmark_test.dart` (220)
- `test/editor_screen_responsive_layout_test.dart` (133)
- `test/page_overlay_text_gestures_test.dart` (113)
- `test/resizable_frame_test.dart` (33)
- `test/widget_test.dart` (20)

## 11. Krytyczne konwencje

1. Zmiana `notes_database.dart` wymaga `dart run build_runner build`. Przy
   zmianie schematu świadomie podbij `schemaVersion` i dodaj migrację, jeśli
   istniejące dane mają przetrwać. Nie edytuj `notes_database.g.dart`.
2. `_toolFromIndex` i `_toolToIndex` w `notebook_repository.dart` muszą być
   symetryczne. Zmiana kolejności `DrawingTool.values` wymaga migracji danych.
3. Mutacja stanu strony, która ma być cofalna, musi używać `EditorAction` i
   `_applyAction`/`_applyInkAction`, nie bezpośredniej zmiany `pages`.
4. Szybkie zmiany zapisują dirty strony przez `saveNotebookPages`; zmiany
   strukturalne używają pełnego `saveNotebook`. Ochrona integralności archiwizuje
   podejrzaną redukcję przed zapisem i blokuje ją, jeśli dowodu nie da się
   utrwalić.
5. Nie konsoliduj `DrawingCanvas` z `DocumentDrawingCanvas` ani
   `PageOverlay` z `DocumentPageOverlay` bez wyraźnej zgody — mają różne
   układy współrzędnych.
6. Notebook ma stałą logiczną szerokość strony 820 px. Przy zmianie okna
   skaluj wspólną macierz dokumentu; nie przeliczaj rozmiarów/pozycji tekstu,
   obrazów ani ink i nie dodawaj osobnej skali wewnątrz overlayów. Zachowaj
   pas overview do `x=118` i stały prawy margines strony 56 px. Wizualny bleed
   clippera może odsłaniać ramkę/cień, ale nie może zmieniać geometrii układu.
7. OCR działa tylko na Android/iOS. Import PDF na Linuxie używa `pdftoppm`
   (`poppler-utils`); pozostałe platformy używają `pdfx`.
8. Obrazy natywne mają trwałe ścieżki; inline `bytes` są przeznaczone dla web
   lub migracji starych danych i są czyszczone po utrwaleniu pliku.

## 12. Komendy

```bash
flutter pub get
flutter run
dart format lib test
dart analyze
flutter test
dart run build_runner build
dart compile js -O4 -o web/drift_worker.dart.js web/drift_worker.dart
```

Linux: użytkownik instaluje `zenity` (file picker) i `poppler-utils` (PDF).
