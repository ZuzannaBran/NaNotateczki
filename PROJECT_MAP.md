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

### `lib/app/app_scope.dart` (633 linie)

Otwiera bazę, buduje serwisy/Providery, nakłada zapisany kolor akcentu bez
przebudowywania `MaterialApp` i planuje backup po zapisie. Scope przechwytuje
anulowalne żądanie zamknięcia aplikacji: gdy rysik ma aktywny kontakt,
edytor, repozytorium lub backup ma pracę w toku, odrzuca pierwsze wyjście,
pokazuje blokujący spinner, czeka na zakończenie stroke'a, wymusza zapis
edytora → opróżnienie kolejki SQLite → końcowy backup i dopiero potem żąda
obowiązkowego zamknięcia. Zwykły backup nie wyświetla wskaźnika
postępu, ale podczas zamykania blokujący spinner nadal chroni zapis.
Scheduler w trybie exit nie czeka na idle rysika i nie porzuca zmian
po błędzie. Motyw jasny/ciemny jest nakładany reaktywnie z preferencji.

- 24: `AppScope`; 31: `_AppScopeState`; 73: `didRequestAppExit`.
- 226: `_ExitGuardOverlay`; 252: `_FinishingExitOverlay`;
  360: `_BackupScheduler`;
  556: `flushForExit`.

## 3. Core

### Motyw

- `lib/core/theme/app_colors.dart` (86): jasna paleta oraz tryb ciemny:
  tło #2D2E2B, panele #3A3B39, aktywne #4A4B48, kartka/panele #5A5B57,
  ciemniejszy canvas notatek #50514D, tekst #EEECE6. `displayInkColor` odwraca jasność HSL wszystkich odcieni,
  zachowując hue, saturację i alpha (czerń↔biel, jasny błękit↔ciemny).
  Transformacja działa przy wyświetlaniu i eksporcie aktualnego motywu,
  bez modyfikowania zapisanych kresek. 50: `AppColors`.
- `lib/core/theme/app_metrics.dart` (3): współdzielone metryki A4.
  1: `AppMetrics`.
- `lib/core/theme/app_theme.dart` (113): `AppTheme.light` i `AppTheme.dark`
  z kontrastowymi kontrolkami i nagłówkami. 5: `AppTheme`.

### Wejście i preferencje

- `lib/core/input/app_preferences_controller.dart` (156):
  tryb urządzenia, akcent i trwałe `darkMode` w `app_prefs.json`;
  brak klucza zachowuje tryb jasny;
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

### `lib/data/backup/backup_eraser_flattening.dart` (12 linii)

Cienki adapter zgodności dla backupu; deleguje normalizację starych masek
bezpośrednio do `InkEraserEngine`. Nie zawiera własnej geometrii gumki.

- 5: `flattenErasersForBackup`; 9: `flattenPageErasersForBackup`.

### `lib/data/export/notebook_export_service.dart` (779 linii)

