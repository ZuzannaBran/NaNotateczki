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
    ├── planner/                 sesje nauki i kalendarz
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

### `lib/app/app_scope.dart` (632 linie)

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

- Dostarcza również singleton `StudyPlannerController` (Provider),
  niezależny od migracji bazy notatek.
- 25: `AppScope`; 32: `_AppScopeState`; 74: `didRequestAppExit`.
- 232: `_ExitGuardOverlay`; 255: `_FinishingExitOverlay`;
  363: `_BackupScheduler`;
  559: `flushForExit`.

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
- `lib/core/theme/app_theme.dart` (114): `AppTheme.light` i `AppTheme.dark`
  z kontrastowymi kontrolkami i nagłówkami. 5: `AppTheme`.

### Wejście i preferencje

- `lib/core/input/app_preferences_controller.dart` (190):
  tryb urządzenia, akcent, `darkMode` i czułość dotyku
  `touchNavigationSensitivity` (0.5–2.0; domyślnie 1.0) w `app_prefs.json`.
  Podgląd suwaka działa bez ciągłego zapisu na dysk, a puszczenie
  suwaka utrwala ustawienie; brak klucza zachowuje dotychczasowe 1.0;
  starsze Classic, Sakura i Mint są migrowane do nowego Bubblegum.
  Dotychczasowy zapis `bubblegum` zachowuje stary wybór jako Cherry.
  8: `DeviceInputMode`;
  27:
  `AppPreferencesController`.
- `lib/core/input/touch_navigation_scroll_physics.dart` (24):
  mnożnik dystansu scrolla i próg startu drag listy plików i stron,
  bez ingerencji w rysowanie czy transformację obiektów.
  4: `TouchNavigationScrollPhysics`.
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

### `lib/data/export/notebook_export_service.dart` (764 linie)

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
  64: `exportNotebook`; publiczne metody `renderPngPagesForTest` i
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
- `lib/features/notebook/domain/ink_eraser_engine.dart` (836):
  jedyny silnik modyfikacji gumki dla boarda i notebooka. Obsługuje zwykłą
  gumkę, erase-stroke, gumkę zakresową (przycinanie fragmentów)
  oraz scratch erase. Legacy maski są tu wyłącznie jednorazowo
  normalizowane do zwykłego ink; generator fragmentów unika
  kolizji ID i obsługuje też pojedyncze punkty.
  34: `InkEraserEngine`; 37: `normalizePage`; 42: `normalizeNotebook`;
  107: `scratchInkHitCount`; 129: `eraseScratchParts`;
  169: `eraseAreaParts` — przycinanie na krawędziach wielokąta;
  215: `flattenLegacyErasers`.
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

### `lib/features/notebook/presentation/notebook_screen.dart` (34 linie)

Wybiera pusty stan albo właściwy `EditorScreen`; przekazuje flagę
widoczności wspólnego paska narzędzi i `showCompactTimer`, sterujące
wyświetlaniem `CompactStudyTimer` w nagłówku edytora.

- 8: `NotebookScreen`.

## 6. Biblioteka

### `lib/features/library/presentation/library_controller.dart` (738 linii)

Stan folderów, listy dokumentów, wyszukiwania, syncu, importu i recovery.
Zapisuje kształt i indywidualny kolor ikony okładki folderu w zgodnym wstecznie
`library_folders.json` (legacy lista nazw lub nowy obiekt z `folders` i
`covers`); nie zmienia schematu SQLite. Wybór dokumentu synchronizuje
też aktywny folder, dzięki czemu drzewko biblioteki zaznacza folder i notatkę
jednocześnie. Asynchroniczny start
nie powiadamia słuchaczy po usunięciu kontrolera. Zapis samych folderów
zgłasza pusty zestaw zmian repozytorium, więc aktualizuje manifest bez
oznaczania notebooków jako dirty. Sprzątanie osieroconych obrazów działa
tylko przy normalnym starcie istniejącej, zdrowej bazy.

- 15: `FolderCoverShape`; 17: `FolderCoverStyle`; 48: `LibraryController`.
- 121: `initialize`; 136: `loadItems`.
- 318: `updateFolderCover`; 330–470: foldery i dokumenty.
- 504: `selectFolder`; 615: `_loadFolders`; 654: `_saveFolders`
  — zapis folderów zgłasza pusty zestaw zmian.

### `lib/features/library/presentation/library_screen.dart` (1550 linii)

