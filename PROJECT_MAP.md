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

### `lib/main.dart` (120 linii)
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
- 35: `_runApp()` — `WidgetsFlutterBinding.ensureInitialized()`, ładuje
  utrwalony `AppErrorLog`, instaluje logowanie `FlutterError`, inicjalizuje
  kanał stanu przycisku rysika, instaluje filtr key data, odnawia go po
  `syncKeyboardState()` i przez krótki watchdog startowy, potem
  `runApp(NotesApp())`.
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

### `lib/app/app_scope.dart` (228 linii) — DI + bootstrap
- 16: `class AppScope` — root scope aplikacji, tworzy `_AppScopeState`.
- 23: `_AppScopeState` — trzyma pojedynczy `_openFuture`, repozytorium,
  backup service, sync service, scheduler backupu i flagę jednorazowego
  zapisania błędu startu.
- 42–58: jeśli bootstrap zwróci błąd, zapisuje go do `AppErrorLog` i pokazuje
  `_StartupErrorScreen` z kopiowaniem błędów.
- 61–65: spinner podczas otwierania Isara.
- 69–85: tworzy/cache'uje `NotebookRepository`, `LocalBackupService`,
  `CloudSyncService` i `_BackupScheduler`; `repository.onChanged` tylko
  planuje backup, nie robi snapshotu natychmiast.
- 85–113: `MultiProvider` z `AppPreferencesController`,
  `NotebookRepository`, `LocalBackupService`, `LibraryController`
  (`wasReset`/`freshFile`/`resetReason` z Isara) →
  `MaterialApp(home: LibraryScreen)`, bez debug bannera.
- 115: `_StartupErrorScreen` — awaryjny ekran startu z przyciskiem
  `Copy errors`, dostępny nawet gdy ustawienia aplikacji nie zdążą się otworzyć.
- 166: `_BackupScheduler` — osobny idle debounce backupu (`8s`), blokada przed
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

### `lib/core/input/stylus_button_state.dart` (42 linie)
Platform-channel state dla natywnego przycisku rysika.
- 6: `class StylusButtonState` — globalny `ValueNotifier<bool>` z aktualnym
  stanem przycisku rysika raportowanym przez hosta oraz licznik żądań
  przełączenia gumki (Apple Pencil double tap).
- 17: `initialize()` — idempotentnie rejestruje handler kanału
  `nanotateczki/stylus_button`.
- 25: `_handleMethodCall(call)` — obsługuje `setPressed({pressed, button})`
  oraz `toggleEraser`.

### `lib/core/input/app_preferences_controller.dart` (88 linii)
Globalne preferencje aplikacji niezależne od konkretnego edytora.
- 7: `enum DeviceInputMode { computer, tablet }` — ręczny tryb urządzenia dla
  zachowania pól tekstowych.
- 9: `extension DeviceInputModeX` — etykiety i opisy UI dla ustawienia.
- 26: `class AppPreferencesController` — `ChangeNotifier`, ładuje/zapisuje
  `app_prefs.json`; domyślnie Android/iOS = tablet, desktop = computer.

### `lib/core/input/soft_keyboard.dart` (22 linie)
- 7: `requestSoftKeyboardForFocus(context, focusNode)` — jeśli globalny
  `DeviceInputMode.tablet`, focusuje pole i wysyła do Fluttera `TextInput.show`
  jako prośbę o systemową klawiaturę ekranową.

### `lib/core/error/app_error_log.dart` (166 linii)
Lokalny bufor ostatnich błędów aplikacji do kopiowania z ustawień, utrwalany w
`app_error_log.json`.
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
- 111: `class AppErrorLogEntry` — immutable wpis błędu z JSON
  `fromJson/toJson`.
- 156: `format()` — tekstowy format jednego wpisu.

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

### `lib/data/backup/local_backup_service.dart` (181 linii)
Przyrostowy lokalny backup JSON w `local_backup/`: `manifest.json` +
`notebooks/<uid>.json`; stary `notebooks_latest.json` nadal jest czytany jako
fallback restore.
- 11: `class LocalBackupService(this.repository)`.
- 21: `_backupDir()` — tworzy katalog jeśli brak.
- 30: `_file(name)`.
- 35: `_notebooksDir()` / 43: `_manifestFile()` / 48: `_notebookFile(uid)`.
- 53: `snapshot(items)` — zapisuje tylko zmienione pliki notebooków
  i usuwa pliki notebooków spoza manifestu; przed JSON-em spłaszcza
  `eraserBrush`/`eraserArea` przez `flattenErasersForBackup`, żeby backup
  nie zawierał stroke'ów gumki ani zamazanych fragmentów.
- 97: `hasLatest()` — rozpoznaje nowy manifest albo legacy `notebooks_latest.json`.
- 106: `readLatest()` — preferuje backup przyrostowy, fallback do legacy.
- 114: `_readIncrementalLatest()` / 150: `_readLegacyLatest()`.
- 168: `restoreFromLatest()` — zapisuje wszystkie notebooki do Isara, zwraca count.

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

### `lib/data/export/notebook_export_service.dart` (663 linie)
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
  notebook wielostronicowy jako folder `page_XX.png` w wybranym katalogu.
- 163: `_saveBytesAs(...)` — `FilePicker.saveFile`, dopisanie rozszerzenia na
  desktopie, przekazanie bytes na Android/iOS.
- 208: `_renderNotebook(...)` — dla notebooka przekazuje origin strony
  tekstom/obrazom, a kreski zostawia w lokalnym układzie strony.
- 253: `_renderPage(...)` — `dart:ui` canvas, tło papieru z opcjonalną
  kratką/liniami, obrazy, tekst, strokes; obsługuje osobny `strokeOrigin`.
- 281: `_paintBackground(...)` — rysuje papier i wzór tła z alignmentem do
  przestrzeni boarda.
- 316: `_paintImages(...)`.
- 347: `_paintTextBlocks(...)` / 361: `_textSpans(block)` — prosty render delty Quill.
- 420: `_paintStrokes(...)` / 465: `_buildInkPath(...)` — render stroke'ów
  z tym samym adaptacyjnym wygładzaniem pen/highlighter co canvas.
- 540: `_pageContentBounds(page)` — obszar eksportu boarda.

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

### `lib/features/notebook/domain/drawing_tool.dart` (43 linie)
- 1: `enum DrawingTool` — pen, highlighter, eraserBrush, eraserStroke,
  line, arrow, rectangle, square, triangle, ellipse, circle, text, image,
  blockArrow, edit, lasso, eraserArea.
- 21: `extension DrawingToolX` — `isEraser`, `isShape`, `isInk`
  (uwaga: `isInk` true dla pen/highlighter/eraserów/wszystkich kształtów/lassa).

### `lib/features/notebook/domain/ink_stroke.dart` (53 linii)
- 5: `class InkStroke { id, points, color, width, tool }` + `copyWith`.
- 37: `class InkPoint { dx, dy, pressure }` + `fromOffset` + `toOffset`.

