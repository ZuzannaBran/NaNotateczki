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
- Tekst: `flutter_quill`; ramki transformacji: `flutter_box_transform`;
  obrazy/PDF: `image_picker`, `file_picker`, `pdfx`.
- OCR: `google_mlkit_text_recognition`, tylko Android/iOS.
- Główny przepływ:
  `main` → `AppScope` → `LibraryController` → `EditorController` →
  `NotebookRepository` → Drift.
- Po zapisie repozytorium przekazuje schedulerowi UID-y zmienionych
  notebooków. Backup czeka na bezczynność rysika, przetwarza tylko dirty
  dokumenty i może przerwać worker po wznowieniu pisania.
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

### `lib/app/app_scope.dart` (679 linii)

Otwiera bazę, buduje serwisy/Providery, nakłada zapisany kolor akcentu bez
przebudowywania `MaterialApp` i planuje backup po zapisie. Scope przechwytuje
anulowalne żądanie zamknięcia aplikacji: gdy rysik ma aktywny kontakt,
edytor, repozytorium lub backup ma pracę w toku, odrzuca pierwsze wyjście,
pokazuje blokujący spinner, czeka na zakończenie stroke'a, wymusza zapis
edytora → opróżnienie kolejki SQLite → końcowy backup i dopiero potem żąda
obowiązkowego zamknięcia. Scheduler w trybie exit nie czeka na idle
rysika i nie porzuca zmian po błędzie.

- 24: `AppScope`; 31: `_AppScopeState`; 73: `didRequestAppExit`.
- 302: `_FinishingExitOverlay`; 410: `_BackupScheduler`;
  606: `flushForExit`.

## 3. Core

### Motyw

- `lib/core/theme/app_colors.dart` (133): kolory akcentów oraz wspólna neutralna paleta beżów interfejsu: `#E6E6E6` dla tła, `#FBFBFB` dla toolbarów/panelu folderów i `#DBDBDB` dla separatorów. Bazowe kolory Cherry, Bubblegum, Lavender, Peach i Baby blue pozostają bez zmian. 3: `AppAccentColor`; 61: `AppAccentPalette`; 117: `AppColors`.
- `lib/core/theme/app_metrics.dart` (3): współdzielone metryki A4.
  1: `AppMetrics`.
- `lib/core/theme/app_theme.dart` (39): jasny Material 3 z ciemniejszym neutralnym tłem `#E6E6E6`, jasnym chromem `#FBFBFB` i separatorami `#DBDBDB`; kolory przewodnie nadal sterują akcentami i zaznaczeniami. 5: `AppTheme`.

### Wejście i preferencje

- `lib/core/input/app_preferences_controller.dart` (139):
  globalny tryb urządzenia i kolor akcentu zapisane w `app_prefs.json`;
  starsze Classic, Sakura i Mint są migrowane do nowego Bubblegum.
  Dotychczasowy zapis `bubblegum` zachowuje stary wybór jako Cherry.
  8: `DeviceInputMode`;
  27:
  `AppPreferencesController`.
- `lib/core/input/ink_activity_tracker.dart` (61): globalnie śledzi kontakt
  rysika i okres wyciszenia używany przez zapis/backup; exit guard może czekać
  na zakończenie aktywnego kontaktu przed flushowaniem edytora.
  5: `InkActivityTracker`; 14: `hasActiveContacts`;
  22: `waitForNoActiveContacts`.
- `lib/core/input/soft_keyboard.dart` (22): prosi o klawiaturę ekranową w
  trybie tablet.
  7: `requestSoftKeyboardForFocus`.
- `lib/core/input/stylus_button_state.dart` (42): stan przycisku rysika i
  Apple Pencil double tap przez platform channel.
  6: `StylusButtonState`; 17: `initialize`; 25: `_handleMethodCall`.

### Storage i diagnostyka

- `lib/core/storage/app_save_coordinator.dart` (50): rejestr aktywnych
  edytorów i wspólny flush ich oczekujących zapisów przed zamknięciem.
  3: `AppSaveCoordinator`.
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

### `lib/data/drift/notes_database.dart` (337 linii)