Jednopanelowy sidebar biblioteki w formie drzewa obok pełnego widoku
katalogów: start aplikacji pokazuje kafelki folderów, przycisk `Projects`
wraca do katalogów, kliknięcie folderu otwiera siatkę podglądów dokumentów,
a wybór dokumentu uruchamia edytor. Powrót z edytora wymusza flush
niezapisanych zmian przed ponownym wczytaniem miniatur. Lista folderów
i plików wykorzystuje ustawioną czułość dotyku. Folder i aktywny dokument
mają miękkie, zaokrąglone zaznaczenie; sidebar używa kompaktowej typografii
Georgia i jasnej neutralnej powierzchni panelu. Panel można zwijać i zmieniać
jego szerokość.

U dołu panelu jest `StudyTimerCard`, wyrównany do dolnej krawędzi
i przewijany przy większej zawartości. Po zwinięciu panelu
`CompactStudyTimer` wyświetla się obok Settings w AppBar katalogu,
notebooka lub boarda. `_openCatalogSettings` otwiera wspólne ustawienia
na kontrolerze wybranego albo pierwszego dokumentu; w pustej bibliotece
udostępnia ustawienia globalne bez tworzenia dokumentu. Przewijanie timera
również reaguje na wspólną czułość dotyku.
Pod strzałką panelu folderów jest drugi przycisk zwijania wspólnego paska
narzędzi; oba są pionowo wyśrodkowane we własnych obszarach, mają 24 px
szerokości, 44 px wysokości, cień i obrys. Stan toolbaru pozostaje zachowany
przy przełączaniu dokumentów.

Menu trzech kropek folderów, notebooków i boardów (130 px) oraz menu
dodawania przez `+` (150 px) używają wspólnej pozycji przy prawej krawędzi
całego sidebaru (włącznie z 12 px uchwytem resize), jego koloru i animacji
180 ms. Lewe narożniki mają jawny promień zero, a wyłącznie prawe
promień 12 px. Menu styka się z panelem bez szczeliny: obie strony
styku są bez cienia i bez 1 px kreski uchwytu resize. Menu ma elevation 0,
a osobny dekoracyjny cień o alpha 0x44 jest przycięty do prawej strony;
2 px łącznik koloru panelu maskuje linię graniczną. Menu folderu zawiera także
edycję okładki; etykiety mają rozmiar 14 px, a opcje dodawania nie mają ikon.

- 23: `LibraryScreen`; 30: `_LibraryScreenState`;
  438: `_openCatalogSettings`;
  773: `_CreateMenuButton`;
  816: `_LibraryTreePane`;
  1047: `_FolderTreeRow`;
  1141: `_LibraryTreeItemRow`;
  1213: `_sidebarMenuShape`;
  1227: `_SidebarMenuShadowPainter`;
  1268: `_showSidebarMenu`;
  1350: `_TreeRowActions`;
  1424: `_LibraryWorkspace`;
  1498: `_LeftZoneToggleTab`.

### `lib/features/library/presentation/library_catalog.dart` (725 linii)

Kafelkowa strona główna folderów oraz siatka podglądów zawartości folderu.
AppBar pokazuje nazwę biblioteki/folderu, Settings i opcjonalny
`CompactStudyTimer`; folder ma też akcję edycji okładki.
Okładka ma automatycznie rozjaśniony dominujący kolor ink/tekstu we wszystkich
stronach dokumentów folderu; kształt i kolor ikony można zmieniać w dialogu.
Domyślna okładka używa takiej samej obrysowanej ikony folderu jak sidebar.
Dialog pozwala również wybrać dowolny kolor przez `EditorToolbar.pickColor`,
wspólny selektor notebooka z HEX i suwakami RGB/B-W.
`_CatalogTile` umieszcza nazwę i menu kafelka nad miniaturą.
Notatki mają pionowy podgląd pierwszej strony (820×1160), boardy kwadratowy
podgląd dopasowany do granic obiektów z pierwszej strony. Miniatury rysują
ink, tekst oraz dostępne obrazy bez uruchamiania edytora.
Katalog i okładki respektują motyw; miniatury odwracają kolory ink/tekstu
tylko przy renderowaniu, bez zmiany danych. Zmiana motywu wymusza repaint.
Siatka reaguje na wspólną czułość dotyku.