### `lib/features/notebook/domain/text_block.dart` (45 linii)
- 3: `class TextBlock { id, text, deltaJson?, position, fontSize, color,
  width, rotation }` + `copyWith`.

### `lib/features/notebook/domain/image_block.dart` (71 linii)
- 4: `class ImageBlock { id, path, ocrText, position, width, height, bytes?,
  imageExt?, imageMime?, rotation, cropLeft/Top/Right/Bottom }` + `copyWith`
  (crop domyślnie 0/0/1/1, `clearBytes` usuwa legacy/fallback bytes).

### `lib/features/notebook/data/notebook_repository.dart` (684 linii)
Mostek domena ↔ Isar ↔ JSON.
- 19: `class NotebookRepository(this.isar, {this.onChanged})` — callback po każdym zapisie.
- 27: `lastFetchSkippedCorruptRows` — flaga dla backupu po fallbacku.
- 29: `fetchNotebooks()` — sortowane po `updatedAtDesc`, z fallbackiem.
- 43: `_fetchNotebooksDefensively()` — id-by-id, loguje skipy i usuwa
  nieodczytywalne rekordy.
- 71: `_deleteCorruptRows(ids)` — kasuje uszkodzone rekordy po Isar id.
- 80: `createNotebook({title, folder})` — `NotebookKind.notebook`, 1 strona „Page 1".
- 106: `createBoard({title, folder})` — `NotebookKind.board`, jedna strona „Canvas".
- 132: `getNotebook(uid)`.
- 148: `saveNotebook(notebook)` — migruje stare obrazy inline do trwałego
  katalogu `images/`, czyści `bytes` przy trwałym `path`, potem
  `writeTxn(put)`, woła `onChanged`.
- 184: `_persistInlineImageBytes(block)` — przenosi obrazy z `bytes` bez
  trwałej ścieżki poza rekord Isara do katalogu dokumentów aplikacji i usuwa
  bytes z modelu po utrwaleniu pliku.
- 217: `deleteNotebook(uid)`.
- 231: `encodeNotebooks(items)` / 235: `decodeNotebooks(items)` — JSON.
- 242–295: mapowanie entity↔domain (`_fromEntity`, `_pageFromEntity`,
  `_toEntity`, `_pageToEntity`).
- 327–420: konwersje per-blok (`_textFrom/ToEntity`, `_imageFrom/ToEntity`,
  `_strokeFrom/ToEntity`).
- 423–648: JSON serializery (`_notebookTo/FromJson`, `_pageTo/FromJson`,
  `_textTo/FromJson`, `_imageTo/FromJson`, `_strokeTo/FromJson`).
- 298: `_indexTabsFromEntity(...)` — lista zakładek + migracja starego pojedynczego pola.
- 485: `_indexTabToJson` / 493: `_indexTabsFromJson` — JSON wielu zakładek + migracja starego backupu.
- 591: `_imageBytesForJson(block)` — do backupu/sync czyta bytes z pamięci
  albo z pliku pod `path`, bez wkładania ich do Isara.
- 650: `_toolFromIndex(int)` — symetryczne, prosty mapping przez `DrawingTool.values`.
- 658: `_toolToIndex(tool)` — `tool.index`. **Symetria wymagana** —
  zmieniasz jedną, zmieniaj drugą + bump `kManualSchemaRevision`.
- 660: `_bytesFromEntity(List<int>?)`.
- 667: `_bytesToBase64` / 674: `_bytesFromBase64`.

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

### `lib/features/library/presentation/library_screen.dart` (961 linii)
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
- 259: `_promptNewFolder(controller)` — dialog tworzenia folderu; w trybie
  tablet prosi system o klawiaturę ekranową.
- 294: `_promptRenameFolder(controller, folder)` — dialog zmiany nazwy folderu;
  w trybie tablet prosi system o klawiaturę ekranową.
- 332: `_promptRenameItem(controller, item)` — dialog zmiany nazwy
  notebooka/tablicy; w trybie tablet prosi system o klawiaturę ekranową.
- 374: `_confirmDeleteFolder(controller, folder)` — potwierdzenie usunięcia
  folderu razem z zawartością.
- 407: `enum _FolderAction { rename, delete }`.
- 409: `class _FolderListPane` — lista folderów (iconOnly gdy pane < 165px),
  separatory jak w liście notatek, 426–497 iconOnly, 500–537 normalny z menu
  akcji folderu.
- 552: `class _FolderChipBar` — chipy folderów (mobile) z menu akcji folderu.
- 621: `class _LibraryItemsPane` — lista notebooków (empty states 653, 693;
  722–773 iconOnly, 774–844 normalny widok z `LibraryItemCard`).
- 849: `class _LibraryWorkspace` — wybiera `BoardScreen` lub `NotebookScreen`
  na podstawie `item.kind`, owija w `ChangeNotifierProvider<EditorController>`.