Schemat SQLite i bezpieczne otwieranie bazy z trzema próbami. Start sprawdza
`PRAGMA quick_check` i `PRAGMA foreign_key_check`; po potwierdzonej korupcji lub naruszeniu integralności natywna baza jest
zachowywana jako plik `.corrupt_*`, a aplikacja
otwiera świeżą bazę, aby lokalny recovery mógł odtworzyć dane.

- 9: `NotebookRows`; 21: `PageRows`; 32: `TextBlockRows`;
  49: `ImageBlockRows`; 72: `InkStrokeRows`.
- 85: `DatabaseOpenResult`; 99: `DatabaseOpenStage`;
  110: `DatabaseOpenException`; 143: `NotesDatabase`.
- 150: `NotesDatabase.open`; 294: kontrola integralności;
  322: `schemaVersion` (`2`); 325: `migration` — usuwa dane starego
  mechanizmu Index tab podczas przejścia z v1.

- `lib/data/drift/notes_database_connection.dart` (2): conditional export
  natywnego lub webowego połączenia.
- `lib/data/drift/notes_database_connection_io.dart` (196): SQLite w katalogu
  dokumentów przez `NativeDatabase.createInBackground`.
  7: `NotesDatabaseConnection`; 14: `openNotesDatabaseConnection`.
- `lib/data/drift/notes_database_connection_web.dart` (41): SQLite WASM z
  trwałym IndexedDB.
  6: `NotesDatabaseConnection`; 13: `openNotesDatabaseConnection`.
- `lib/data/drift/notes_database.g.dart` (5181): kod wygenerowany przez Drift;
  nie czytaj ani nie edytuj ręcznie.

### Backup, eksport i synchronizacja

### `lib/data/backup/local_backup_service.dart` (2607 linii)

Przyrostowy backup z atomowym `manifest.json` i checksumami SHA-256. Format
v6 rozdziela notebook na niezmienne, content-addressed pliki stron w
`local_backup/pages/`; manifest przechowuje metadane notebooka oraz
referencje do stron. Przy zwykłym `saveNotebookPages` worker dostaje tylko
dirty `NotePage`, aplikuje gumki, koduje JSON, liczy SHA-256 i atomowo zapisuje
plik strony bez odsyłania dużego JSON-a do UI isolate. Niezmienione strony są
ponownie używane po lekkiej kontroli pliku. Zmiana metadanych nie serializuje
żadnej strony.

Obrazy pozostają niezmiennymi assetami w `local_backup/assets/`; referencje
assetów są przechowywane per strona. Pierwsza zmiana notebooka ze starszego
formatu migruje go do v6, potem zapis jest page-level. Odczyt pozostaje zgodny
z manifestami v1–v5 oraz mieszanymi wpisami legacy/v6. Restore weryfikuje
checksumę każdej strony i assetu. Pliki stron i assetów nie są usuwane w hot
path, żeby historia manifestów nie straciła zależności. Web nadal zapisuje
pełny snapshot w `localStorage`.

- 19: `LocalBackupService`; 37: `waitUntilIdle`; 153: `snapshot`;
  84: `_pagesDir`.
- 772: `_pageReferenceFromJson`; 1054: `readLatest`;
  1283: `_readBackupPageJson`; 1508: `restoreFromLatest`.
- 1883: `_BackupPageWorkerRequest`; 1922: `_BackupWorkerClient`;
  2116: `_createPageBackupPayload`; 2521: `_BackupPageReference`.
- 2407: `BackupSnapshotReport`.

### `lib/data/backup/backup_eraser_flattening.dart` (18 linii)

Warstwa zgodności backupu delegująca spłaszczenie starych masek gumki do
wspólnego `InkEraserEngine`. Nowe edycje nie zapisują stroke'ów gumki.

- 5:
  `flattenErasersForBackup`;
  11:
  `flattenPageErasersForBackup`.

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
- `lib/features/notebook/domain/note_page.dart` (39): zawartość strony.
  5: `NotePage`.
- `lib/features/notebook/domain/drawing_tool.dart` (43): enum narzędzi i
  klasyfikacja eraser/shape/ink.
  1: `DrawingTool`; 21: `DrawingToolX`.