- 21: `dominantFolderColor`; 58: `LibraryCatalog`;
  248: `_FolderTile`; 321: `_DocumentTile`; 361: `_CatalogTile`;
  422: `_DocumentPreview`; 505: `_boardPreviewBounds`;
  547: `_PagePreviewPainter`; 619: `showFolderCoverEditor`.

### `lib/features/library/presentation/widgets/library_item_card.dart` (132 linie)

Karta notebooka/boarda z menu zmiany nazwy i usuwania.

- 8: `LibraryItemCard`; 110: `_ItemKindIcon`.

## 6a. Planer nauki (bez migracji SQLite)

- `lib/features/planner/state/study_planner_controller.dart` (537):
  `StudySession`, `StudyTechnique`, `StudyStatus`, `StudyPlannerController`.
  Jeden stan Provider + ChangeNotifier, trwały `study_planner.json` przez
  cross-platform `text_storage`. Timery liczone względem deadline,
  odtwarzanie po restarcie, Pomodoro 25/5, Focus 50/10, Deep 90/20,
  jednorazowa ocena 1–5 gwiazdek i zapis chroniony przez
  `AppSaveCoordinator`. Pominięta ocena zamyka sesję i zapisuje ją
  bez oceny w historii (także po ponownym uruchomieniu); starsze sesje
  pozostawione w stanie review są przenoszone do historii bez ponagleń.
  Powiadomienia tylko wewnątrz działającej aplikacji.
  Wynik wczytywania po dispose jest ignorowany: bez powiadomienia, timera
  ani zapisu odzyskanej historii.
  10: `StudyTechnique`; 42: `StudyStatus`; 46: `StudySession`;
  152: `StudyPlannerController`; 232: `load`; 298: `create`;
  366: `start`; 528: `flush`.
- `lib/features/planner/presentation/study_timer_widgets.dart` (568):
  `StudyTimerCard`, `CompactStudyTimer`, dialog edycji i gwiazdkowej oceny
  sesji, funkcja `studyRatingStars`; zamknięcie dialogu traktowane jako
  pominięcie oceny, bez przycisku „Rate” w bocznym timerze.
  Motyw obejmuje także kompaktowy timer, a formularz sesji korzysta
  ze wspólnej czułości przewijania.
  24: `studyRatingStars`; 31: `openStudyPlanner`;
  37: `showStudySessionEditor`; 57: `showStudyRating`;
  341: `StudyTimerCard`; 520: `CompactStudyTimer`.
- `lib/features/planner/presentation/study_action_theme.dart` (96):
  `StudyActionTheme`, `StudyActionStyles`; czytelny, ale subtelny beż
  tylko dla wyróżnianych akcji; pozostałe przyciski i ikony bez ciemnego
  wypełnienia w jasnym motywie. Tryb ciemny używa globalnej palety,
  kontrolki zachowują typografię aplikacji. `primary(ThemeData)` zależy
  od bieżącego motywu. 6: `StudyActionStyles`; 39: `StudyActionTheme`.
- `lib/features/planner/presentation/planner_screen.dart` (759):
  `PlannerScreen` – pełnoekranowe Today/Week/Month, drag/drop między dniami,
  tworzenie, edycja, usuwanie i historia. Nazwa dnia tygodnia znajduje się
  w każdej komórce kalendarza: pełna w Today, skrócona w Week/Month.
  Dostęp do globalnych ustawień i wspólnej czułości scrolla kalendarza
  oraz historii. 13: `CalendarMode`; 15: `PlannerScreen`;
  22: `_PlannerScreenState`.
- `test/study_planner_controller_test.dart`: zapis, resume, pauza, konflikt
  timerów, Pomodoro, ocena, pominięcie oceny, recovery dawnych review
  i ochrona uszkodzonych danych; sukces/błąd wczytywania po dispose.
- `test/study_planner_widget_test.dart`: kalendarz, timer, wybór gwiazdek,
  pominięcie i zamknięcie oceny, historia oceniona i bez oceny.
- `test/study_planner_calendar_weekday_test.dart`: komplet nazw dni
  tygodnia we wszystkich widokach i po zmianie daty; osobny krok CI.
- `test/study_planner_button_contrast_test.dart`: regresja widoczności
  aktywnych przycisków i wyraźnych stanów wybranego widoku kalendarza;
  typografia kontrolek w obu motywach.

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
  formatowanie aktywnego tekstu, opcjonalnie po zachowanym ID,
  zapisywane jako `UpdateTextAction`.