- 877: `class _LibraryRoute` — wąski layout (push'owane), `FutureBuilder` do `getNotebook`.
- 903: `enum _CreateAction { notebook, board }`.
- 905: `class _PaneResizeHandle` — pasek do przeciągania szerokości pane.
- 927: `class _LeftZoneToggleTab` — strzałka chevron do collapsowania nawigacji.

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

### `lib/features/editor/state/editor_controller.dart` (2501 linii)
Mózg edytora. **Najczęściej modyfikowany plik aplikacji.** Trzyma stan stron,
narzędzia, kolory, undo/redo, zoom/pan, schowek elementów.
- 32: `class LassoSelection` - trzyma metadane zaznaczenia lasso
  (bounds dokumentowe, ID elementów, delty).
- 64: `_sameInkStrokeIds(a, b)` — szybkie porównanie list stroke'ów po ID.
- 71: `class EditorController extends ChangeNotifier`.
- 72–74: `minViewScale=0.25`, `maxViewScale=4.0`,
  `_inkSaveDebounceDelay=2s`.
- 76: konstruktor — `pages = notebook.pages`, ładuje prefs.
- 82–137: pola — `repository, notebook, _uuid, _imagePicker, pages,
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
  _suppressBackgroundTap, viewScale, viewPan,
  _pageWidth/_pageHeight/_pageGap`.
- 138–157: gettery `currentPage`, `canUndo`, `canRedo`,
  `allowsFingerDrawing`, `currentBackgroundSettings`, `contentBounds`,
  `layoutPageSize`, `layoutPageGap`, `defaultBackgroundSettingsForKind`.
- 160: `dispose()` — domyka aktywną edycję tekstu, flushuje pending prefs/save
  i sprząta listenery.

#### Layout/wiewport
- 147: `updatePageLayout({pageWidth, pageHeight, pageGap})`.
- 162: `setViewTransform({pan?, scale?})`.
- 176: `panBy(delta)`.
- 183: `zoomBy(factor, focalPoint)`.
- 196: `viewportToWorld(offset)` / 201: `worldToViewport(offset)`.

#### Strony
- 205: `pageAt(index)`.
- 209: `_pageExtent` getter (height + gap).
- 211: `_pageOriginForIndex(index)`.
- 218: `_pageIndexForPosition(offset)` — który page index zawiera punkt Y.

#### Lookupy / aktywne elementy
- 229: `findTextBlockById(id)`.
- 240: `findImageBlockById(id)`.
- 251: `_pageIndexContainingTextBlock(id)`.
- 260: `_pageIndexContainingImageBlock(id)`.
- 269: `_ensurePageSelected(pageIndex)`.

#### Per-page entry points (board/notebook → mapują na current page)
Tylko te `*OnPage`, które są realnie wołane z `page_overlay`/`drawing_canvas`.
- 279: `handleTapOnPage(pageIndex, point)`.
- 315: `updateTextBlockContentOnPage(...)` / 325 position /
  334 cały blok / 339 delete / 344 commitMove / 354 commit update.
- 364: `runOcrForImageOnPage`.
- 369: `updateImageBlockPositionOnPage` / 378 cały blok /
  386 OCR text / 391 delete.
- 396: `addInkStrokeOnPage(pageIndex, points, {widthOverride, toolOverride})`.
- 410: `eraseInkStrokesByIdOnPage(pageIndex, ids)`.
- 415: `replaceInkStrokesOnPage(pageIndex, strokes)` — undoowalna podmiana
  stroke'ów strony, używana przez częściową gumkę scratch-erase.
- 420: `commitImageMoveOnPage`.
- 430: `finalizeImageMoveOnPage` — **decyduje czy stroke przechodzi
  na inną stronę** (`_moveImageBlockToPage`) czy zostaje (`commitImageMoveOnPage`).
- 447: `commitImageResizeOnPage`.
- 489: `selectWithLasso(points, pageIndex)` — Ray-Casting; stroke'y liczone w
  koordynatach strony, tekst/obrazy w koordynatach dokumentu; stroke'i gumki
  są ignorowane przez selekcję.
- 567: `updateLassoMove(delta)` — zapisuje bieżące przesunięcie tylko w
  `lassoDragDelta`, bez przebudowy całego controllera.
- 572: `commitLassoMove()` — zatwierdza `lassoDragDelta` jako
  `MoveSelectionAction`, przesuwa bounds i dopiero wtedy robi notify/save.

#### Narzędzia, kolory, prefs
- 466: `setTool(newTool)` — aktualizuje `lastEraserTool` i `lastShapeTool`;
  wybór trybu gumki trafia do `editor_prefs.json`.
- 471: `setActiveTextBlock(id, controller)` / 484 clear; domyka poprzednią
  sesję tekstową jako jedną akcję undo.
- 468: `setActiveImageBlock(id)` / 482 clear.
- 688: `markTextTap()` / 692: `consumeBackgroundTapSuppression()`.
- 706: `setColor(color)`.
- 713: `setLastTextFontFamily` / 718 size / 723 color.
- 756: `setStrokeWidth(value)` — zapisuje trwały rozmiar narzędzi/gumki
  w `editor_prefs.json`.
- 762: `setPointerInputMode(mode)` — zapisuje tryb rozróżniania rysika/palca.
- 771: `setStylusButtonsEnabled(enabled)` — zapisuje obsługę przycisków rysika.
- 780: `setScratchEraseEnabled(enabled)` — zapisuje automatyczną gumkę
  bazgrołem.
- 789: `setDefaultBackgroundSettings(kind, settings)` — zapisuje globalne
  domyślne tło osobno dla notebooków i boardów; oznacza zmieniony typ do
  scalania zapisu preferencji.
- 804: `setCurrentBackgroundSettings(settings)` — zapisuje lokalne tło
  bieżącego notebooka/boarda po `uid`; oznacza zmieniony `uid` do scalania
  zapisu preferencji.
- 811: `setQuickColor(index, color)`.
- 820: `_addRecentColor(color)` (cap 12, dedup po ARGB).
- 828: `_loadEditorPrefs()` (`editor_prefs.json`: kolory, tekst,
  `inkStrokeWidth`, `lastEraserTool`, `pointerInputMode`,
  `stylusButtonsEnabled`, `scratchEraseEnabled`, domyślne i lokalne tła; nie
  nadpisuje lokalnie zmienionych teł, jeśli load kończy się po zmianie UI).
- 942: `_schedulePrefsSave()` (debounce 250 ms).
- 949: `_saveEditorPrefs()` — zapisuje preferencje, scalając tła z aktualnym
  plikiem zamiast nadpisywać je snapshotem z jednej instancji kontrolera.
- 985: `_readEditorPrefs(file)` — defensywny odczyt istniejącego JSON-a
  preferencji do scalania.
- 998: `_mergedBackgroundDefaults(...)` — scala globalne tła per
  `NotebookKind`, aktualizując tylko dirty typy albo brakujące klucze.
- 1020: `_mergedLocalBackgrounds(...)` — scala lokalne tła per `uid`,
  aktualizując tylko dirty notatniki/tablice.
- 1048: `_prefsFile()`.
- 1053: `_eraserToolFromIndex(value)` — waliduje, że zapisany indeks to tryb gumki.
- 1061: `_colorFromHex(value)`.

#### Gesty / undo / redo / strony
- 1076: `handleTap(point)` — text vs image vs nic.
- 1087: `undo()` / 1099: `redo()` — domykają aktywną edycję tekstu przed operacją.
- 1111: `addPage()` — nowy `NotePage`, czyści aktywne.
- 1124: `deleteLastPage()` — usuwa ostatnią stronę, nie schodzi poniżej jednej strony.
- 1138: `_createPage(index)`.
- 1150: `_ensurePageCount(working, count)`.
- 1156: `setCurrentPage(index)`.
- 1171: `toggleBookmark()`.
- 1177: `addIndexTab({color, position})` — undoowalnie dopisuje nową zakładkę na bieżącej stronie.
- 1190: `updateIndexTab({id, color, position})` — undoowalnie edytuje konkretną zakładkę.
- 1213: `clearIndexTab(id)` — undoowalnie usuwa konkretną zakładkę indeksującą.
- 1209: `beginIndexTabDrag({pageIndex, id})` — start przeciągania zakładki, zapamiętuje stronę do jednej akcji undo.
- 1229: `updateIndexTabDrag({id, position})` — live przesunięcie zakładki góra/dół bez zapisu na każdy ruch.
- 1266: `commitIndexTabDrag()` — kończy przeciąganie i zapisuje jedną akcję undo.

#### Operacje tekstowe (current page)
- 1310: `addTextBlock(position)` — Quill Delta z lastText* defaultami.
- 1337: `addTextBlockFromText(position, text)` — z clipboarda/pliku.
- 1365: `updateTextBlockContent(before, {plainText, deltaJson})` — szybka ścieżka
  wpisywania: aktualizuje `pages` bez
  `notifyListeners()` i debouncuje zapis.
- 1380: `updateTextBlockPosition`.
- 1387: `updateTextBlockWidth`.
- 1394: `deleteTextBlock`.
- 1404: `commitTextMove(id, start, end)`.
- 1418: `commitTextResize(before, after)`.
- 1426: `commitTextUpdate(before, after)` — undoowalne zatwierdzenie zmiany
  szerokości/rotacji/pozycji całego bloku tekstu.

#### Obrazy / clipboard / wklejanie
- 1440: `addImageBlock(position)` — image picker (galeria), jedna kopia pliku do katalogu obrazów.
- 1449: `insertFromFilePicker(position)` — png/jpg/jpeg/pdf/txt; Linux hint o zenity.
- 1484: `insertFromClipboard(position)` — image lub tekst z `super_clipboard`,
  fallback `Clipboard.getData(text/plain)`; przed wstawieniem wybiera stronę z pozycji dokumentowej.
- 1512: `pasteElementOrClipboard(position)` — wkleja zapamiętany
  `_elementClipboard` (Text/Image/Lasso) albo wpada do `insertFromClipboard`;
  tekst/obrazy trafiają na stronę wynikającą z pozycji dokumentowej.
- 1594: `copyActiveElementToClipboard()` — lasso→wewnętrzny clipboard,
  text→clipboard text+`_elementClipboard`, image→PNG/JPEG.
- 1646: `cutActiveElementToClipboard()` — copy + `deleteActiveElement`.
- 1655: `deleteActiveElement()` — kasuje aktywny tekst lub obraz na właściwej stronie.
- 1680: `copyActiveImageToClipboard()` — wykrywa jpg/jpeg → `Formats.jpeg`, inaczej `png`.
- 1709: `_tryInsertImageFromClipboard(reader, position)` — PNG first, potem JPEG.
- 1683: `_readTextFromClipboard(reader)`.
- 1691: `_readClipboardImageBytes(reader, format)`.
- 1715: `_readStreamBytes(stream)`.
- 1723: `_initialImageBlockSize(sourceSize)` — clampuje do strony (notebook
  używa `_pageWidth/_pageHeight`, board ma stałe 360x520).
- 1743: `_addImageBlockFromBytes(bytes, position, extension)` — zapisuje bajty do pliku, blok trzyma tylko `path`.
- 1768: `_insertFile(file, position)` — branchuje po rozszerzeniu (png/jpg/pdf/txt).
- 1786: `_addImageBlockFromFile(file, position, {runOcr=true})` — kopiuje plik,
  blok trzyma tylko `path`, OCR jeżeli wspierane.
- 1829: `_activateInsertedImage(id)` — switch na tool `edit`, set active image.
- 1837: `_addPdfAsImages(pdfFile, position)` — używa `pdfx` (non-Linux),
  renderuje każdą stronę, zapisuje PNG do trwałego katalogu obrazów, bez `bytes`
  w bloku; na końcu dopisuje nowe obrazy do aktualnych stron zamiast nadpisywać
  `pages` snapshotem sprzed importu.
- 1916: `_addPdfAsImagesWithPoppler(pdfFile, position)` — Linux fallback,
  uruchamia `pdftoppm` (`poppler-utils`), zapisuje PNG do trwałego katalogu obrazów.
- 1998: `_appendImageBlocksOnPages(additions)` — scala obrazy z importu PDF z aktualnym stanem stron, zachowując istniejące `imageBlocks`.
- 2017: `runOcrForImage(block)`.
- 2030: `updateImageBlockPosition` / 2037 size / 2053 OCR text.
- 2067: `restoreImageCache(pageIndex, blockId)` — odtwarza plik z legacy `bytes`, potem czyści `bytes`.
- 2093: `deleteImageBlock(id)`.

#### Strokes / commits
- 2143: `addInkStroke(points, {widthOverride, toolOverride})` — highlighter
  ma `inkStrokeWidth * 8.0`; zapis do repo jest debounced, żeby szybkie
  odrywanie rysika nie blokowało kolejnego stroke'a na Isar/backup.
- 2123: `eraseInkStrokesById(ids)` — usuwa stroke'i undoowalnie i debouncuje
  zapis.
- 2136: `replaceInkStrokes(strokes)` — undoowalnie podmienia listę stroke'ów;
  używane przez częściowe wycinanie zamazanego zakresu.
- 2145: `createInkStrokeId()` — publiczny generator ID dla nowych fragmentów
  stroke'ów po rozcięciu.
- 2190: `commitImageMove(id, start, end)`.
- 2204: `commitImageResize(before, after)` — porównuje pos/size/crop/rotation.
- 2218: `_moveImageBlockToPage(fromIdx, toIdx, id, position)`.

#### Helpery
- 2260: `_persistImageFile(file)`.
- 2225: `_persistImageBytes(bytes, filename)`.
- 2232: `_imagesDir()` — tworzy/trzyma obrazy w dokumentach aplikacji, nie w
  katalogu tymczasowym.
- 2241: `_colorToHex(color)`.
- 2246: `_imageSize(file)` — `instantiateImageCodec`.
- 2254: `_runOcr(file)` — mlkit, Latin script.
- 2270: `_isOcrSupported()` — Android/iOS only.
- 2277: `_computeContentBounds()` — bbox stroke + text + image dla widoku.
- 2371: `_applyAction(action)` — domyka aktywną edycję tekstu, push undo,
  clear redo, apply, update page.
- 2336: `_applyActionWithoutNotify(action)` — wariant dla commitowania lassa;
  zmienia `pages` i undo stack bez pośredniego `notifyListeners()`.
- 2346: `_updatePage(page)`.
- 2397: `_replaceTextBlockOnCurrentPage(block, {notify})` — live update tekstu
  bez przebudowy drzewa podczas szybkiego pisania.
- 2368: `_beginTextEdit(blockId)` / 2383: `_commitActiveTextEdit()` /
  2407: `_discardActiveTextEdit()` — grupowanie wielu znaków w jedną akcję undo.
- 2412: `_scheduleSave()` — debouncuje zapis notebooka
  przez `_inkSaveDebounceDelay` po live-edit tekstu i krótkich seriach stroke'ów.
- 2420: `_save()` — wywołuje
  `repository.saveNotebook(notebook.copyWith(pages, updatedAt=now))`.
- 2428–2452: sealed `_ElementClipboardItem` + `_TextElementClipboardItem`
  + `_ImageElementClipboardItem` + `_LassoElementClipboardItem`.

---

### `lib/features/editor/presentation/editor_settings_screen.dart` (343 linie)
Panel ustawień edytora.
- 12: `class EditorSettingsScreen extends StatelessWidget` — ekran ustawień
  z górnym `TabBar` (`System`, `Visual`, `Widgets`); zakładka systemowa zawiera
  `Device mode` (`Computer`/`Tablet`) oraz trzy `SegmentedButton` `Off/On`:
  rozróżnianie rysika/palca, obsługa przycisków rysika oraz gumka bazgrołem,
  plus pozycję `Errors` z kopiowaniem ukrytego domyślnie podglądu błędów;
  zakładka Visual zawiera globalne domyślne tło osobno dla notebooków i boardów.
- 198: `_showErrorsDialog(context)` — dialog `Errors` z `Copy`, `Clear`,
  `Close` i zwijanym podglądem zawartości logu.
- 280: `class _BackgroundSection` — kontrolki stylu tła `Plain/Grid/Lines`,
  slider zagęszczenia i podgląd.

### `lib/features/editor/presentation/editor_screen.dart` (2629 linii)
Layout edytora notebooka (stronicowy). Listener gestów, transformacja zoom/pan
strony, przesunięcie kolumny strony, mini-mapa, podgląd skali, podgląd ramki
strony.
- 30: `class EditorScreen extends StatefulWidget`.
- 37: `_EditorScreenState` — stałe (38–52: `_pageGap=26`, paddings,
  footer `Add page`, sensytywności pan/scroll, scale floors, granica kolumny
  podglądu, tolerancja zatrzymania na krawędzi). A4 ratio czytane z
  `AppMetrics.a4HeightRatio`.
- 53–74: pola stanu (ScrollController, GlobalKey canvas, `_pageExtent`,
  `_isViewportNavigating`, aktywny rysik, pending touch navigation, gesty
  multi-touch, `_pageScale=1`, `_pagePan`, `_pageMin/MaxScale`,
  `_pageColumnOffset`, granice przesunięcia kolumny).
- 75: `initState` — `_scrollController.addListener(_handleScroll)`.
- 81: `dispose`.
- 87: `_handleScroll()`.
- 94: `_onPagesScroll(notification, controller)` — synchronizuje bieżącą stronę
  po zakończeniu scrolla; scroll nie tworzy stron automatycznie.
- 109: `_syncCurrentPageToViewport(controller)`.
- 132: `_addPageBelow(controller)` — dodaje stronę przez kontroler bez
  automatycznego przewijania widoku.
- 139: `_syncPageTransformBounds({docWorldSize, fitToWidthScale, viewportSize})`.
- 176: `_syncPageColumnOffsetBounds({basePageLeft})` — clampuje poziome
  przesunięcie kolumny strony do obszaru poza kolumną podglądu.
- 197: `_applyPageColumnPan(deltaX)` — przesuwa kolumnę strony gestem dwoma
  palcami w osi X, z clampem poza kolumną podglądu i tolerancją zatrzymania
  na krawędziach.
- 223: `_snapToPageColumnEdge(offset)` / 233: `_snapPageColumnToEdge(edge)` —
  wygaszają ułamkowe drgania przy limicie przesunięcia.
- 242: `_isNavigationPointerKind(kind)` — touch/trackpad/mouse (NIE pen/stylus).
- 247: `_isStylusPointerKind(kind)`.
- 252: `_onPointerDown(event, docWorldSize, viewportSize)` — pending touch
  navigation przy narzędziach rysowania; gdy rysik jest aktywny, dotyk dłoni
  nie wchodzi w nawigację viewportu; przy `allowsFingerDrawing == false`
  pojedynczy dotyk od razu zaczyna przesuwanie widoku.
- 298: `_onPointerMove(...)` — multi-touch pinch/pan; gdy pierwszy dotyk
  przesunie się przed drugim palcem, awansuje go z pending do aktywnych pointerów,
  żeby gest dwoma palcami nadal wystartował bez przypadkowego stroke'a; w trybie
  bez pisania palcem jeden palec przesuwa widok, dwa palce zoomują.
- 389: `_onPointerUpOrCancel(event)`.
- 423: `_startViewportNavigation(docWorldSize, viewportSize)` — startuje
  nawigację od jednego palca w trybie bez pisania palcem albo od dwóch palców
  w starym trybie.
- 458: `_onPointerPanZoomStart(event, ...)` — trackpad scroll wheel.
- 483: `_onPointerPanZoomUpdate(...)`.
- 525: `_onPointerPanZoomEnd(event)`.
- 537: `_onPointerSignal(event, ...)` — `PointerScrollEvent` (myszka).
- 561: `_applyPageTransform({scale, pan, ...})` — aktualizuje `_pageScale/_pagePan`.
- 609: `_clampPagePan({pan, scale, docWorldSize, viewportSize})` — centruje
  dokument w osi, w której po oddaleniu mieści się w viewportcie.
- 645: `_stopViewportNavigation()`.
- 655: `_midpoint(a, b)` / 659: `_distanceBetween` / 663: `_documentHeight`.
- 670: `_visibleDocumentRect({docWorldSize, viewportSize})` — który fragment widać.
- 709: `_pageBoundaryVisibilityInDocument(...)` — liczy widoczne krawędzie strony;
  przy pełnej widoczności strony zwraca wszystkie krawędzie.
- 770: `_visiblePageRange(...)` — wylicza okno renderowanych stron
  jako strona viewportu + jedna powyżej i trzy poniżej, żeby długie notatniki
  nie budowały wszystkich stron naraz.
- 799: `_insertPositionForViewport({...})` — gdzie wstawić blok dla insert toolbara; wybiera stronę z centrum widoku, nie ze starego `currentPageIndex`.
- 830: `_withBusyOverlay(...)` — pokazuje centralny spinner podczas długiego importu/eksportu i ukrywa go w `finally`.
- 843: `_handleInsertFile(controller)` — wstawianie pliku przez picker pod busy overlayem.
- 856: `_handleExport(controller, format)` — eksportuje aktualną notatkę do
  PDF/PNG przez `NotebookExportService`, obsługuje anulowanie dialogu zapisu.
- 886: `_openSettings()` — otwiera `EditorSettingsScreen` i przenosi na trasę
  istniejący `EditorController` przez `ChangeNotifierProvider.value`.
- 925: `_handleDelete(controller)`.
- 929: `_showIndexTabEditor(controller, pageIndex, tabId)` — dialog edycji istniejącej zakładki po dwukliku.
- 1078: `_indexTabChannelSlider(...)` — slider RGB w dialogu zakładki.
- 1104: `_showCanvasContextMenu(...)` / 1149: `_contextMenuInsertPosition(...)` — menu `Paste` z prawego kliku, przycina punkt wstawiania do obszaru strony.
- 1177: `_startTouchContextMenuTimer(...)` — po 1 s przytrzymania palcem na canvie pokazuje menu `Paste` pod kursorem.
- 1224: `build(context)` — Scaffold(AppBar=tytuł notebooka+bookmark+settings) + Column
  (EditorToolbar, TextEditToolbar gdy aktywny tekst, InsertToolbar gdy `_isInsertToolbarVisible`,
  LayoutBuilder z głównym canvas: SingleChildScrollView (bez drag-scrolla przy
  narzędziach ink) + poziome przesunięcie kolumny strony + Listener +
  Transform(`_pageScale/_pagePan`) + Stack[tylko widoczne strony
  (DecoratedBox+`PageBackgroundPaint`+`_PageFramePainter`),
  `DocumentPageOverlay`(bg+inactive),
  `DocumentDrawingCanvas`, `DocumentPageOverlay`(active), `_IndexTabsOverlay`]
  + przyciski `Add page` / `Delete page`
  pozycjonowany w przestrzeni dokumentu tuż pod ostatnią stroną); pozycjonuje
  `_ZoomPercentBadge` + `_ProjectMiniMapOverlay` + `BusyOverlay`.
- 1670–1717: skróty klawiszowe (Ctrl/Cmd+V/C/X, Delete) → CallbackActions
  (paste/copy/cut/delete) — **wyłączone gdy aktywny TextEditor**.
- 1748: `class _PasteFromClipboardIntent`.
- 1752: `class _IndexTabEditResult` — wynik dialogu edycji zakładki (`save/remove`).
- 1779: `_CopyElementIntent`.
- 1783: `_CutElementIntent`.
- 1787: `_DeleteElementIntent`.
- 1791: `enum _CanvasContextAction { paste }`.
- 1793: `class _BoundaryVisibility` — które krawędzie strony są widoczne.
- 1826: `class _PageRenderRange` — półotwarty zakres stron renderowanych w
  głównym edytorze.
- 1833: `class _PageFramePainter extends CustomPainter` — rysuje pomarańczową
  ramkę aktywnej strony.
- 1908: `class _IndexTabsOverlay` — rysuje wiele kolorowych zakładek; dwuklik otwiera edycję, a długie przytrzymanie pozwala przesuwać zakładkę góra/dół.
- 2018: `class _ZoomPercentBadge` — chip „150%".
- 2048: `class _ProjectMiniMapOverlay extends StatefulWidget` (mini-mapa).
- 2069: `_ProjectMiniMapOverlayState` — synchronizacja widoku + cache miniatur obrazów/PDF.
- 2103: `_precacheMinimapImages()` — dekoduje asynchronicznie obrazy tylko dla stron blisko widoku.
- 2180: `_minimapImagePageRange()` — zakres stron, dla których minimapa trzyma zdekodowane obrazy.
- 2238: `_syncMinimapToViewport()`.
- 2272: `_visiblePanelHeight(...)` / 2276: `_contentHeight(...)` — wysokość mini-mapy rośnie z liczbą stron do limitu panelu.
- 2389: `class _ProjectMiniMapPainter` — rysuje strony, content thumbnails,
  zdekodowane miniatury obrazów/PDF oraz paski zakładek, bez podświetlania krawędzi.
- 2602: `class _MiniMapImageCacheEntry` — cache key + zdekodowany obraz mini-mapy.
- 2609: `class _MiniMapViewportOverlayPainter` — rysuje wypełniony prostokąt widoku bez podświetlanych krawędzi.

### `lib/features/editor/presentation/widgets/busy_overlay.dart` (38 linii)
Centralny overlay ładowania dla długich operacji importu/eksportu w edytorach.
- 3: `class BusyOverlay extends StatelessWidget` — półprzezroczysta blokująca warstwa z centralnym `CircularProgressIndicator`.

### `lib/features/editor/presentation/widgets/drawing_canvas.dart` (3475 linii)
Dwie warianty canvasu rysowania. **Notebook używa `DocumentDrawingCanvas`,
board używa `DrawingCanvas`.** Logika prawie zduplikowana — to świadoma decyzja
(różne układy współrzędnych). Oba warianty opóźniają start stroke dla dotyku,
odrzucają duży kontakt dłoni, dają pierwszeństwo aktywnemu rysikowi/myszy
i przy aktywnym `PointerInputMode` blokują rozpoczynanie kreski palcem.
- 36: `_eraseStrokeParts(...)` / 66: `_scratchEraseInkHitCount(...)` —
  scratch-erase ma dwa promienie: mała tolerancja tylko do odpalenia gumki
  oraz szeroki promień realnego usunięcia, żeby nie zostawiać kropek tuszu;
  do odpalenia wymaga `3+` trafień istniejącego tuszu.
- 159: `_isScratchEraseGesture(...)` — wymaga aktywnego pena, `3+` nawrotów
  oraz minimalnego zagęszczenia ścieżki względem obszaru gestu.
- 286: `_scratchEraseIntersectionRadius(strokeWidth)` — mała tolerancja
  przecięcia wizualnej linii (`max(1, width * 0.5)`), nie pełny promień gumki.
- 293: `_scratchEraseDeleteRadius(strokeWidth)` — realny promień usuwania
  zamazanego zakresu (`max(8, width * 6)`).
- 313: `class DrawingCanvas extends StatefulWidget` — board, jedna strona/canvas.
- 333: `class DocumentDrawingCanvas extends StatefulWidget` — notebook,
  N stron pionowo, params `{worldOrigin, pages, pageSize, pageGap,
  allowMultiTouch, interactionEnabled, firstPageIndex, lastPageIndex}`; painter
  renderuje tylko ten zakres, hit-test nadal liczy po pełnym dokumencie.
- 359: `_buildInkPath(...)` / 396: `_shouldSmoothStroke(...)` — wspólne,
  adaptacyjne wygładzanie szybkich stroke'ów pen/highlighter; kształty, lasso
  i gumka zostają odcinkami.
- 430: `_shouldAcceptInkPoint(...)` —
  wspólny filtr punktów pen/highlighter: odrzuca nagłe, boczne skoki kontaktu
  oddalone od dotychczasowego kierunku kreski.
- 448: `_shouldRejectViewportEdgePoint(...)` / 466 `_isNearViewportEdge(...)` —
  ignoruje nienaturalne skoki do samej krawędzi okna programu.
- 477: `_isDiscontinuousInkJump(...)` — wykrywa boczny, daleki skok względem
  ostatniego stabilnego kierunku kreski.
- 508: `_toolForPointerEvent(...)` / 525 `_toggleEraserShortcut(...)` /
  531 `_hasStylusButton(...)` — tymczasowo używają ostatniej gumki dla
  `invertedStylus` oraz, gdy `stylusButtonsEnabled == true`, dla natywnego
  stanu `StylusButtonState`, standardowych przycisków stylusa Fluttera
  (`primary/secondary`) i linuksowego fallbacku `secondary/middle mouse`;
  obsługują też przełączenie gumki z Apple Pencil double tap.
- 539: `_eraserStrokeRadius(strokeWidth)` — wspólny promień hit-testu i śladu
  widmo magicznej gumki (`max(4, width * 1.5)`).
- 543: `_trimEraserTrail(trail)` — ogranicza długość widocznego śladu magicznej
  gumki do `_eraserTrailMaxLength`.

#### `_DrawingCanvasState` (board) — 560–1752
- 617: `build` — `MouseRegion` ustawia natywny kursor `basic` dla
  pen/highlighter, `Listener` z `_onPointerDown/Move/Up/Cancel` +
  `ValueListenableBuilder(controller.lassoDragDelta)` + dwa `CustomPaint` w
  `RepaintBoundary`: zapisane stroke'i i szybki overlay aktywnej kreski.
- 706: `_onPointerDown(event, controller, viewportSize)` — wybiera aktywny pointer;
  dotyk startuje dopiero po progu ruchu w trybie `Off`; pozostałe tryby
  blokują pisanie palcem; rysik/mysz startują od razu; przycisk rysika ustawia
  gumkę tylko dla aktywnego stroke'a.
- 814: `_onPointerMove` — dodaje punkty, ewentualnie eraser; wykrywa też zmianę
  `buttons` w trakcie ruchu i przełącza segment na gumkę/poprzednie narzędzie.
- 913: `_onPointerUp` — commit stroke przez `controller.addInkStroke`; przed
  commitem pen sprawdza, czy skupiony szybki gest ma wyciąć fragmenty stroke'ów.
- 1055: `_syncActiveToolWithPointerMove(...)` — domyka bieżący segment i zaczyna
  nowy po wciśnięciu lub puszczeniu przycisku rysika w trakcie kontaktu.
- 1075: `_commitCurrentSegment(...)` / 1149: `_addCurrentStroke(...)` —
  wspólny commit używany przy normalnym `up` i przy przełączaniu narzędzia.
- 1178: `_tryCommitScratchErase(...)` — jeśli `scratchEraseEnabled`, najpierw
  sprawdza `3+` nawrotów i zagęszczenie gestu, potem `3+` małe trafienia
  istniejącego tuszu, a dopiero szerokim promieniem podmienia stroke'i przez
  `replaceInkStrokes*`.
- 1218: `_clearCurrentSegmentForToolSwitch()` — czyści overlay bez kończenia
  aktywnego pointera.
- 1238: `_onPointerCancel`.
- 1252: `_resetCurrent()`.
- 1286: `_notifyInkChanged()` — lekki repaint overlayu aktywnej kreski.
- 1290: `_addEraserTrailPoint(offset)` — zbiera i przycina punkty śladu widmo magicznej gumki.
- 1298: `_activeTool(controller)` — zwraca override z przycisku rysika albo
  aktualne narzędzie controllera.
- 1302: `_toWorld(local)`.
- 1306: `_shouldAddPoint(offset, tool)` — min odległość + filtr skoków kontaktu.
- 1327: `_startSnapTimer(offset)` — po holdzie z czystym kształtem wywołuje `_snapToShape`.
- 1337: `_eraseAt(offset, page, controller)`.
- 1349: `_resolvedPage(controller)` / 1353: `_resolvedPageIndex`.
- 1357: `_strokeHitTest(stroke, point, radius)`.
- 1376: `_distanceSquaredToSegment(p, a, b)`.
- 1389: `_snapToShape()` — wykrywa line/rect/ellipse.
- 1447: `_clearSnapHintSoon()`.
- 1460: `_isRoughlyStraight(start, end, points)`.
- 1484: `_isRoughlyRectangle(points)`.
- 1509: `_isRoughlyEllipse(points)`.
- 1578: `_findFarthestCorner(points, holdPoint)`.
- 1602: `_isInkTool(tool)`.
- 1606: `_isSnapTool(tool)` — pen/highlighter snapują, eraser/kształty nie.
- 1610: `_usesCustomInkCursor(tool)` — pen/highlighter używają natywnego kursora `basic`.
- 1614: `_effectiveStrokeWidth(tool, baseWidth)` — highlighter ma mnożnik 8,
  zwykła gumka `_eraserBrushWidthScale`.
- 1652: `_squareCorner(start, end)` — wymuszony kwadrat/koło.

#### `_DocumentDrawingCanvasState` (notebook) — 1753–3009
Te same metody co wyżej, ale operują w przestrzeni dokumentu (offset per page).
- 1812: `build` — też nasłuchuje `lassoDragDelta` przy repaint zaznaczonych stroke'ów.
- 1902: `_onPointerDown` / 2028 Move / 2162 Up / 2430 Cancel; lasso w dokumencie
  woła `selectWithLasso`, aktywny `PointerInputMode` blokuje pisanie palcem,
  a przycisk rysika ustawia gumkę dla aktywnego stroke'a także gdy `buttons`
  zmienia się w trakcie ruchu.
- 2257: `_syncActiveToolWithPointerMove(...)`.
- 2298: `_commitCurrentSegment(...)` / 2359: `_addCurrentStroke(...)`.
- 2372: `_tryCommitScratchErase(...)` — jeśli `scratchEraseEnabled`,
  notebookowy wariant częściowego wycinania konwertuje gest z dokumentu do
  koordynatów strony.
- 2409: `_clearCurrentSegmentForToolSwitch()`.
- 2444: `_resetCurrent`.
- 2480: `_notifyInkChanged()` — lekki repaint overlayu aktywnej kreski.
- 2484: `_addEraserTrailPoint(offset)` — zbiera i przycina punkty śladu widmo magicznej gumki.
- 2492: `_activeTool(controller)` — zwraca override z przycisku rysika albo
  aktualne narzędzie controllera.
- 2496: `_toWorld(local)`.
- 2503: `_pageOrigin(pageIndex)` / 2513: `_toPageLocal(world, pageIndex)` /
  2521: `_toDocument(pageLocal, pageIndex)` / 2529: `_isInsidePage(pageLocal)`.
- 2554: `_shouldAddPoint(offset, tool)` — min odległość + filtr skoków kontaktu.
- 2575: `_startSnapTimer`.
- 2585: `_eraseAt(localOffset, pageIndex)`.
- 2600: `_strokeHitTest` / 2619: `_distanceSquaredToSegment`.
- 2645: `_snapToShape`.
- 2703: `_clearSnapHintSoon`.
- 2716: `_isRoughlyStraight` / 2740: `_isRoughlyRectangle` / 2765: `_isRoughlyEllipse`.
- 2834: `_findFarthestCorner`.
- 2858: `_isInkTool` / 2862: `_isSnapTool` /
  2866: `_usesCustomInkCursor` / 2870: `_effectiveStrokeWidth`.
- 2908: `_squareCorner`.

#### Paintery
- 3008: `class _InkPainter extends CustomPainter` (board) — rysuje zapisane
  stroke'i i lasso selection; nie odświeża się przy każdym punkcie aktywnej kreski.
- 3109: `class _InkOverlayPainter extends CustomPainter` — lekka warstwa
  aktywnej kreski, snap hint i śladu magicznej gumki,
  sterowana `ValueNotifier`; ślad magicznej gumki jest krótkim, rozmytym
  trailem bez rdzenia, z gradientową maską ogona do pełnej przezroczystości
  (`_pointAlongTrail` na 3178), aktywny ślad zwykłej gumki ma kolor papieru,
  ale pojedynczy punkt zwykłej gumki nie jest rysowany jako okrągły preview;
  zapisany stroke gumki nadal czyści przez `BlendMode.clear`.
- 3329: `class _DocumentInkPainter extends CustomPainter` (notebook) —
  analogiczny painter zapisanych stroke'ów dla dokumentu; filtruje zakres po
  `firstPageIndex/lastPageIndex`, zawęża `saveLayer` do renderowanego zakresu,
  a zaznaczenie po `selectedPageIndex`.

### `lib/features/editor/presentation/widgets/page_overlay.dart` (1995 linii)
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
  zaznaczenie lasso daje border/shadow i przesuwa tylko `Positioned` przez
  `ValueListenableBuilder`,
  `_cornerDelta`/`_clampSize`/`_cornerPosition`/`_cropOffsetX|Y`.
- 1663: `_editOcr(...)` — dialog edycji tekstu OCR; w trybie tablet prosi
  system o klawiaturę ekranową.
- 1784: `_LassoSelectionWidget` — niewidzialny hit target do dragowania całego
  zaznaczenia + pasek akcji copy/delete w powiększonym, klikalnym obszarze;
  nie rysuje prostokąta, bounds są dokumentowe, widget odejmuje `worldOrigin`
  strony i śledzi `dragDeltaListenable`.
- 1938: `_LassoActionButton` — wspólny 48×48 przycisk akcji lassa.
- 1968: `enum _CropAnchorAxis { left, right, top, bottom }`.
- 1970: `class _CropAnchor`.
- 1977: `enum _ImageContextAction { copy }`.
- 1979: top-level `Offset _globalDeltaToLocalDelta(...)`.

### `lib/features/editor/presentation/widgets/editor_toolbar.dart` (905 linii)
Główny pasek narzędzi nad canvasem (narzędzia, kolory, stroke width, undo/redo,
export).
- 11: `class EditorToolbar extends StatelessWidget`.
- 24: `build` — lewy przewijany segment z narzędziami, lokalnym przyciskiem tła
  i stały prawy przycisk
  eksportu.
- 119: `_exportButton()` — popup PDF/PNG wyrównany do prawej strony toolbara.
- 145: `_indexTabButton(context)` — ikonka zakładki; wybór koloru i wysokości w dialogu, dodaje kolejną zakładkę.
- 176: `_backgroundButton(context)` — lokalne ustawienia tła bieżącego notebooka/boarda.
- 191: `_showBackgroundDialog(context)` — dialog `Plain/Grid/Lines`, slider zagęszczenia i podgląd.
- 268: `_actionButton({...})` — generyczny IconButton.
- 286: `_toolButton({...})` — IconButton z aktywnym tłem gdy `tool == ...`.
- 305: `_toolHighlightStyle(selected)` — wspólny kwadratowy hover i aktywne tło dla przycisków toolbara.
- 322: `_eraserSelector()` — popup z `eraserBrush`/`eraserStroke`/`eraserArea`.
- 386: `_shapeSelector()` — popup z liniami/strzałkami/prostokątami/kołami.
- 422: `_selectorMenuButton({...})` — węższy przycisk strzałki dla selektorów.
- 485: `_shapeLabel(tool)`.
- 508: `_colorDot(...)` — kafelek koloru (quickColors + recentColors + picker).
- 544: `_pickColor(...)` — dialog wyboru koloru.
- 656: `_pickIndexTabPosition(...)` — dialog wyboru wysokości zakładki.
- 744: `_channelSlider({...})` — slider R/G/B w pickerze niestandardowym.
- 793: `_toByte(component)`.
- 798: `class _EraserIcon` — klasyczna ikonka gumki z opcjonalnymi błyskotkami/kółkiem obszaru.
- 837: `class _EraserIconPainter` — rysuje bazową sylwetkę gumki i znacznik gumki zakresowej.

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

### `lib/features/board/presentation/board_screen.dart` (878 linii)
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
  PageOverlay, `_BoardZoomControls` pozycjonowane) + `BusyOverlay`.