- `lib/features/notebook/domain/ink_stroke.dart` (49): stroke i punkt z
  naciskiem.
  5: `InkStroke`; 37: `InkPoint`.
- `lib/features/notebook/domain/ink_spatial_index.dart` (125): cache'owany
  indeks siatkowy kandydatów do hit-testu.
  14: `inkSpatialIndexFor`; 24: `InkSpatialIndex`.
- `lib/features/notebook/domain/ink_eraser_engine.dart` (549):
  wspólny destrukcyjny silnik gumki dla boarda i notebooka. Zwykła gumka
  wycina fragmenty stroke'a i zapisuje pozostałe części jako realny ink;
  erase-stroke i area kasują całe trafione stroke'y. Stary zapis masek gumki
  jest jednorazowo spłaszczany do zwykłego ink.
  35: `InkEraserEngine`.
- `lib/features/notebook/domain/text_block.dart` (45): blok Quill z pozycją,
  stylem, szerokością i rotacją.
  3: `TextBlock`.
- `lib/features/notebook/domain/image_block.dart` (71): obraz, OCR, crop,
  rotacja oraz legacy inline bytes.
  4: `ImageBlock`.

### `lib/features/notebook/data/notebook_repository.dart` (2227 linii)

Most domena ↔ Drift ↔ JSON, z kolejką zapisu per UID i ochroną przed
podejrzaną utratą danych. `NotebookRepositoryChange` rozróżnia pełną zmianę,
zmianę konkretnych page IDs i zmianę samych metadanych, dzięki czemu scheduler
może uruchomić backup v6 tylko dla właściwych stron. Repozytorium udostępnia
też oczekiwanie na wszystkie trwające zapisy per UID. Ręczny eksport pozostaje
samowystarczalny i zachowuje obrazy inline.

- 23: `DataIntegrityIncidentHandler`; 30: `NotebookRepositoryChange`;
  45: `RepositoryChangeHandler`; 55: `NotebookRepository`.
- 81: `waitForPendingSaves`; 483: `saveNotebook`;
  513: `saveNotebookPages`; 721: `updateNotebookMetadata`;
  1095: `deleteNotebook`.
- 1236: `encodeNotebookForLocalBackup`; 1239:
  `encodePageForLocalBackup`.
- 2079: `_toolFromIndex`; 2087: `_toolToIndex` — muszą pozostać symetryczne.
- 2132: `DataIntegrityProtectionException`.

### `lib/features/notebook/presentation/notebook_screen.dart` (24 linie)

Wybiera pusty stan albo właściwy `EditorScreen`.

- 8: `NotebookScreen`.

## 6. Biblioteka

### `lib/features/library/presentation/library_controller.dart` (640 linii)

Stan folderów, listy dokumentów, wyszukiwania, syncu, importu i recovery.
Wybór dokumentu synchronizuje też aktywny folder, dzięki czemu drzewko
biblioteki zaznacza folder i notatkę jednocześnie. Zapis samych folderów
zgłasza pusty zestaw zmian repozytorium, więc aktualizuje manifest bez
oznaczania notebooków jako dirty. Sprzątanie osieroconych obrazów działa
tylko przy normalnym starcie istniejącej, zdrowej bazy.

- 14: `LibraryController`; 78: `initialize`; 87: `loadItems`;
  159: `restoreCorruptDocumentsFromBackup`; 217: `syncNow`.
- 261–389: tworzenie/zmiana/usuwanie folderów i dokumentów.
- 417: `selectItem`; 433: `selectFolder`; 442: `setSearchQuery`.
- 447: `exportBackup`; 476: `importBackup`; 489: `selectedItem`.
- 563: `_saveFolders` — zapis folderów zgłasza pusty zestaw zmian.

### `lib/features/library/presentation/library_screen.dart` (1045 linie)

Jednopanelowa biblioteka w formie drzewa: wspólny pasek sterowania,
rozwijane i zwijane foldery oraz zagnieżdżone notebooki i boardy. Folder
i aktywny dokument mają miękkie, zaokrąglone zaznaczenie; sidebar używa
kompaktowej typografii Georgia i jasnej neutralnej powierzchni panelu. Panel można
zwijać w całości i zmieniać jego szerokość. Pionowy separator uchwytu ma 1 px, ten sam kolor co linia pod toolbarami i leży na prawej krawędzi, dzięki czemu linie stykają się.