- 2684: `_applyAction`; 2693: `_applyInkAction`;
  2795: `_scheduleSave`; 2816: `_saveDirtyPages`; 2838: `_save`.

## 8. UI edytora

### `lib/features/editor/presentation/editor_screen.dart` (2395 linii)

Wielostronicowy edytor notebooka: nagłówek notesu ma 18 px;
toolbar i pasek tekstowy są nakładkami `Stack` nad pełnowymiarowym
canvasem, zamiast zajmować jego wysokość. `showToolbar` steruje
widocznością nakładek. Początkowe 72 px odsunięcia strony realizuje
`_pagePan` wewnątrz viewportu, zamiast dodatkowego paddingu przewijania.
`showCompactTimer` pokazuje `CompactStudyTimer` w nagłówku przy zwiniętym
panelu biblioteki.
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
Gesty pan palcem oraz przewijanie stron i minimapy respektują czułość
nawigacji; zoom i gesty narzędzi pozostają bez zmian.
Po zakończeniu transformacji normalna nawigacja wraca. Stronę można przesuwać
poziomo dotykiem także wtedy, gdy jest węższa od viewportu; clamp pozwala jej
dojść od lewej do prawej granicy pasa, ale nigdy wejść pod margines. Bleed
pozostaje tylko pionowo. Overview przyjmuje kliknięcia poprzez Listener
na obszarze widocznym niezależnie od gestów scrolla minimapy; przenosi
widok do wskazanego fragmentu notatnika przy aktualnym powiększeniu
z uwzględnieniem scrolla minimapy, paddingu, pan i granic przesunięć.
Gest przeciągnięcia nadal przewija samą minimapę, a blokada transformacji
obiektu ignoruje wybór. Programowy scroll nie nadpisuje aktywnej strony.

- 37: `EditorScreen`; 51: `_EditorScreenState`.
- 52: `_logicalPageWidth`; 99: `_effectivePageScale` — skala okna pomnożona
  przez zoom użytkownika.
- 149: synchronizacja strony; 180: nawigacja do klikniętego obszaru.
- 275–694: gesty pan/zoom, blokada viewportu i transformacje.
- 866–896: busy overlay, komendy importu/eksportu i clipboard oraz ustawienia.
- 1017: `_buildTransformedDocumentLayer` rozkłada warstwy w logicznym
  rozmiarze 820 px przed skalowaniem, żeby viewport nie obcinał prawej
  krawędzi.
- 1043: główny `build`; pasek tekstu jest renderowany na podstawie
  aktywnego `TextBlock`, niezależnie od starego `QuillController`; wspólna
  macierz `pageTransform` skaluje dokument.
- 1541: `_PageViewportClipper`; 1599: `_PageFramePainter`;
  1706: `_ProjectMiniMapOverlay`; 1999: Listener kliknięć minimapy;
  2125: `_ProjectMiniMapPainter` renderuje wyłącznie zwykły ink.

### `lib/features/editor/presentation/editor_commands.dart` (170 linii)

Komendy importu, kopiowania i eksportu; przy starcie zadania zapisu
przekazują aktualny `Theme.brightness` do wspólnego renderera PDF/PNG.

### `lib/features/editor/presentation/editor_settings_screen.dart` (674 linii)

Ustawienia wejścia, dwuczłonowy selektor `Light` / `Dark` w Visual:
wybór używa beżowych odcieni `divider`/`toolbar` w jasnym motywie
oraz `darkActive`/`darkToolbar` w ciemnym. Zaznaczona opcja ma
mocniejszą ramkę, bez czarnego lub białego tła. Zakładka System
ma suwak czułości nawigacji 0.5×–2.0×. Pozostałe sekcje
obsługują ustawienia tła i podgląd logów diagnostycznych.
`EditorController` jest opcjonalny: ustawienia globalne działają z pustego
katalogu i planera; tła i ustawienia rysika wymagają otwartego dokumentu.

- 16:
  `EditorSettingsScreen`;
  356:
  `_showErrorsDialog`;
  438:
  `_showDataIntegrityDialog`;
  525:
  `_showOptimizationDialog`;
  611:
  `_BackgroundSection`.

### `lib/features/editor/presentation/interaction/notebook_overview_navigation.dart` (55 linii)