Renderuje notebook/board do PNG lub PDF i zapisuje przez systemowy dialog.
Eksport wywołany z edytora używa aktywnego motywu: jasnego albo ciemnego.
W dark mode tło kartki (#50514D), siatka, tekst i wszystkie kolory tuszu
są odpowiednio renderowane; warianty PDF i PNG współdzielą ten sam renderer.
Publiczne metody testowe przyjmują `darkMode` (domyślnie false).
Obrazy pozostają bez zmian, a oryginalne kolory w danych są zachowane.
Przed renderem normalizuje legacy gumki; renderer zna wyłącznie zwykły
ink i nie używa `BlendMode.clear`.

- 25: `NotebookExportFormat`; 27: `NotebookExportFormatLabel`;
  38: `NotebookExportService`; 45: `exportController`;
  62: `exportNotebook`; publiczne metody `renderPngPagesForTest` i
  `renderPdfBytesForTest` uruchamiają produkcyjny renderer bez systemowego
  dialogu zapisu pliku.

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
- `lib/features/notebook/domain/ink_eraser_engine.dart` (719):
  jedyny silnik modyfikacji gumki dla boarda i notebooka. Obsługuje zwykłą
  gumkę, erase-stroke, area oraz scratch erase. Legacy maski są tu wyłącznie
  jednorazowo normalizowane do zwykłego ink; generator fragmentów unika
  kolizji ID i obsługuje też pojedyncze punkty.
  37: `InkEraserEngine`; 40: `normalizePage`; 45: `normalizeNotebook`;
  117: `scratchInkHitCount`; 139: `eraseScratchParts`;
  194: `flattenLegacyErasers`.
- `lib/features/notebook/domain/text_block.dart` (45): blok Quill z pozycją,
  stylem, szerokością i rotacją.
  3: `TextBlock`.
- `lib/features/notebook/domain/image_block.dart` (71): obraz, OCR, crop,
  rotacja oraz legacy inline bytes.
  4: `ImageBlock`.

### `lib/features/notebook/data/notebook_repository.dart` (2361 linii)

Most domena ↔ Drift ↔ JSON, z kolejką zapisu per UID i ochroną przed
podejrzaną utratą danych. Jest też kanoniczną granicą migracji starego modelu
gumki: odczyt normalizuje legacy maski, a zdrowe strony są fizycznie
przepisywane w SQLite bez eraser-stroke'ów i bez zmiany metadanych notebooka.
Migracja korzysta z tej samej kolejki per UID co zwykłe zapisy, więc nie
ściga się z aktywnym save'em. Zapis, import, restore i JSON normalizują dane
ponownie, a niskopoziomowa serializacja odrzuca próbę utrwalenia eraser-stroke.
`NotebookRepositoryChange` rozróżnia pełną zmianę, zmianę konkretnych page IDs
i zmianę samych metadanych, dzięki czemu scheduler może uruchomić backup v6
tylko dla właściwych stron. Repozytorium udostępnia też oczekiwanie na
wszystkie trwające zapisy per UID. Ręczny eksport pozostaje samowystarczalny
i zachowuje obrazy inline.

- 23: `DataIntegrityIncidentHandler`; 30: `NotebookRepositoryChange`;
  45: `RepositoryChangeHandler`; 55: `NotebookRepository`.
- 81: `waitForPendingSaves`; 141: `fetchNotebooks`;
  518: `saveNotebook`; zapis stron jest bezpośrednio dalej.
- 1499: `_readPage`; 1561: `_persistLegacyEraserPages` — migracja masek,
  po wejściu do kolejki ponownie czyta aktualny stan SQLite.
- 1921: `_strokeToCompanion`; 2150: `_strokeToJson` — oba blokują
  utrwalenie eraser-stroke.
- `_toolFromIndex` i `_toolToIndex` muszą pozostać symetryczne.

### `lib/features/notebook/presentation/notebook_screen.dart` (26 linii)

Wybiera pusty stan albo właściwy `EditorScreen`; przekazuje flagę
widoczności wspólnego paska narzędzi.

- 8: `NotebookScreen`.

## 6. Biblioteka

### `lib/features/library/presentation/library_controller.dart` (663 linie)

Stan folderów, listy dokumentów, wyszukiwania, syncu, importu i recovery.
Wybór dokumentu synchronizuje też aktywny folder, dzięki czemu drzewko
biblioteki zaznacza folder i notatkę jednocześnie. Asynchroniczny start
nie powiadamia słuchaczy po usunięciu kontrolera. Zapis samych folderów
zgłasza pusty zestaw zmian repozytorium, więc aktualizuje manifest bez
oznaczania notebooków jako dirty. Sprzątanie osieroconych obrazów działa
tylko przy normalnym starcie istniejącej, zdrowej bazy.

- 14: `LibraryController`; 78: `initialize`; 87: `loadItems`;
  159: `restoreCorruptDocumentsFromBackup`; 217: `syncNow`.
- 261–389: tworzenie/zmiana/usuwanie folderów i dokumentów.
- 417: `selectItem`; 433: `selectFolder`; 442: `setSearchQuery`.
- 447: `exportBackup`; 476: `importBackup`; 489: `selectedItem`.
- 563: `_saveFolders` — zapis folderów zgłasza pusty zestaw zmian.

### `lib/features/library/presentation/library_screen.dart` (1091 linii)

Jednopanelowa biblioteka w formie drzewa: wspólny pasek sterowania,
rozwijane i zwijane foldery oraz zagnieżdżone notebooki i boardy. Folder
i aktywny dokument mają miękkie, zaokrąglone zaznaczenie; sidebar używa
kompaktowej typografii Georgia i jasnej neutralnej powierzchni panelu. Panel można
zwijać w całości i zmieniać jego szerokość. Tytuł panelu to `Projects`. Pod strzałką panelu folderów
jest drugi przycisk zwijania wspólnego paska narzędzi boarda i notebooka.
Obie strzałki są pionowo wyśrodkowane we własnych obszarach (nagłówek
58 px i toolbar 72 px), przypięte do prawej krawędzi panelu,
a ich kierunki lewo/prawo odpowiadają zwijaniu bocznemu.
Oba przyciski mają węższą szerokość 24 px, wysokość 44 px,
ikonę 18 px oraz mocniejszy cień (elevation 8, black54)
i cienki obrys dla kontrastu z tłem.
Stan toolbaru pozostaje zachowany przy przełączaniu dokumentów. Pionowy separator uchwytu ma 1 px i leży na jego prawej krawędzi.

- 16: `LibraryScreen`; 23: `_LibraryScreenState`;
  545: `_LibraryTreePane`; 772: `_FolderTreeRow`;
  882: `_LibraryTreeItemRow`; 973: `_LibraryWorkspace`;
  1039: `_LeftZoneToggleTab` — poziome strzałki folderów i toolbaru.

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

### `lib/features/editor/state/editor_controller.dart` (2900 linii)

Centralny `ChangeNotifier`: strony, narzędzia, undo/redo, zaznaczenie, media,
preferencje, viewport i zapis. Dostaje już znormalizowany ink z repozytorium;
`addInkStroke` odrzuca próbę zapisania narzędzia gumki jako stroke'a.
Rejestruje się w `AppSaveCoordinator`;
`flushPendingSaves` commit'uje aktywną edycję tekstu, anuluje debounce,
czeka na istniejące zapisy repozytorium i wymusza zapis dirty stron przed
zgodą na zamknięcie aplikacji. Nowo wstawiony lub wklejony tekst i obraz
przechodzą od razu do trybu `edit` i pozostają aktywne do transformacji;
wklejone zaznaczenie zachowuje lasso w trybie `edit`. Obrazy pozostają pod
tuszem i tekstem; wybór narzędzia ink lub tekstu dezaktywuje aktywny obraz.
`isObjectTransformActive` blokuje zmianę viewportu na czas move/resize ramki.

- 36: `LassoSelection`; 75: `EditorController`; 2359: `addInkStroke`;
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

### `lib/features/editor/presentation/editor_screen.dart` (2251 linii)

Wielostronicowy edytor notebooka: nagłówek notesu ma 18 px;
toolbar i pasek tekstowy są nakładkami `Stack` nad pełnowymiarowym
canvasem, zamiast zajmować jego wysokość. `showToolbar` steruje
widocznością nakładek. Początkowe 72 px odsunięcia strony realizuje
`_pagePan` wewnątrz viewportu, zamiast dodatkowego paddingu przewijania.
Viewport pozostaje 22 px od górnej krawędzi canvasa, więc strona nie jest
ucinana przez pusty pas, gdy użytkownik wsuwa ją pod toolbar.
Rozszerzony zakres pionowego pan pozwala również przesuwać stronę niżej.
Granice widoczności i wybór aktywnej strony uwzględniają przesunięcie.
Wysokość klipu i przewijanej zawartości rośnie wraz z dodatnim `_pagePan.dy`,
aby dolna część ostatniej strony nie została ucięta. Strona jest domyślnie
centrowana poziomo wewnątrz obszaru między minimapą i prawym marginesem;
po ręcznym przesunięciu lub zoomie jej pozycja X nie jest resetowana
przy przebudowie widoku.
`AppBar` ma wyłączoną zmianę wysokości cienia i tint podczas scrollowania.
Minimapa i wskaźnik zoomu zachowują odstęp od widocznych pasków,
a wysokość minimapy jest ograniczona dostępnej przestrzeni.
Viewport obejmujący overview i strony notesu ma tło #E6E6E6;
nagłówek, toolbary i panel folderów używają zwykłego tła motywu. Viewport, wirtualizowane strony, canvasy, minimapa,
wspólne komendy edytora. Strona zachowuje logiczną
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

- 33: `EditorScreen`; 42: `_EditorScreenState`.
- 43: `_logicalPageWidth`; 91: `_effectivePageScale` — skala okna pomnożona
  przez zoom użytkownika.
- 209–630: gesty pan/zoom, blokada viewportu i transformacje.
- 802–888: busy overlay, import/eksport i clipboard.
- 1007: `_buildTransformedDocumentLayer` rozkłada warstwy w logicznym
  rozmiarze 820 px przed skalowaniem, żeby viewport nie obcinał prawej
  krawędzi.
- 980: główny `build`; pasek tekstu jest renderowany na podstawie
  aktywnego `TextBlock`, niezależnie od starego `QuillController`; wspólna
  macierz `pageTransform` skaluje dokument.
- 1463: `_PageViewportClipper`; 1521: `_PageFramePainter`;
  minimapa zaczyna się przy 1624 i renderuje wyłącznie zwykły ink.

### `lib/features/editor/presentation/editor_commands.dart` (170 linii)

Komendy importu, kopiowania i eksportu; przy starcie zadania zapisu
przekazują aktualny `Theme.brightness` do wspólnego renderera PDF/PNG.

### `lib/features/editor/presentation/editor_settings_screen.dart` (618 linii)

Ustawienia wejścia, dwuczłonowy selektor `Light` / `Dark` w Visual:
wybór używa beżowych odcieni `divider`/`toolbar` w jasnym motywie
oraz `darkActive`/`darkToolbar` w ciemnym. Zaznaczona opcja ma
mocniejszą ramkę, bez czarnego lub białego tła. Pozostałe sekcje
obsługują ustawienia tła i podgląd logów diagnostycznych.

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
- `lib/features/editor/presentation/widgets/page_background_paint.dart` (131):
  render tła i kratki w bieżącym trybie wizualnym, także na ciemniejszej
  kartce #50514D. 6: `PageBackgroundPaint`;
  36: `PageBackgroundPreview`; 64: `_PageBackgroundPainter`.
- `lib/features/editor/presentation/widgets/editor_toolbar.dart` (926):
  główny toolbar narzędzi, kolorów, gumek, kształtów, tła i eksportu;
  całość ma kształt kapsułki i pośrodku obszaru zwęża się do szerokości
  ikon, gdy mieszczą się w całości; przy braku miejsca przewija się poziomo.
  Zewnętrzne marginesy wynoszą po 52 px, wewnętrzne boczne po 22 px,
  a pionowy padding 3 px; przycisk zwijania pozostaje dostępny;
  ikony pobierają kontrast z motywu, próbki szarości pokazują ich
  aktualny kolor wyświetlania, a styl pozostaje lekki i obrysowy.
  Lasso używa gotowej ikony Material `highlight_alt_outlined`, która
  przedstawia zaznaczanie obszaru kursorem.
  10: `EditorToolbar`; 190: dialog tła; 344: selektor gumki;
  412: selektor kształtu; 819: `_EraserIcon`.
- `lib/features/editor/presentation/widgets/text_edit_toolbar.dart` (583):
  pasek formatowania aktywnego `TextBlock` współpracujący bezpośrednio z
  `EditableText`. Obsługuje realne formatowanie całego bloku: bold, italic,
  underline, strike, font, rozmiar, kolor, wyrównanie, reset stylu i usunięcie.
  Listy oraz formatowanie tylko zaznaczonego fragmentu są celowo pominięte,
  ponieważ obecny `EditableText` nie renderuje ich jako rich-text.
  Pasek używa takiej samej kapsułki: zwęża się do zawartości,
  pozostaje wycentrowany i przewija poziomo na wąskich ekranach.
  Ma 52 px zewnętrznego i 22 px wewnętrznego marginesu bocznego
  oraz 2 px pionowego paddingu.
  9: `TextEditToolbar`; 43: `build`.

- `lib/features/editor/presentation/interaction/object_transform_engine.dart` (362):
  wspólny silnik move/resize dla obiektów nie-ink. Używa typów
  `HandlePosition` i `ResizeMode` z `flutter_box_transform`, ale po zmianach
  API 0.4.7 sam liczy geometrię logiczną, clamp i skalowanie, dzięki
  czemu działa niezależnie od zoomu dokumentu i nie dotyka stroke'ów.
  6: `ObjectTransformKind`; 8: `ObjectTransformSnapshot`;
  24: `ObjectTransformEngine`; 263: `_ObjectTransformSession`.
- `lib/features/editor/presentation/widgets/object_transform_hud.dart` (645):
  wspólna ramka transformacji dla tekstu i obrazów/PDF; używa gotowych
  `DefaultCornerHandle` i `DefaultSideHandle` z `flutter_box_transform`
  oraz wspólnego grabbera nad górną krawędzią do przesuwania obiektu.
  Grabber działa także wtedy, gdy środek ramki jest wyłączony z dragowania,
  np. podczas aktywnej edycji tekstu. Dedykowane uchwyty używają surowych
  pointer events zamiast rozpoznawania pan, więc reagują od pierwszego ruchu
  bez systemowego touch slop. Niewidzialny hit-area skaluje się liniowo z
  rozmiarem ramki przez sqrt(width*height), z zakresem 32–80 px. Górne
  uchwyty resize oraz uchwyt move mają rozdzielone strefy dotyku dokładnie
  w połowie odstępu między górną krawędzią a grabberem, niezależnie od
  rozmiaru ramki. Interaktywny obrót i przycisk rotate są usunięte,
  a zapisane historycznie kąty pozostają odczytywane.
  Udostępnia callbacki startu i końca transformacji, dzięki którym warstwa
  obiektu blokuje viewport dokładnie na czas move/resize; dispose aktywnego
  HUD-u również zwalnia blokadę. Kolor, rozmiary i grubość ramki są
  konfigurowalne przez `ObjectTransformHudStyle`.
  13: `ObjectTransformHudStyle`; 54: `ObjectTransformHud`;
  106: `_ObjectTransformHudState`; 591: `_ObjectTransformFramePainter`.
- `lib/features/editor/presentation/widgets/text_hud_block.dart` (533):
  aktywny `TextBlock` renderowany przez Flutter `EditableText`; ramka,
  move/resize/scale są delegowane do wspólnego `ObjectTransformHud`; obrót
  jest wyłączony. Podczas edycji treści uchwyty resize i osobny grabber move
  pozostają aktywne, a środek ramki przepuszcza gesty do `EditableText`.
  Start transformacji zapisuje najnowszą treść, włącza blokadę viewportu
  i używa tej treści jako snapshotu resize, więc zmiana rozmiaru ani anulowanie
  gestu nie przywracają starszego tekstu. Kolor aktywnego tekstu jest
  wyznaczany z pierwszego formatowanego fragmentu Delta (lub bloku),
  a jego jasność odwracana w dark mode. Nieaktywne teksty używają
  starego Quilla jako fallback.

### `lib/features/editor/presentation/widgets/drawing_canvas.dart` (4190 linii)

Dwa świadomie osobne canvasy ink, wspólna geometria rozpoznawania gestów,
lasso, handoff aktywnej kreski i pomiary wydajności. Wszystkie modyfikacje
gumki, włącznie ze scratch erase, delegują dane do jednego
`InkEraserEngine`. Canvas nie ma już drugiego silnika cięcia, zapisanego
`BlendMode.clear` ani martwego stanu kursora gumki. Tymczasowy podgląd
brush/area istnieje tylko podczas aktywnego gestu. Lasso oraz gumka
zakresowa mają wspólny podgląd przerywanego konturu przez `path_drawing`,
bez zmiany danych wejściowych używanych przez selekcję i eraser.
Notebookowe operacje
zmieniające ink zawsze czytają bieżący stan z `EditorController.pageAt(...)`.
Statyczne i aktywne kreski oraz podgląd zapisu renderują kontrastowe
szarości w trybie ciemnym bez zmian modelu. Podczas rysowania
pen/highlighter overlay stosuje ten sam LOD co zapisany
tusz, a ścieżki pióra i markera są wygładzane od trzeciego punktu.

- 45: `_InkPerfLog`; geometria rozpoznawania scratch pozostaje przed
  deklaracjami canvasów, ale hit-test i cięcie są w `InkEraserEngine`.
- 658: `DrawingCanvas`; 680: `DocumentDrawingCanvas`.
- 897: `_DrawingCanvasState`; 2241: `_DocumentDrawingCanvasState`.
- 3783: `_InkPainter`; 3843: `_InkOverlayPainter`;
  4088: `_InkPageLayer`; 4135: `_PageInkPainter`.

- `lib/features/editor/presentation/widgets/selection_outline.dart` (32):
  wspólny painter przerywanego konturu dla lassa i gumki zakresowej;
  `dashPath` kompensuje skalę viewportu i nie zmienia źródłowej ścieżki.
  11: `dashedSelectionOutline`; 22: `paintSelectionOutline`.

### `lib/features/editor/presentation/widgets/page_overlay.dart` (2892 linie)

Interaktywna warstwa tekstu, obrazów i lassa nad ink; osobne warianty boarda
i dokumentu. Aktywny blok tekstu przechodzi do `TextHudBlock`: `EditableText`
oraz wspólny `ObjectTransformHud` dla move/resize/scale. Nieaktywne teksty
korzystają z Quilla; w dark mode dostają osobną, wyłącznie odczytową kopię
Delta z odwróconymi kolorami wszystkich fragmentów tekstu. Oryginalny
`QuillController` i zapisane Delta pozostają bez zmian. Aktywne obrazy/PDF
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
- 1420: `_ImageBlockWidget`; 1443: `_ImageBlockWidgetState`.
- 2439: `_editOcr`; 2513: `_OcrTextDialog`;
  2612: `_LassoSelectionWidget`; 2766: `_LassoActionButton`.

## 9. Board

### `lib/features/board/presentation/board_screen.dart` (885 linii)

Jednostronicowa, swobodna tablica z pan/zoom, wspólnym kontrolerem i
warstwami tła/canvasu/overlayu; podczas aktywnej transformacji obiektu
ignoruje pointery nawigacyjne, trackpad i scroll, a kontroler blokuje zmianę
`viewPan/viewScale`. `BoardSceneBoundsResolver` zamraża prostokąt sceny
podczas move/resize, aby zmiany `contentBounds` nie przesuwały lokalnego
układu współrzędnych. Po zakończeniu gestu granice odświeżają się.
Pasek tekstu jest wiązany z aktywnym `TextBlock`, a nie ze starym
`QuillController`. Główny toolbar i pasek tekstu respektują `showToolbar`
i unoszą się na nakładce nad canvasem, zamiast zmniejszać jego wysokość.
Board ma stały boczny odstęp 16 px, ale nie ma marginesu u góry,
więc zawartość można swobodnie przesuwać za toolbar. Nagłówek ma
wyłączony tint podczas przewijania. Panele dziedziczą aktywną paletę.

- 28: `BoardScreen`; 37: `_BoardScreenState`.
- 59: `_buildBoardRect`; 67–388: obsługa pointerów i viewportu.
- 499: główny `build`; import/eksport i skróty przez `EditorCommands`.
- 742: `BoardSceneBoundsResolver` — stabilne granice sceny podczas gestu.
- 778: `_BoardPaintProbe`; 795: `_RenderBoardPaintProbe`;
  818: `_BoardZoomControls`.

## 10. Platformy, web i testy

- `ios/Podfile`: zależności CocoaPods dla pluginów bez obsługi SwiftPM;
  deklaracja iOS 15 i targetów Runner/RunnerTests. W CI iOS wyłącza SwiftPM,
  wykonuje `pod install` i sprawdza obecność Pods w `Runner.xcworkspace`;
  wymaga potwierdzenia w buildzie symulatora.
- `ios/Flutter/Debug.xcconfig`, `Release.xcconfig`: dziedziczą config
  Pods-Runner, aby linker znajdował framework CocoaPods podczas buildów.

- `windows/CMakeLists.txt`: zgodność generatora pdfx/pdfium z CMake 4; przed
  włączeniem pluginów ustawia `CMAKE_POLICY_VERSION_MINIMUM=3.5` dla
  potomnych procesów CMake, bez obniżania wersji dla reszty projektu.
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

- `test/notebook_repository_test.dart` (1141): zapis, migracja legacy gumek, ochrona danych i
  migracja v1→v2 usuwająca dane Index tab bez utraty stron.
- `test/local_backup_service_test.dart` (1337)
- `test/editor_save_flush_test.dart` (63): wymuszenie dirty page save przed
  zamknięciem.
- `test/editor_controller_layering_test.dart` (77): aktywne obrazy są
  dezaktywowane po wyborze narzędzia ink lub tekstu, a nowy tekst startuje
  zaznaczony w trybie edit.
- `test/backup_eraser_flattening_test.dart` (109)
- `test/cloud_sync_service_test.dart` (84)
- `test/library_controller_test.dart` (33)
- `test/library_screen_responsive_layout_test.dart` (326):
  szeroki układ, drzewo folderów i przełączanie widoczności toolbaru
  boarda/notebooka z kontrolką pod strzałką panelu; regresja pionowego
  centrowania i szerokości strzałek, cienia/obrysu i kierunku zwijania;
  wyśrodkowanie, zwężanie kapsułek, wysokość, odstępy boczne
  oraz przewijanie na wąskim ekranie
- `test/ink_activity_tracker_test.dart` (25): exit guard czeka na koniec
  aktywnego kontaktu rysika.
- `test/ink_spatial_index_test.dart` (49)
- `test/ink_eraser_engine_test.dart` (244): zwykła gumka, scratch erase,
  erase-stroke/area hit-test, migracja legacy gumek, pojedyncze punkty,
  kolizje ID i undo
- `test/ink_render_benchmark_test.dart` (220)
- `test/selection_outline_test.dart`: przerywane kontury otwarte i zamknięte,
  brak mutacji źródła oraz zgodność rozmiaru segmentów z zoomem
- `test/editor_screen_responsive_layout_test.dart` (346):
  pełna wysokość canvasa pod pływającym toolbarem, położenie strony
  poniżej narzędzi i domyślne centrowanie poziome z zachowaniem ręcznego
  pan, wsuwanie strony pod pasek bez maskującego marginesu,
  rozszerzenie dolnej granicy klipu, stabilny kolor `AppBar`,
  minimapa na krótkim ekranie i interaktywność narzędzi
- `test/page_overlay_text_gestures_test.dart` (432): blokowy toolbar
  tekstu, układ uchwytów i odwracanie kolorów starych bloków rich text
  w jasnym/ciemnym motywie bez modyfikowania zapisanych Delta,
  blokadę viewportu oraz brak zmian pan/zoom kontrolera podczas resize;
  dodatkowo rozdział stref dotyku uchwytów dla różnych rozmiarów ramek;
  tryb tekstu ignoruje obrazy pod kursorem, a resize nie gubi zmian
- `test/board_scene_bounds_test.dart` (153): stały układ współrzędnych
  boarda podczas resize/move, pełna wysokość canvasa pod toolbarem,
  zachowanie viewportu po schowaniu narzędzi i kolor nagłówka.
- `test/object_transform_engine_test.dart` (67): wspólna geometria
  move, corner-scale, side-resize i zachowanie historycznych kątów
- `test/resizable_frame_test.dart` (33)
- `test/widget_test.dart` (20)
- `test/dark_mode_theme_test.dart` (219): paleta dark, odwracanie jasności
  wszystkich barw HSL, alfa, zachowanie odcieni i przełącznik Visual.


Dodatkowe testy i automatyzacja wieloplatformowa:

- `test/cross_platform/regression_test.dart`: powtarzalne wymazywanie,
  brak powracających kresek, niezmienność migracji legacy, indeks przestrzenny,
  cofnięcie/anulowanie transformacji oraz trwałe preferencje tła.
- `test/cross_platform/save_and_exit_test.dart`: opróżnianie kolejki
  edytorów, błędy flush i wiele aktywnych kontaktów rysika.
- `test/cross_platform/object_transform_hit_zones_test.dart`: granica
  niewidzialnych stref resize/move dla małych i dużych ramek, obsługa touch
  i stylus oraz anulowanie gestu.
- `test/critical_editor_regressions_test.dart`: erase → lasso → save →
  reload, sekwencje undo/redo gumki i zamrożenie viewportu.
- `test/cloud_sync_service_test.dart`: dodatkowe konflikty czasów i ID.
- `test/cross_platform/eraser_stress_test.dart`: deterministyczne sekwencje
  gumki z kontrolą unikalności i niepowracania raz usuniętych ID.
- `test/library_controller_lifecycle_test.dart`: dispose podczas
  asynchronicznego ładowania biblioteki.
- `integration_test/app_smoke_test.dart`: start rzeczywistej aplikacji
  i inicjalizacja platformy bez utknięcia na ekranie ładowania.
- `integration_test/document_lifecycle_test.dart`: create/rename/read/delete
  w rzeczywistej bazie danej platformy; działa wyłącznie z flagą
  `NANOTATECZKI_ISOLATED_CI=true` na izolowanym runnerze.
- `test/production/persistence_roundtrip_test.dart`: rich text z Delta,
  crop i bytes obrazów, dwie strony, dirty-page, równoległe zapisy, backup
  i przywrócenie do nowego SQLite; każdy test ma własny katalog dokumentów
  i fake `PathProviderPlatform`, bez zapisu do danych użytkownika. Test
  restore zamyka źródłowy `NotesDatabase` przed otwarciem docelowego,
  aby nie utrzymywać dwóch instancji Drift w tym samym isolate.
- `test/production/export_render_test.dart` (308): produkcyjne PNG/PDF
  w pamięci, liczba stron i rozmiar obrazu, treść oraz legacy gumka.
  Renderer działa w `tester.runAsync`, poza `FakeAsync` testu widgetowego.
  Regresje obejmują 12 stron, eksport boarda i piksele tej samej zapisanej
  notatki w trybie jasnym i ciemnym, łącznie z oboma wariantami PDF.
- `android/app/build.gradle.kts` i `android/app/proguard-rules.pro`:
  Release uruchamia R8 z wyjątkami wyłącznie dla opcjonalnych modułów
  ML Kit (Chinese/Devanagari/Japanese/Korean). OCR używa tylko
  `TextRecognitionScript.latin`; nie dodawaj nieużywanych modeli
  ani nie wyłączaj shrinkingu dla całej aplikacji.
- `.github/scripts/android_emulator_tests.sh`: czeka na `adb` i
  `sys.boot_completed`, następnie uruchamia obydwa testy integracyjne.
  Runner emulatora wywołuje pojedynczą komendę Bash, zamiast interpretować
  instrukcje pętli oddzielnie przez `/bin/sh`.
- `.github/workflows/cross_platform_tests.yml`: CI na Linux, Windows, macOS,
  Chrome, Android oraz symulatorach iPhone i iPad, na push `dev`.
  Eksport PNG/PDF jest osobnym jobem z własnym timeoutem; pozostałe testy
  generują niezależny raport pokrycia z progiem początkowym 35%.
  Nieblokujący job Wasm sprawdza kompilację `flutter build web --wasm`,
  oddzielnie od działającego JS web. Android kompiluje APK Debug i Release,
  a jego emulator uruchamia dedykowany skrypt Bash.
  Windows lifecycle używa jednej linii PowerShell, a iOS jawnie instaluje
  CocoaPods i weryfikuje workspace; buduje zarówno symulator, jak i
  niepodpisany wariant Release na urządzenie. Desktop Release uruchamia się
  również po niepowodzeniu testu uruchomienia. Harmonogram i manualny
  trigger wymagają workflow na domyślnym `main`.
- `docs/TEST_MATRIX.md`: plan testów, wymagania urządzeń i niedomknięte
  scenariusze, których CI jeszcze nie pokrywa.

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
9. `DrawingTool.eraser*` pozostają w enumie wyłącznie dla zgodności indeksów
   i wyboru narzędzia. Eraser nie może być zapisanym `InkStroke`; runtime
   kasuje destrukcyjnie, a legacy maski wolno interpretować tylko w
   `InkEraserEngine` podczas normalizacji.

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