- 16: `LibraryScreen`;
  23:
  `_LibraryScreenState`;
  523:
  `_LibraryTreePane`;
  749:
  `_FolderTreeRow`;
  859:
  `_LibraryTreeItemRow`;
  949:
  `_LibraryWorkspace`.

### `lib/features/library/presentation/widgets/library_item_card.dart` (132 linie)

Karta notebooka/boarda z menu zmiany nazwy i usuwania.

- 8: `LibraryItemCard`; 110: `_ItemKindIcon`.

## 7. Stan edytora

### `lib/features/editor/state/editor_actions.dart` (452 linii)

Akcje undo/redo; każda implementuje `apply(page)` i `revert(page)`.
Kasowanie gumką używa `DeleteInkStrokesAction`, która przechowuje tylko
usunięte stroke'y i ich pierwotne indeksy zamiast pełnej kopii strony.

- 8: `EditorAction`.
- 13: dodawanie tekstu/obrazu/ink;
  88: destrukcyjne usuwanie ink.
- 88–242: update/delete/move tekstu i obrazu.
- 262: `MoveSelectionAction`; 318: `DeleteSelectionAction`;
  354: `PasteSelectionAction`; 390: `OffsetPosition`.

### `lib/features/editor/state/input_mode.dart` (30 linii)

Tryb zezwalający lub zabraniający rozpoczynania kreski palcem.

- 1: `PointerInputMode`; 3: `PointerInputModeX`;
  25: `pointerInputModeFromIndex`.

### `lib/features/editor/state/page_background.dart` (69 linii)

Model tła Plain/Grid/Lines i jego serializacja.

- 3: `PageBackgroundStyle`; 5: `PageBackgroundStyleX`;
  15: `PageBackgroundSettings`; 64: `backgroundPrefsKeyForKind`.

### `lib/features/editor/state/editor_controller.dart` (2913 linii)

Centralny `ChangeNotifier`: strony, narzędzia, undo/redo, zaznaczenie, media,
preferencje, viewport i zapis. Przy otwarciu jednorazowo spłaszcza legacy
stroke'y gumki i zapisuje oczyszczone strony. Rejestruje się w `AppSaveCoordinator`;
`flushPendingSaves` commit'uje aktywną edycję tekstu, anuluje debounce,
czeka na istniejące zapisy repozytorium i wymusza zapis dirty stron przed
zgodą na zamknięcie aplikacji. Nowo wstawiony lub wklejony tekst i obraz
przechodzą od razu do trybu `edit` i pozostają aktywne do transformacji;
wklejone zaznaczenie zachowuje lasso w trybie `edit`. Obrazy pozostają pod
tuszem i tekstem; wybór narzędzia ink lub tekstu dezaktywuje aktywny obraz.
`isObjectTransformActive` blokuje zmianę viewportu na czas move/resize ramki.

- 36: `LassoSelection`; 75: `EditorController`;
  200: `flushPendingSaves`.
- 259–332: layout i transformacje viewportu; 274: start blokady transformacji,
  290: `setViewTransform`.
- 362–498: operacje `*OnPage` używane przez canvasy/overlaye.
- 507–899: narzędzia, aktywne elementy, lasso i preferencje; 559: `setTool`;
  591: `commitActiveTextEdit` — zamyka edycję treści przed transformacją ramki.
- 1249: `undo`; 1262: `redo`; 1334: `toggleBookmark`;
  1340: operacje tekstowe; 1410: `updateActiveTextStyle` — blokowe
  formatowanie aktywnego tekstu, zapisywane jako `UpdateTextAction`.
- 2684: `_applyAction`; 2693: `_applyInkAction`;
  2795: `_scheduleSave`; 2816: `_saveDirtyPages`; 2838: `_save`.

## 8. UI edytora

### `lib/features/editor/presentation/editor_screen.dart` (2336 linii)