`NotebookOverviewNavigation` (5) mapuje lokalny punkt oraz scroll minimapy
na współrzędne dokumentu i wyznacza docelowy scroll/pan zachowujący zoom.
`NotebookOverviewTarget` (50) przechowuje wynik nawigacji.

### Widgety edytora

- `lib/features/editor/presentation/widgets/busy_overlay.dart` (18): blokujący
  spinner długiej operacji. 3: `BusyOverlay`.
- `lib/features/editor/presentation/widgets/page_background_paint.dart` (131):
  render tła i kratki w bieżącym trybie wizualnym, także na ciemniejszej
  kartce #50514D. 6: `PageBackgroundPaint`;
  36: `PageBackgroundPreview`; 64: `_PageBackgroundPainter`.
- `lib/features/editor/presentation/widgets/editor_toolbar.dart` (959):
  główny toolbar narzędzi, kolorów, gumek, kształtów, tła i eksportu;
  całość ma kształt kapsułki i pośrodku obszaru zwęża się do szerokości
  ikon, gdy mieszczą się w całości; przy braku miejsca przewija się poziomo.
  Zewnętrzne marginesy wynoszą po 52 px, wewnętrzne boczne po 22 px,
  a pionowy padding 3 px; przycisk zwijania pozostaje dostępny;
  ikony pobierają kontrast z motywu, próbki szarości pokazują ich
  aktualny kolor wyświetlania, a styl pozostaje lekki i obrysowy.
  Lasso używa gotowej ikony Material `highlight_alt_outlined`, która
  przedstawia zaznaczanie obszaru kursorem.
  Publiczny `EditorToolbar.pickColor` współdzieli pełny selektor HEX/RGB/B-W
  z edycją koloru ikon okładek folderów. W dark mode próbki Recent,
  podgląd, HEX oraz suwaki pracują na odwróconym kolorze widocznym,
  a przed zapisem wracają do wartości bazowej; wybór bez zmian jest bezstratny.
  Kontroler HEX jest zwalniany dopiero
  po zakończeniu animacji zamykania dialogu, także przy zagnieżdżonej edycji.
  10: `EditorToolbar`; 198: dialog tła; 337: selektor gumki;
  405: selektor kształtu; 573: `pickColor`; 852: `_EraserIcon`.
- `lib/features/editor/presentation/widgets/text_edit_toolbar.dart` (345):
  pasek formatowania aktywnego `TextBlock` współpracujący bezpośrednio z
  `EditableText`. Wybór koloru używa wspólnego dialogu narzędzi i zachowuje
  ID bloku przez czas jego otwarcia, nawet przy utracie aktywnego zaznaczenia. Obsługuje realne formatowanie całego bloku: bold, italic,
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
- `lib/features/editor/presentation/widgets/text_hud_block.dart` (530):
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

### `lib/features/editor/presentation/widgets/drawing_canvas.dart` (4201 linii)

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

- 46: `_InkPerfLog`; geometria rozpoznawania scratch pozostaje przed
  deklaracjami canvasów, ale hit-test i cięcie są w `InkEraserEngine`.
- 665: `DrawingCanvas`; 687: `DocumentDrawingCanvas`.
- 904: `_DrawingCanvasState`; 2250: `_DocumentDrawingCanvasState`.
- 3783: `_InkPainter`; 3843: `_InkOverlayPainter`;
  4087: `_InkPageLayer`; 4134: `_PageInkPainter`.

- `lib/features/editor/presentation/widgets/selection_outline.dart` (32):
  wspólny painter przerywanego konturu dla lassa i gumki zakresowej;
  `dashPath` kompensuje skalę viewportu i nie zmienia źródłowej ścieżki.
  11: `dashedSelectionOutline`; 22: `paintSelectionOutline`.

### `lib/features/editor/presentation/widgets/page_overlay.dart` (2891 linii)

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
W trybach rysunkowych (pióro, marker, gumki, kształty) overlay obiektów
nie uczestniczy w hit-teście; tekst oraz obrazy/PDF pozostają widoczne.
Lasso zachowuje swoje interakcje.
Operuje wyłącznie w logicznych współrzędnych strony/dokumentu; responsywną
skalę nadaje wspólny rodzic w `EditorScreen`, nie poszczególne bloki
overlayu. Pojedyncze wskazanie nieaktywnego Quilla jest stosowane po oknie
double tap, aby arena gestów Quilla zakończyła się przed podmianą widgetu na
`TextHudBlock`.