- 796: `enum _BoardContextAction { paste }`.
- 798: `_PasteFromClipboardIntent` / 802 Copy / 806 Cut / 810 Delete (te same
  intent klasy co w editor_screen ale lokalne).
- 814: `class _BoardZoomControls` — przyciski +/–/fit/reset zoom.

---

### `test/backup_eraser_flattening_test.dart` (96 linii)
Testy sanitizacji backupu gumki.
- 11: `flattens brush erasers into stroke fragments` — sprawdza, że
  `eraserBrush` znika z backupu, a oryginalny stroke zostaje tylko jako
  niezamazany fragment.
- 33: `flattens area erasers and removes eraser strokes from backup` —
  sprawdza, że `eraserArea` usuwa zamazany stroke i nie trafia do payloadu.
- 64: `_notebook(strokes)` — fixture jednego notebooka z jedną stroną.
- 88: `_stroke(...)` — fixture stroke'a z listy `Offset`.

### `test/widget_test.dart` (20 linii)
Smoke test: `NotesApp` pumpuje `MaterialApp` + jeden `CircularProgressIndicator`
(bo `IsarService.open()` jeszcze biegnie).

## 4. Kluczowe konwencje, na które agent musi uważać

- **Schemat Isar**: każda zmiana w `notebook_entity.dart` wymaga regeneracji
  `*.g.dart` (`dart run build_runner build --delete-conflicting-outputs`)
  i podbicia `kManualSchemaRevision` w
  [isar_service.dart:9](lib/data/isar/isar_service.dart#L9). Brak podbicia →
  aplikacja zrobi auto-wipe i pokaże banner reset.
- **`_toolFromIndex`/`_toolToIndex`** (repo, [linie 650 i 658](lib/features/notebook/data/notebook_repository.dart#L650))
  są obecnie **symetryczne** (`tool.index` ↔ `DrawingTool.values[index]`).
  Wcześniejsza wersja była dziurawa (gubiła square/circle/triangle/ellipse/
  text/image/edit przy roundtripie) — schema bumpnięty z 1 do 2, żeby wymusić
  auto-wipe. Zmieniasz kolejność `DrawingTool.values`? Albo dodajesz/wycinasz
  wartość pośrodku? Bump `kManualSchemaRevision` ponownie.
- **Save flow**: mutacje w `EditorController` debouncują `_save()` → repo →
  `onChanged` → `_BackupScheduler` → `LocalBackupService.snapshot` po idle.
  Backup jest przyrostowy per notebook (`manifest.json` + `notebooks/<uid>.json`).
- **OCR** działa wyłącznie na Android/iOS
  ([editor_controller.dart:1775](lib/features/editor/state/editor_controller.dart#L1775)).
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
  ([notebook_repository.dart:148](lib/features/notebook/data/notebook_repository.dart#L148))
  przenosi stare inline `bytes` z nietrwałą/pustą ścieżką do katalogu
  dokumentów aplikacji i czyści `bytes` po utrwaleniu pliku. `bytes` nie są
  zapisywane do Isara, jeśli blok ma trwały `path`, żeby duże obrazy nie
  spowalniały zapisu i odczytu notebooka.

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
