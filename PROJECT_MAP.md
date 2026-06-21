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
- Lokalna baza: **Drift + SQLite** (`drift`, `sqlite3_flutter_libs`,
  `drift_dev`; kodogen w `notes_database.g.dart`).
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
│   ├── data/                  ← Drift/SQLite, backup, sync
│   └── features/
│       ├── library/           ← lista notebooków, foldery, search, sync
│       ├── notebook/          ← modele domeny + repository + ekran "pusty"
│       ├── editor/            ← edytor stronicowy (notebook)
│       └── board/             ← edytor canvas (board, jedna „strona")
├── test/widget_test.dart      ← smoke test: NotesApp pumpuje MaterialApp
├── web/                       ← Flutter web + assety Drift WASM
├── linux/runner/              ← GTK runner + natywny kanał przycisku rysika
├── pubspec.yaml               ← zależności (Drift, Quill, mlkit, pdfx…)
└── AI_INSTRUCTIONS.md         ← skrót Effective Dart Style
```

## 3. Mapa plików (linijka po linijce)

Format pozycji: `LL: nazwa — krótki opis`. `LL` to numer linii startowej.

---

### `lib/main.dart` (122 linie)
Entry point.
- 11: `_wrappedKeyDataHandler` — oryginalny handler Fluttera opakowany przez
  filtr niepoprawnych pakietów key data.
- 12: `_wrappedPlatformErrorHandler` — poprzedni globalny handler błędów
  platformy, zachowany dla błędów niezwiązanych z key data.
- 15: `_wrappedFlutterErrorHandler` — poprzedni handler FlutterError, zachowany
  po dodaniu logowania błędów aplikacji.
- 17: `_invalidKeyDataFilter` — konsumuje pakiety key data z
  `physical/logical == 0`, żeby nie dochodziły do asercji Fluttera na Linuksie.
- 24: `void main()` — uruchamia aplikację w `runZonedGuarded` i zapisuje
  nieobsłużone błędy Dart zone do `AppErrorLog`.
- 36: `_runApp()` — `WidgetsFlutterBinding.ensureInitialized()`, ładuje
  utrwalony `AppErrorLog` i `OptimizationLog`, instaluje logowanie
  `FlutterError`, inicjalizuje kanał stanu przycisku rysika, instaluje filtr
  key data, odnawia go po `syncKeyboardState()` i przez krótki watchdog
  startowy, potem `runApp(NotesApp())`.
- 54: `_installFlutterErrorLogger()` — opakowuje `FlutterError.onError`
  i zachowuje poprzedni handler.
- 63: `_flutterErrorLogger(details)` — zapisuje błędy frameworka do
  `AppErrorLog`, potem przekazuje je poprzedniemu handlerowi.
- 68: `_installInvalidKeyDataFilter()` — idempotentnie instaluje filtr i nie
  owija ponownie własnego handlera.
- 78: `_installInvalidKeyDataErrorFilter()` — instaluje wąski fallback dla
  asercji `HardwareKeyboard`, jeśli Flutter zdąży nadpisać handler.
- 88: `_invalidKeyDataErrorFilter(...)` — wycisza tylko asercję niepoprawnych
  key data, resztę zapisuje do `AppErrorLog` i przekazuje poprzedniemu handlerowi
  błędów.
- 97: `_isInvalidKeyDataAssertion(...)` — rozpoznaje dokładną asercję
  `data.physical != 0 && data.logical != 0` ze stosu `KeyEventManager`.
- 105: `_startKeyDataFilterWatchdog()` — przez ok. godzinę po starcie odnawia
  filtr co 500 ms, bo Flutter potrafi nadpisać `onKeyData` po inicjalizacji
  tekstu na Linuksie.

### `lib/app/notes_app.dart` (12 linii)
- 5: `class NotesApp extends StatelessWidget` — owija aplikację w `AppScope`.

### `lib/app/app_scope.dart` (318 linii) — DI + bootstrap
- 16: `class AppScope` — root scope aplikacji, tworzy `_AppScopeState`.
- 26: `_AppScopeState` — trzyma pojedynczy `_openFuture`, repozytorium,
  backup service, sync service, scheduler backupu i flagę jednorazowego
  zapisania błędu startu; w `initState()` uruchamia też `FrameTimingTracker`.
- 51–65: jeśli bootstrap zwróci błąd, zapisuje go do `AppErrorLog` i przekazuje
  oryginalny wyjątek do `_StartupErrorScreen`.
- 68–71: spinner podczas otwierania SQLite/Drift.
- 77–91: tworzy/cache'uje `NotebookRepository`, `LocalBackupService`,
  `CloudSyncService` i `_BackupScheduler`; `repository.onChanged` tylko
  planuje backup, nie robi snapshotu natychmiast.
- 93–117: `MultiProvider` z `AppPreferencesController`,
  `NotebookRepository`, `LocalBackupService`, `LibraryController`
  (`wasReset`/`freshFile`/`resetReason` z `NotesDatabase.open`) →
  `MaterialApp(home: LibraryScreen)`, bez debug bannera.
- 121: `_StartupErrorScreen` — pokazuje etap awarii otwierania bazy, liczbę
  prób, przyczynę systemową i informację o zachowaniu pliku; udostępnia też
  `Copy errors`, nawet gdy ustawienia aplikacji nie zdążą się otworzyć.
- 197: `_BackupScheduler` — osobny idle debounce backupu (`8s`), blokada przed
  nakładaniem snapshotów oraz flush przy lifecycle `inactive/paused/detached`;
  loguje `[backup]` z czasem fetch/snapshot/total, szczegółowym raportem
  `LocalBackupService.snapshot` oraz zagregowanym `build/raster/total`
  z `FrameTimingTracker` dla okresu backupu.

### `lib/core/theme/app_colors.dart` (18 linii)
- 3: `class AppColors` — stałe: `paper`, `toolbar`, `inkBlack`, `shadow`,
  `divider` + lista `inkPalette` (6 kolorów).

### `lib/core/theme/app_theme.dart` (21 linii)
- 5: `class AppTheme.light()` — Material 3, seed = `inkBlack`, paper background,
  AppBar w `toolbar`.

### `lib/core/theme/app_metrics.dart` (3 linie)
- 1: `class AppMetrics` — stałe metryczne wspólne dla edytora i miniaturek.
  - `a4HeightRatio = 297 / 210` (height/width pojedynczej strony A4).

### `lib/core/input/stylus_button_state.dart` (42 linie)
Platform-channel state dla natywnego przycisku rysika.
- 6: `class StylusButtonState` — globalny `ValueNotifier<bool>` z aktualnym
  stanem przycisku rysika raportowanym przez hosta oraz licznik żądań
  przełączenia gumki (Apple Pencil double tap).
- 17: `initialize()` — idempotentnie rejestruje handler kanału
  `nanotateczki/stylus_button`.
- 25: `_handleMethodCall(call)` — obsługuje `setPressed({pressed, button})`
  oraz `toggleEraser`.

### `lib/core/input/app_preferences_controller.dart` (84 linie)
Globalne preferencje aplikacji niezależne od konkretnego edytora.
- 7: `enum DeviceInputMode { computer, tablet }` — ręczny tryb urządzenia dla
  zachowania pól tekstowych.
- 9: `extension DeviceInputModeX` — etykiety i opisy UI dla ustawienia.
- 26: `class AppPreferencesController` — `ChangeNotifier`, ładuje/zapisuje
  `app_prefs.json` przez wspólny storage; domyślnie Android/iOS = tablet,
  desktop/web = computer.

### `lib/core/storage/text_storage.dart` (2 linie)
Conditional export magazynu małych plików tekstowych: IO domyślnie,
`localStorage` przy `dart.library.js_interop`.

### `lib/core/storage/text_storage_io.dart` (21 linii)
- 5: `readStoredText(key)` — czyta plik z katalogu dokumentów aplikacji.
- 13: `writeStoredText(key, value)` — zapisuje plik tekstowy w katalogu
  dokumentów aplikacji.

### `lib/core/storage/text_storage_web.dart` (9 linii)
- 3: `readStoredText(key)` / 7: `writeStoredText(key, value)` — webowy storage
  oparty o `window.localStorage`.

### `lib/core/input/soft_keyboard.dart` (22 linie)
- 7: `requestSoftKeyboardForFocus(context, focusNode)` — jeśli globalny
  `DeviceInputMode.tablet`, focusuje pole i wysyła do Fluttera `TextInput.show`
  jako prośbę o systemową klawiaturę ekranową.

### `lib/core/error/app_error_log.dart` (161 linii)
Lokalny bufor ostatnich błędów aplikacji do kopiowania z ustawień, utrwalany w
`app_error_log.json` natywnie albo `localStorage` w web.
- 8: `class AppErrorLog extends ChangeNotifier` — singleton trzymający do 80
  błędów z ostatnich 3 dni, powiadamia UI po zmianach.
- 25: `load()` — wczytuje zapisany JSON błędów, odrzuca niepoprawne wpisy i
  przycina historię.
- 46: `record(error, stackTrace, {source})` — dodaje wpis z datą, źródłem,
  treścią błędu i opcjonalnym stack trace, potem zapisuje plik.
- 61: `recordFlutterError(details)` — adapter dla `FlutterErrorDetails`.
- 69: `clear()` — czyści bufor i zapisany plik.
- 78: `toClipboardText()` — formatuje zawartość bufora do skopiowania.
- 85: `_prune()` — zostawia wpisy z ostatnich 3 dni i maksymalnie 80 rekordów.
- 94: `_save()` — zapisuje aktualny bufor do `app_error_log.json`.
- 106: `class AppErrorLogEntry` — immutable wpis błędu z JSON
  `fromJson/toJson`.
- 151: `format()` — tekstowy format jednego wpisu.

### `lib/core/diagnostics/optimization_log.dart` (347 linii)
Lokalny bufor przefiltrowanych zdarzeń wydajnościowych do kopiowania z ustawień,
utrwalany w `optimization_log.json` natywnie albo `localStorage` w web.
- 9: `class OptimizationLog extends ChangeNotifier` — singleton trzymający do
  80 podejrzanych wpisów z ostatnich 3 dni, sortowanych po score i czasie.
- 26: `load()` — wczytuje zapisany JSON i przycina historię.
- 47: `recordInkStroke(...)` — filtruje logi stroke'ów z canvasu; zapisuje
  tylko wolne/podejrzane przypadki (`slow move`, `slow frame`, dużo move przy
  małej liczbie punktów, wolny `input-to-paint`, itp.).
- 110: `recordBackup(...)` — filtruje kosztowne backupy i błędy/skipy backupu.
- 161: `toClipboardText()` — formatuje posortowaną listę podejrzanych wpisów.
- 176: `_inkScore(...)` / 218: `_backupScore(...)` — heurystyki filtra i score.
- 240: `_record(entry)` / 247: `_prune()` / 262: `_save()`.
- 274: `class OptimizationLogEntry` — wpis `category/label/score/reasons/details`
  z JSON `fromJson/toJson`.
- 334: `format()` — tekstowy format jednego wpisu.

### `lib/core/diagnostics/frame_timing_tracker.dart` (132 linie)
Globalny agregat `FrameTiming` do korelacji logów `[ink]` i `[backup]`
z prawdziwym kosztem build/raster.
- 3: `class FrameTimingTracker` — singleton instalujący
  `SchedulerBinding.addTimingsCallback`, trzymający bufor ostatnich klatek
  i wystawiający `captureCursor()/summarySince(cursor)`.
- 89: `class FrameTimingSummary` — gotowy do logowania agregat
  `frames/build/raster/total` z avg/max i licznikami klatek >16.7 ms / >33 ms.

### `lib/core/diagnostics/board_scene_perf_tracker.dart` (153 linie)
Debug-only agregat build/paint warstw boarda, żeby korelować `[ink] board`
z kosztami `BoardScreen`.
- 3: `class BoardScenePerfTracker` — singleton z `captureCursor()`,
  `recordBuild()` i `recordPaint(layer, us)`, trzymający ring-buffer
  ostatnich próbek sceny boarda.
- 80: `class BoardScenePerfSummary` — agregat `sceneBuild`, `scenePaint`,
  `background`, `inactiveOverlay`, `canvasHost`, `activeOverlay` do jednej
  linii logu.

### `lib/core/widgets/empty_state.dart` (30 linii)
- 3: `class EmptyState` — wycentrowane `title + message`, max width 360.

### `lib/core/widgets/resizable_frame.dart` (200 linii)
- 5: `enum ResizeDirection` (8 kierunków: topLeft…bottomRight).
- 16: `class ResizableFrame extends StatefulWidget` — owija dziecko,
  pokazuje 8 uchwytów gdy `isSelected`.
- 40: `_ResizableFrameState` — z `_activeHandle` do podświetlania.
- 45: `build` — gdy nie wybrany, zwraca samo dziecko; inaczej `Stack` z 8 `_buildHandle`.
- 106: `_buildHandle({alignment, direction, cursor})` — `MouseRegion + GestureDetector` (onLongPress z opóźnieniem),
  liczy delta w lokalnej przestrzeni, animuje skalę uchwytu.
- 162: `_endResize` — kończy resize idempotentnie; cancel odkłada na kolejną
  klatkę, żeby nie wołać `setState` podczas zablokowanej finalizacji drzewa.
- 193: `_globalToFrameLocal` — `RenderBox.globalToLocal`.

### `linux/runner/my_application.cc` (299 linii)
GTK runner dla desktopowego Linuksa.
- 10: `struct _MyApplication` — trzyma argumenty Dart entrypoint i kanał
  `stylus_button_channel`.
- 18: `first_frame_cb(...)` — pokazuje okno po pierwszej wyrenderowanej klatce.
- 23: `source_device_for_event(event)` — wybiera source device z fallbackiem do
  zwykłego device.
- 31: `is_tablet_like_source(source)` — wspólne rozpoznanie
  `PEN/ERASER/TABLET_PAD`.
- 36: `device_tool_is_eraser(tool)` — rozpoznaje natywną końcówkę gumki GDK.
- 44: `device_name_suggests_stylus(device)` — ostrożny fallback dla zdarzeń
  klawiszowych zgłaszanych przez urządzenie nazwane jak rysik/tablet.
- 65: `send_stylus_button_state(...)` — wysyła do Darta stan przycisku rysika.
- 75: `is_stylus_button_event(event)` — wykrywa przyciski urządzeń
  `GDK_SOURCE_PEN/ERASER/TABLET_PAD` lub eventy z `device_tool`; końcówka
  gumki aktywuje gumkę także przez primary/tip.
- 97: `stylus_button_event_cb(...)` — wysyła do Darta
  `nanotateczki/stylus_button.setPressed({pressed, button})`, ale nie konsumuje
  eventu GTK.
- 114: `is_stylus_key_event(event)` — wykrywa klawiszowe zdarzenia
  rysika/tablet-pad bez przejmowania zwykłej klawiatury.
- 134: `stylus_key_event_cb(...)` — mapuje press/release klawisza rysika na
  tymczasowy stan gumki.
- 151: `my_application_activate(...)` — tworzy okno GTK, `FlView`, rejestruje
  native listenery button/key press/release dla rysika, pluginy i focusuje widok
  Fluttera.
- 262: `my_application_shutdown(...)` — cleanup pluginów.
- 271: `my_application_dispose(...)` — zwalnia kanał rysika i argumenty Dart
  entrypoint.

### `ios/Runner/SceneDelegate.swift` (45 linii)
iOS scene delegate.
- 4: `class SceneDelegate` — rozszerza `FlutterSceneDelegate` i implementuje
  `UIPencilInteractionDelegate`.
- 7: `scene(...willConnectTo...)` — po utworzeniu sceny instaluje obsługę Apple
  Pencil.
- 16: `installPencilInteraction()` — podpina kanał
  `nanotateczki/stylus_button` do `FlutterViewController` i dodaje
  `UIPencilInteraction`.
- 33: `pencilInteractionDidTap(...)` — respektuje `preferredTapAction`; dla
  `switchEraser`/`switchPrevious` wysyła do Darta `toggleEraser`.

---

### `lib/data/drift/notes_database.dart` (236 linii)
Schemat Drift/SQLite i otwieranie lokalnej bazy `notes.sqlite`.
- 12: `class NotebookRows extends Table` — notebook/board: `uid`, tytuł,
  rodzaj, folder, daty.
- 24: `class PageRows extends Table` — strony z `notebookUid`, kolejnością,
  tytułem, bookmarkiem i legacy polami pojedynczej zakładki.
- 37: `class IndexTabRows extends Table` — wiele zakładek strony.
- 47: `class TextBlockRows extends Table` — bloki tekstu; kolumna DB `text`
  jest w kodzie nazwana `plainText`, żeby nie kolidować z helperem Drifta.
- 64: `class ImageBlockRows extends Table` — bloki obrazów, crop/rotation,
  opcjonalne legacy bytes tylko gdy brak trwałego `path`.
- 87: `class InkStrokeRows extends Table` — stroke; punkty trzymane jako
  `pointsJson` per stroke, nie jako osobne rekordy per punkt.
- 100: `class DatabaseOpenResult` — `database`, `wasReset`, `freshFile`,
  `resetReason`.
- 111: `DatabaseOpenStage` / 113: `DatabaseOpenException` — rozróżnia awarię
  tworzenia połączenia od walidacji/migracji i zachowuje pierwotną przyczynę.
- 147: `class NotesDatabase extends _$NotesDatabase`.
- 154: `open()` — otwiera `notes.sqlite` przez conditional connection; przy
  błędzie wykonuje do 3 prób, loguje etap każdej próby, a po ich wyczerpaniu
  rzuca `DatabaseOpenException` bez usuwania pliku bazy.
- 227: `schemaVersion => 1`.
- 230: `migration` — `createAll()` i `PRAGMA foreign_keys = ON`.

### `lib/data/drift/notes_database_connection.dart` (2 linie)
Conditional export: IO implementation domyślnie, web implementation przy
`dart.library.js_interop`.

### `lib/data/drift/notes_database_connection_io.dart` (21 linii)
Natywne połączenie Drift.
- 7: `class NotesDatabaseConnection` — `QueryExecutor` + `freshFile`.
- 14: `openNotesDatabaseConnection(name)` — `NativeDatabase.createInBackground`
  w katalogu dokumentów aplikacji.

### `lib/data/drift/notes_database_connection_web.dart` (28 linii)
Webowe połączenie Drift WASM z trwałym IndexedDB bez zależności od workera.
- 6: `class NotesDatabaseConnection` — `QueryExecutor` + `freshFile`.
- 13: `openNotesDatabaseConnection(name)` — ładuje `web/sqlite3.wasm`,
  rejestruje `IndexedDbFileSystem` i otwiera `WasmDatabase`.

### `lib/data/drift/notes_database.g.dart` (6075 linii)
Wygenerowane przez `drift_dev` — **NIE edytuj ręcznie**. Po zmianach w
`notes_database.dart` uruchom `dart run build_runner build`.

### `web/drift_worker.dart` (5 linii)
Źródło workera Drifta dla webowego SQLite WASM.
- 3: `main()` — `WasmDatabase.workerMainForOpen()`.

### `web/drift_worker.dart.js`
Skompilowany worker używany przez `notes_database_connection_web.dart`; odtwarzaj
po zmianie `web/drift_worker.dart` komendą
`dart compile js -O4 -o web/drift_worker.dart.js web/drift_worker.dart`.

### `web/sqlite3.wasm`
Binary SQLite WASM wymagany przez `WasmDatabase.open`.

### `lib/data/backup/local_backup_service.dart` (456 linii)
Przyrostowy lokalny backup JSON w `local_backup/`: `manifest.json` +
`notebooks/<uid>.json`; stary `notebooks_latest.json` nadal jest czytany jako
fallback restore. Stare snapshoty usuniętych notebooków trafiają do
`local_backup/trash/` zamiast znikać bez śladu. W web pojedynczy snapshot JSON
jest zapisywany w `localStorage`.
- 13: `class LocalBackupService(this.repository)`.
- 23: `_backupDir()` — tworzy katalog jeśli brak.
- 32: `_file(name)`.
- 37: `_notebooksDir()` / 45: `_manifestFile()` / 50: `_notebookFile(uid)` /
  55: `_trashDir()`.
- 65: `snapshot(items)` — zwraca `BackupSnapshotReport`; poza samym zapisem
  mierzy per-notebook `flatten/encode/json/compare/write`, liczbę stron,
  stroke'ów, punktów i rozmiar JSON-a, a w raporcie globalnym zbiera też
  `manifestMs`, `staleListMs` i najwolniejszy notebook.
- 191: `hasLatest()` — rozpoznaje webowy snapshot, nowy manifest albo legacy.
- 203: `readLatest()` — web czyta `localStorage`, natywnie preferuje backup
  przyrostowy i używa legacy jako fallbacku.
- 221: `_readIncrementalLatest()` / 262: `_readLegacyLatest()` — logują błędy
  odczytu backupu do `AppErrorLog`.
- 285: `restoreFromLatest()` — zapisuje wszystkie notebooki do repozytorium,
  zwraca count.
- 304: `_snapshotForWeb(items)` — zapisuje spłaszczony pełny snapshot JSON do
  `localStorage`.
- 332: `_moveStaleNotebookBackupToTrash(file)` — archiwizuje osierocony plik
  backupu zamiast go usuwać.
- 370: `class BackupSnapshotReport` — agregat całego snapshotu do logu
  `[backup]`, z liczbą notebooków/stron/stroke'ów/punktów i `slowest{...}`.
- 421: `class NotebookBackupReport` — per-notebook rozbicie kosztu backupu.

### `lib/data/backup/backup_eraser_flattening.dart` (272 linie)
Sanityzacja lokalnego backupu: stosuje zapisane stroke'i gumki do wcześniejszych
stroke'ów i wyrzuca same gumki z payloadu backupu.
- 9: `flattenErasersForBackup(notebook)` — zwraca kopię notebooka z
  przetworzonymi stronami.
- 15: `_flattenPageErasers(page)` — idzie po stroke'ach w kolejności rysowania;
  `eraserBrush`/`eraserArea` tną wcześniejsze stroke'i, `eraserStroke` nie jest
  zapisywany.
- 50: `_applyBrushEraser(...)` — rozcina stroke'i po kolizji z polyline gumki.
- 74: `_applyAreaEraser(...)` — rozcina stroke'i po wejściu/przecięciu polygonu.
- 97: `_splitStroke(...)` — wspólne dzielenie stroke'a na fragmenty z nowymi ID.
- 150: `_distanceSquaredToPolyline(...)` / 167 `_segmentDistanceSquaredToPolyline(...)`
  / 188 `_distanceSquaredToSegment(...)` / 200 `_segmentDistanceSquared(...)` —
  helpery geometrii gumki-pędzla.
- 212: `_pointInPolygon(...)` / 228 `_segmentIntersectsPolygon(...)` /
  239 `_segmentsIntersect(...)` — helpery geometrii gumki-obszaru.

### `lib/data/export/notebook_export_service.dart` (683 linie)
Eksport notebooków/boardów do wybranej przez użytkownika lokalizacji
(`Documents/exports` jako domyślny katalog dialogu na desktopie).
- 22: `enum NotebookExportFormat { pdf, png }`.
- 35: `class NotebookExportService` — renderuje aktualny model edytora do PNG
  i opakowuje strony w PDF.
- 44: `exportController(controller, format)` — bierze bieżące strony, tło i
  odstęp stron z `EditorController`, zwraca `null` po anulowaniu zapisu.
- 61: `exportNotebook(notebook, format, {pageSize, pageGap, background})`.
- 86: `_exportPdf(...)` — renderuje strony jako obrazy i zapisuje jeden PDF przez
  systemowy dialog zapisu.
- 120: `_exportPng(...)` — board/jedna strona jako plik przez dialog zapisu,
  notebook wielostronicowy natywnie jako folder `page_XX.png`, a w web jako
  seria pobranych plików.
- 179: `_saveBytesAs(...)` — `FilePicker.saveFile`, dopisanie rozszerzenia na
  desktopie, przekazanie bytes na Android/iOS/web.
- 228: `_renderNotebook(...)` — dla notebooka przekazuje origin strony
  tekstom/obrazom, a kreski zostawia w lokalnym układzie strony.
- 273: `_renderPage(...)` — `dart:ui` canvas, tło papieru z opcjonalną
  kratką/liniami, obrazy, tekst, strokes; obsługuje osobny `strokeOrigin`.
- 301: `_paintBackground(...)` — rysuje papier i wzór tła z alignmentem do
  przestrzeni boarda.
- 336: `_paintImages(...)`.
- 367: `_paintTextBlocks(...)` / 381: `_textSpans(block)` — prosty render delty Quill.
- 440: `_paintStrokes(...)` / 485: `_buildInkPath(...)` — render stroke'ów
  z tym samym adaptacyjnym wygładzaniem pen/highlighter co canvas.
- 560: `_pageContentBounds(page)` — obszar eksportu boarda.

### `lib/data/sync/cloud_sync_service.dart` (136 linii)
Folder-based sync (`notatek_cloud.json` we wskazanym folderze).
- 10: `class CloudSyncResult` — `totalNotebooks, uploaded, downloaded`.
- 22: `class CloudSyncService(this.repository)`.
- 30: `getCloudPath()` — czyta `cloud_sync.json`; w web zwraca brak ścieżki.
- 48: `setCloudPath(path)` / 56: `sync(local)` — w web zgłaszają jawny
  `UnsupportedError`, bo przeglądarka nie udostępnia trwałej ścieżki folderu.
- 87: `_readCloudNotebooks`.
- 100: `mergeNotebooks` — last-write-wins po `updatedAt`; przy remisie zachowuje
  wersję lokalną, żeby równy timestamp nie wyczyścił nowszego stanu użytkownika.
- 118: `_countNewer`.
- 132: `_configFile`.

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

### `lib/features/notebook/domain/drawing_tool.dart` (43 linie)
- 1: `enum DrawingTool` — pen, highlighter, eraserBrush, eraserStroke,
  line, arrow, rectangle, square, triangle, ellipse, circle, text, image,
  blockArrow, edit, lasso, eraserArea.
- 21: `extension DrawingToolX` — `isEraser`, `isShape`, `isInk`
  (uwaga: `isInk` true dla pen/highlighter/eraserów/wszystkich kształtów/lassa).

### `lib/features/notebook/domain/ink_stroke.dart` (53 linii)
- 5: `class InkStroke { id, points, color, width, tool }` + `copyWith`.
- 37: `class InkPoint { dx, dy, pressure }` + `fromOffset` + `toOffset`.

### `lib/features/notebook/domain/ink_spatial_index.dart` (125 linii)
Cache'owany względem listy stroke'ów indeks przestrzenny o siatce 128 px,
używany przez gumkę, scratch erase i wstępne filtrowanie lassa.
- 13: `inkSpatialIndexFor(strokes)` — zwraca indeks z `Expando`, więc nowa lista
  stroke'ów automatycznie dostaje nowy indeks.
- 23: `class InkSpatialIndex` — buduje komórki bez zmiany kolejności stroke'ów;
  bardzo długie stroke'i trzyma w osobnej liście overflow.
- 50: `query(bounds)` / 76: `queryPoint(point, radius)` — zwracają wyłącznie
  kandydatów; dokładny hit-test nadal wykonuje kod wywołujący.

### `lib/features/notebook/domain/text_block.dart` (45 linii)
- 3: `class TextBlock { id, text, deltaJson?, position, fontSize, color,
  width, rotation }` + `copyWith`.

### `lib/features/notebook/domain/image_block.dart` (71 linii)
- 4: `class ImageBlock { id, path, ocrText, position, width, height, bytes?,
  imageExt?, imageMime?, rotation, cropLeft/Top/Right/Bottom }` + `copyWith`
  (crop domyślnie 0/0/1/1, `clearBytes` usuwa legacy/fallback bytes).

### `lib/features/notebook/data/notebook_repository.dart` (1085 linii)
Mostek domena ↔ Drift/SQLite ↔ JSON.
- 21: `class NotebookRepository` — repo z callbackiem po zapisie i opcjonalnym
  testowym handlerem błędów odczytu.
- 39: `lastFetchSkippedCorruptRows` / 40: `lastCorruptNotebookCount` /
  42: `lastCorruptNotebookIds` — stan ostatniego defensywnego fetchu po `uid`.
- 44: `fetchNotebooks()` — składa notebooki z tabel dzieci; częściowo
  uszkodzony dokument pozostaje na liście i jest oznaczany do recovery, a błąd
  głównego zapytania jest zgłaszany zamiast udawać pustą bazę.
- 86: `saveRecoveredCopy(...)` — zapisuje kopię odzyskaną z nowym `uid` i
  dopiskiem do tytułu, żeby nie nadpisać uszkodzonego oryginału.
- 100: `archiveNotebookBeforeDelete(...)` — natywnie odkłada ręcznie usuwany
  notebook do `deleted_notebooks/<ts>_<uid>.json`; w web pomija plikowe
  archiwum.
- 135: `createNotebook({title, folder})` — `NotebookKind.notebook`, 1 strona „Page 1".
- 161: `createBoard({title, folder})` — `NotebookKind.board`, jedna strona „Canvas".
- 187: `getNotebook(uid)` — zwraca także częściowo czytelny dokument i oznacza
  jego UID jako uszkodzony.
- 211: `saveNotebook(notebook)` — odrzuca snapshot bez stron i szereguje zapisy
  per UID w kolejności wywołań; `_saveNotebookNow` (233) odrzuca częściowo
  odczytany dokument, migruje stare obrazy inline, atomowo odrzuca snapshot
  starszy od najnowszej wersji i zastępuje dzieci w transakcji.
- 282: `updateNotebookMetadata(uid, {title, folder})` — aktualizuje wyłącznie
  nagłówek z monotonicznym `updatedAt`, bez zastępowania zawartości notatki.
- 329: `_persistInlineImages(notebook)` / 352 `_persistInlineImageBytes(block)` —
  przenosi obrazy z `bytes` bez trwałej ścieżki do katalogu dokumentów aplikacji
  i czyści `bytes` po utrwaleniu pliku; w web zachowuje bajty inline w SQLite.
- 388: `deleteNotebook(uid)` — przed delete próbuje zarchiwizować aktualną
  wersję notebooka do pliku odzyskiwania, potem kasuje dzieci i nagłówek.
- 397: `encodeNotebooks(items)` / 401: `decodeNotebooks(items)` — JSON.
- 408: `_readNotebook(row)` / 448: `_readPage(row)` — defensywnie składa
  dokument; błąd pojedynczej tabeli, strony lub dziecka nie ukrywa całego UID.
- 522: `_readRowsSafely` / 536: `_convertRowsSafely` / 554: `_recordReadError`
  — wspólne granice błędów odczytu i konwersji rekordów dzieci.
- 577: `_insertPage(notebookUid, page, pageIndex)` — zapisuje stronę i jej
  dzieci w kolejności z modelu.
- 619: `_deleteNotebookChildren(notebookUid)` — usuwa dzieci stron przed
  zastąpieniem snapshotu notebooka.
- 647–766: konwersje Drift row/companion ↔ domena per blok.
- 768: `_pointsToJson(points)` / 782: `_pointsFromJson(value)` — punkty stroke'a
  jako JSON per stroke.
- 799–1024: JSON serializery backup/sync (`_notebookTo/FromJson`,
  `_pageTo/FromJson`, `_textTo/FromJson`, `_imageTo/FromJson`,
  `_strokeTo/FromJson`).
- 1034: `_toolFromIndex(int)` / 1042: `_toolToIndex(tool)` — symetryczne,
  prosty mapping przez `DrawingTool.values`.
- 1035: `_bytesFromEntity(Uint8List?)`.
- 1042: `_bytesToBase64` / 1049: `_bytesFromBase64`.
- 1061: `_NotebookReadResult` / 1071: `_PageReadResult` — wynik modelu razem
  z flagą pominiętych uszkodzonych rekordów.

---

### `lib/features/library/presentation/library_controller.dart` (593 linie)
ChangeNotifier — stan ekranu Biblioteki.
- 13: `class LibraryController extends ChangeNotifier` — repo, cloud, backup,
  flagi `wasReset/freshFile/resetReason` oraz stan recovery uszkodzonych dokumentów.
- 29–47: pola: `autoRestoreCount, isLoading, isSyncing,
  isLoadingSelectedItem, isRecoveringCorruptDocuments, items, selectedItemId,
  selectedFolder='', searchQuery, cloudPath, lastSyncedAt, lastSyncResult, loadError,
  _folders, _activeNotebook, _corruptRecoveryDismissed, corruptDocumentCount,
  recoverableCorruptDocuments`.
- 51: `shouldShowResetBanner` getter.
- 54: `hasCorruptDocuments`; 56: `shouldPromptCorruptRecovery`;
  61: `shouldShowCorruptionBanner`.
- 66: `dismissResetBanner()` / 71: `dismissCorruptRecoveryPrompt()`.
- 77: `initialize()` — `_loadFolders` → `loadItems` → `_loadCloudPath`.
- 83: `loadItems()` — podmienia listę dopiero po udanym odczycie; przy błędzie
  zachowuje dotychczasowe elementy, ustawia `loadError` i loguje incydent;
  obsługuje też recovery po świeżej bazie.
- 139: `restoreCorruptDocumentsFromBackup()` — zapisuje każdą odzyskaną notatkę
  jako oddzielną kopię `Recovered`, bez nadpisywania oryginału.
- 192: `syncNow()` — resetuje `isSyncing` także po wyjątku.
- 205: `setCloudPath(path)`.
- 211: `visibleItems` getter — filtr folderem + searchem.
- 224: `folderNames` getter — `_folders ∪ items.folder`, sortowane
  alfabetycznie bez względu na wielkość liter.
- 236: `createFolder(name)`.
- 251: `renameFolder(oldName, newName)` — aktualizuje wyłącznie metadane
  notebooków przypisanych do folderu, bez przepisywania ich stron.
- 294: `deleteFolder(name)` — usuwa folder i wszystkie notebooki w nim.
- 326: `createNotebook()` / 338: `createBoard()` — używają wybranego folderu
  albo fallbacku `Notes`, zaznaczają i zwracają utworzony element.
- 350: `deleteItem(uid)`.
- 364: `renameItem(uid, title)` — aktualizuje tylko tytuł nagłówka bez
  przepisywania stron notebooka/tablicy.
- 392: `selectItem(uid)` — async load z repo, ustawia `_activeNotebook`.
- 404: `selectFolder(folder)`.
- 413: `setSearchQuery(value)`.
- 418: `exportBackup()` — pisze `notatek_backup_<ts>.json` w docs dir.
- 428: `importBackup(path)` — dekoduje + `saveNotebook` per item + reload.
- 442: `selectedItem()` — wybiera active pasujący do id albo item po id.
- 452: `_itemById(uid)`.
- 462: `_firstItemInFolder(folder)`.
- 470: `_selectedItemIsInFolder(folder)`.
- 478: `_targetFolderForNewItem()`.
- 489: `_loadCloudPath`.
- 495: `_loadFolders` / 518: `_saveFolders` (`library_folders.json`) przez
  wspólny storage plikowy/webowy.
- 533: `_compareFolderNames(a, b)`.
- 541: `_matches(notebook, query)` — title/page title/textBlock/ocrText.
- 563: `_refreshCorruptRecoveryState()` — wylicza brakujące względem backupu
  kandydaty do odzyskania, uwzględniając także nadal widoczne UID z częściowo
  uszkodzonymi dziećmi; gdy kandydatów brak, zapisuje incydent do `AppErrorLog`.

### `lib/features/library/presentation/library_screen.dart` (1082 linie)
Trójkolumnowy layout (folders | items | workspace) z resizable pane.
- 17: `class LibraryScreen extends StatefulWidget`.
- 24: `_LibraryScreenState` — stałe layoutu (25–30: `_wideBreakpoint=1100`,
  pane min/max widths, `_resizeHandleWidth=12`) + flaga
  `_isShowingCorruptRecoveryDialog`.
- 38: `initState` — post-frame `controller.initialize()`.
- 46: `build` — Scaffold + bannery resetu, korupcji i błędu odczytu z retry +
  LayoutBuilder;
  wywołuje `_maybeShowCorruptRecoveryDialog(controller)` przy starcie.
- 122–234: wide layout (≥1100): folder pane, resize handle, items pane,
  resize handle, workspace + `_LeftZoneToggleTab`.
- 237–266: wąski layout: `_FolderChipBar` na górze + lista items na pełnej
  szerokości.
- 271: `_toggleLeftNavigation`.
- 278: `_createItem(kind)` — tworzy notebook/tablicę i zwraca nowy element.
- 286: `_createAndSelectItem(kind)` — desktopowe tworzenie z natychmiastowym
  dialogiem nazwy, bez push trasy.
- 295: `_createAndOpenItem(kind)` — tworzy element, pokazuje dialog nazwy
  i otwiera go na wąskim widoku.
- 310: `_promptNewFolder(controller)` — dialog tworzenia folderu; w trybie
  tablet prosi system o klawiaturę ekranową.
- 345: `_promptRenameFolder(controller, folder)` — dialog zmiany nazwy folderu;
  w trybie tablet prosi system o klawiaturę ekranową.
- 383: `_promptRenameItem(controller, item)` — dialog zmiany nazwy
  notebooka/tablicy; w trybie tablet prosi system o klawiaturę ekranową.
- 425: `_confirmDeleteFolder(controller, folder)` — potwierdzenie usunięcia
  folderu razem z zawartością.
- 457: `_maybeShowCorruptRecoveryDialog(controller)` — modalne pytanie
  `Yes/No` o odzyskanie kopii z lokalnego backupu; przy odzysku zapisuje
  osobne kopie i pokazuje `SnackBar`.
- 528: `enum _FolderAction { rename, delete }`.
- 530: `class _FolderListPane` — lista folderów (iconOnly gdy pane < 165px),
  separatory jak w liście notatek, 533–604 iconOnly, 607–644 normalny z menu
  akcji folderu.
- 673: `class _FolderChipBar` — chipy folderów (mobile) z menu akcji folderu.
- 742: `class _LibraryItemsPane` — lista notebooków i empty state.
- 970: `class _LibraryWorkspace` — wybiera `BoardScreen` lub `NotebookScreen`
  na podstawie `item.kind`, owija w `ChangeNotifierProvider<EditorController>`.
- 998: `class _LibraryRoute` — wąski layout (push'owane), `FutureBuilder` do
  `getNotebook`.
- 1024: `enum _CreateAction { notebook, board }`.
- 1026: `class _PaneResizeHandle` — pasek do przeciągania szerokości pane.
- 1048: `class _LeftZoneToggleTab` — strzałka chevron do collapsowania nawigacji.

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

### `lib/features/editor/state/input_mode.dart` (30 linii)
Ustawienie rozróżniania rysika i palca w edytorze.
- 1: `enum PointerInputMode` — tryby `off` i `on`; `off` zachowuje pisanie
  palcem jak dotąd, `on` wyłącza rozpoczynanie kreski przez
  `PointerDeviceKind.touch`.
- 3: `extension PointerInputModeX` — etykiety/opisy UI oraz semantyka
  `allowsFingerDrawing`.
- 25: `pointerInputModeFromIndex(value)` — bezpieczne odtwarzanie trybu
  z `editor_prefs.json`, fallback do `off`; stare indeksy platformowe `>0`
  migrują do `on`.

### `lib/features/editor/state/page_background.dart` (69 linii)
Model preferencji tła strony/canvasu.
- 3: `enum PageBackgroundStyle { blank, grid, lines }`.
- 5: `extension PageBackgroundStyleX` — etykiety UI.
- 15: `class PageBackgroundSettings` — styl tła i rozstaw linii/kratki,
  clampowany do 16–64 px, JSON `toJson/fromJson`.
- 64: `backgroundPrefsKeyForKind(kind)` — klucze `notebook`/`board` dla
  `editor_prefs.json`.

### `lib/features/editor/state/editor_controller.dart` (2652 linie)
Mózg edytora. **Najczęściej modyfikowany plik aplikacji.** Trzyma stan stron,
narzędzia, kolory, undo/redo, zoom/pan, schowek elementów.
- 33: `class LassoSelection` - trzyma metadane zaznaczenia lasso
  (bounds dokumentowe, ID elementów, delty).
- 65: `_sameInkStrokeIds(a, b)` — szybkie porównanie list stroke'ów po ID.
- 72: `class EditorController extends ChangeNotifier`.
- 73–75: `minViewScale=0.25`, `maxViewScale=4.0`,
  `_inkSaveDebounceDelay=2s`.
- 77: konstruktor — `pages = notebook.pages`, ładuje prefs.
- 83–142: pola — `repository, notebook, _uuid, _imagePicker, pages,
  currentPageIndex, tool, lastEraserTool, lastShapeTool, `pointerInputMode`,
  `stylusButtonsEnabled`, `scratchEraseEnabled`, domyślne tła notebook/board,
  inkColor, inkStrokeWidth, quickColors (3 sloty), recentColors (12),
  _undo/_redoActions, lokalne tła po `notebook.uid`, dirty-sety scalania
  zapisu teł, _prefsSaveDebounce, `_notebookSaveDebounce`,
  lastTextFontFamily/Size/Color, activeTextBlockId, activeTextController,
  `_activeTextEditPageIndex/_activeTextEditBefore`, activeImageBlockId,
  lassoSelection,
  `lassoDragDelta` (`ValueNotifier<Offset>` do płynnego dragowania lassa bez
  pełnego `notifyListeners()` na każdy ruch), _elementClipboard,
  _suppressBackgroundTap, viewScale, viewPan, `inkRevision`,
  `historyRevision`, rewizje ink per `pageId`,
  _pageWidth/_pageHeight/_pageGap`.
- 144–175: gettery `currentPage`, `canUndo`, `canRedo`,
  `allowsFingerDrawing`, `currentBackgroundSettings`, `contentBounds`,
  `layoutPageSize`, `layoutPageGap`, `defaultBackgroundSettingsForKind`.
- 158: `inkRevisionForPage(pageId)` / 162: `pageById(pageId)` — lokalne
  źródło repaintu statycznego ink bez globalnej przebudowy notebooka.
- 179: `dispose()` — domyka aktywną edycję tekstu, flushuje pending prefs/save
  i sprząta listenery.

#### Layout/wiewport
- 197: `updatePageLayout({pageWidth, pageHeight, pageGap})`.
- 212: `setViewTransform({pan?, scale?})`.
- 226: `panBy(delta)`.
- 233: `zoomBy(factor, focalPoint)`.
- 246: `viewportToWorld(offset)` / 251: `worldToViewport(offset)`.

#### Strony
- 255: `pageAt(index)`.
- 259: `_pageExtent` getter (height + gap).
- 261: `_pageOriginForIndex(index)`.
- 268: `_pageIndexForPosition(offset)` — który page index zawiera punkt Y.

#### Lookupy / aktywne elementy
- 279: `findTextBlockById(id)`.
- 290: `findImageBlockById(id)`.
- 301: `_pageIndexContainingTextBlock(id)`.
- 310: `_pageIndexContainingImageBlock(id)`.
- 319: `_ensurePageSelected(pageIndex)`.

#### Per-page entry points (board/notebook → mapują na current page)
Tylko te `*OnPage`, które są realnie wołane z `page_overlay`/`drawing_canvas`.
- 333: `handleTapOnPage(pageIndex, point)`.
- 338: `updateTextBlockContentOnPage(...)` / 348 position /
  357 cały blok / 362 delete / 367 commitMove / 377 commit update.
- 386: `runOcrForImageOnPage`.
- 391: `updateImageBlockPositionOnPage` / 400 cały blok /
  408 OCR text / 413 delete.
- 418: `addInkStrokeOnPage(pageIndex, points, {widthOverride, toolOverride})`.
- 432: `eraseInkStrokesByIdOnPage(pageIndex, ids)`.
- 437: `replaceInkStrokesOnPage(pageIndex, strokes)` — undoowalna podmiana
  stroke'ów strony, używana przez częściową gumkę scratch-erase.
- 442: `commitImageMoveOnPage`.
- 452: `finalizeImageMoveOnPage` — **decyduje czy stroke przechodzi
  na inną stronę** (`_moveImageBlockToPage`) czy zostaje (`commitImageMoveOnPage`).
- 469: `commitImageResizeOnPage`.
- 532: `selectWithLasso(points, pageIndex)` — indeks przestrzenny + Ray-Casting;
  stroke'y liczone w
  koordynatach strony, tekst/obrazy w koordynatach dokumentu; stroke'i gumki
  są ignorowane przez selekcję.
- 649: `updateLassoMove(delta)` — zapisuje bieżące przesunięcie tylko w
  `lassoDragDelta`, bez przebudowy całego controllera.
- 654: `commitLassoMove()` — zatwierdza `lassoDragDelta` jako
  `MoveSelectionAction`, przesuwa bounds i dopiero wtedy robi notify/save.

#### Narzędzia, kolory, prefs
- 478: `setTool(newTool)` — aktualizuje `lastEraserTool` i `lastShapeTool`;
  wybór trybu gumki trafia do `editor_prefs.json`.
- 494: `setActiveTextBlock(id, controller)` / 507 clear; domyka poprzednią
  sesję tekstową jako jedną akcję undo.
- 514: `setActiveImageBlock(id)` / 706 clear.
- 774: `markTextTap()` / 778: `consumeBackgroundTapSuppression()`.
- 784: `setColor(color)`.
- 791: `setLastTextFontFamily` / 796 size / 801 color.
- 807: `setStrokeWidth(value)` — zapisuje trwały rozmiar narzędzi/gumki
  w `editor_prefs.json`.
- 813: `setPointerInputMode(mode)` — zapisuje tryb rozróżniania rysika/palca.
- 822: `setStylusButtonsEnabled(enabled)` — zapisuje obsługę przycisków rysika.
- 831: `setScratchEraseEnabled(enabled)` — zapisuje automatyczną gumkę
  bazgrołem.
- 840: `setDefaultBackgroundSettings(kind, settings)` — zapisuje globalne
  domyślne tło osobno dla notebooków i boardów; oznacza zmieniony typ do
  scalania zapisu preferencji.
- 855: `setCurrentBackgroundSettings(settings)` — zapisuje lokalne tło
  bieżącego notebooka/boarda po `uid`; oznacza zmieniony `uid` do scalania
  zapisu preferencji.
- 862: `setQuickColor(index, color)`.
- 871: `_addRecentColor(color)` (cap 12, dedup po ARGB).
- 880: `_loadEditorPrefs()` (`editor_prefs.json`: kolory, tekst,
  `inkStrokeWidth`, `lastEraserTool`, `pointerInputMode`,
  `stylusButtonsEnabled`, `scratchEraseEnabled`, domyślne i lokalne tła; nie
  nadpisuje lokalnie zmienionych teł, jeśli load kończy się po zmianie UI).
- 993: `_schedulePrefsSave()` (debounce 250 ms).
- 1000: `_saveEditorPrefs()` — zapisuje preferencje, scalając tła z aktualnym
  plikiem zamiast nadpisywać je snapshotem z jednej instancji kontrolera.
- 1036: `_readEditorPrefs()` — defensywny odczyt istniejącego JSON-a
  preferencji do scalania.
- 1050: `_mergedBackgroundDefaults(...)` — scala globalne tła per
  `NotebookKind`, aktualizując tylko dirty typy albo brakujące klucze.
- 1072: `_mergedLocalBackgrounds(...)` — scala lokalne tła per `uid`,
  aktualizując tylko dirty notatniki/tablice.
- 1093: `_eraserToolFromIndex(value)` — waliduje, że zapisany indeks to tryb gumki.
- 1101: `_colorFromHex(value)`.

#### Gesty / undo / redo / strony
- 1127: `handleTap(point)` — text vs image vs nic.
- 1138: `undo()` / 1151: `redo()` — domykają aktywną edycję tekstu przed operacją.
- 1164: `addPage()` — nowy `NotePage`, czyści aktywne.
- 1177: `deleteLastPage()` — usuwa ostatnią stronę, nie schodzi poniżej jednej strony.
- 1191: `_createPage(index)`.
- 1203: `_ensurePageCount(working, count)`.
- 1209: `setCurrentPage(index)`.
- 1224: `toggleBookmark()`.
- 1230: `addIndexTab({color, position})` — undoowalnie dopisuje nową zakładkę na bieżącej stronie.
- 1243: `updateIndexTab({id, color, position})` — undoowalnie edytuje konkretną zakładkę.
- 1266: `clearIndexTab(id)` — undoowalnie usuwa konkretną zakładkę indeksującą.
- 1277: `beginIndexTabDrag({pageIndex, id})` — start przeciągania zakładki, zapamiętuje stronę do jednej akcji undo.
- 1297: `updateIndexTabDrag({id, position})` — live przesunięcie zakładki góra/dół bez zapisu na każdy ruch.
- 1322: `commitIndexTabDrag()` — kończy przeciąganie i zapisuje jedną akcję undo.

#### Operacje tekstowe (current page)
- 1349: `addTextBlock(position)` — Quill Delta z lastText* defaultami.
- 1375: `addTextBlockFromText(position, text)` — z clipboarda/pliku.
- 1404: `updateTextBlockContent(before, {plainText, deltaJson})` — szybka ścieżka
  wpisywania: aktualizuje `pages` bez
  `notifyListeners()` i debouncuje zapis.
- 1419: `updateTextBlockPosition`.
- 1426: `updateTextBlockWidth`.
- 1433: `deleteTextBlock`.
- 1443: `commitTextMove(id, start, end)`.
- 1457: `commitTextResize(before, after)`.
- 1465: `commitTextUpdate(before, after)` — undoowalne zatwierdzenie zmiany
  szerokości/rotacji/pozycji całego bloku tekstu.

#### Obrazy / clipboard / wklejanie
- 1474: `addImageBlock(position)` — image picker; natywnie kopiuje plik do
  katalogu obrazów, w web zapisuje bajty inline.
- 1491: `insertFromFilePicker(position)` — png/jpg/jpeg/pdf/txt; web przyjmuje
  pliki jako bajty, w tym PDF renderowany przez `PdfDocument.openData`.
- 1544: `insertFromClipboard(position)` — image lub tekst z `super_clipboard`,
  fallback `Clipboard.getData(text/plain)`; przed wstawieniem wybiera stronę z pozycji dokumentowej.
- 1551: `pasteElementOrClipboard(position)` — wkleja zapamiętany
  `_elementClipboard` (Text/Image/Lasso) albo wpada do `insertFromClipboard`;
  tekst/obrazy trafiają na stronę wynikającą z pozycji dokumentowej.
- 1633: `copyActiveElementToClipboard()` — lasso→wewnętrzny clipboard,
  text→clipboard text+`_elementClipboard`, image→PNG/JPEG.
- 1685: `cutActiveElementToClipboard()` — copy + `deleteActiveElement`.
- 1694: `deleteActiveElement()` — kasuje aktywny tekst lub obraz na właściwej stronie.
- 1719: `copyActiveImageToClipboard()` — wykrywa jpg/jpeg → `Formats.jpeg`, inaczej `png`.
- 1748: `_tryInsertImageFromClipboard(reader, position)` — PNG first, potem JPEG.
- 1765: `_readTextFromClipboard(reader)`.
- 1773: `_readClipboardImageBytes(reader, format)`.
- 1797: `_readStreamBytes(stream)`.
- 1805: `_initialImageBlockSize(sourceSize)` — clampuje do strony (notebook
  używa `_pageWidth/_pageHeight`, board ma stałe 360x520).
- 1846: `_addImageBlockFromBytes(bytes, position, extension)` — natywnie
  zapisuje bajty do pliku, w web trzyma je inline w bloku i SQLite.
- 1891: `_insertFile(file, position)` — branchuje po rozszerzeniu (png/jpg/pdf/txt).
- 1868: `_addImageBlockFromFile(file, position, {runOcr=true})` — kopiuje plik,
  blok trzyma tylko `path`, OCR jeżeli wspierane.
- 1911: `_activateInsertedImage(id)` — switch na tool `edit`, set active image.
- 1963: `_addPdfAsImages(pdfFile, position)` — używa `pdfx` (non-Linux),
  renderuje każdą stronę, zapisuje PNG do trwałego katalogu obrazów, bez `bytes`
  w bloku; na końcu dopisuje nowe obrazy do aktualnych stron zamiast nadpisywać
  `pages` snapshotem sprzed importu.
- 1980: `_addPdfBytesAsImages(bytes, position)` / 1998:
  `_addPdfDocumentAsImages(...)` — webowy import PDF z bajtów; wyrenderowane
  strony przechowuje jako obrazy inline w SQLite.
- 2074: `_addPdfAsImagesWithPoppler(pdfFile, position)` — Linux fallback,
  uruchamia `pdftoppm` (`poppler-utils`), zapisuje PNG do trwałego katalogu obrazów.
- 2156: `_appendImageBlocksOnPages(additions)` — scala obrazy z importu PDF z aktualnym stanem stron, zachowując istniejące `imageBlocks`.
- 2175: `runOcrForImage(block)` — przed dostępem do pliku zwraca jawny
  komunikat o ograniczeniu Android/iOS; 2442: `supportsOcr` dla UI.
- 2112: `updateImageBlockPosition` / 2119 size / 2134 OCR text.
- 2149: `restoreImageCache(pageIndex, blockId)` — odtwarza plik z legacy `bytes`, potem czyści `bytes`.
- 2175: `deleteImageBlock(id)`.

#### Strokes / commits
- 2182: `addInkStroke(points, {widthOverride, toolOverride})` — zwraca ID
  zapisanego stroke'a do atomowego handoffu overlay → warstwa statyczna;
  highlighter
  ma `inkStrokeWidth * 8.0`; zapis do repo jest debounced, żeby szybkie
  odrywanie rysika nie blokowało kolejnego stroke'a na SQLite/backup.
- 2206: `eraseInkStrokesById(ids)` — usuwa stroke'i undoowalnie i debouncuje
  zapis.
- 2219: `replaceInkStrokes(strokes)` — undoowalnie podmienia listę stroke'ów;
  używane przez częściowe wycinanie zamazanego zakresu.
- 2228: `createInkStrokeId()` — publiczny generator ID dla nowych fragmentów
  stroke'ów po rozcięciu.
- 2230: `commitImageMove(id, start, end)`.
- 2244: `commitImageResize(before, after)` — porównuje pos/size/crop/rotation.
- 2258: `_moveImageBlockToPage(fromIdx, toIdx, id, position)`.

#### Helpery
- 2379: `_persistImageFile(file)`.
- 2387: `_persistImageBytes(bytes, filename)`.
- 2394: `_imagesDir()` — tworzy/trzyma obrazy w dokumentach aplikacji, nie w
  katalogu tymczasowym.
- 2403: `_colorToHex(color)`.
- 2408: `_imageSize(file)` / 2412: `_imageSizeFromBytes(bytes)` —
  `instantiateImageCodec`.
- 2419: `_runOcr(file)` — mlkit, Latin script.
- 2435: `_isOcrSupported()` — Android/iOS only.
- 2360: `_computeContentBounds()` — bbox stroke + text + image dla widoku.
- 2411: `_applyAction(action)` — domyka aktywną edycję tekstu, push undo,
  clear redo, apply, update page.
- 2420: `_applyInkAction(action)` — aktualizuje tylko stronę ink, jej rewizję,
  globalną rewizję minimapy i historię; pełne `notifyListeners()` zachowuje
  wyłącznie dla boarda, którego bounds zależą od stroke'ów.
- 2445: `_applyActionWithoutNotify(action)` — wariant dla commitowania lassa;
  zmienia `pages` i undo stack bez pośredniego `notifyListeners()`.
- 2456: `_updatePage(page)`.
- 2464: `_replaceTextBlockOnCurrentPage(block, {notify})` — live update tekstu
  bez przebudowy drzewa podczas szybkiego pisania.
- 2478: `_beginTextEdit(blockId)` / 2493: `_commitActiveTextEdit()` /
  2517: `_discardActiveTextEdit()` — grupowanie wielu znaków w jedną akcję undo.
- 2606: `_scheduleSave()` — debouncuje zapis notebooka
  przez `_inkSaveDebounceDelay` po live-edit tekstu i krótkich seriach stroke'ów.
- 2614: `_save()` — wywołuje
  `repository.saveNotebook(notebook.copyWith(pages, updatedAt=now))`.
- 2622–2652: sealed `_ElementClipboardItem` + `_TextElementClipboardItem`
  + `_ImageElementClipboardItem` + `_LassoElementClipboardItem`.

---

### `lib/features/editor/presentation/editor_settings_screen.dart` (448 linii)
Panel ustawień edytora.
- 12: `class EditorSettingsScreen extends StatelessWidget` — ekran ustawień
  z górnym `TabBar` (`System`, `Visual`, `Widgets`); zakładka systemowa zawiera
  `Device mode` (`Computer`/`Tablet`) oraz trzy `SegmentedButton` `Off/On`:
  rozróżnianie rysika/palca, obsługa przycisków rysika oraz gumka bazgrołem,
  plus pozycje `Errors` i `Optimization`; `Optimization` pokazuje wyłącznie
  wpisy po heurystycznym filtrze, a terminal nadal ma pełny raw log;
  zakładka Visual zawiera globalne domyślne tło osobno dla notebooków i boardów.
- 214: `_showErrorsDialog(context)` — dialog `Errors` z `Copy`, `Clear`,
  `Close` i zwijanym podglądem zawartości logu.
- 299: `_showOptimizationDialog(context)` — dialog `Optimization` z
  `Copy`, `Clear`, `Close`, opisem że to tylko filtered entries, oraz
  zwijanym podglądem wpisów z `OptimizationLog`.
- 392: `class _BackgroundSection` — kontrolki stylu tła `Plain/Grid/Lines`,
  slider zagęszczenia i podgląd.

### `lib/features/editor/presentation/editor_screen.dart` (2663 linie)
Layout edytora notebooka (stronicowy). Listener gestów, transformacja zoom/pan
strony, przesunięcie kolumny strony, mini-mapa, podgląd skali, podgląd ramki
strony.
- 33: `class EditorScreen extends StatefulWidget`.
- 40: `_EditorScreenState` — stałe (41–55: `_pageGap=26`, paddings,
  footer `Add page`, sensytywności pan/scroll, scale floors, granica kolumny
  podglądu, minimalna użyteczna szerokość canvasu, tolerancja zatrzymania na
  krawędzi). A4 ratio czytane z `AppMetrics.a4HeightRatio`.
- 56–85: pola stanu (ScrollController, GlobalKey canvas, `_pageExtent`,
  `_isViewportNavigating`, aktywny rysik, pending touch navigation, gesty
  multi-touch, `_pageScale=1`, `_pagePan`, `_pageMin/MaxScale`,
  `_pageColumnOffset`, granice przesunięcia kolumny, throttling logu zbyt
  wąskiego okna).
- 87: `initState` — `_scrollController.addListener(_handleScroll)`.
- 93: `dispose`.
- 100: `_handleScroll()`.
- 107: `_onPagesScroll(notification, controller)` — synchronizuje bieżącą stronę
  po zakończeniu scrolla; scroll nie tworzy stron automatycznie.
- 122: `_syncCurrentPageToViewport(controller)`.
- 145: `_addPageBelow(controller)` — dodaje stronę przez kontroler bez
  automatycznego przewijania widoku.
- 149: `_syncPageTransformBounds({docWorldSize, fitToWidthScale, viewportSize})`.
- 186: `_syncPageColumnOffsetBounds({basePageLeft})` — clampuje poziome
  przesunięcie kolumny strony do obszaru poza kolumną podglądu.
- 207: `_applyPageColumnPan(deltaX)` — przesuwa kolumnę strony gestem dwoma
  palcami w osi X, z clampem poza kolumną podglądu i tolerancją zatrzymania
  na krawędziach.
- 233: `_snapToPageColumnEdge(offset)` / 243: `_snapPageColumnToEdge(edge)` —
  wygaszają ułamkowe drgania przy limicie przesunięcia.
- 252: `_isNavigationPointerKind(kind)` — touch/trackpad/mouse (NIE pen/stylus).
- 257: `_isStylusPointerKind(kind)`.
- 262: `_onPointerDown(event, docWorldSize, viewportSize)` — pending touch
  navigation przy narzędziach rysowania; gdy rysik jest aktywny, dotyk dłoni
  nie wchodzi w nawigację viewportu; przy `allowsFingerDrawing == false`
  pojedynczy dotyk od razu zaczyna przesuwanie widoku.
- 308: `_onPointerMove(...)` — multi-touch pinch/pan; gdy pierwszy dotyk
  przesunie się przed drugim palcem, awansuje go z pending do aktywnych pointerów,
  żeby gest dwoma palcami nadal wystartował bez przypadkowego stroke'a; w trybie
  bez pisania palcem jeden palec przesuwa widok, dwa palce zoomują.
- 399: `_onPointerUpOrCancel(event)`.
- 433: `_startViewportNavigation(docWorldSize, viewportSize)` — startuje
  nawigację od jednego palca w trybie bez pisania palcem albo od dwóch palców
  w starym trybie.
- 464: `_onPointerPanZoomStart(event, ...)` — trackpad scroll wheel.
- 489: `_onPointerPanZoomUpdate(...)`.
- 531: `_onPointerPanZoomEnd(event)`.
- 543: `_onPointerSignal(event, ...)` — `PointerScrollEvent` (myszka).
- 567: `_applyPageTransform({scale, pan, ...})` — aktualizuje `_pageScale/_pagePan`.
- 615: `_clampPagePan({pan, scale, docWorldSize, viewportSize})` — centruje
  dokument w osi, w której po oddaleniu mieści się w viewportcie.
- 651: `_stopViewportNavigation()`.
- 661: `_midpoint(a, b)` / 665: `_distanceBetween` / 669: `_documentHeight`.
- 676: `_visibleDocumentRect({docWorldSize, viewportSize})` — który fragment widać.
- 715: `_pageBoundaryVisibilityInDocument(...)` — liczy widoczne krawędzie strony;
  przy pełnej widoczności strony zwraca wszystkie krawędzie.
- 771: `_visiblePageRange(...)` — wylicza okno renderowanych stron
  jako strona viewportu + jedna powyżej i trzy poniżej, żeby długie notatniki
  nie budowały wszystkich stron naraz.
- 800: `_insertPositionForViewport({...})` — gdzie wstawić blok dla insert toolbara; wybiera stronę z centrum widoku, nie ze starego `currentPageIndex`.
- 831: `_withBusyOverlay(...)` — pokazuje centralny spinner podczas długiego importu/eksportu i ukrywa go w `finally`.
- 844: `_handleInsertFile(controller)` — wstawianie pliku przez picker pod busy overlayem.
- 857: `_handleExport(controller, format)` — eksportuje aktualną notatkę do
  PDF/PNG przez `NotebookExportService`, obsługuje anulowanie dialogu zapisu.
- 887: `_openSettings()` — otwiera `EditorSettingsScreen` i przenosi na trasę
  istniejący `EditorController` przez `ChangeNotifierProvider.value`.
- 926: `_handleDelete(controller)`.
- 930: `_showIndexTabEditor(controller, pageIndex, tabId)` — dialog edycji istniejącej zakładki po dwukliku.
- 1079: `_indexTabChannelSlider(...)` — slider RGB w dialogu zakładki.
- 1105: `_showCanvasContextMenu(...)` / 1150: `_contextMenuInsertPosition(...)` — menu `Paste` z prawego kliku, przycina punkt wstawiania do obszaru strony.
- 1178: `_startTouchContextMenuTimer(...)` — po 1 s przytrzymania palcem na canvie pokazuje menu `Paste` pod kursorem.
- 1225: `_logNarrowCanvas(width)` — debug-only, throttlowany log `[layout]`
  gdy panel edytora jest za wąski do bezpiecznego renderowania.
- 1241: `build(context)` — Scaffold(AppBar=tytuł notebooka+settings) + Column
  (EditorToolbar, TextEditToolbar gdy aktywny tekst, InsertToolbar gdy `_isInsertToolbarVisible`,
  LayoutBuilder z komunikatem przy zbyt wąskim oknie albo głównym canvas:
  SingleChildScrollView (bez drag-scrolla przy narzędziach ink) + poziome
  przesunięcie kolumny strony + Listener +
  Transform(`_pageScale/_pagePan`) + Stack[tylko widoczne strony
  (DecoratedBox+`PageBackgroundPaint`+`_PageFramePainter`),
  `DocumentPageOverlay`(bg+inactive),
  `DocumentDrawingCanvas`, `DocumentPageOverlay`(active), `_IndexTabsOverlay`]
  + przyciski `Add page` / `Delete page`
  pozycjonowany w przestrzeni dokumentu tuż pod ostatnią stroną); pozycjonuje
  `_ZoomPercentBadge` + `_ProjectMiniMapOverlay` + `BusyOverlay`.
- 1694–1727: skróty klawiszowe (Ctrl/Cmd+V/C/X, Delete) → CallbackActions
  (paste/copy/cut/delete) — **wyłączone gdy aktywny TextEditor**.
- 1758: `class _PasteFromClipboardIntent`.
- 1762: `class _IndexTabEditResult` — wynik dialogu edycji zakładki (`save/remove`).
- 1789: `_CopyElementIntent`.
- 1793: `_CutElementIntent`.
- 1797: `_DeleteElementIntent`.
- 1801: `enum _CanvasContextAction { paste }`.
- 1803: `class _BoundaryVisibility` — które krawędzie strony są widoczne.
- 1836: `class _PageRenderRange` — półotwarty zakres stron renderowanych w
  głównym edytorze.
- 1843: `class _PageFramePainter extends CustomPainter` — rysuje pomarańczową
  ramkę aktywnej strony.
- 1918: `class _IndexTabsOverlay` — rysuje wiele kolorowych zakładek; dwuklik otwiera edycję, a długie przytrzymanie pozwala przesuwać zakładkę góra/dół.
- 2028: `class _ZoomPercentBadge` — chip „150%".
- 2077: `class _ProjectMiniMapOverlay extends StatefulWidget` (mini-mapa),
  nasłuchuje `controller.inkRevision`, aby stroke odświeżał miniaturę bez
  globalnego rebuilda edytora.
- 2100: `_ProjectMiniMapOverlayState` — synchronizacja widoku + cache miniatur obrazów/PDF.
- 2134: `_precacheMinimapImages()` — dekoduje asynchronicznie obrazy tylko dla stron blisko widoku.
- 2211: `_minimapImagePageRange()` — zakres stron, dla których minimapa trzyma zdekodowane obrazy.
- 2269: `_syncMinimapToViewport()`.
- 2303: `_visiblePanelHeight(...)` / 2307: `_contentHeight(...)` — wysokość mini-mapy rośnie z liczbą stron do limitu panelu.
- 2423: `class _ProjectMiniMapPainter` — rysuje strony, content thumbnails,
  zdekodowane miniatury obrazów/PDF oraz paski zakładek, bez podświetlania krawędzi.
- 2636: `class _MiniMapImageCacheEntry` — cache key + zdekodowany obraz mini-mapy.
- 2643: `class _MiniMapViewportOverlayPainter` — rysuje wypełniony prostokąt widoku bez podświetlanych krawędzi.

### `lib/features/editor/presentation/widgets/busy_overlay.dart` (38 linii)
Centralny overlay ładowania dla długich operacji importu/eksportu w edytorach.
- 3: `class BusyOverlay extends StatelessWidget` — półprzezroczysta blokująca warstwa z centralnym `CircularProgressIndicator`.

### `lib/features/editor/presentation/widgets/drawing_canvas.dart` (4233 linie)
Dwie warianty canvasu rysowania. **Notebook używa `DocumentDrawingCanvas`,
board używa `DrawingCanvas`.** Logika prawie zduplikowana — to świadoma decyzja
(różne układy współrzędnych). Oba warianty opóźniają start stroke dla dotyku,
odrzucają duży kontakt dłoni, dają pierwszeństwo aktywnemu rysikowi/myszy
i przy aktywnym `PointerInputMode` blokują rozpoczynanie kreski palcem.
- 37: `_debugInkLog(message)` — debug-only, bardzo skondensowane logi
  `[ink]` końca stroke'a i `[scratch]` bazgrołowej gumki.
- 44: `class _InkPerfLog` — debug-only agregat per stroke: czas obsługi
  `PointerMove`, liczba wywołań repaintu overlayu, czas do zaplanowanej klatki
  oraz dodatkowo `canvasBuildUs*`, `staticPaintUs*`, `activePaintUs*` i
  rzeczywiste opóźnienie `inputToPaintUs*` do zakończenia paintu overlayu.
- 254: `_CachedInkGeometry` / 308: `_geometryForStroke` — cache `Path`, bounds
  i segmentów hit-testu per niezmienny `InkStroke`.
- 274: `_StaticInkLod` / 354: `_staticInkLodForScale` /
  364: `_pathForStrokeLod` — trzy progowe poziomy detalu; uproszczone ścieżki
  pióra/highlightera są liczone raz i cache'owane, aktywny stroke i gumki
  pozostają pełnej jakości.
- 425: `_savedInkLayerBounds(...)` — ogranicza bufor `saveLayer` do sumy
  wizualnych bounds stroke'ów zamiast pełnego canvasu.
- 458: `_cachedStrokeHitTest(...)` / 477: `_drawSavedStroke(...)` — wspólna
  geometria hit-testu i renderowania zapisanych stroke'ów.
- 548: `class _CanvasProjectStats` — zwięzły opis wielkości renderowanego
  kontekstu (`pages/renderPages/savedStrokes/savedPts`) dopisywany do logów
  `[ink]`.
- 578: `_eraseStrokeParts(...)` / 614: `_scratchEraseInkHitCount(...)` —
  scratch-erase ma dwa promienie: mała tolerancja tylko do odpalenia gumki
  oraz szeroki promień realnego usunięcia, żeby nie zostawiać kropek tuszu;
  do odpalenia wymaga `3+` trafień istniejącego tuszu; indeks przestrzenny
  odrzuca dalekie stroke'i przed dokładnym testem punktów/segmentów.
- 724: `_isScratchEraseGesture(...)` — wymaga aktywnego pena, `3+` nawrotów
  oraz minimalnego zagęszczenia ścieżki względem obszaru gestu.
- 853: `_scratchEraseIntersectionRadius(strokeWidth)` — mała tolerancja
  przecięcia wizualnej linii (`max(1, width * 0.5)`), nie pełny promień gumki.
- 860: `_scratchEraseDeleteRadius(strokeWidth)` — realny promień usuwania
  zamazanego zakresu (`max(8, width * 6)`), zgodny ze starszym zachowaniem.
- 880: `class DrawingCanvas extends StatefulWidget` — board, jedna strona/canvas.
- 902: `class DocumentDrawingCanvas extends StatefulWidget` — notebook,
  N stron pionowo, params `{worldOrigin, pages, pageSize, pageGap,
  allowMultiTouch, interactionEnabled, firstPageIndex, lastPageIndex,
  effectiveScale}`; statyczny ink renderuje tylko wskazany zakres stron jako
  osobne `RepaintBoundary`, hit-test nadal liczy po pełnym dokumencie.
- 930: `_buildInkPath(...)` / 967: `_shouldSmoothStroke(...)` — wspólne,
  adaptacyjne wygładzanie szybkich stroke'ów pen/highlighter; kształty, lasso
  i gumka zostają odcinkami.
- 1001: `_shouldAcceptInkPoint(...)` —
  wspólny filtr punktów pen/highlighter: odrzuca nagłe, boczne skoki kontaktu
  oddalone od dotychczasowego kierunku kreski.
- 1019: `_shouldRejectViewportEdgePoint(...)` / 1037 `_isNearViewportEdge(...)` —
  ignoruje nienaturalne skoki do samej krawędzi okna programu.
- 1048: `_isDiscontinuousInkJump(...)` — wykrywa boczny, daleki skok względem
  ostatniego stabilnego kierunku kreski.
- 1077: `_toolForPointerEvent(...)` / 1093 `_toggleEraserShortcut(...)` /
  1099 `_hasStylusButton(...)` — tymczasowo używają ostatniej gumki dla
  `invertedStylus` oraz, gdy `stylusButtonsEnabled == true`, dla natywnego
  stanu `StylusButtonState`, standardowych przycisków stylusa Fluttera
  (`primary/secondary`) i linuksowego fallbacku `secondary/middle mouse`;
  obsługują też przełączenie gumki z Apple Pencil double tap.
- 1113: `_eraserStrokeRadius(strokeWidth)` — wspólny promień hit-testu i śladu
  widmo magicznej gumki (`max(4, width * 1.5)`).
- 1117: `_trimEraserTrail(trail)` — ogranicza długość widocznego śladu magicznej
  gumki do `_eraserTrailMaxLength`.

#### `_DrawingCanvasState` (board) — 1128–2397
- 1132–1192: stan pointera, handoffu zapisanych stroke'ów i metryk `_inkPerf`.
  `_inkPerf` — stan do jednej linii `[ink]` po zakończeniu stroke'a, razem z
  agregatem opóźnień i korelacją z `FrameTimingTracker`.
- 1194: `build` — `MouseRegion` ustawia natywny kursor `basic` dla
  pen/highlighter, `Listener` z `_onPointerDown/Move/Up/Cancel` +
  `ValueListenableBuilder(controller.lassoDragDelta)` + dwa `CustomPaint` w
  `RepaintBoundary`: zapisane stroke'i i szybki overlay aktywnej kreski.
  Painter zapisanych stroke'ów używa ograniczonego `saveLayer`, cache geometrii
  i progowego LOD; mierzy też `canvasBuildUs*` dla tej gałęzi.
- 1300: `_onPointerDown(event, controller, viewportSize)` — wybiera aktywny pointer;
  dotyk startuje dopiero po progu ruchu w trybie `Off`; pozostałe tryby
  blokują pisanie palcem; rysik/mysz startują od razu; przycisk rysika ustawia
  gumkę tylko dla aktywnego stroke'a; start stroke'a łapie też kursor
  `FrameTimingTracker`.
- 1411: `_onPointerMove` — dodaje punkty, ewentualnie eraser; mierzy czas obsługi
  eventu; wykrywa też zmianę `buttons` w trakcie ruchu i przełącza segment na
  gumkę/poprzednie narzędzie.
- 1527: `_onPointerUp` — commit stroke przez `controller.addInkStroke`; przed
  commitem pen sprawdza, czy skupiony szybki gest ma wyciąć fragmenty stroke'ów.
- 1608: `_syncActiveToolWithPointerMove(...)` — domyka bieżący segment i zaczyna
  nowy po wciśnięciu lub puszczeniu przycisku rysika w trakcie kontaktu.
- 1639: `_commitCurrentSegment(...)` / 1694: `_addCurrentStroke(...)` —
  wspólny commit używany przy normalnym `up` i przy przełączaniu narzędzia.
- 1728: `_retainCommittedStroke(...)` / 1749: `_handleStaticInkPainted(...)` —
  gotowy stroke pozostaje w szybkim overlayu do chwili potwierdzonego paintu
  właściwej rewizji warstwy statycznej.
- 1766: `_tryCommitScratchErase(...)` — jeśli `scratchEraseEnabled`, najpierw
  sprawdza `3+` nawrotów i zagęszczenie gestu, potem `3+` małe trafienia
  istniejącego tuszu, a dopiero szerokim promieniem podmienia stroke'i przez
  `replaceInkStrokes*`; loguje jedną linię `[scratch]` tylko przy rozpoznanym
  geście bazgrołowej gumki.
- 1822: `_clearCurrentSegmentForToolSwitch()` — czyści overlay bez kończenia
  aktywnego pointera.
- 1842: `_onPointerCancel`.
- 1856: `_resetCurrent()`.
- 1894: `_notifyInkChanged()` — lekki repaint overlayu aktywnej kreski,
  koalescowany do jednej zaplanowanej klatki; aktualizuje metryki `_inkPerf`.
- 1909: `_logStrokeUp(...)` — jedna linia `[ink]` po zakończeniu stroke'a
  boarda z metrykami wielkości projektu i `FrameTimingSummary`
  (`build/raster/total` dla klatek, które wydarzyły się w trakcie stroke'a),
  plus zapis podejrzanych przypadków do `OptimizationLog`; zawiera też
  rozbicie `canvasBuildUs*`, `staticPaintUs*`, `activePaintUs*`,
  `inputToPaintUs*` oraz
  `BoardScenePerfSummary` z `BoardScreen`.
- 1962: `_addEraserTrailPoint(offset)` — zbiera i przycina punkty śladu widmo magicznej gumki.
- 1970: `_activeTool(controller)` — zwraca override z przycisku rysika albo
  aktualne narzędzie controllera.
- 1974: `_toWorld(local)`.
- 1978: `_shouldAddPoint(offset, tool)` — min odległość + filtr skoków kontaktu.
- 1999: `_startSnapTimer(offset)` — po holdzie z czystym kształtem wywołuje `_snapToShape`.
- 2009: `_eraseAt(offset, page, controller)` — kandydaci z indeksu przestrzennego.
- 2024: `_resolvedPage(controller)` / 2028: `_resolvedPageIndex`.
- 2032: `_strokeHitTest(stroke, point, radius)`.
- 2036: `_snapToShape()` — wykrywa line/rect/ellipse.
- 2094: `_clearSnapHintSoon()`.
- 2107: `_isRoughlyStraight(start, end, points)`.
- 2131: `_isRoughlyRectangle(points)`.
- 2156: `_isRoughlyEllipse(points)`.
- 2225: `_findFarthestCorner(points, holdPoint)`.
- 2249: `_isInkTool(tool)`.
- 2253: `_isSnapTool(tool)` — pen/highlighter snapują, eraser/kształty nie.
- 2257: `_usesCustomInkCursor(tool)` — pen/highlighter używają natywnego kursora `basic`.
- 2261: `_effectiveStrokeWidth(tool, baseWidth)` — highlighter ma mnożnik 8,
  zwykła gumka `_eraserBrushWidthScale`.
- 2299: `_squareCorner(start, end)` — wymuszony kwadrat/koło.

#### `_DocumentDrawingCanvasState` (notebook) — 2399–3832
Te same metody co wyżej, ale operują w przestrzeni dokumentu (offset per page).
- 2403–2464: stan pointera, handoffu zapisanych stroke'ów i metryk
  `_inkPerf` — stan do jednej linii `[ink]` po zakończeniu stroke'a, razem z
  agregatem opóźnień i korelacją z `FrameTimingTracker`.
- 2466: `build` — też nasłuchuje `lassoDragDelta` przy repaint zaznaczonych
  stroke'ów; aktywny overlay tuszu nie jest dodatkowo klipowany; mierzy też
  `canvasBuildUs*` dla notebookowego canvasa.
- 2560: `_buildSavedInkPages(...)` — osobny stabilny `RepaintBoundary` i
  rewizja ink dla każdej renderowanej strony.
- 2599: `_onPointerDown` / 2730 Move / 2876 Up; lasso w dokumencie
  woła `selectWithLasso`, aktywny `PointerInputMode` blokuje pisanie palcem,
  `Move` mierzy czas obsługi eventu, a przycisk rysika ustawia gumkę dla
  aktywnego stroke'a także gdy `buttons` zmienia się w trakcie ruchu.
- 2962: `_syncActiveToolWithPointerMove(...)`.
- 3003: `_commitCurrentSegment(...)` / 3059: `_addCurrentStroke(...)`.
- 3084: `_retainCommittedStroke(...)` / 3105: `_handleStaticInkPainted(...)` —
  notebookowy handoff overlay → statyczna strona.
- 3122: `_tryCommitScratchErase(...)` — jeśli `scratchEraseEnabled`,
  notebookowy wariant częściowego wycinania konwertuje gest z dokumentu do
  koordynatów strony; loguje jedną linię `[scratch]` tylko przy rozpoznanym
  geście bazgrołowej gumki.
- 3175: `_clearCurrentSegmentForToolSwitch()`.
- 3210: `_resetCurrent`.
- 3249: `_notifyInkChanged()` — lekki repaint overlayu aktywnej kreski,
  koalescowany do jednej zaplanowanej klatki; aktualizuje metryki `_inkPerf`.
- 3264: `_logStrokeUp(...)` — jedna linia `[ink]` po zakończeniu stroke'a
  notebooka z rozmiarem renderowanego zakresu stron i `FrameTimingSummary`,
  plus zapis podejrzanych przypadków do `OptimizationLog`; zawiera też
  rozbicie `canvasBuildUs*`, `staticPaintUs*`, `activePaintUs*` i
  `inputToPaintUs*`.
- 3335: `_addEraserTrailPoint(offset)` — zbiera i przycina punkty śladu widmo magicznej gumki.
- 3343: `_activeTool(controller)` — zwraca override z przycisku rysika albo
  aktualne narzędzie controllera.
- 3347: `_toWorld(local)`.
- 3372: `_pageOrigin(pageIndex)` / 3382: `_toPageLocal(world, pageIndex)` /
  3390: `_toDocument(pageLocal, pageIndex)` / 3398: `_isInsidePage(pageLocal)`.
- 3405: `_shouldAddPoint(offset, tool)` — min odległość + filtr skoków kontaktu.
- 3426: `_startSnapTimer`.
- 3436: `_eraseAt(localOffset, pageIndex)` — kandydaci z indeksu przestrzennego.
- 3454: `_strokeHitTest` / 3471: `_snapToShape`.
- 3529: `_clearSnapHintSoon`.
- 3542: `_isRoughlyStraight` / 3566: `_isRoughlyRectangle` / 3591: `_isRoughlyEllipse`.
- 3660: `_findFarthestCorner`.
- 3684: `_isInkTool` / 3688: `_isSnapTool` /
  3692: `_usesCustomInkCursor` / 3696: `_effectiveStrokeWidth`.
- 3734: `_squareCorner`.

#### Paintery
- 3834: `class _InkPainter extends CustomPainter` (board) — rysuje zapisane
  stroke'i i lasso selection w `saveLayer` ograniczonym do bounds ink; korzysta
  z cache geometrii i LOD, loguje `staticPaintUs*`; nie odświeża się przy
  każdym punkcie aktywnej kreski.
- 3892: `class _InkOverlayPainter extends CustomPainter` — lekka warstwa
  aktywnej kreski, snap hint i śladu magicznej gumki,
  sterowana `ValueNotifier`; ślad magicznej gumki jest krótkim, rozmytym trailem bez
  rdzenia, z gradientową maską ogona do pełnej przezroczystości i warstwą
  ograniczoną do bounds traila; aktywny ślad
  zwykłej gumki ma kolor papieru, ale pojedynczy punkt zwykłej gumki nie jest
  rysowany jako okrągły preview; zapisany stroke gumki nadal czyści przez
  `BlendMode.clear`; rysuje też stroke'i oczekujące na handoff.
- 4134: `_InkPageLayer` / 4180: `_PageInkPainter` — statyczny ink notebooka
  per strona i per rewizja, z osobnym `RepaintBoundary`, ograniczonym
  `saveLayer`, cache geometrii i LOD.

### `lib/features/editor/presentation/widgets/page_overlay.dart` (2029 linii)
Warstwa interaktywna nad rysunkiem (tekst + obrazy, drag/resize/crop).
- 32: `class PageOverlay extends StatelessWidget` (board, single-page);
  aktywna warstwa przepuszcza gesty lasso mimo `tool.isInk`; przekazuje
  `lassoDragDelta` tylko do elementów zaznaczonych lasso.
- 161: `class DocumentPageOverlay extends StatelessWidget` (notebook, N stron).
  Params `firstPageIndex/lastPageIndex` oraz
  `renderBackground/renderInactive/renderActive` (dwie warstwy w EditorScreen:
  bg+inactive PRZED canvasem, active PONAD).
- 220: `class _TextBlockWidget extends StatefulWidget`.
- 243: `_TextBlockWidgetState` — build/_initQuill/_isOnFrame, uchwyty
  tekstu w stylu Canva: punkt w lewym górnym rogu skaluje okno przez
  rozmiar czcionki i deltę Quill, prawy pusty prostokątny uchwyt zmienia
  szerokość z zawijaniem tekstu, przycisk przesuwania, dwuklik w dozwolonych
  trybach przełącza blok w edycję; helpery do delty Quill, poprawne mapowanie
  atrybutów list Quilla i skróty `Ctrl/Cmd+B/I/U`, `Ctrl/Cmd+Shift+7/8/C`;
  zaznaczenie lasso daje podświetlenie akcentem z palety aplikacji, w trybie
  tablet prosi system o klawiaturę ekranową i przesuwa pozycję przez lokalny
  `ValueListenableBuilder`, bez rebuildowania Quilla.
- 1036: `class _ImageBlockWidget extends StatefulWidget`.
- 1057: `_ImageBlockWidgetState` — Listener (drag+pinch dwoma palcami=resize),
  `ResizableFrame` z 8 uchwytami, prawy klik → menu kopiowania,
  `_imageChild` (`Image.memory(bytes)` lub `Image.file(path)` z
  `Transform.rotate` + crop `Rect.fromLTRB(cropLeft,cropTop,cropRight,cropBottom)`),
  `_normalizeBlockToImageBounds`, `_startResize`/`_updateResize`/`_endResize`;
  obrazy webowe z pustą ścieżką renderuje i mierzy bezpośrednio z `bytes`;
  zaznaczenie lasso daje border/shadow i przesuwa tylko `Positioned` przez
  `ValueListenableBuilder`,
  `_cornerDelta`/`_clampSize`/`_cornerPosition`/`_cropOffsetX|Y`.
- 1682: `_editOcr(...)` — dialog edycji tekstu OCR; na platformach bez ML Kit
  pokazuje komunikat i pozostawia ręczną edycję, a przycisk `Run OCR` ukrywa;
  w trybie tablet prosi system o klawiaturę ekranową.
- 1818: `_LassoSelectionWidget` — niewidzialny hit target do dragowania całego
  zaznaczenia + pasek akcji copy/delete w powiększonym, klikalnym obszarze;
  nie rysuje prostokąta, bounds są dokumentowe, widget odejmuje `worldOrigin`
  strony i śledzi `dragDeltaListenable`.
- 1972: `_LassoActionButton` — wspólny 48×48 przycisk akcji lassa.
- 2002: `enum _CropAnchorAxis { left, right, top, bottom }`.
- 2004: `class _CropAnchor`.
- 2011: `enum _ImageContextAction { copy }`.
- 2013: top-level `Offset _globalDeltaToLocalDelta(...)`.

### `lib/features/editor/presentation/widgets/editor_toolbar.dart` (917 linii)
Główny pasek narzędzi nad canvasem (narzędzia, kolory, stroke width, undo/redo,
export).
- 11: `class EditorToolbar extends StatelessWidget`.
- 24: `build` — lewy przewijany segment z narzędziami, lokalnym przyciskiem tła
  i stały prawy przycisk
  eksportu.
- 131: `_exportButton()` — popup PDF/PNG wyrównany do prawej strony toolbara.
- 157: `_indexTabButton(context)` — ikonka zakładki; wybór koloru i wysokości w dialogu, dodaje kolejną zakładkę.
- 188: `_backgroundButton(context)` — lokalne ustawienia tła bieżącego notebooka/boarda.
- 203: `_showBackgroundDialog(context)` — dialog `Plain/Grid/Lines`, slider zagęszczenia i podgląd.
- 280: `_actionButton({...})` — generyczny IconButton.
- 298: `_toolButton({...})` — IconButton z aktywnym tłem gdy `tool == ...`.
- 317: `_toolHighlightStyle(selected)` — wspólny kwadratowy hover i aktywne tło dla przycisków toolbara.
- 334: `_eraserSelector()` — popup z `eraserBrush`/`eraserStroke`/`eraserArea`.
- 398: `_shapeSelector()` — popup z liniami/strzałkami/prostokątami/kołami.
- 434: `_selectorMenuButton({...})` — węższy przycisk strzałki dla selektorów.
- 485: `_shapeLabel(tool)`.
- 520: `_colorDot(...)` — kafelek koloru (quickColors + recentColors + picker).
- 556: `_pickColor(...)` — dialog wyboru koloru.
- 668: `_pickIndexTabPosition(...)` — dialog wyboru wysokości zakładki.
- 756: `_channelSlider({...})` — slider R/G/B w pickerze niestandardowym.
- 805: `_toByte(component)`.
- 810: `class _EraserIcon` — klasyczna ikonka gumki z opcjonalnymi błyskotkami/kółkiem obszaru.
- 849: `class _EraserIconPainter` — rysuje bazową sylwetkę gumki i znacznik gumki zakresowej.

### `lib/features/editor/presentation/widgets/page_background_paint.dart` (123 linie)
Render tła strony/canvasu i preview w ustawieniach.
- 6: `class PageBackgroundPaint extends StatelessWidget` — warstwa `CustomPaint`
  z papierem oraz opcjonalną kratką/liniami; `origin` kotwiczy wzór w
  koordynatach świata boarda.
- 36: `class PageBackgroundPreview extends StatelessWidget` — mały podgląd dla
  ustawień i dialogu toolbara.
- 64: `class _PageBackgroundPainter extends CustomPainter` — rysuje papier,
  poziome linie oraz pionowe linie dla kratki, wyrównane do `origin`.

### `lib/features/editor/presentation/widgets/text_edit_toolbar.dart` (545 linii)
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
- 533: `_listAttribute(value, unset)` — mapuje bullet/ordered/checklist na
  natywne atrybuty Quilla i usuwa listę przez `Attribute.clone(..., null)`.

---

### `lib/features/board/presentation/board_screen.dart` (941 linii)
Edytor canvas (kind=board): jedna „strona" o nieograniczonych granicach,
swobodne rozmieszczanie + zoom/pan z trackpada/touch.
- 27: `class BoardScreen extends StatefulWidget`.
- 34: `_BoardScreenState`.
- 48: `_buildBoardRect(controller, viewportSize)` — content bounds + padding.
- 69: `_onPointerDown` / 114 Move / 185 Up/Cancel — pending touch navigation
  przy narzędziach rysowania; zapamiętuje aktywny pointer rysika, żeby dotyk
  dłoni nie przesuwał boarda podczas kreski; w trybie bez pisania palcem jeden
  palec przesuwa board, dwa palce zoomują.
- 225: `_startViewportNavigation(controller)` — startuje nawigację od jednego
  palca w trybie bez pisania palcem albo od dwóch palców w starym trybie.
- 251: `_onPointerPanZoomStart(event, controller)` / 271 Update / 310 End.
- 325: `_onPointerSignal(event, controller)` — myszka kółkiem zoom.
- 360: `_stopViewportNavigation(controller)`.
- 370: `_midpoint(a, b)` / 374 `_distanceBetween`.
- 378: `_isNavigationPointerKind(kind)` / 383 `_isStylusPointerKind(kind)`.
- 388: `_boardInsertPosition(controller, viewportSize)` — gdzie wstawić nowy element.
- 401: `_handleInsertFile(controller)` — wstawianie pliku przez picker pod busy overlayem.
- 414: `_handleExport(controller, format)` — eksportuje tablicę do PDF/PNG,
  obsługuje anulowanie dialogu zapisu.
- 444: `_withBusyOverlay(...)` — pokazuje centralny spinner podczas długiego importu/eksportu i ukrywa go w `finally`.
- 457: `_openSettings()` — otwiera `EditorSettingsScreen` i przenosi na trasę
  istniejący `EditorController` przez `ChangeNotifierProvider.value`.
- 496: `_handleDelete(controller)`.
- 553: `build` — Scaffold(AppBar tytuł boarda+settings) + Column(EditorToolbar,
  TextEditToolbar opcjonalnie, Stack(Transform pan/zoom
  z `PageBackgroundPaint(origin: boardRect.topLeft)`, DrawingCanvas i
  PageOverlay, `_BoardZoomControls` pozycjonowane) + `BusyOverlay`; w
  `LayoutBuilder` mierzy też `sceneBuildUs*` i owija warstwy boarda w
  `_BoardPaintProbe`, żeby logować `scene/background/overlay/canvasHost`.
- 822: `class _BoardPaintProbe` / 839 `_RenderBoardPaintProbe` — cienki
  `RenderProxyBox` mierzący czas `paint()` wybranej warstwy boarda i
  zapisujący próbkę do `BoardScenePerfTracker`.
- 860: `enum _BoardContextAction { paste }`.
- 862: `_PasteFromClipboardIntent` / 866 Copy / 870 Cut / 874 Delete (te same
  intent klasy co w editor_screen ale lokalne).
- 878: `class _BoardZoomControls` — przyciski +/–/fit/reset zoom.

---

### `test/notebook_repository_test.dart` (236 linii)
- 11: `saveNotebook updates existing notebook without breaking foreign keys` —
  smoke test zapisu pełnego snapshotu notebooka.
- 31: `database open retries transient failures without resetting data` —
  sprawdza trzy próby otwarcia i brak flagi resetu po sukcesie.
- 59: `database open fails closed after retries` — sprawdza, że trwały błąd
  jest zwracany z etapem, liczbą prób i przyczyną bez destrukcyjnego fallbacku.
- 94: `older snapshot cannot replace newer notebook data` — sprawdza, że
  starszy snapshot nie usuwa nowszych stron ani metadanych.
- 128: `later equal-timestamp snapshot wins in save order` — kolejka per UID
  zachowuje kolejność równoległych zapisów o równym czasie.
- 145: `empty snapshot cannot erase notebook pages` — walidacja blokuje zapis
  dokumentu bez stron.
- 160: `top-level fetch failure is reported instead of returning empty` — błąd
  odczytu nie jest przedstawiany jako pusta baza.
- 172: `metadata update preserves pages and blocks an older snapshot` —
  sprawdza zapis samego nagłówka i późniejsze odrzucenie starego modelu.
- 194: `corrupt stroke does not hide its notebook or page` — sprawdza
  częściowy odczyt, oznaczenie UID, blokadę zapisu i zachowanie wadliwego
  rekordu w SQLite.

### `test/cloud_sync_service_test.dart` (24 linie)
- 11: `local snapshot wins when sync timestamps are equal` — remis czasu nie
  pozwala chmurze zastąpić lokalnego snapshotu.

### `test/library_controller_test.dart` (33 linie)
- 13: `load failure preserves previously visible notebooks` — błąd głównego
  odczytu pozostawia poprzednią listę i kończy stan ładowania.

### `test/backup_eraser_flattening_test.dart` (96 linii)
Testy sanitizacji backupu gumki.
- 11: `flattens brush erasers into stroke fragments` — sprawdza, że
  `eraserBrush` znika z backupu, a oryginalny stroke zostaje tylko jako
  niezamazany fragment.
- 33: `flattens area erasers and removes eraser strokes from backup` —
  sprawdza, że `eraserArea` usuwa zamazany stroke i nie trafia do payloadu.
- 64: `_notebook(strokes)` — fixture jednego notebooka z jedną stroną.
- 88: `_stroke(...)` — fixture stroke'a z listy `Offset`.

### `test/ink_render_benchmark_test.dart` (211 linii)
- 24: `ink render benchmark` — deterministyczny benchmark prawdziwego
  `DocumentDrawingCanvas`; po rozgrzewce renderuje fixture'y 100/1000/5000
  stroke'ów na pełnym/średnim/niskim LOD, wykonuje syntetyczny gest rysika
  i wypisuje porównywalne linie
  `INK_BENCHMARK` z `staticPaintUs*`, `activePaintUs*`, `inputToPaintUs*`
  oraz pozostałymi metrykami `[ink]`; czasy nie mają progów zależnych od
  maszyny, test pilnuje kompletności logu i rozmiaru renderowanego zakresu.
- 144: `_notebookFor(scenario)` / 172: `_strokeFor(...)` — deterministyczne
  generatory stron, stroke'ów i punktów benchmarku.
- 193: `_BenchmarkScenario` — opis rozmiaru fixture'a, efektywnego zoomu
  i liczba renderowanych
  stron.

### `test/ink_spatial_index_test.dart` (49 linii)
- 10: zachowuje kolejność bliskich kandydatów i odrzuca odległe stroke'i.
- 24: bardzo długi stroke trafia do overflow zamiast tysięcy komórek siatki.

### `test/resizable_frame_test.dart` (33 linie)
- 8: demontaż widgetu podczas aktywnego resize nie wywołuje `setState` po
  `dispose`.

### `test/widget_test.dart` (20 linii)
Smoke test: `NotesApp` pumpuje `MaterialApp` + jeden `CircularProgressIndicator`
(bo `NotesDatabase.open()` jeszcze biegnie).

## 4. Kluczowe konwencje, na które agent musi uważać

- **Schemat Drift**: każda zmiana tabel w
  [notes_database.dart](lib/data/drift/notes_database.dart) wymaga regeneracji
  `notes_database.g.dart` (`dart run build_runner build`) i świadomego
  podbicia `schemaVersion` + migracji, jeśli trzeba zachować istniejące dane.
- **`_toolFromIndex`/`_toolToIndex`** (repo, [linie 1034 i 1042](lib/features/notebook/data/notebook_repository.dart#L1034))
  są obecnie **symetryczne** (`tool.index` ↔ `DrawingTool.values[index]`).
  Wcześniejsza wersja była dziurawa (gubiła square/circle/triangle/ellipse/
  text/image/edit przy roundtripie). Zmieniasz kolejność `DrawingTool.values`?
  Albo dodajesz/wycinasz wartość pośrodku? Zaplanuj migrację zapisanych
  `toolIndex`.
- **Save flow**: mutacje w `EditorController` debouncują `_save()` → repo →
  `onChanged` → `_BackupScheduler` → `LocalBackupService.snapshot` po idle.
  Backup jest przyrostowy per notebook (`manifest.json` + `notebooks/<uid>.json`).
- **OCR** działa wyłącznie na Android/iOS
  ([editor_controller.dart:2435](lib/features/editor/state/editor_controller.dart#L2435)).
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
- **Migracja obrazów w `saveNotebook`**
  ([notebook_repository.dart:329](lib/features/notebook/data/notebook_repository.dart#L329))
  przenosi stare inline `bytes` z nietrwałą/pustą ścieżką do katalogu
  dokumentów aplikacji i czyści `bytes` po utrwaleniu pliku. `bytes` nie są
  zapisywane do SQLite, jeśli blok ma trwały `path`, żeby duże obrazy nie
  spowalniały zapisu i odczytu notebooka.

## 5. Skrypty / przydatne komendy

```bash
flutter pub get
flutter run                                # uruchomienie aplikacji
dart format lib test                       # formatowanie
dart analyze                               # analiza statyczna
dart run build_runner build                # regen Drift
dart compile js -O4 -o web/drift_worker.dart.js web/drift_worker.dart
flutter test                               # smoke test
```

Zależności systemowe (Linux): `zenity` (file picker), `poppler-utils` (PDF).