Wielostronicowy edytor notebooka: nagłówek notesu ma 18 px; toolbary mają
kolor tła aplikacji i są oddzielone od strefy notatek separatorem takim jak
panel folderów. Cały viewport pod toolbarami, obejmujący overview i strony notesu, ma ciemniejsze neutralne tło #E6E6E6; nagłówek, toolbary i panel folderów zachowują normalne tło motywu. Viewport, wirtualizowane strony, canvasy, minimapa,
skróty i import/eksport. Strona zachowuje logiczną
szerokość 820 px, a węższe okno skaluje cały dokument bez reflow tekstu.
Overview ma po 10 px wolnej przestrzeni po lewej i prawej stronie; poziomy
viewport strony zaczyna się przy x=116 i kończy 56 px przed prawą krawędzią.
Zoom i pan działają wewnątrz tego pasa, ale podczas aktywnego move/resize
obiektu viewport jest zamrożony: custom pan/zoom jest ignorowany, a pionowy
`SingleChildScrollView` przechodzi na `NeverScrollableScrollPhysics`.
Po zakończeniu transformacji normalna nawigacja wraca. Stronę można przesuwać
poziomo dotykiem także wtedy, gdy jest węższa od viewportu; clamp pozwala jej
dojść od lewej do prawej granicy pasa, ale nigdy wejść pod margines. Bleed
pozostaje tylko pionowo.

- 33: `EditorScreen`; 40: `_EditorScreenState`.
- 41: `_logicalPageWidth`; 84: `_effectivePageScale` — skala okna pomnożona
  przez zoom użytkownika.
- 203–624: gesty pan/zoom, blokada viewportu i transformacje.
- 802–888: busy overlay, import/eksport i clipboard.
- 1007: `_buildTransformedDocumentLayer` rozkłada warstwy w logicznym
  rozmiarze 820 px przed skalowaniem, żeby viewport nie obcinał prawej
  krawędzi.
- 1033: główny `build`; pasek tekstu jest renderowany na podstawie
  aktywnego `TextBlock`, niezależnie od starego `QuillController`; wspólna
  macierz `pageTransform` skaluje dokument.
- 1535: `_PageViewportClipper`; 1605: `_PageFramePainter`;
  1712: `_ProjectMiniMapOverlay`; 2064: `_ProjectMiniMapPainter`.

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
- `lib/features/editor/presentation/widgets/editor_toolbar.dart` (889):
  główny toolbar narzędzi, kolorów, gumek, kształtów, tła i eksportu; tło paska używa jasnej neutralnej powierzchni #FBFBFB;
  ikony są lekkie, obrysowe i wizualnie dopasowane do typografii Georgia.
  Lasso używa gotowej ikony Material `highlight_alt_outlined`, która
  przedstawia zaznaczanie obszaru kursorem.
  10: `EditorToolbar`; 181: dialog tła; 316: selektor gumki;
  382: selektor kształtu; 782: `_EraserIcon`.
- `lib/features/editor/presentation/widgets/text_edit_toolbar.dart` (565):
  pasek formatowania aktywnego `TextBlock` współpracujący bezpośrednio z
  `EditableText`. Obsługuje realne formatowanie całego bloku: bold, italic,
  underline, strike, font, rozmiar, kolor, wyrównanie, reset stylu i usunięcie.
  Listy oraz formatowanie tylko zaznaczonego fragmentu są celowo pominięte,
  ponieważ obecny `EditableText` nie renderuje ich jako rich-text.
  9: `TextEditToolbar`; 43: `build`.

- `lib/features/editor/presentation/interaction/object_transform_engine.dart` (424):
  wspólny silnik move/resize/rotate dla obiektów nie-ink. Używa typów
  `HandlePosition` i `ResizeMode` z `flutter_box_transform`, ale po zmianach
  API 0.4.7 sam liczy geometrię logiczną, clamp, skalowanie i obrót, dzięki
  czemu działa niezależnie od zoomu dokumentu i nie dotyka stroke'ów.
  6: `ObjectTransformKind`; 8: `ObjectTransformSnapshot`;
  24: `ObjectTransformEngine`; 315: `_ObjectTransformSession`.