- 32: `PageOverlay`; 193: `DocumentPageOverlay`.
- aktywny tekst: `TextHudBlock`; fallback nieaktywnego tekstu:
  `_TextBlockWidget` / `_TextBlockWidgetState`.
- 1418: `_ImageBlockWidget`; 1441: `_ImageBlockWidgetState`.
- 2504: `_editOcr`; 2578: `_OcrTextDialog`;
  2677: `_LassoSelectionWidget`; 2833: `_LassoActionButton`.

## 9. Board

### `lib/features/board/presentation/board_screen.dart` (899 linii)

Jednostronicowa, swobodna tablica z pan/zoom, wspólnym kontrolerem i
warstwami tła/canvasu/overlayu; podczas aktywnej transformacji obiektu
ignoruje pointery nawigacyjne, trackpad i scroll, a kontroler blokuje zmianę
`viewPan/viewScale`. `BoardSceneBoundsResolver` zamraża prostokąt sceny
podczas move/resize, aby zmiany `contentBounds` nie przesuwały lokalnego
układu współrzędnych. Po zakończeniu gestu granice odświeżają się.
Pasek tekstu jest wiązany z aktywnym `TextBlock`, a nie ze starym
`QuillController`. Główny toolbar i pasek tekstu respektują `showToolbar`
i unoszą się na nakładce nad canvasem, zamiast zmniejszać jego wysokość.
`showCompactTimer` wyświetla `CompactStudyTimer` w nagłówku po zwinięciu
panelu biblioteki.
Pan dotykowy boarda ma regulowaną czułość i próg gestu; rysik,
zoom i transformacje obiektów są niezależne od tego ustawienia.
Board ma stały boczny odstęp 16 px, ale nie ma marginesu u góry,
więc zawartość można swobodnie przesuwać za toolbar. Nagłówek ma
wyłączony tint podczas przewijania. Panele dziedziczą aktywną paletę.

- 30: `BoardScreen`; 44: `_BoardScreenState`.
- 70: `_buildBoardRect`; 80–394: obsługa pointerów i viewportu.
- 512: główny `build`; import/eksport i skróty przez `EditorCommands`.
- 758: `BoardSceneBoundsResolver` — stabilne granice sceny podczas gestu.
- 794: `_BoardPaintProbe`; 811: `_RenderBoardPaintProbe`;
  834: `_BoardZoomControls`.

## 10. Platformy, web i testy

- `LICENSE.md`: niezmieniony oficjalny tekst PolyForm Noncommercial 1.0.0
  obejmujący prawa licencjodawcy do oryginalnych elementów projektu.
- `NOTICE`: wymagana informacja o prawach autorskich właściciela.
- `docs/LICENSING.md`: zakres licencji, wstępny przegląd licencji
  zależności Flutter/natywnych i kontrola przed dystrybucją.


- `ios/Podfile`: zależności CocoaPods dla pluginów bez obsługi SwiftPM;
  deklaracja iOS 15 i targetów Runner/RunnerTests. W CI iOS wyłącza SwiftPM,
  wykonuje `pod install` i sprawdza obecność Pods w `Runner.xcworkspace`;
  wymaga potwierdzenia w buildzie symulatora.
- `ios/Flutter/Debug.xcconfig`, `Release.xcconfig`, `Profile.xcconfig`:
  każdy tryb Xcode dziedziczy odpowiadający mu config Pods-Runner;
  profil nie dziedziczy już przypadkowo ustawień Release.

- `windows/CMakeLists.txt`: zgodność generatora pdfx/pdfium z CMake 4; przed
  włączeniem pluginów ustawia `CMAKE_POLICY_VERSION_MINIMUM=3.5` dla
  potomnych procesów CMake, bez obniżania wersji dla reszty projektu.
- `linux/runner/my_application.cc` (301): GTK runner i kanał przycisku rysika.
  10: `_MyApplication`; 65–134: zdarzenia rysika;
  153: `my_application_activate`.
- `linux/runner/main.cc` (8) i `linux_environment.cc` (20): przed startem
  GTK korygują `GSETTINGS_SCHEMA_DIR` odziedziczone z Code Snap, jeżeli
  istnieje systemowy `gschemas.compiled`; inne jawne katalogi pozostają.
  5: `configure_linux_environment` w `linux_environment.cc`.
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
- `test/editor_controller_layering_test.dart`: aktywne obrazy są
  dezaktywowane po wyborze narzędzia ink lub tekstu, a nowy tekst startuje
  zaznaczony w trybie edit; obraz ma dane inline, a przed zamknięciem
  testowej bazy następuje rzeczywisty zapis.