- `lib/features/editor/presentation/widgets/object_transform_hud.dart` (664):
  wspólna ramka transformacji dla tekstu i obrazów/PDF; używa gotowych
  `DefaultCornerHandle` i `DefaultSideHandle` z `flutter_box_transform`
  oraz wspólnego grabbera nad górną krawędzią do przesuwania obiektu.
  Grabber działa także wtedy, gdy środek ramki jest wyłączony z dragowania,
  np. podczas aktywnej edycji tekstu. Dedykowane uchwyty używają surowych
  pointer events zamiast rozpoznawania pan, więc reagują od pierwszego ruchu
  bez systemowego touch slop. Niewidzialny hit-area skaluje się liniowo z
  rozmiarem ramki przez sqrt(width*height), z zakresem 32–80 px.
  Udostępnia callbacki startu i końca transformacji, dzięki którym warstwa
  obiektu blokuje viewport dokładnie na czas move/resize; dispose aktywnego
  HUD-u również zwalnia blokadę. Kolor, rozmiary i grubość ramki są
  konfigurowalne przez `ObjectTransformHudStyle`.
  14: `ObjectTransformHudStyle`; 59: `ObjectTransformHud`;
  113: `_ObjectTransformHudState`; 610: `_ObjectTransformFramePainter`.
- `lib/features/editor/presentation/widgets/text_hud_block.dart` (511):
  aktywny `TextBlock` renderowany przez Flutter `EditableText`; ramka,
  move/resize/scale są delegowane do wspólnego `ObjectTransformHud`; obrót
  jest wyłączony. Podczas edycji treści uchwyty resize i osobny grabber move
  pozostają aktywne, a środek ramki przepuszcza gesty do `EditableText`.
  Start transformacji zapisuje najnowszą treść, włącza blokadę viewportu
  i używa tej treści jako snapshotu resize, więc zmiana rozmiaru ani anulowanie
  gestu nie przywracają starszego tekstu. Nieaktywne teksty nadal
  używają starego Quilla jako bezpieczny fallback.

### `lib/features/editor/presentation/widgets/drawing_canvas.dart` (4461 linie)

Dwa świadomie osobne canvasy ink, wspólna geometria, scratch erase, lasso,
handoff aktywnej kreski i pomiary wydajności. Podczas rysowania
pen/highlighter overlay stosuje ten sam LOD co zapisany tusz, żeby
ograniczyć zmianę wyglądu po oderwaniu rysika. Oba delegują gumkę do jednego
`InkEraserEngine`; zwykła gumka destrukcyjnie wycina tylko przejechany
fragment, a erase-stroke/area usuwają całe stroke'y. Żaden tryb nie zapisuje
masek gumki w `inkStrokes`.

- 45: `_InkPerfLog`; 260–483: cache/LOD/geometria.
- 584–873: częściowe wymazywanie i rozpoznanie scratch erase.
- 887: `DrawingCanvas` (board, world = page).
- 909:
  `DocumentDrawingCanvas` (notebook, world = document).
- 1135:
  `_DrawingCanvasState`;
  2440:
  `_DocumentDrawingCanvasState`.
- 3912: `_InkPainter`; 3970: `_InkOverlayPainter`;
  4223: `_InkPageLayer`; 4269: `_PageInkPainter`.

### `lib/features/editor/presentation/widgets/page_overlay.dart` (2823 linii)

Interaktywna warstwa tekstu, obrazów i lassa nad ink; osobne warianty boarda
i dokumentu. Aktywny blok tekstu przechodzi do `TextHudBlock`: `EditableText` oraz wspólny `ObjectTransformHud` dla
move, width-resize i scale. Nieaktywne teksty zachowują stary Quill jako fallback. Aktywne obrazy/PDF
korzystają z tego samego `ObjectTransformHud`; obrót jest wyłączony, rogi skalują, boki zachowują
crop, a lasso/ink pozostają poza tym silnikiem. Piksele obrazów/PDF są zawsze renderowane w warstwie tła przed
tuszem i tekstem, także gdy obraz jest aktywny; aktywna warstwa zawiera wtedy
tylko ramkę i uchwyty edycji. W trybie tekstu obrazy ignorują hit-test i nie
mogą przejąć kliknięcia przeznaczonego do wstawiania lub edycji tekstu.
Operuje wyłącznie w logicznych współrzędnych strony/dokumentu; responsywną
skalę nadaje wspólny rodzic w `EditorScreen`, nie poszczególne bloki
overlayu. Pojedyncze wskazanie nieaktywnego Quilla jest stosowane po oknie
double tap, aby arena gestów Quilla zakończyła się przed podmianą widgetu na
`TextHudBlock`.