- `test/backup_eraser_flattening_test.dart` (109)
- `test/cloud_sync_service_test.dart` (84)
- `test/library_controller_test.dart` (33)
- `test/library_catalog_test.dart` (204): kolor dominujący, serializacja
  okładek, start katalogu, siatka notatek/boardów, nagłówek i Settings,
  edycja okładki z pełnym selektorem kolorów, bezpieczne zamknięcie
  zagnieżdżonego pickera oraz powrót z edytora.
- `test/merged_ui_integration_test.dart`: wspólny motyw katalogu/planera,
  ustawienia pustej biblioteki, nocne miniatury bez mutacji danych i repaint
  po zmianie motywu, kontrast planera/timera, pozycja menu względem
  prawej granicy sidebaru przy resize w obu motywach, maskowanie
  cienia na styku oraz wspólna czułość nowych scrollerów.
- `test/library_screen_responsive_layout_test.dart` (675):
  szeroki układ, drzewo folderów i przełączanie widoczności toolbaru
  boarda/notebooka z kontrolką pod strzałką panelu; regresja pionowego
  centrowania i szerokości strzałek, cienia/obrysu i kierunku zwijania;
  wyśrodkowanie, zwężanie kapsułek, wysokość, odstępy boczne
  oraz przewijanie na wąskim ekranie; wyrównanie timera do dolnej krawędzi
  panelu i aktualizacja mnożnika przewijania plików bez restartu; geometria,
  kolor i obsługa menu
  folderu, notebooka oraz boarda, a także menu dodawania (3 pozycje,
  wyrównanie do panelu i jednostronne zaokrąglenia), zgodność wielkości
  czcionki menu z nazwami dokumentów, brak ikon w menu dodawania,
  stykanie menu z prawą granicą całego sidebaru (w tym resize handle),
  prosty lewy brzeg, brak cienia i podziałki w miejscu styku
  oraz cień wyłącznie po zewnętrznych stronach menu.
- `test/touch_navigation_sensitivity_test.dart` (80):
  granice czułości i porównanie dystansów scrolla przy gestach palcem.
- `test/ink_activity_tracker_test.dart` (25): exit guard czeka na koniec
  aktywnego kontaktu rysika.
- `test/ink_spatial_index_test.dart` (49)
- `test/ink_eraser_engine_test.dart` (348): zwykła gumka, scratch erase,
  erase-stroke/area hit-test, precyzyjne fragmenty zakresu, undo/redo,
  migracja legacy gumek, pojedyncze punkty,
  kolizje ID i undo
- `test/ink_render_benchmark_test.dart` (220)
- `test/selection_outline_test.dart`: przerywane kontury otwarte i zamknięte,
  brak mutacji źródła oraz zgodność rozmiaru segmentów z zoomem
- `test/notebook_overview_navigation_test.dart`: kliknięcia widocznej minimapy,
  przełączanie strony, scroll minimapy bez nawigacji, wybór po przewinięciu,
  blokada transformacji, mapowanie współrzędnych i zachowanie skali.
- `test/editor_screen_responsive_layout_test.dart` (355):
  pełna wysokość canvasa pod pływającym toolbarem, położenie strony
  poniżej narzędzi i domyślne centrowanie poziome z zachowaniem ręcznego
  pan, wsuwanie strony pod pasek bez maskującego marginesu,
  rozszerzenie dolnej granicy klipu, stabilny kolor `AppBar`,
  minimapa na krótkim ekranie, regulacja scrolla stron i interaktywność
  narzędzi
- `test/editor_toolbar_color_picker_test.dart`: dark/light picker, odwrócone
  Recent i wartości RGB/HEX, suwak i zapis z zachowaniem koloru wizualnego,
  brak modyfikacji danych po zatwierdzeniu bez zmian.
- `test/page_overlay_text_gestures_test.dart` (679): blokowy toolbar
  tekstu, układ uchwytów i odwracanie kolorów starych bloków rich text
  w jasnym/ciemnym motywie bez modyfikowania zapisanych Delta,
  blokadę viewportu oraz brak zmian pan/zoom kontrolera podczas resize;
  dodatkowo rozdział stref dotyku uchwytów dla różnych rozmiarów ramek;
  tryb tekstu ignoruje obrazy pod kursorem, a resize nie gubi zmian;
  w trybach ink kliknięcia przechodzą przez tekst i obrazy/PDF;
  regresja selektora koloru tekstu po utracie zaznaczenia oraz undo/redo