- 32: `PageOverlay`; 193: `DocumentPageOverlay`.
- aktywny tekst: `TextHudBlock`; fallback nieaktywnego tekstu:
  `_TextBlockWidget` / `_TextBlockWidgetState`.
- 1357: `_ImageBlockWidget`; 1380: `_ImageBlockWidgetState`.
- 2439: `_editOcr`; 2513: `_OcrTextDialog`;
  2612: `_LassoSelectionWidget`; 2766: `_LassoActionButton`.

## 9. Board

### `lib/features/board/presentation/board_screen.dart` (963 linii)

Jednostronicowa, swobodna tablica z pan/zoom, wspólnym kontrolerem i
warstwami tła/canvasu/overlayu; podczas aktywnej transformacji obiektu
ignoruje pointery nawigacyjne, trackpad i scroll, a kontroler blokuje zmianę
`viewPan/viewScale`. Pasek tekstu, tak jak w notebooku, jest wiązany z
aktywnym `TextBlock`, a nie ze starym `QuillController`. Pomocnicze panele
UI dziedziczą aktywną paletę.

- 29: `BoardScreen`; 36: `_BoardScreenState`.
- 57: `_buildBoardRect`; 75–379: obsługa pointerów i viewportu.
- 420–463: import, eksport i busy overlay; 572: główny `build`.
- 842: `_BoardPaintProbe`; 859: `_RenderBoardPaintProbe`;
  898: `_BoardZoomControls`.

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

- `test/notebook_repository_test.dart` (1079): zapis, ochrona danych i
  migracja v1→v2 usuwająca dane Index tab bez utraty stron.
- `test/local_backup_service_test.dart` (1337)
- `test/editor_save_flush_test.dart` (63): wymuszenie dirty page save przed
  zamknięciem.
- `test/editor_controller_layering_test.dart` (77): aktywne obrazy są
  dezaktywowane po wyborze narzędzia ink lub tekstu, a nowy tekst startuje
  zaznaczony w trybie edit.
- `test/backup_eraser_flattening_test.dart` (109)
- `test/cloud_sync_service_test.dart` (24)
- `test/library_controller_test.dart` (33)
- `test/library_screen_responsive_layout_test.dart` (112)
- `test/ink_activity_tracker_test.dart` (25): exit guard czeka na koniec
  aktywnego kontaktu rysika.
- `test/ink_spatial_index_test.dart` (49)
- `test/ink_eraser_engine_test.dart` (150): zwykła gumka
  dzieląca stroke na fragmenty, erase-stroke/area hit-test, migracja legacy
  gumek i undo
- `test/ink_render_benchmark_test.dart` (220)
- `test/editor_screen_responsive_layout_test.dart` (196)
- `test/page_overlay_text_gestures_test.dart` (246): sprawdza blokowy
  toolbar tekstu i brak nieobsługiwanych list, skalowanie hit-area uchwytów,
  blokadę viewportu oraz brak zmian pan/zoom kontrolera podczas resize;
  tryb tekstu ignoruje obrazy pod kursorem, a resize nie gubi zmian
- `test/object_transform_engine_test.dart` (68): wspólna geometria
  move, corner-scale, side-resize i snap rotacji dla globalnego HUD-u
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
   overview od `x=10` do `x=106` i równy 10 px odstęp po obu jego stronach;
   viewport strony zaczyna się przy `x=116` i kończy 56 px przed prawą
   krawędzią. Przy zoomie nie zwężaj viewportu do bazowej szerokości strony.
   Jeśli strona jest węższa od viewportu, poziomy pan ma zakres od lewego do
   prawego wyrównania zamiast jednej sztywnej pozycji. Clipper nie może
   wypuszczać strony poziomo pod marginesy; bleed może być tylko pionowy.
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