- `test/board_scene_bounds_test.dart` (178): stały układ współrzędnych
  boarda podczas resize/move, pełna wysokość canvasa pod toolbarem,
  zachowanie viewportu po schowaniu narzędzi, kolor nagłówka i porównanie
  szybkości przesuwania palcem dla 0.5× i 2.0×.
- `test/object_transform_engine_test.dart` (67): wspólna geometria
  move, corner-scale, side-resize i zachowanie historycznych kątów
- `test/resizable_frame_test.dart` (33)
- `test/widget_test.dart` (20)
- `test/dark_mode_theme_test.dart` (197): paleta dark, odwracanie jasności
  wszystkich barw HSL, alfa, zachowanie odcieni, przełącznik Visual
  i podgląd suwaka czułości w System.


Dodatkowe testy i automatyzacja wieloplatformowa:

- `test/linux/linux_environment_test.cc` oraz
  `.github/scripts/test_linux_environment.sh`: sześć testów C++/GLib
  automatycznej korekty schematów Code Snap i zachowania innych środowisk,
  wykonywanych także w linuksowej części macierzy CI; bez GUI/bazy notatek.

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
  Testy używają izolowanego natywnego katalogu dla preferencji i logów błędów,
  aby regresje nie generowały `MissingPluginException`.
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
- `test/support/native_test_documents.dart`: katalog testowy i natywny
  adapter PathProvider zapobiegają błędom pluginu przy logowaniu i preferencjach
  w testach; nie przekierowują danych użytkownika.
- `.github/scripts/flutter_integration_retry.sh` i
  `.github/scripts/test_flutter_integration_retry.sh`: ponowny start testu
  Android wyłącznie po błędzie inicjalizacji DDS; osobny test regresji
  pilnuje, żeby asercje i powtarzające się awarie pozostały blokujące.
- `test/android_build_toolchain_test.dart`: test regresyjny progu wersji
  pluginu Kotlin Android >= 2.3.20 i użycia `compilerOptions` / JVM 17
  zamiast wycofanego `kotlinOptions.jvmTarget`.
- `test/production/storage_crash_recovery_test.dart`: atomiczne pliki
  ustawień: częściowe zapisy `.tmp`, odzyskiwanie `.previous`, błąd I/O
  i ponowny zapis oraz równoległe write'y jednego klucza.
- `test/production/backup_crash_recovery_test.dart`: symulacje awarii
  między rename manifestu, błędu dostępu do katalogu stron i przerwania
  backupu z zachowaniem starego kompletnego snapshotu.
- `test/production/persistence_roundtrip_test.dart` (300): rich text z Delta,
  crop i bytes obrazów, dwie strony, dirty-page, równoległe zapisy, backup
  i przywrócenie do nowego SQLite; każdy test ma własny katalog dokumentów
  i fake `PathProviderPlatform`, bez zapisu do danych użytkownika. Test
  restore zamyka źródłowy `NotesDatabase` przed otwarciem docelowego,
  aby nie utrzymywać dwóch instancji Drift w tym samym isolate.
  Weryfikuje również trwałość ustawienia czułości nawigacji.
- `test/production/export_render_test.dart` (305): produkcyjne PNG/PDF
  w pamięci, liczba stron i rozmiar obrazu, treść oraz legacy gumka.
  Renderer działa w `tester.runAsync`, poza `FakeAsync` testu widgetowego.
  Regresje obejmują 12 stron, eksport boarda i piksele tej samej zapisanej
  notatki w trybie jasnym i ciemnym, łącznie z oboma wariantami PDF.
- Android toolchain: sprawdzony Gradle 8.14 + AGP 8.11.1 z Kotlin
  2.3.20; Gradle 9 blokuje zależność `irondash_engine_context 0.5.5`,
  której skrypt CargoKit korzysta z usuniętego `Project.exec`.
  `test/android_build_toolchain_test.dart` zabezpiecza ten stan.
- `android/app/build.gradle.kts` i `android/app/proguard-rules.pro`:
  Release wymaga prywatnego `android/key.properties` poza CI i jawnym trybem
  debug-signing; konfiguracja odrzuca niepełne klucze i brak keystore.
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
