# PROJECT_MAP.md

Skrócony indeks projektu **NaNotateczki** (`pubspec.yaml`:
`name: program`). Stan sprawdzony względem repozytorium 2026-10-27.

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
- OCR nie ma interfejsu ani zależności runtime na żadnej platformie; stare pole
  `ocrText` pozostaje odczytywane wyłącznie dla zgodności istniejących danych.
- Główny przepływ:
  `main` → `AppScope` → `LibraryController` → `EditorController` →
  `NotebookRepository` → Drift.
- Po zapisie repozytorium przekazuje schedulerowi UID-y zmienionych
  notebooków. Backup na serwer czeka na bezczynność użytkownika,
  a kodowanie JSON i SHA-256 na natywnych platformach trafia do isolate. Backup czeka na bezczynność rysika, przetwarza tylko dirty
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

### `lib/main.dart` (169 linii)

Start aplikacji, globalne logowanie błędów i linuksowy filtr błędnych zdarzeń
klawiatury. Przed wczytaniem logów przygotowuje i migruje prywatny katalog
danych aplikacji.

- 37: `main`; 48: `_runApp`; 77–169: handlery błędów i watchdog key data.

### `lib/app/notes_app.dart` (12 linii)

Root widget przekazujący sterowanie do scope aplikacji.

- 5: `NotesApp`.

### `lib/app/app_scope.dart` (1016 linii)

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
`AppScrollBehavior` ukrywa automatyczne scrollbary we wszystkich stanach
aplikacji, również w dialogach, zachowując przewijanie gestami i myszą.
`AppUiScale` skaluje cały widok (także touch hit-test) oraz logiczny
`MediaQuery` bez zmiany geometrii zapisanych notatek i boardów.

- Dostarcza również singleton `StudyPlannerController` (Provider),
  niezależny od migracji bazy notatek.
- Dostarcza klient API, ładowaną asynchronicznie sesję/profil konta, zdalny
  backup i live sync; repozytorium przekazuje zmiany do schedulerów po zapisie.
- 36: `AppScope`; 43: `_AppScopeState`; 130: `didRequestAppExit`;
  `_startAccountSync` automatycznie odtwarza stan po logowaniu i restarcie
  na wszystkich platformach, zanim uruchomi backup.
- 235: `_syncAccountSettings`; 269: `_startAccountSync`;
  568: `AppUiScale`; 616: `_ExitGuardOverlay`;
  639: `_FinishingExitOverlay`; 747: `_BackupScheduler`;
  943: `flushForExit`.

## 3. Core

### Motyw

- `lib/core/theme/app_colors.dart`: jasna paleta i trzy współdzielone
  zestawy Blue/Pink/Green dla canvasu oraz okładek: trzy wspólne odcienie
  ciemny/średni/jasny, dostępne dla pióra i zakreślacza
  (Blue #03223A/#083F69/#7DADC8, Pink #823C44/#D8798A/#EAA6AE,
  Green #273526/#45624E/#CADFB8); dokładne wartości dla motywu
  jasnego podane przez użytkownika; w ciemnym transformacja HSL
  zachowuje barwę i odwraca jasność. Kontrast poszczególnych próbek
  w ciemnym trybie nie musi maleć kolejno od 1 do 3.
  Tryb ciemny:
  tło #2D2E2B, panele #3A3B39, aktywne #4A4B48, kartka/panele #5A5B57,
  ciemniejszy canvas notatek #50514D, tekst #EEECE6. `displayInkColor` odwraca jasność HSL wszystkich odcieni,
  zachowując hue, saturację i alpha (czerń↔biel, jasny błękit↔ciemny).
  Transformacja działa przy wyświetlaniu i eksporcie aktualnego motywu,
  bez modyfikowania zapisanych kresek. 50: `AppColors`.
- `lib/core/theme/app_metrics.dart` (3): współdzielone metryki A4.
  1: `AppMetrics`.
- `lib/core/theme/app_typography.dart`: cztery rozmiary tekstu interfejsu
  (18/16/14/12 px), wbudowane Gelasio (zbliżone do Georgii) z fallbackiem
  Georgia / Noto Serif / DejaVu Serif / Liberation Serif / Times New Roman /
  serif; regular/medium/semibold/bold oraz kursywa są lokalnymi assetami
  `assets/fonts/` (SIL OFL), również na web. Dokumenty z ręcznie
  wybraną czcionką zachowują własny krój i rozmiar.
- `lib/core/theme/app_theme.dart`: `AppTheme.light` i `AppTheme.dark`
  z kontrastowymi kontrolkami i nagłówkami. Tekstowe i konturowe
  przyciski jasnego motywu używają `onSurface` zamiast bladego akcentu.
  Wspólny promień 12 px dla prostokątnych przycisków, kart, dialogów,
  menu i pól formularza. Okrągłe próbki kolorów i uchwyty bez zmian.
  5: `AppTheme`.

### Wejście i preferencje

- `lib/core/input/app_preferences_controller.dart` (224):
  tryb urządzenia, akcent, `darkMode`, czułość dotyku
  `touchNavigationSensitivity` (0.5–2.0) i skalę `uiScale` (0.75–1.5;
  domyślnie 1.0) w `app_prefs.json`.
  Podgląd suwaków działa bez ciągłego zapisu na dysk, a puszczenie
  suwaka utrwala ustawienie; brak klucza zachowuje dotychczasowe 1.0;
  starsze Classic, Sakura i Mint są migrowane do nowego Bubblegum.
  Dotychczasowy zapis `bubblegum` zachowuje stary wybór jako Cherry.
  8: `DeviceInputMode`;
  27:
  `AppPreferencesController`.
- `lib/core/input/app_scroll_behavior.dart`: globalnie ukrywa paski
  przewijania na desktopie i urządzeniach dotykowych bez zmiany gestów,
  kółka myszy ani fizyki przewijania. `AppScrollBehavior`.
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

- `lib/core/storage/active_storage_namespace.dart`: wybiera nazwę SQLite,
  pliki Local/konta i klucze Web przed bootstrapem AppScope.
- `lib/app/notes_app.dart`: odbudowuje AppScope po bezpiecznym
  przełączeniu tożsamości; osobna baza per konto.
- `lib/data/sync/study_share_guest_outbox.dart`: odizolowany per share
  klucz na guest draft, nadal legacy v1; nie aktywuje Share v2.
- `test/active_storage_namespace_test.dart`: izolacja, fail-closed profilu
  oraz brak dostępu do starej biblioteki podczas zmiany konta.


- `lib/core/storage/app_data_directory.dart`: conditional export natywnego
  układu danych i webowego no-op.
- `lib/core/storage/app_data_directory_native.dart` (23): rozwiązuje ścieżki
  `path_provider` i udostępnia `getAppDataPath` oraz
  `prepareAppDataDirectory`. 6: `getAppDataPath`; 11:
  `prepareAppDataDirectory`.
- `lib/core/storage/app_data_directory_io.dart` (262): niezależny od Fluttera
  silnik bezstratnej migracji starego katalogu Dokumenty do
  `Application Support/data` przez plik tymczasowy, flush i SHA-256;
  konfliktów nie nadpisuje; obejmuje też lokalny profil konta bez sekretów.
  51: `migrateNativeAppData`; 172: atomowe
  przeniesienie pojedynczego pliku.
- `lib/core/storage/app_data_directory_web.dart` (10): webowy odpowiednik bez
  migracji systemu plików.
- `lib/core/storage/app_data_migration_report.dart` (13): wynik migracji ze
  ścieżkami przeniesionymi i konfliktowymi. 1: `AppDataMigrationReport`.
- `lib/core/storage/app_save_coordinator.dart` (50): rejestr aktywnych
  edytorów i wspólny flush ich oczekujących zapisów przed zamknięciem.
  3: `AppSaveCoordinator`.
- `lib/core/storage/text_storage.dart`: conditional import IO/web,
  opcjonalne podmiany odczytu/zapisu dla testów oraz możliwość wskazania
  katalogu natywnego (używana przez backup folderów); produkcja używa
  prywatnego katalogu aplikacji.
- `lib/core/storage/text_storage_io.dart`: odczyty i zapisy małych
  plików współdzielą kolejkę operacji per klucz i katalog; operacja trafia
  do niej przed asynchronicznym rozwiązaniem ścieżki, więc zachowuje kolejność
  wywołań i zapobiega usuwaniu aktywnego `.tmp` przez równoległy odczyt
  backupu. `waitForPendingTextStorageOperations` pozwala testom czekać na
  zakończenie kolejki przed usunięciem katalogu. Zapis nadal jest atomowy
  przez `.tmp`/`.previous` z recovery.
- `lib/core/storage/text_storage_web.dart` (9): odpowiednik w `localStorage`.
  3: `readStoredText`; 7: `writeStoredText`.
- `lib/core/error/app_error_log.dart` (180): trwały bufor błędów z ostatnich
  3 dni. Identyczne błędy z 10 minut są grupowane z licznikiem powtórzeń;
  starsze logi bez licznika pozostają czytelne.
  8: `AppErrorLog`; 120: `AppErrorLogEntry`.
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

- `lib/core/widgets/app_header_divider.dart`: wspólny 1 px separator nagłówka
  w ekranie głównym, planerze i ustawieniach. Wspólna wysokość paska to
  56 px, styl tytułu to 18 px i waga 600 jak Projects we wszystkich ekranach.
  Kolor linii w jasnym motywie: AppColors.divider (#CFCCC5),
  jak pasek suwaka; w ciemnym outlineVariant 45% na
  surfaceContainerLowest. W planerze i ustawieniach linia jest pierwszym
  elementem body bez zwiększania wysokości AppBar.
  4: `AppHeaderDivider`; 7: `colorOf`.
- `lib/core/widgets/app_dialog_actions.dart`: kolory dolnych akcji
  dialogowych dopasowane do `onSurface` w trybie jasnym i ciemnym;
  pozostałe przyciski nie zmieniają wyglądu.
- `lib/core/widgets/app_labeled_field.dart`: stałe etykiety i wspólne obrysy formularzy konta i zgłoszeń.
- `lib/core/widgets/empty_state.dart` (30): wspólny pusty stan.
  3: `EmptyState`.
- `lib/core/widgets/resizable_frame.dart` (200): ramka z ośmioma uchwytami
  resize.
  5: `ResizeDirection`; 16: `ResizableFrame`;
  40: `_ResizableFrameState`.

## 4. Warstwa danych

### Drift

### `lib/data/drift/notes_database.dart` (376 linii)

Schemat SQLite i bezpieczne otwieranie bazy z trzema próbami. Start sprawdza
`PRAGMA quick_check` i `PRAGMA foreign_key_check`; po potwierdzonej korupcji lub naruszeniu integralności natywna baza jest
zachowywana jako plik `.corrupt_*`, a aplikacja
otwiera świeżą bazę, aby lokalny recovery mógł odtworzyć dane.
Po migracji katalogu aktualizuje w SQLite prefiks trwałych ścieżek obrazów.

- 9: `NotebookRows`; 21: `PageRows`; 32: `TextBlockRows`;
  49: `ImageBlockRows`; 72: `InkStrokeRows`.
- 85: `DatabaseOpenResult`; 99: `DatabaseOpenStage`;
  110: `DatabaseOpenException`; 143: `NotesDatabase`.
- 152: `NotesDatabase.open` (opcjonalna publiczna nazwa osobnej bazy);
  304: relokacja ścieżek obrazów; 318: kontrola integralności;
  346: `_createOperationSchema`; 353: `schemaVersion` (`5`);
  356: `migration` — zachowuje migrację v1→v2 i dodaje tabele operacji
  w migracji v2→v3, zachowuje tombstones v4 i status blocked v5.

- `lib/data/drift/operation_schema.dart`: addytywne tabele surowego SQL
  dla operacji, outboxu, ACK, tombstones, checkpointów, snapshotów,
  assetów oraz stanów aktorów; bez zmiany wygenerowanego DAO.
- `lib/data/drift/notes_database_connection.dart` (2): conditional export
  natywnego lub webowego połączenia.
- `lib/data/drift/notes_database_connection_io.dart` (210): przed otwarciem
  migruje dane i otwiera SQLite w prywatnym `Application Support/data` przez
  `NativeDatabase.createInBackground`.
  9: `NotesDatabaseConnection`; 27: `openNotesDatabaseConnection`; 70:
  `quarantineNotesDatabase`.
- `lib/data/drift/notes_database_connection_web.dart` (41): SQLite WASM z
  trwałym IndexedDB.
  6: `NotesDatabaseConnection`; 13: `openNotesDatabaseConnection`.
- `lib/data/drift/notes_database.g.dart` (5181): kod wygenerowany przez Drift;
  nie czytaj ani nie edytuj ręcznie.

### Backup, eksport i synchronizacja

### `lib/data/backup/local_backup_service.dart` (2657 linii)

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
path, żeby historia manifestów nie straciła zależności. Manifest
v6 zachowuje też metadane `library_folders.json` (okładki i Recent), obok
listy `folders` zachowanej dla starszych kopii. Walidacja sumy kontrolnej
uwzględnia opcjonalne `folderMetadata`, bez łamania starych manifestów.
Restore starszych manifestów
pozostaje zgodny. Odczyt i odtwarzanie `library_folders.json` korzysta ze
wspólnej, serializowanej warstwy text storage, tak jak zapis biblioteki.
Web nadal zapisuje pełny snapshot w `localStorage`.

- 19: `LocalBackupService`; 37: `waitUntilIdle`; 153: `snapshot`;
  84: `_pagesDir`.
- 772: `_pageReferenceFromJson`; 1054: `readLatest`;
  1283: `_readBackupPageJson`; 1508: `restoreFromLatest`.
- 1883: `_BackupPageWorkerRequest`; 1922: `_BackupWorkerClient`;
  2116: `_createPageBackupPayload`; 2521: `_BackupPageReference`.
- 2407: `BackupSnapshotReport`.

### `lib/data/backup/remote_backup_service.dart` (aktualizowany)
Odzyskiwanie archiwalnych metadanych biblioteki nie przywraca pustych usuniętych folderów; tylko faktycznie odzyskane dokumenty mogą przywrócić swoje ścieżki nadrzędne, okładki i zadania. Test `test/recovered_library_metadata_test.dart`.


Kompletny snapshot serwerowy v2: opróżnia zapisy, dołącza obrazy, foldery,
zadania, planer, ustawienia, Recent i preferencję backupu; liczy SHA-256,
wykonuje pending → upload → finalize i uznaje
wyłącznie odpowiedź `verified`. Limit klienta wynosi 64 MiB.
Etap 9: kopia z `accountId`, `schemaVersion`, `operationCheckpoint`.
Notatki i checkpoint są czytane transakcyjnie; zmiana plików planera i
preferencji przerywa snapshot, a obecny outbox blokuje wysyłkę do ACK.
Zwykły start nie importuje backupu. Marker per konto odróżnia utraconą
SQLite/IndexedDB od nowej lub celowo pustej biblioteki.

- 12: `RemoteBackupReceipt`; 24: `RemoteBackupService`;
  42: `uploadVerifiedSnapshot`; 145: `hydrateFromLatestAccountBackup` pobiera
  najnowszy zweryfikowany backup, weryfikuje SHA oryginalnych bajtów i dołącza
  brakujące dokumenty; inną wersję zachowuje z nazwą `(1)`, `(2)` w tym samym
  folderze. Historia synchronizacji i tombstones mają pierwszeństwo.
  Odmienny szkic z backupu zachowuje jako kopię obok rewizji konta;
  nie wskrzesza dokumentów oznaczonych jako usunięte.
  Łączy foldery i zachowuje zadania przy właściwej kopii planera.
  Nie nadpisuje istniejących preferencji ani historii planera. Tylko
  potwierdzona utrata lokalnej bazy wyzwala automatyczne recovery;
  można wtedy przywrócić identyczny backupId mimo markera odzyskiwania.
  Błąd odzyskania nie zatrzymuje inicjalizacji live sync. Znacznik backupId zapobiega dublowaniu kopii konfliktowych
  podczas ponownego przetwarzania tego samego snapshotu. Oczekujące offline
  usunięcia z outboxu mają pierwszeństwo nad snapshotem.

- `lib/data/backup/backup_payload_bytes.dart`: 6: `backupPayloadBytes`
  wycina oryginalne UTF-8 payloadu z już poprawnego JSON, bez zmiany
  zapisu liczb, Unicode i escape'ów podczas sprawdzania SHA-256.

### `lib/data/backup/remote_backup_scheduler.dart` (zmienny indeks)

Jawnie włączany scheduler zalogowanego konta: po zmianach wysyła verified
snapshot po ustawionym okresie bezczynności (domyślnie 30 sekund), po błędzie
ponawia po 5 minutach; dostępne opóźnienia: 15, 30, 60, 120, 300, 900,
1800 sekund. Resume nie resetuje czasu bezczynności; ukryta karta nie przesuwa czasu
interakcji, a modyfikacje danych przez synchronizację nie są uznawane za
aktywność użytkownika. Kliknięcia, sprzętowe klawisze i Quill z soft keyboard
rejestrują aktywność.
Samo logowanie nie włącza wysyłki. Stan wyniku i błędu jest czyszczony przy
zmianie konta, a losowy `deviceId` ma osobny plik per `userId`.

- 17: `RemoteBackupScheduler`; logika bezczynności i zapis per konto; `enableForSignedInAccount`, `setIdleSeconds`, `backupNow`,
  `ensureVerifiedForExit` blokuje normalne wyjście, jeżeli snapshot nie jest zweryfikowany, ale kończy oczekiwanie po kontrolowanym
  `exitBackupTimeout` zamiast uruchamiać kolejne wielominutowe uploady;
  102: `refreshAccountPreference`; 130: `uploadNow`; 144: `backupNow`.
  Licznik generacji nie pozwala zgubić zmiany wykonanej
  podczas trwającego uploadu. `reconcileBeforeBackup` odczytuje z serwera
  notatniki, ustawienia i planner przed wykonaniem snapshotu;
  błąd uzgodnienia zachowuje `dirty` i blokuje nieaktualny backup.
  Czysty lokalnie klient nadal pobiera remote przez live sync
  (WebSocket i 45-sekundowy fallback), a import zmiany oznacza backup jako dirty.

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

### Protokół operacji v1 (etap 1)

- `lib/data/sync/operation_protocol.dart`: `OperationEnvelope` i
  `OperationKind` definiują wersjonowany format operacji. Stabilne ID,
  aktor, sekwencja, zależności i licznik logiczny. Bez mieszania stanu
  widoku z treścią. Test: `test/operation_protocol_test.dart`.
- `server/api/tests/test_dart_python_operation_contract.py`: uruchamiany w
  CI aplikacji test zgodności nazw, targetów i ograniczeń protokołu
  Flutter/Python, sprawdza rzeczywisty model Python bez atrap.
- Kanoniczny opis i reguły payloadu:
  `NaNotateczki-serwer/docs/OPERATION_PROTOCOL_V1.md`.
  Walidacja v2 dopuszcza puste `value`, odrzuca nadmiarowe pola payloadu,
  zmianę `id`/`uid` i niedozwolone znaki w identyfikatorach.
  Ten kontrakt jeszcze nie zastępuje istniejącego snapshotowego sync.

### Porządkowanie operacji v1 (etap 2)

- `lib/data/sync/operation_ordering.dart`: `OperationActorClock`
  (Lamport, zakres jednego dokumentu zachowany w checkpointcie, redukcja
  tylko przyczynowo pokrytych frontierów, fail-closed ponad 256 niezależnych),
  `CausalOperationBuffer` (atomowe zatwierdzanie gotowych operacji,
  kwarantanna wadliwych zaległych pakietów, duplikaty i rozgałęzienia),
  `OperationCheckpoint` (pełna historia i odrzucone ID, bez kompaktowania)
  oraz `OperationPropertyRegister` (reguły pól i tombstones).
  `test/operation_ordering_test.dart`: kolejność, błędne zależności,
  wycofanie po błędzie, restart, odrzucone ID, limit zależności.
  Nowy `OperationStore` zapisuje operacje w Drift od etapu 3;
  legacy klienci nadal używają snapshotów v1 do czasu migracji.

### Trwały lokalny dziennik (etap 3)

- `lib/data/sync/operation_store.dart`: transakcyjny zapis projekcji i
  `OperationEnvelope`, rosnący `actorSeq`, idempotencja, lokalny outbox,
  atomowy ACK, tombstones, checkpointy i checksummed snapshots.
  Referencje nowych assetów mają klucz z pageId i objectId,
  bez usuwania starszych odwołań o nieznanej stronie.
  Snapshot jest blokowany, jeśli cofa potwierdzony kursor ACK albo
  istniejący checkpoint snapshotu.
  Zależności są weryfikowane jako należące do tego samego dokumentu. Projekcja
  wywołującego musi używać tej samej bazy Drift. Nie jest jeszcze wpięty
  we wszystkie legacy ścieżki `saveNotebook` (etap 5).
- `lib/data/drift/operation_schema.dart`: SQLite v5 z migracją v3 → v4
  zachowującą tombstones oraz pageId usuniętego obiektu; v5 zapisuje
  trwały status `blocked` dla nieodwracalnych błędów wysyłki.
  Tabele są tworzone przez `customStatement` bez nowych mapowań `.g.dart`.
- `notes_database_connection_io.dart`: WAL + `synchronous=FULL`.
- `notebook_repository.dart`: `_upsertNotebookPages` i `_upsertPage`
  aktualizują rekordy zamiast pełnego kasowania i reinstalacji.
- `test/operation_store_test.dart`: rollback, ponawianie, ACK, usunięcia,
  migracja z v2, snapshoty i checkpointy.
- `test/notebook_incremental_update_test.dart`: wyzwalacze SQL wykrywają
  niepotrzebne usuwanie stron i tekstów przy zwykłej edycji.
- `docs/ETAP_3_SQLITE.md`: wymagania wdrożeniowe i testy crash-recovery.

### Operacyjny silnik v2 (etap 5, opt-in)

- `lib/data/sync/operation_gateway.dart`: `OperationGateway`,
  `HttpOperationGateway`, `OperationReceipt`, `OperationFeedPage`.
  Waliduje payload, ACK, kursory i limit 1 MiB API v2;
  backend sprawdza też limit rozmiaru materializowanej projekcji;
  przekazuje nagłówek Share `X-Share-Id`.
- `lib/data/sync/sync_engine.dart`: `SyncEngine` i
  `RemoteOperationReducer`. Trwały lokalny outbox, max 50/800 KiB
  w paczce, aktorzy per dokument, ACK bez replay, REST catch-up,
  WebSocket hints, najwcześniejszy retry, generation token na stop,
  odświeżenie sesji i rebase przez callback. Błąd pull nie blokuje push.
  Pakiet 409/413/422 próbuje bezpiecznego prefiksu, bez pomijania actorSeq.
  `onRemoteCommitted` powiadamia UI dopiero po commit SQLite i przed
  przesunięciem kursora; błędny patch jest ponawiany, a ACK własnego
  aktora nie odmalowuje widoku. `lastError` znika po sukcesie.
  Nie podłączać do UID v1 przed etapem 11.
- `lib/data/sync/operation_store.dart`: `pending(includeDeferred)`,
  `isPending`, `isLocalOperation`, `advanceCheckpoint`; strzeże actorSeq także przy
  retry, lokalne operacje zależą od trwałych zdalnych frontierów,
  a zaakceptowane przez serwer opóźnione edycje usuniętego UID
  pozostają w dzienniku jako no-op.
- `test/sync_engine_test.dart`, `test/operation_gateway_test.dart`:
  utracone ACK, echo, rebase, cursor gap, retry, kontrakt JSON.
- `test/operation_store_test.dart`: dodatkowe regresje frontier i
  tombstones po przyjętej operacji zdalnej.
- `docs/ETAP_5_SYNC_ENGINE.md`: granica migracji v1/v2 i
  nieuruchomione scenariusze E2E. Etap 6 dodaje konkretne reduktory
  edytora/Share, etap 11 przełącza istniejące dokumenty.

### Share v2 — przyrostowe operacje (etap 6, opt-in)

- `lib/data/sync/share_operation_projection.dart`: `ShareOperationProjection`
  redukuje dokument/strony/obiekty i tombstones według stabilnych ID,
  bez pełnych snapshotów; `PendingShareProjection` nakłada oczekujące
  lokalne operacje na potwierdzony stan i ujawnia nierozwiązane usunięcia.
- `lib/data/sync/share_text_edit_adapter.dart`:
  `ShareTextEditAdapter` mapuje zmianę plain text na atomowe intenty,
  wstawia/usuwania z kotwicami i dzieli wsady po 256; formatowanie
  Quill jest jawnie blokowane do czasu migracji atrybutów.
  Regresja: `test/share_text_edit_adapter_test.dart`.
- `lib/data/sync/operation_text_sequence.dart`:
  `OperationTextSequence` — RGA/CRDT atomów z deterministycznym
  porządkiem, kotwicami i usunięciami zachowanymi do replay;
  `operation_protocol.dart` waliduje `text.insert/delete` i blokuje
  próby zmiany typu obiektu oraz wewnętrznych danych CRDT.
  Backend odpowiednik: `api/app/text_sequence.py`, podłączony w
  `api/app/operation_projection.py` repo NaNotateczki-serwer.
- `lib/features/share/presentation/study_share_memory_db_web.dart`:
  `openSharedGuestOperationDatabase(shareId)` otwiera trwały, izolowany
  per parę shareId + guestActorId SQLite WASM w IndexedDB
  (odrębny od bazy v1, konta i pozostałych gości).
- `lib/features/editor/state/editor_controller.dart`:
  `applyConfirmedShareObjectPatch` aplikuje jeden już utrwalony obiekt
  bez podmiany kontrolera, historii widoku lub innych stron; aktualizacja
  koloru/geometrii ink nie zmienia z-order, jawny `sortIndex` go zmienia.
- Regresje: `test/operation_text_sequence_test.dart`,
  `test/share_operation_projection_test.dart`,
  `test/share_operation_guest_database_test.dart` (Chrome),
  `test/share_editor_object_patch_test.dart`; serwer:
  `api/tests/test_text_sequence.py`,
  `api/tests/test_operations_share_auth.py` (wygaśnięcie v2 Share).
- `docs/ETAP_6_SHARE_OPERATIONS.md`: stan wdrożenia i scenariusze E2E.
  **Nie podłączono jeszcze do legacy hosta/gościa.** `StudyShareGuestEditor`
  i `LiveWebSyncService` pozostają w v1 do migracji UID (etap 11);
  preview strokes, assety i Quill rich-text wymagają dalszej integracji.

### Nowa synchronizacja serwerowa

- `lib/data/sync/api_client.dart`: klient REST z wymuszeniem HTTPS,
  timeoutem, limitem odpowiedzi, Bearer tokenem i request ID.
  HTTP 5xx oraz błędy transportu wpisuje automatycznie do `Errors`
  (`AppErrorLog`), bez treści odpowiedzi i tokenów; wyklucza health
  oraz diagnostyczny pomiar zegara, aby nie powstała pętla raportowania.
  HTTP 4xx, w tym zwykły konflikt 409, nie tworzy wpisu.
  7: `ApiResponse`; 18: `ApiException`; 29: `ApiClient`.
  Domyślny adres dla wszystkich platform to `https://api.nanotateczki.pl`;
  `BACKEND_URL` może go nadpisać w buildach lokalnych/testowych.
- `lib/data/sync/device_clock_check.dart`: jednorazowy pomiar
  czasu UTC przy rozpoczęciu zalogowanej sesji przez `GET /v1/time`.
  `Stopwatch` mierzy RTT; szacowanie środka żądania ma tolerancję
  60 sekund + połowę RTT, pomija RTT ponad 10 s i skok zegara w trakcie
  pomiaru. Różnicę wpisuje do Errors i pokazuje SnackBar w `AppScope`
  bez blokowania synchronizacji. Brak sieci nie generuje alarmu.
- `test/device_clock_check_test.dart`: aktualny zegar, opóźnienie i
  przyspieszenie o 2 min, tolerancja i niepoprawna odpowiedź API.
- `lib/data/sync/app_activity_wake_service.dart`: wysyła bez danych
  użytkownika nieautoryzowany GET /health przy starcie trybu konta, a potem
  najwyżej raz na 30 minut pod warunkiem kolejnej aktywności myszki,
  dotyku, rysika, przewijania lub klawiatury. Nie działa w localOnly,
  nie używa timera, nie blokuje UI; błędy sieci są ignorowane.
- `test/app_activity_wake_service_test.dart`: throttling, inactive/localOnly
  oraz żądanie bez tokenu.
- `lib/data/sync/diagnostics_upload_service.dart`: podczas zalogowanej sesji
  nasłuchuje trzech lokalnych logów i przesyła aktualny snapshot po
  12 s bezczynności do `PUT /v1/reports/diagnostics`; błędy ponawia
  po 5 min, nie blokuje aplikacji; jeden trwały UUID urządzenia.
  Backend utrwala `errors` w
  `data/diagnostics/<account UUID>/<device UUID>.json` i nadpisuje
  poprzedni snapshot danego urządzenia.
- `lib/data/sync/account_credential_store.dart`: `AccountCredentialStore`
  pozwala w testach używać pamięci; implementacja
  `SecureAccountCredentialStore` korzysta z `flutter_secure_storage`
  dla natywnych systemów oraz Web.
- `lib/data/sync/account_session_controller.dart` (531): trwały profil
  pierwszego uruchomienia i trybu lokalnego, rejestracja/logowanie,
  rotacja refresh tokenów i ich bezpieczne utrwalanie poza
  `account_profile.json`. Przy starcie odświeża zapisaną sesję,
  sprawdza `boundUserId`, login i adres API; offline nie wymusza
  logowania, a odrzucony token usuwa. Login i wylogowanie są
  serializowane z operacjami na magazynie sekretów; ponowny login
  nie traci danych lokalnych. Przy logout kończy zapisy i synchronizację
  przed odwołaniem serwerowej sesji; błąd flush pozostawia aktywne konto.
  `shouldShowStartupDialog` tylko przy nieukończonym onboardingu.
  10: `AccountDataMode`; 12: `AccountSessionController`;
  84: `_loadProfile`; 223: `_refreshSession`;
  247: `_restorePersistedSession`; 313: `_persistRefreshCredential`;
  343: `changePassword`; 396: `useLocalProfile`.
  Hasła 8–128 przy tworzeniu i 1–256 przy logowaniu.
- `lib/data/sync/account_settings_sync_service.dart` (aktualizowany):
  11: `AccountSettingsSyncService`; 34: `syncNow`; 164: `stop`.
  `AccountSettingsSyncService.syncNow` odnawia wygasły access JWT
  i uzgadnia rewizje konta: `appPreferences`, `editorPreferences`,
  `recentColors`, `backupPreferences` oraz `libraryState`.
  Biblioteka obsługuje CAS i ponowienie po 409 z trójstronnym
  scalaniem folderów, okładek i zadań oraz zachowaniem lokalnych zmian
  powstałych podczas uploadu. Pozostałe ustawienia nie nadpisują
  automatycznie konfliktujących edycji. Zachowuje kopię sprzed importu.
  Pierwszy odczyt istniejącego stanu konta ma pierwszeństwo przed
  niepowiązanym archiwalnym lokalnym plikiem folderów, którego zawartość
  zostaje zachowana przed importem; test
  `test/account_settings_sync_service_test.dart`.
  `AppScope` uruchamia odczyt po logowaniu, przy wznowieniu i co 45 s
  oraz wysyłkę po zmianie preferencji, recent i czasu backupu.
- `lib/data/sync/library_state_merge.dart`: trójstronne porównanie
  `libraryState` według ostatniej zatwierdzonej rewizji; zachowuje
  niezależne dodatki, tombstones oraz numerowane konflikty zadań.
- `test/library_state_merge_test.dart`: równoczesne edycje zadań,
  usunięcia i niezależne zmiany folderów.
- `test/account_settings_sync_service_test.dart`: dwa urządzenia,
  retry access JWT i zabezpieczenie edycji lokalnej podczas żądania REST.
- `lib/data/sync/live_web_sync_service.dart` (aktualizowany): jawna polityka pierwszej
  synchronizacji, trwały mały outbox/kursor, CAS, idempotencja, tombstones,
  kopie konfliktowe, pełne stronicowanie REST reconciliation i WebSocket
  tylko jako sygnał na wszystkich platformach; własny push nie przesuwa
  kursora zdarzeń z innych
  urządzeń. Zapisy outboxu i kursora są serializowane wraz z kolejką
  sprzed startu, żeby starszy zapis nie wymazał nowszych UID.
  Bootstrap przechowuje zweryfikowany kursor już z pierwszej strony;
  test regresyjny potwierdza jego trwały zapis przy skompaktowanym tombstone.
  `start`/`stop` zerują pamięciowy stan konta, a zapis stanu używa
  utrwalonego `userId`, więc kursor, rewizje i outbox nie przechodzą między
  kontami. Normalizuje ścieżki obrazów oraz daty dokumentu do UTC,
  zapobiegając fałszywym konfliktom między Linuxem, Web, iOS i Androidem.
  Potwierdzenia własnego PUT podczas share nie nadpisują aktywnego canvasa:
  zachowują bazę ostatnio widocznego stanu oraz zaakceptowany stan serwera,
  a kolejne lokalne zmiany są na niego trójstronnie rebazowane. Odroczona
  rewizja trafia do SQLite dopiero gdy nie ma oczekujących zapisów i aktywnego
  gestu. Obydwie bazy trafiają do limitowanego checkpointu synchronizacji.
  Test `test/live_web_sync_service_test.dart` weryfikuje hosta piszącego
  podczas zmiany gościa i zachowanie obiektów przy kolejnym wysłaniu.
  Bazowy snapshot zachowuje dokładną odpowiedź serwera, bez normalizacji,
  ponieważ API weryfikuje go względem niezmiennej historii rewizji.
  Niezmieniona data utworzenia zachowuje oryginalny zapis bazy także w PUT.
  20: `InitialSyncPolicy`; 26: `sharedDocumentSyncDebounce`; 28:
  `LiveWebSyncService`; 115: `start`;
  po reconnect i wznowieniu aplikacji REST uzupełnia utracone sygnały WebSocket;
  Przy odbiorze zmian gości najpierw opróżnia edytor właściciela i wysyła
  jego oczekujące operacje ścieżką serwerowego scalenia, zanim zastosuje
  feed, aby niezależne zmiany nie tworzyły kopii konfliktowej.
  Ostatnią bazę zatwierdzonego dokumentu zapisuje razem z rewizją,
  aby móc scalać niezależne edycje także po restarcie; stan bazowy
  jest limitowany do 1 MiB, a pojedynczy dokument do 256 KiB.
  `setSharedDocumentUid` wybiera 120 ms debounce dla active share, aby
  pełny snapshot nie był wysyłany dla każdego lokalnego zapisu;
  reentrancy nie gubi zmian podczas poprzedniego requestu. Usunięta
  została dawna ścieżka `restoreDeleted`; edycje po tombstone nie
  wznawiają oryginalnego UID. `enqueue`, `syncNow`, `stop`.
- `lib/data/sync/notebook_merge.dart`: trójstronne scalanie niezależnych
  zmian pól oraz obiektów o osobnych ID; kolizje wymagają kopii.
- `test/notebook_merge_test.dart`: dopiski, usuwanie i jawne konflikty.
- `lib/data/sync/notebook_conflicts.dart`: `numberedNotebookCopy`
  zachowuje treść w tym samym folderze pod numerowaną nazwą i nadaje
  nowe UID dokumentu, stron, tekstów, obrazów i kresek.
  `copyLocalNotebookToAccount` kopiuje lokalny dokument do konta,
  zachowując tytuł bez konfliktu; kolizja nazw w tym samym folderze
  i rodzaju otrzymuje pierwszy wolny sufiks `(1)`, `(2)`.
  Sam helper nie realizuje przełączenia magazynów ani migracji konta.

## 5. Domena notebooka i repozytorium

### Modele

- `lib/features/notebook/domain/notebook.dart` (42): dokument i jego strony.
  4: `Notebook`.
- `lib/features/notebook/domain/notebook_kind.dart`: notebook, board lub
  planner, z niezmienionymi indeksami starych typów.
  1: `NotebookKind`; 3: `NotebookKindValue`.
- `lib/features/notebook/domain/note_page.dart` (39): zawartość strony.
  5: `NotePage`.
- `lib/features/notebook/domain/drawing_tool.dart` (43): enum narzędzi i
  klasyfikacja eraser/shape/ink.
  1: `DrawingTool`; 21: `DrawingToolX`.
- `lib/features/notebook/domain/ink_stroke.dart` (55): stroke i punkt z
  naciskiem; `usesHighlighterStrokeCap` rozpoznaje półprzezroczyste
  geometryczne kształty uzyskane przez przytrzymanie zakreślacza.
  5: `InkStroke`; 37: `InkPoint`.
- `lib/features/notebook/domain/ink_spatial_index.dart` (125): cache'owany
  indeks siatkowy kandydatów do hit-testu.
  14: `inkSpatialIndexFor`; 24: `InkSpatialIndex`.
- `lib/features/notebook/domain/ink_eraser_engine.dart` (824):
  jedyny silnik modyfikacji gumki dla boarda i notebooka. Obsługuje zwykłą
  gumkę, erase-stroke, gumkę zakresową (przycinanie fragmentów)
  oraz scratch erase. Promień bazgrołu skaluje się do jego rozmiaru;
  rzadkie punkty tuszu są przycinane, bez kasowania całego odcinka.
  Legacy maski są tu wyłącznie jednorazowo
  normalizowane do zwykłego ink; generator fragmentów unika
  kolizji ID i obsługuje też pojedyncze punkty.
  34: `InkEraserEngine`; 37: `normalizePage`; 42: `normalizeNotebook`;
  108: `scratchEraseRadius`;
  125: `scratchInkHitCount`; 147: `eraseScratchParts`;
  187: `eraseAreaParts` — przycinanie na krawędziach wielokąta;
  232: `flattenLegacyErasers`.
- `lib/features/notebook/domain/text_block.dart` (45): blok Quill z pozycją,
  stylem, szerokością i rotacją.
  3: `TextBlock`.
- `lib/features/notebook/domain/image_block.dart` (71): obraz, legacy tekst
  OCR, crop, rotacja oraz legacy inline bytes.
  4: `ImageBlock`.

### `lib/features/notebook/data/notebook_repository.dart` (aktualizowany)

Most domena ↔ Drift ↔ JSON, z kolejką zapisu per UID i ochroną przed
podejrzaną utratą danych. Po zapisaniu dowodów podejrzany zapis
jest blokowany wyjątkiem przed transakcją SQLite. Zapis z edytora
przekazuje identyfikatory elementów usuniętych jawnie przez użytkownika;
guard rozpoznaje przeniesienie obrazu po ID i tożsamości pliku/bajtów
(bez porównywania geometrii i legacy OCR). Nie pomija niezgłoszonych
usunięć i skrócenia istniejących danych. Jest też kanoniczną granicą migracji starego modelu
gumki: odczyt normalizuje legacy maski, a zdrowe strony są fizycznie
przepisywane w SQLite bez eraser-stroke'ów i bez zmiany metadanych notebooka.
Migracja korzysta z tej samej kolejki per UID co zwykłe zapisy, więc nie
ściga się z aktywnym save'em. Zapis, import, restore i JSON normalizują dane
ponownie, a niskopoziomowa serializacja odrzuca próbę utrwalenia eraser-stroke.
`NotebookRepositoryChange` rozróżnia pełną zmianę, zmianę konkretnych page IDs
i zmianę samych metadanych, dzięki czemu scheduler może uruchomić backup v6
tylko dla właściwych stron. Repozytorium udostępnia też oczekiwanie na
wszystkie trwające zapisy per UID. Atomowe przywracanie i import respektują
parametr `notifyChanges`, zgłaszając zmianę dopiero po zatwierdzeniu.
Ręczny eksport pozostaje samowystarczalny
i zachowuje obrazy inline.

- 23: `DataIntegrityIncidentHandler`; 30: `NotebookRepositoryChange`;
  45: `RepositoryChangeHandler`; 55: `NotebookRepository`.
- `createPlanner`: nowy typ wpisu bazujący na istniejącym schemacie
  SQLite i pustej stronie technicznej; lista zadań zapisywana osobno.
- 81: `waitForPendingSaves`; 141: `fetchNotebooks`;
  518: `saveNotebook`; zapis stron jest bezpośrednio dalej.
- 1499: `_readPage`; 1561: `_persistLegacyEraserPages` — migracja masek,
  po wejściu do kolejki ponownie czyta aktualny stan SQLite.
- 1921: `_strokeToCompanion`; 2150: `_strokeToJson` — oba blokują
  utrwalenie eraser-stroke.
- `_toolFromIndex` i `_toolToIndex` muszą pozostać symetryczne.

### `lib/features/notebook/presentation/notebook_screen.dart` (40 linii)

Wybiera pusty stan albo właściwy `EditorScreen`; przekazuje aktualny tytuł
notatnika, flagi narzędzi/timera i opcjonalny przycisk otwarcia nawigacji
mobilnej, bez zmiany modelu dokumentu.

- 8: `NotebookScreen`.

## 6. Biblioteka

### `lib/features/library/presentation/library_controller.dart` (1083 linie)

Stan folderów wielopoziomowych, listy dokumentów, wyszukiwania, syncu,
importu i recovery. Hierarchia folderów korzysta ze ścieżek logicznych
`Rodzic/Dziecko` w dotychczasowym polu `Notebook.folder` i liście
`folders` w JSON; starsze pojedyncze nazwy są folderami głównymi.
`childFoldersOf` filtruje bezpośrednie dzieci. Zmiana nazwy lub usunięcie
folderu obejmuje rekurencyjnie podfoldery, dokumenty, okładki i zadania.
Przenoszenie notebooków i boardów między folderami zapisuje tylko metadane
w SQLite; aktywny dokument zachowuje zaznaczenie w nowym folderze.
`moveFolderToFolder` relokuje całe poddrzewo: ścieżki folderów, dokumenty,
okładki i bieżące zaznaczenie. Odrzuca własny podfolder, dotychczasowego
rodzica i kolizję z folderem o tej samej nazwie w celu.
Zapisuje kształt, indywidualny kolor ikony okładki i ostatnie 12
wybranych kolorów w zgodnym wstecznie `library_folders.json`
(legacy lista nazw lub obiekt z `folders`, `covers` i `recentCoverColors`);
nie zmienia schematu SQLite. Wspólne `library_folders.json` przechowuje
  również zadania plannerów (`plannerTasks`); dlatego lokalny backup
  obejmuje ich treść bez migracji Drift. Każde zadanie ma UID, tytuł,
  stan odhaczenia oraz opcjonalny deadline i godzinę. Opcja
  Odhaczone zadania są zawsze prezentowane na dole, bez zmiany
  kolejności danych; historyczny "plannerCompletedLast" jest ignorowany.
  Zapisy tekstu są
  grupowane krótkim debounce; `AppSaveCoordinator` opróżnia kolejkę przed
  zamknięciem. Usuwanie folderu lub planera usuwa jego zadania.
  Wybór dokumentu synchronizuje
też aktywny folder, dzięki czemu drzewko biblioteki zaznacza folder i notatkę
jednocześnie. Asynchroniczny start
nie powiadamia słuchaczy po usunięciu kontrolera. Zapis samych folderów
zgłasza pusty zestaw zmian repozytorium, więc aktualizuje manifest bez
oznaczania notebooków jako dirty. Sprzątanie osieroconych obrazów działa
tylko przy normalnym starcie istniejącej, zdrowej bazy.

- 21: `FolderCoverShape`; 23: `FolderCoverStyle`; 54: `LibraryController`.
- 146: `initialize`; 161: `loadItems`.
- 328: `folderNames`; 354: `childFoldersOf`; 363: `updateFolderCover`.
- 382: `createFolder`; 405: `renameFolder`;
  473: `canMoveFolderToFolder`; 491: `moveFolderToFolder`;
  551: `deleteFolder` (poddrzewo).
- 749: `moveItemToFolder`; 796: `selectFolder`; 924: `_loadFolders`;
  986: `_saveFolders` — zapis folderów zgłasza pusty zestaw zmian.

### `lib/features/library/presentation/library_screen.dart` (aktualizowany)
`_PersistentWorkspaceEditor` utrzymuje lokalny `EditorController` przez
zmiany rewizji serwerowej; zamiast tworzyć nowy kontroler po każdym sync,
odracza import podczas aktywnego gestu, a po nim odświeża tylko treść.
`StudyShareGuestEditor` stosuje ten sam mechanizm i własny viewport. Odroczony import gościa zachowuje osobną bazę ostatnio widocznej rewizji, dzięki czemu nowszy sygnał nie interpretuje niewyświetlonego potwierdzenia jako lokalnej edycji; test `shared_edit_conflicts_test.dart`.


Nawigacja popup sprawdza rzeczywisty aktywny tryb drawer, nie samo
`MediaQuery.sizeOf`, aby zachować desktopowe wyrównanie menu po resize.
Widok responsywny: od 960 logicznych px sidebar biblioteki pozostaje
obok katalogu/edytora; poniżej progu ten sam panel otwiera się jako
wysuwany drawer z przycisku w nagłówku. `SafeArea` zabezpiecza cały
widok przed systemowymi paskami i wycięciami ekranów Android/iOS.
Globalny klucz workspace zachowuje kontroler podczas obracania ekranu.
Układ desktopowy z drzewem obok pełnego widoku katalogów: start aplikacji pokazuje kafelki folderów, przycisk `Projects`
wraca do katalogów, kliknięcie folderu otwiera siatkę podglądów dokumentów,
a wybór dokumentu uruchamia edytor. Powrót z edytora wymusza flush
niezapisanych zmian przed ponownym wczytaniem miniatur. Lista folderów
i plików wykorzystuje ustawioną czułość dotyku. Folder i aktywny dokument
mają miękkie, zaokrąglone zaznaczenie; sidebar używa kompaktowej typografii
Georgia, foldery 16 px, notatki/boardy 14 px, oraz jasnej neutralnej
powierzchni panelu. Panel można zwijać i zmieniać
jego szerokość. Nagłówek `Projects` ma 56 px, tak jak górne paski
katalogu, notebooka i boarda; jeden separator w nadrzędnym `Stack`
biegnie przez całą szerokość na wysokości 56 px także po zwinięciu panelu.
Lokalny panel rezerwuje pod separatorem 1 px bez rysowania drugiej linii.
Nagłówek Projects jest klikalny, ale nie ma podświetlenia przy hover,
naciśnięciu ani podczas wyświetlania katalogu głównego.

Dolny slot konta korzysta z tego samego panelu w szerokim sidebarze i w
mobilnym drawerze; udostępnia ręczny wybór polityki synchronizacji na
wszystkich platformach. Po załadowaniu pustego profilu ekran pokazuje niedający się
trwale pominąć onboarding konta/lokalnej nazwy.

Panel dzieli wysokość na rozwijane drzewko folderów,
bezramkową sekcję `StudyTimerCard` i aktywny dolny pasek konta o wysokości
56 px (identycznej jak Projects). Timer zajmuje tylko wysokość treści,
maksymalnie 45% obszaru między nagłówkiem a paskiem konta;
separatory folderów/timera i paska konta używają `AppHeaderDivider`,
na desktopie sięgają przez 12 px uchwytu do prawej krawędzi sidebaru.
Pionowy separator uchwytu korzysta z tego samego koloru motywu.
Panel timera ma poziomy przycisk `study-panel-toggle` (44 × 24 px)
po lewej stronie separatora (margines 8 px). Chevron jest skierowany
w dół przy rozwiniętym panelu (przycisk wyżej), a w górę po zwinięciu.
Przycisk zachowuje zaokrągloną górę i ostry dół
stykającym się z poziomym separatorem. Współdzieli kolor i obrys
z przyciskiem folderów. Zamiast mocniejszego, pojedynczego BoxShadow używa standardowego
profilu kElevationToShadow[8]. Każda warstwa zachowuje rozmycie
i spread; jej alfa wynosi 30% poprzedniej wartości, a przesunięcie
pionowe zmienia się na poziome (w prawo).
Material ma elevation 0, więc nie powstaje drugi cień. Zakładka
znajduje się wewnątrz `Stack` listy folderów, dzięki czemu całe
24 px wysokości jest klikalne, także po zwinięciu timera. Zwinięcie
zwraca miejsce liście bez pustego paska i podwójnego separatora.
Przy ponownym rozwinięciu timer zachowuje osobny scroll.
Bez lokalnego Fluttera: sprawdź ręcznie górne 4 px przycisku, ostre dolne
rogi, kontakt z separatorem oraz przełączanie w obu motywach.
Upcoming ma osobne przewijanie i limit 25% obszaru roboczego sidebaru,
niższy niż połowa dostępnego miejsca na foldery. Cały timer nadal
nie przekracza 45% tego obszaru. Przy małym oknie timer przewija się
niezależnie, a drzewko folderów wykorzystuje pozostałą wysokość. Działa również w mobilnym drawerze.
Po zwinięciu panelu
`CompactStudyTimer` wyświetla się obok Settings w AppBar katalogu,
notebooka lub boarda. `_openCatalogSettings` otwiera wspólne ustawienia
na kontrolerze wybranego albo pierwszego dokumentu; w pustej bibliotece
udostępnia ustawienia globalne bez tworzenia dokumentu. Przewijanie timera
również reaguje na wspólną czułość dotyku.
Pod strzałką panelu folderów jest drugi przycisk zwijania wspólnego paska
narzędzi; oba są pionowo wyśrodkowane we własnych obszarach, mają 24 px
szerokości, 44 px wysokości, cień i obrys. Stan toolbaru pozostaje zachowany
przy przełączaniu dokumentów. Aktualny tytuł notebooka lub boarda jest
przekazywany do nagłówka bez odtwarzania kontrolera edytora po zmianie nazwy.

W drzewku folderów przytrzymanie notebooka, boarda albo folderu uruchamia
drag & drop na wiersz innego folderu (również zwiniętego). Folder źródłowy
zwija się przy rozpoczęciu gestu, a po przeniesieniu pozostaje zwinięty pod
nowym rodzicem razem z całym poddrzewem. Podczas przeciągania cały wiersz
zachowuje oryginalną szerokość, nazwę i menu, ma mocniejsze
podświetlenie i przesuwa się tylko w pionie; w miejscu źródłowym nie
wyświetla się jego kopia. Folder docelowy przyjmuje element z podświetleniem
i rozwija się po upuszczeniu. Przed ruchem kończone są oczekujące
zapisy edytora; zmiana folderu aktywnego dokumentu odtwarza
kontroler edytora z aktualnymi metadanymi, zamiast zostawiać stary folder.

Wiersze drzewa folderów, notatników, tablic i planerów nie mają
piktogramów typów. Pozostają strzałki rozwijania folderów i menu
trzech kropek. Foldery zaczynają nazwę 8 px za 30-pikselową
strzałką, dokumenty mają wcięcie 48 px; podfoldery zachowują
rekurencyjne wcięcie 16 px.

Menu trzech kropek folderów, notebooków i boardów (130 px) oraz menu
dodawania przez `+` (150 px) używają wspólnej pozycji przy prawej krawędzi
całego sidebaru (włącznie z 12 px uchwytem resize), jego koloru i animacji
180 ms. Kolor menu i łącznika maskującego cień pobierany jest bezpośrednio z
`surfaceContainerLowest`, czyli dokładnie z tego samego źródła co panel
folderów. Lewe narożniki mają jawny
promień zero, a wyłącznie prawe promień 12 px. Menu styka się z panelem
bez szczeliny: obie strony
styku są bez cienia i bez 1 px kreski uchwytu resize. Menu ma elevation 0,
a osobny dekoracyjny cień o alpha 0x44 jest przycięty do prawej strony
i do obszaru poza obrysem menu, przez ścieżkę even-odd zgodną z Canvas
(bez nieobsługiwanego parametru clipOp);
na czas otwarcia dowolnego menu cienie obu strzałek sidebaru są wyłączone
i przywracane natychmiast po zamknięciu;
2 px łącznik koloru panelu maskuje linię graniczną. Menu folderu zawiera także
edycję okładki; etykiety mają rozmiar 14 px, a opcje dodawania nie mają ikon.

- Menu dodawania oferuje New main folder, New folder (w aktywnym folderze),
  Notebook, Board i Planner. Sidebar wyświetla podfoldery rekurencyjnie
  z wcięciem; rozwijanie i upuszczanie dokumentów działa na każdym poziomie.
  Katalog cofa do rodzica, nie od razu do Projects.
  Planner otwiera `TaskListScreen` zamiast kontrolera edytora.
  Ustawienia katalogu i planera nie tworzą `EditorController` dla
  `NotebookKind.planner`, aby nie zgłaszać `UnsupportedError`.
- 35: `LibraryScreen`; 44: `_LibraryScreenState`;
  437: `_maybeShowAccountOnboarding`;
  586: `_keepCatalogOnMovedFolder`; 688: `_openCatalogSettings`;
  1052: `_CreateMenuButton`;
  1097: `_LibraryTreePane` (`_LibraryTreePaneState` 1124);
  1339: `_buildFolder`; 1526: `_FolderTreeRow`;
  1629: `_LibraryTreeItemRow` (bez ikon typów);
  1730: `_sidebarMenuShape`;
  1744: `_SidebarMenuShadowPainter`;
  1780: `_showSidebarMenu`;
  1893: `_TreeRowActions`;
  1973: `_LibraryWorkspace`;
  2111: `_LeftZoneToggleTab` (również przycisk timera).

### `lib/features/library/presentation/library_account_slot.dart` (1104 linie)

Onboarding `Create account`/`Sign in`/`Try local` z jednym
nagłówkiem NaNotateczki i tekstem Welcome poniżej, bez podwójnego tytułu,
podglądem haseł i spójnymi odstępami
12 px między przyciskami konta, formularzy i akcji synchronizacji.
Nazwa użytkownika w pasku konta używa kompaktowego 14 px i wagi 400,
tak jak nazwy dokumentów w drzewku. Nagłówki dialogów i profilu
pozostają w stylu `AppHeaderDivider.titleStyle` (18 px, waga 600);
opisy statusu, trybu konta i polityk synchronizacji to 12 px w kolorze
`onSurfaceVariant`. Nagłówek sekcji synchronizacji to 16 px, waga 600.
Globalny motyw dostarcza Georgia (lub systemowy zamiennik).
Dolny pasek pokazuje nazwę konta i status w dwóch wyrównanych do timera
wierszach, bez awatara, bez dodatkowej karty i z marginesem 14 px.
Status jest pokazywany również w trybie lokalnym i przed logowaniem.
Inicjał z okrągłą obramówką pozostaje w dialogu ustawień konta;
ikona ustawień ma 18 px
przy zachowanym rozmiarze obszaru kliknięcia. Rejestracja i zmiana hasła
wymagają zgodnego powtórzenia. Formularze logowania, rejestracji, lokalnej
nazwy i zmiany hasła współdzielą `AppLabeledField` i używają etykiet nad polami (14 px, bold, odstęp 6 px),
obrysu 12 px i nieruchomych podpisów jak edytor wydarzeń w kalendarzu;
brak pływających etykiet oraz wypełnionego tła pola;
ustawienia pozwalają wymusić backup, zmienić hasło i przełączać tryb. Po
loginie `AppScope` automatycznie inicjuje odzyskiwanie i bezpieczny sync,
a po zmianie hasła zatrzymuje usługi przed wyczyszczeniem sesji.
  Automatyczne inicjowanie synchronizacji należy do `AppScope`, także na
  platformach natywnych; ręczne polityki pozostają awaryjnym wyborem.

- 19: `showLibraryAccountDialog`; 48: `LibraryAccountSlot`;
  153: `_AccountAvatar`; 185: `_AccountDialog`;
  198: `_AccountDialogState`; 695: `_usernameField`;
  716: `_accountLabeledField`; 908: `_backupNow`;
  945: `_changePassword`.

### `lib/features/library/presentation/library_catalog.dart` (1288 linii)

Katalog Projects pokazuje wyłącznie foldery główne. Po wejściu do folderu
widok rozdziela bezpośrednie podfoldery i dokumenty na dwie wyśrodkowane
siatki; tytuły folderów pokazują tylko lokalną nazwę, a Back wraca do rodzica.
Katalog główny układa foldery w responsywną siatkę od 1 do 5
kolumn, z górnym marginesem 24 px. Cały blok folderów jest wyśrodkowany
w poziomie, a ostatni niepełny wiersz zaczyna się od lewej. Brak linii
oddzielających kafelki i zewnętrznej ramki; blok nie zajmuje całej
szerokości ekranu. Podfoldery używają tej samej siatki 1–5 kolumn i rzędów 292 px co Projects
(szerokość pola 246 px, odstęp 36 px), bez wpływu liczby dokumentów.
Dokumenty są w oddzielnej, wyśrodkowanej siatce o rzędach 372 px.
Każdy dokument ma podgląd o tej samej szerokości i tej samej
górnej krawędzi; notebooki są wyższe (0,72), boardy kwadratowe (1,0).
Rzędy dokumentów mają 372 px wysokości. Menu i nazwa są wyrównane
do wspólnej lewej krawędzi podglądów i nie wychodzą poza ich szerokość.
AppBar pokazuje nazwę biblioteki/folderu, Settings i opcjonalny
przycisk nawigacji w trybie kompaktowym oraz
`CompactStudyTimer`; edycja okładki
pozostaje w menu folderu, bez ikony palety w nagłówku otwartego folderu.
Okładki folderów mają ponownie delikatne, wektorowe ikony Lucide
(`FolderCoverIcon`, `FolderCoverStrokePainter`), z konturem 1,25 px
i wygładzonymi krawędziami. Zachowują kwadratowe proporcje także jako
podfoldery, w identycznych rzędach jak foldery główne. Dekoracje na
okładce (serce, gwiazdka,
kwiat, błysk) można ponownie wybierać z poziomu edytora folderu.
Kafelki mają promień 12 px i neutralne tło; zapisany kolor modyfikuje
kolor ikon, nie powoduje automatycznego podświetlania całej okładki.
Hover i press są nakładkami na `Ink` przyciętymi przez `Material`.
Dialog edycji okładki otwiera się natychmiast; próbki Recent pochodzą
od razu z kontrolera folderów, a `FutureBuilder` doładowuje dodatkowe
kolory ze wspólnej historii bez duplikatów i bez blokowania okna.
Dialog kolorów okładki zachowuje wybór dekoracji, ale nie pokazuje
bazowych próbek Cover color. Recent współdzieli zapis kolorów z canvasem
(również po ponownym uruchomieniu), a trzy zestawy Blue/Pink/Green
wyświetlają osobne okrągłe próbki. Pojedyncze kolory z zestawów
mogą być wybierane bez zmiany ustawień pisaka. Wspólny selektor
`EditorToolbar.pickColor` udostępnia te same kolory, Recent, HEX i RGB/B-W;
pokazuje kolory po transformacji aktywnego motywu. Dialog otwiera się
bez czekania na dysk, a wspólna historia Recent doładowuje się asynchronicznie.
`_CatalogTile` umieszcza menu trzech kropek w jawnym rozmiarze
32×32 px (bez przycinania ikony) po lewej od nazwy;
oba elementy są wyrównane do lewej krawędzi okładki/podglądu i mieszczą
się w jego szerokości. Podpis przylega bliżej miniatury (odstęp 2 px),
a długie nazwy są obcinane wielokropkiem.
Kafelki planerów pokazują własny podgląd zadań i checkboxów.
  Notatki mają pionowy podgląd pierwszej strony (820×1160), boardy kwadratowy
podgląd dopasowany do granic obiektów z pierwszej strony. Miniatury rysują
ink, tekst oraz dostępne obrazy bez uruchamiania edytora.
Wspólny `_catalogPreviewRadius` (12 px) określa narożniki cienia,
przycinającego `Material`, papieru i `ClipRRect`. Zewnętrzny
`DecoratedBox` rysuje miękki cień przed klipowaniem, więc cień pozostaje
widoczny również przy zaokrąglonych rogach folderów i dokumentów.
Oba motywy wykorzystują tę samą geometrię i parametry cienia.
Katalog i okładki respektują motyw; miniatury odwracają kolory ink/tekstu
tylko przy renderowaniu, bez zmiany danych. Zmiana motywu wymusza repaint.
Siatka reaguje na wspólną czułość dotyku.

- 27: `dominantFolderColor`; 55: `FolderCoverIcon`;
  109: `FolderCoverStrokePainter`; 235: `LibraryCatalog`;
  565: `_FolderTile`; 632: `_DocumentTile`;
  757: `_CatalogTile`; 881: `_DocumentPreview`;
  964: `_boardPreviewBounds`;
  1006: `_PagePreviewPainter`;
  1078: `showFolderCoverEditor`.

- `lib/core/widgets/workspace_document_app_bar.dart`: wspólny pasek
  tytułu notatnika, boarda i planera (56 px), z marginesem chroniącym
  przed lewymi strzałkami, mobilną nawigacją i akcją Settings.
  6: `WorkspaceDocumentAppBar`.

### `lib/features/library/presentation/widgets/library_item_card.dart` (132 linie)

Karta notebooka/boarda/planera z menu zmiany nazwy i usuwania.

- 8: `LibraryItemCard`; 110: `_ItemKindIcon`.

## 6a. Planer nauki i listy zadań (bez migracji SQLite)

- `lib/features/planner/state/planner_task.dart`: `PlannerTask`,
  `PlannerTaskTone`, deadline z opcjonalną godziną; serializacja.
- `lib/features/planner/presentation/task_list_screen.dart`:
  canvas listy zadań z promieniem 12 px, checkbox, edycja nazw, wybór daty/godziny,
  usuwanie oraz pełnoszerokie separatory. Kolory statusów są wyłącznie
  beżowymi/neutralnymi odcieniami `AppColors` dla aktualnego motywu:
  bez deadline'u ("Recent"), upcoming i overdue; zaległe mają
  najjaśniejsze tło papieru, nadchodzące pośredni odcień, a
  "Recent" dokładny kolor paska folderów z `surfaceContainerLowest`.
  Ukończone (także wcześniej zaległe) mają tło Recent z `Opacity(0.6)`
  dla całego wiersza (tekstu, ikon, checkboxa i tła), i są na dole.
  Przycisk Add task używa jaśniejszego beżu AppColors.toolbar.
  Planer współdzieli nagłówek z edytorami i ma globalne ustawienia.
  Tekst zadania zawija się automatycznie, zwiększając wysokość tylko
  własnego wiersza, z checkboxem i akcjami wyrównanymi do góry.
  Na szerokich ekranach pole tekstowe kończy się 12 px przed blokiem
  faktycznie widocznych kontrolek; margines po prawej jest taki sam.
  W wąskich oknach przyciski deadline'u pozostają poniżej tytułu,
  wyrównane do prawej, a usuwanie pozostaje w górnym wierszu.


- `lib/features/planner/state/study_planner_controller.dart` (789):
  `StudySession`, `StudyEntryKind` (session/event),
  `StudyRepeat` (daily, weekly, monthly, yearly), `StudyTechnique`,
  `StudyStatus`, `StudyPlannerController`. Wydarzenia mają zakres dni,
  całodniowość i powtarzanie z odstępem 1–365 jednostek.
  `calendarEntries` generuje widoczne wystąpienia bez dublowania zapisów,
  a `originalFor` pozwala edytować całą serię. Wydarzenia nie trafiają
  do listy `upcoming`, która obejmuje tylko sesje.
  Jeden stan Provider + ChangeNotifier, trwały `study_planner.json` przez
  cross-platform `text_storage`. Timery liczone względem deadline,
  odtwarzanie po restarcie, Pomodoro 25/5, Focus 50/10, Deep 90/20,
  jednorazowa ocena 1–5 gwiazdek i zapis chroniony przez
  `AppSaveCoordinator`. Pominięta ocena zamyka sesję i zapisuje ją
  bez oceny w historii (także po ponownym uruchomieniu); starsze sesje
  pozostawione w stanie review są przenoszone do historii bez ponagleń.
  Sesje zapisują 1–12 bloków Smart i opcjonalny kolor karty.
  Starsze zapisy otrzymują domyślne wartości techniki oraz brak koloru.
  Czas i przejścia timerów używają liczby wybranych bloków.
  Czas zajmowany w kalendarzu zawiera także przerwy pomiędzy blokami,
  bez przerwy po ostatnim bloku;
  zakończenie sesji otwiera ocenę bez dolnego SnackBara.
  Wynik wczytywania po dispose jest ignorowany: bez powiadomienia, timera
  ani zapisu odzyskanej historii.
  10: `StudyTechnique`; 45: `StudyRepeat`; 51: `StudySession`;
  219: `StudyPlannerController`; 282: `calendarEntries`;
  432: `load`; 498: `create`; 537: `edit`; 779: `flush`.
- `lib/features/planner/presentation/study_timer_widgets.dart` (1006):
  `StudyTimerCard`, `CompactStudyTimer`, dialog edycji i gwiazdkowej oceny
  sesji, funkcja `studyRatingStars`; zamknięcie dialogu traktowane jako
  pominięcie oceny, bez przycisku „Rate” w bocznym timerze.
  Nagłówek bocznego timera nie ma ikony zegara, a napis `Study timer`
  używa typografii nagłówka `Projects`. Ikona kalendarza pozostaje.
  Przyciski `Start session` i `Smart` w panelu bocznym wypełniają
  po połowie dostępnej szerokości z odstępem 8 px
  i promieniem 12 px; przyciski mają 32 px wysokości,
  bez zmiany rozmiaru tekstu.
  ikony Play i Smart z podpisami są centrowane jako jeden blok,
  skalowany do wąskiego panelu. Powiększony padding pionowy timera
  (20 px u góry, 0 px na dole) oraz odstęp pod Ready (30 px)
  zwiększają wysokość całego bloku mimo niższych przycisków.
  Upcoming pokazuje wyłącznie sesje nauki w osobno przewijanej liście,
  również podczas aktywnej sesji zamiast przycisków Start/Smart.
  Formularz wydarzeń pokazuje datę, czas, długość, kolor, opis,
  zakres dat, checkbox All day i regułę powtarzania; nie pokazuje
  ustawień timera ani bloków Focus. Selektor koloru otwiera się od razu,
  a wspólne Recent doładowuje w tle `EditorToolbar.pickColor`.
  Karty Upcoming w sidebarze
  mają obrys jasnobeżowy `AppColors.toolbar` zamiast koloru tekstu
  (bez zmiany obrysów w kalendarzu). Dolny padding timera to 16 px,
  gdy Upcoming jest puste, albo 0 px, gdy istnieją nadchodzące sesje.
  Nowe i edytowane sesje (także z kalendarza) mogą mieć indywidualny
  kolor z tych samych palet, Recent i edytora HEX co foldery.
  Ikona wybranego koloru w formularzu konwertuje HSL w dark mode
  bez modyfikacji zapisanego koloru.
  Formularz Smart umożliwia wybór liczby bloków 1–12.
  Ocena ma wyśrodkowany nagłówek „Great job! Time's up.”.
  Pola Name, Description, Study technique, Duration, Focus blocks i Repeat
  używają wspólnych `AppLabeledField` i `appFormFieldDecoration`, tak jak
  logowanie oraz Contact the creator. Name i Description
  mają jawnie wyłączone pływające etykiety; test sprawdza pozycję
  i wielkość nagłówków po wpisaniu treści sesji oraz wydarzenia.
  W trakcie sesji Resume/Pause oraz Stop mają tę samą wysokość 32 px,
  kontur i promień 12 px co przyciski Start/Smart.
  Selektor techniki w formularzu `isExpanded` mieści się w wąskim dialogu.
  Motyw obejmuje także kompaktowy timer, a formularz sesji korzysta
  ze wspólnej czułości przewijania.
  36: `studyRatingStars`; 43: `openStudyPlanner`;
  49: `showStudySessionEditor`; 69: `showStudyRating`;
  138: `_StudySessionDialog`; 254: `_pickColor`;
  337: `_labeledField` (stałe etykiety formularza);
  669: `StudyTimerCard`; 958: `CompactStudyTimer`.
- `lib/features/planner/presentation/study_action_theme.dart` (166):
  `StudyActionTheme`, `StudyActionStyles`; wspólne style przycisków
  timera i kalendarza (promień 12 px, padding 8/10); wspólna wyśrodkowana
  zawartość ikon i tekstu oraz promień 12 px selektora Today/Week/Month;
  wspólne tło i obrys kart planowanych sesji w kalendarzu i timerze,
  z opcjonalnym odcieniem wybranego koloru po automatycznej konwersji
  HSL w dark mode; zapisany kolor pozostaje bez zmian;
  zaznaczenie przycisków Start/Smart i Day/Week/Month oraz ich
  obrys korzystają z globalnego koloru AppColors.divider, nie
  z ręcznie przypisanego brązu; pozostałe przyciski zachowują tło
  z globalnej palety. Tryb ciemny używa globalnej palety,
  kontrolki zachowują typografię aplikacji. `primary(ThemeData)` zależy
  od bieżącego motywu. 6: `StudyActionStyles`;
  101: `StudyActionTheme`.
- `lib/features/planner/presentation/planner_screen.dart` (1793):
  `PlannerScreen` – kalendarz Day/Week/Month, przeciąganie i edycja.
  Wydarzenia są wspólnymi wpisami kalendarza bez możliwości uruchomienia
  timera, ze wspólnym opisem, kolorem, czasem, edycją i przenoszeniem.
  Kalendarz rozwija wydarzenia cykliczne oraz wielodniowe,
  a każde `+` rozpoczyna od wyboru Event / Study session.
  Edycja lub usunięcie wystąpienia cyklicznego dotyczy całej serii.
  Day domyślnie otwiera aktualny dzień, a kliknięcie pola Week/Month
  przechodzi do wybranej daty. Wszystkie przyciski + otwierają wybór typu.
  Sesje zakończone są na ciemniejszych kartach, zaplanowane na jasnych,
  z `ColorScheme`, promieniem 12 px i obramowaniem w kolorze tekstu.
  Wybrany kolor sesji jest nakładką nad tłem karty w Week/Today/Month.
  W Week i Month bieżący dzień ma wyraźnie jaśniejsze tło z palety:
  AppColors.paper w jasnym i AppColors.darkPaper w ciemnym motywie.
  Day zachowuje normalne tło. Day i Week mają stałą siatkę godzin
  (64 px/h) i bloki pozycjonowane według dokładnej minuty rozpoczęcia
  i całkowitego czasu sesji (w Smart również z przerwami), z podziałem
  na dwa dni przy przekroczeniu północy. Week ma wspólną oś godzin
  po lewej; wąskie ekrany przewijają siatkę poziomo.
  Week i Month mają marginesy boczne 18 px i wspólny pasek nagłówka
  z zaokrąglonymi tylko górnymi rogami (12 px) i ostrymi dolnymi.
  Pasek styka się bez odstępu z siatką; godziny Today/Week zaczynają
  się górną krawędzią tekstu przy odpowiedniej linii godzinowej.
  Month ma wspólne tło z pionowymi i poziomymi separatorami 1 px,
  bez osobnych ramek i odstępów między dniami; pola z sąsiednich miesięcy
  mają jaśniejsze tło z palety motywu, nie tylko przygaszony tekst.
  Week rysuje ciągłe pionowe separatory i pełnowysokie tła kolumn
  na warstwie siatki, niezależnie od scrollowania wierszy godzin.
  Linie poziome kończą się na lewej granicy tabeli, bez przedłużeń
  do etykiet godzin. Segmenty nagłówka wypełniają jego wysokość.
  Today, Week i Month nie pokazują pasków przewijania, ale zachowują
  gesty dotykowe i przewijanie myszy. Czas aktualizuje się co minutę.
  Daty i opisy mają czteropoziomową typografię interfejsu.
  Month po wejściu, zmianie miesiąca lub rozmiaru widoku ustawia
  pionowy scroll tak, by bieżący dzień (lub dzień kotwicy dla obcego
  miesiąca) był w kadrze, także w mobilnej liście. Ręczny scroll
  pozostaje nienaruszony przy zwykłym odświeżeniu.
  Miesiąc generuje tylko niezbędne 4–6 tygodni; komórki dni granicznych
  innych miesięcy pozostają widoczne z opacity 0.5; pomocniczy napis
  Long-press usunięty. Osobne przyciski
  Settings i Study history usunięto – historia pozostaje w kalendarzu,
  a globalne ustawienia w katalogu. Smart session, Add i New event usunięto z nagłówka
  i widoku wąskiego; dodawanie działa przez plus w kalendarzu, a Smart
  i Start session przez boczny timer. Tytuł nagłówka to Calendar.
  Pasek nawigacji pokazuje wyłącznie bieżącą datę lub zakres Week/Month,
  bez osobnego przycisku Today, w układzie wąskim i szerokim;
  strzałki do przechodzenia między okresami pozostają.
  Stały margines 24 px pod kalendarzem uwzględnia systemowy SafeArea.
  Nagłówek ma 56 px i linię 1 px; Month na wąskim ekranie listę.
  17: `CalendarMode`; 19: `CalendarTimeSpan`;
  26: `calendarTimeSpan`; 52: `CalendarSessionPlacement`;
  67: `calendarSessionPlacements`; 164: `monthCalendarFocusOffset`;
  190: `PlannerScreen`; 197: `_PlannerScreenState`;
  1203: `_HourlyDaySchedule`; 1368: `_CalendarHeaderStrip`;
  1409: `_CalendarBorderFrame`; 1432: `_WeekTimeGrid`;
  1727: `_WeekTableClipper`; 1748: `_WeekColumnLinesPainter`.
  `_WeekTimeGrid`: pełnowysokie separatory i wspólna ramka na
  wierzchu siatki; clip uwzględnia lewą granicę tabeli obok osi godzin.
  `calendarSessionPlacements` przydziela niekolidujące kolumny blokom
  Day/Week według widocznych przedziałów czasowych, także przy sesjach
  przez północ; grupy bez konfliktu zachowują pełną szerokość.
  Week i Month rysują ciągły obrys z zaokrąglonymi narożnikami
  nad zawartością komórek (zamiast odcinanych odcinków ramki).
  `_WeekColumnLinesPainter`: kolory dni i pionowe separatory.
  Nowa kontrola ręczna: przewiń Week pionowo i sprawdź pełną wysokość
  wypełnienia bieżącego dnia oraz separatorów od górnej do dolnej granicy
  obszaru. Linie godzin nie powinny wychodzić poza tabelę. Przytrzymaj
  i przesuń widok palcem, sprawdź też jasny i ciemny motyw. Testy
  w `study_planner_widget_test.dart` sprawdzają aktualny układ bez
  łączników wychodzących z tabeli godzin.
  Ręczny scenariusz przy braku Fluttera: 15:45/30 min powinno
  zajmować końcową ćwiartkę godziny 15 i pierwszą ćwiartkę godziny 16
  w Day i Week; Smart 3 × 25 min z przerwami 5 min zajmuje 85 min;
  kliknięcie w tydzień/miesiąc wybiera dzień, a zakładka Day
  przywraca dzisiaj. Sprawdź zaokrąglone dolne rogi, kolor przycisków
  i wyśrodkowany komunikat zakończenia sesji.
- `test/dark_mode_theme_test.dart`: czteropoziomowa typografia obu motywów,
  wspólna lista zamienników Georgii i standardowe promienie 12 px kontrolek.
- `test/ink_color_presets_test.dart`: odcienie trzech palet, wspólny
  wybór koloru dla pióra i zakreślacza,
  transformacja HSL w dark mode, malejący kontrast odcieni 1–3
  z jasną kartką, zgodność HEX z paletami oraz zachowanie migracji,
  domyślny Blue i marker z trzeciej próbki.
  Ręcznie przy braku Fluttera: wybierz trzy próbki Blue i Green,
  zmień motyw jasny/ciemny, uruchom aplikację ponownie i sprawdź
  zachowanie koloru 3 oraz zgodność HEX w trybie jasnym.
- `test/study_planner_controller_test.dart`: zapis bloków i kolorów,
  zgodność starszych sesji, reset koloru, resume, pauza, konflikt
  timerów, Pomodoro, ocena, pominięcie oceny, recovery dawnych review
  i ochrona uszkodzonych danych; sukces/błąd wczytywania po dispose.
- `test/study_planner_widget_test.dart`: konwersja kolorów kart kalendarza
  i próbek formularza w obu motywach, szerokości 50/50, odstępy
  i zaokrąglenia przycisków timera przy panelach 240/320 px;
  środkowanie ikon i etykiet, wspólną wysokość 32 px planera i timera
  i większy padding timera,
  ciemniejsze ukończone sesje
  z obrysem w kolorze tekstu w obu motywach, liczbę bloków Smart,
  kolory New/Edit w kalendarzu, ukrycie Start/Smart podczas sesji i
  nagłówek oceny; przyciski kalendarza o
  tej samej wysokości i zaokrągleniu selektora, zgodność kart Upcoming
  z kalendarzem w obu motywach, brak separatorów i działanie Start,
  dni granicznych miesiąca, łagodne zaznaczenie Week/Month,
  brak zaznaczenia Today i większy odstęp od sesji, wspólną oś godzin Week,
  linię aktualnego czasu, boczne marginesy Week/Month, jednolite
  nagłówki styczne z siatką, ostre dolne rogi, zaokrąglone dolne
  narożniki siatki, minutowe pozycjonowanie bloków (z czasem przerw),
  kliknięcie Week/Month do wybranego Day i reset Day do dzisiejszej
  daty, wyśrodkowanie etykiet i pełnowysokie linie Week oraz
  brak łączników linii godzin poza tabelą, brak scrollbarów bez blokowania
  gestów,
  jaśniejsze tła dni spoza miesiąca w obu motywach,
  osobny scroll Upcoming, limit wysokości listy,
  brak górnych przycisków w obu rozmiarach, dodawanie przez plus,
  brak stałego Today w nawigacji oraz aktualizację nagłówka okresu
  po przejściu między datami (desktop i telefon),
  stałe nagłówki Name i Description podczas pisania,
  checkbox All day oraz warunkowe dolne odstępy timera,
  stałe etykiety formularzy Name/Description, spójne przyciski
  włączonego timera, aktualną paletę zaznaczeń,
  skalowanie Smart i przecinających granicę godziny/doby sesji,
  brak placeholdera nazwy i wyśrodkowanie oceny,
  brak overflow selektora techniki,
  margines dolny i oceny kalendarza.
- `test/planner_editor_isolation_test.dart`: planner nie ma klucza preferencji
  tła, notebook i board zachowują dotychczasowe klucze.
- `test/planner_calendar_layout_test.dart`: regresje grupowania i
  pozycjonowania równoległych sesji Day/Week (w tym sesji przechodzących
  przez północ), obrysu ramek Week/Month oraz początkowej widoczności
  bieżącego dnia miesiąca na desktopie i telefonie.
- `test/study_planner_calendar_weekday_test.dart`: komplet nazw dni
  tygodnia we wszystkich widokach i po zmianie daty; 4/5/6 tygodni
  miesiąca z zachowaniem dni przejściowych; osobny krok CI.
- `test/study_planner_button_contrast_test.dart`: regresja widoczności
  aktywnych przycisków i wyraźnych stanów wybranego widoku kalendarza;
  typografia kontrolek w obu motywach.

## 7. Stan edytora

### `lib/features/editor/state/editor_actions.dart` (532 linie)

Akcje undo/redo dla pojedynczej strony oraz atomowa akcja przeniesienia
obrazu między stronami (`MoveImageBetweenPagesAction`, operacje na liście
stron) z zachowaniem identyfikatora i pierwotnego miejsca przy undo.
Kasowanie gumką używa `DeleteInkStrokesAction`, która przechowuje tylko
usunięte stroke'y i ich pierwotne indeksy zamiast pełnej kopii strony.

- 8: `EditorAction`.
- 13: dodawanie tekstu/obrazu/ink;
  88: destrukcyjne usuwanie ink.
- 88–242: update/delete/move tekstu i obrazu.
- 264: `MoveImageBetweenPagesAction`;
  393: `MoveSelectionAction`; 449: `DeleteSelectionAction`;
  485: `PasteSelectionAction`; 521: `OffsetPosition`.

### `lib/features/editor/state/input_mode.dart` (30 linii)

Tryb zezwalający lub zabraniający rozpoczynania kreski palcem.

- 1: `PointerInputMode`; 3: `PointerInputModeX`;
  25: `pointerInputModeFromIndex`.

### `lib/features/editor/state/page_background.dart` (69 linii)

Model tła Plain/Grid/Lines i jego serializacja.

- 3: `PageBackgroundStyle`; 5: `PageBackgroundStyleX`;
  15: `PageBackgroundSettings`; 64: `backgroundPrefsKeyForKind`.

### `lib/features/editor/state/editor_controller.dart` (3207 linii)

Centralny `ChangeNotifier`: strony, narzędzia, undo/redo, zaznaczenie, media,
preferencje, viewport i zapis. `applyConfirmedRemoteNotebook` odświeża
zatwierdzone strony w tym samym kontrolerze, zachowując lokalny zoom, pan
i aktualną stronę; w trakcie gestu lub dirty save odmawia nadpisania.
W aktywnej wspólnej sesji zapis skończonego gestu nie czeka dodatkowych
2 sekund cooldown rysika. Dostaje już znormalizowany ink z repozytorium;
`addInkStroke` odrzuca próbę zapisania narzędzia gumki jako stroke'a.
Rejestruje się w `AppSaveCoordinator`;
`flushPendingSaves` commit'uje aktywną edycję tekstu, anuluje debounce,
czeka na istniejące zapisy repozytorium i wymusza zapis dirty stron przed
zgodą na zamknięcie aplikacji. Nowo wstawiony lub wklejony tekst i obraz
przechodzą od razu do trybu `edit` i pozostają aktywne do transformacji;
wklejone zaznaczenie zachowuje lasso w trybie `edit`. Obrazy pozostają pod
tuszem i tekstem; aktywny obraz można wskazać i transformować wyłącznie w
narzędziu Move (`edit`), a wybór każdego innego narzędzia kończy zaznaczenie.
`isCanvasNavigationLocked` blokuje zmianę viewportu przez cały czas aktywnego
zaznaczenia obrazu/PDF w Move oraz podczas move/resize ramki.
Podczas usuwania aktywnego HUD-u lub overlayu figury flaga zwalniana jest
synchronicznie, a powiadomienie słuchaczy jest odkładane do post-frame,
jeśli trwa faza budowania/finalizacji drzewa. Callback sprawdza dispose.
`imageTransformPreview` jest osobnym `ValueNotifier<ImageBlock?>` dla
gestów uchwytów obrazów/PDF: aktualizuje wyłącznie ich renderer, bez
`notifyListeners()` całego edytora i bez mutowania `pages` aż do commita.
Ruch korpusu jednym palcem działa niezależnie od preferencji pisania palcem;
dwa kontakty wyłączają ten drag i nie transformują obiektu ani canvasa.
Trzy szybkie kolory domyślnie używają niebieskiego zestawu; wszystkie
próbki wybierają ten sam kolor dla pióra i zakreślacza, bez przypisania
odcienia do narzędzia. Wybór palety wybiera pierwszy kolor. Wcześniejsze
fabryczne Blue/Pink/Green (w tym poprzedni Blue/Green)
są migrowane według indeksu; własne odcienie pozostają
nienaruszone. Zapis preferencji tła obejmuje tylko notebook i board, bo
planner nie ma ustawień tła. `backgroundSettingsListenable` aktualizuje
tło bez powiadamiania całego edytora; odczyt i domyślne wzory
synchronizują ten notifier. Obrazy trafiają do prywatnego katalogu danych
aplikacji. Rozpoznane po przytrzymaniu kształty nie włączają Move.

- 37: `LassoSelection`; 76: `EditorController`;
  220: `flushPendingSaves`; 1015: `setCurrentBackgroundSettings`;
  1029: `applyInkColorPreset`.
- 292–364: layout i transformacje viewportu; 305: start blokady transformacji,
  330: `setViewTransform`.
- 373–509: operacje `*OnPage` używane przez canvasy/overlaye.
- 502–919: narzędzia, aktywne elementy, lasso i preferencje; 591: `setTool`;
  904: `setImageTransformPreview`; 911: `clearImageTransformPreview`;
  kształt po narysowaniu lub rozpoznaniu przechodzi na tymczasowe
  `edit` (`startShapeEdit`), a tap poza figurą przywraca poprzednie
  narzędzie (`finishShapeEdit`). Podgląd i commit transformacji ink
  korzystają z `UpdateInkStrokeAction` i rewizji strony, zachowując ID
  oraz pojedyncze undo/redo.
  682: `commitActiveTextEdit` — zamyka edycję treści przed transformacją ramki.
- 1407: łączenie zapisanych domyślnych teł; 1490: `undo`; 1516: `redo`;
  1591: `toggleBookmark`; 1667: `updateActiveTextStyle` — blokowe
  formatowanie aktywnego tekstu, opcjonalnie po zachowanym ID,
  zapisywane jako `UpdateTextAction`.
- 2725: `_imagesDir`; 2883: `_applyAction`; 2914: `_applyInkAction`;
  3079: `_scheduleSave`; 3101: `_saveDirtyPages`; 3139: `_save`.

- `lib/features/editor/state/ink_color_presets.dart`:
  `InkColorPreset` pobiera globalne zestawy Blue/Pink/Green z `AppColors`
  w kolejności ciemny, średni, jasny; obydwa narzędzia korzystają z jednej
  aktywnej próbki.
  `SharedRecentColors` udostępnia wspólną, serializowaną historię do 12
  kolorów pisaka, tekstu i okładek, z migracją `editor_prefs.json`.
  `resetPendingForTests` izoluje oczekujące operacje między testami FakeAsync.
  Tryb ciemny zachowuje zapisane bazowe wartości kolorów.

## 8. UI edytora

### `lib/features/editor/presentation/editor_screen.dart` (2445 linii)

Wielostronicowy edytor notebooka: nagłówek notesu ma 18 px i korzysta z
aktualnego tytułu przekazanego przez bibliotekę (fallback: kontroler);
toolbar i pasek tekstowy są nakładkami `Stack` nad pełnowymiarowym
canvasem, zamiast zajmować jego wysokość. `showToolbar` steruje
widocznością nakładek. Początkowe 72 px odsunięcia strony realizuje
`_pagePan` wewnątrz viewportu, zamiast dodatkowego paddingu przewijania.
`showCompactTimer` pokazuje `CompactStudyTimer` w nagłówku przy zwiniętym
panelu biblioteki.
W trybie kompaktowej nawigacji (telefon/tablet) edytor nie wyświetla minimapy,
stosuje 12 px marginesów bocznych i dopasowuje stronę do wolnego miejsca
bez zmiany logicznych współrzędnych dokumentu.
Viewport pozostaje 22 px od górnej krawędzi canvasa, więc strona nie jest
ucinana przez pusty pas, gdy użytkownik wsuwa ją pod toolbar.
Rozszerzony zakres pionowego pan pozwala również przesuwać stronę niżej.
Dolny limit przesuwania uwzględnia skalowaną stopkę Add page/Delete page,
więc po zejściu na koniec notatnika pozostają widoczne przyciski i dolny
margines 22 px, również przy powiększeniu.
Granice widoczności i wybór aktywnej strony uwzględniają przesunięcie.
Wysokość klipu i przewijanej zawartości rośnie wraz z dodatnim `_pagePan.dy`,
aby dolna część ostatniej strony nie została ucięta. Strona jest domyślnie
centrowana poziomo wewnątrz obszaru między minimapą i prawym marginesem;
po ręcznym przesunięciu lub zoomie jej pozycja X nie jest resetowana
przy przebudowie widoku.
`AppBar` ma wyłączoną zmianę wysokości cienia i tint podczas scrollowania.
Minimapa zachowuje odstęp od widocznych pasków, a jej wysokość jest
ograniczona dostępną przestrzenią. Procentowy wskaźnik powiększenia nie jest
wyświetlany, ale gesty zoomu pozostają bez zmian.
Viewport obejmujący overview i strony notesu ma tło #E6E6E6;
nagłówek, toolbary i panel folderów używają zwykłego tła motywu. Viewport, wirtualizowane strony, canvasy, minimapa,
wspólne komendy edytora. Strona zachowuje logiczną
szerokość 820 px, a węższe okno skaluje cały dokument bez reflow tekstu.
Overview ma po 10 px wolnej przestrzeni po lewej i prawej stronie; poziomy
viewport strony zaczyna się przy x=116 i kończy 56 px przed prawą krawędzią.
Zoom i pan działają wewnątrz tego pasa, ale przez całe aktywne zaznaczenie
obrazu/PDF viewport jest zamrożony: custom pan/zoom jest ignorowany, a pionowy
`SingleChildScrollView` przechodzi na `NeverScrollableScrollPhysics`.
Powiększony dokument zachowuje rzeczywistą wysokość scrolla; ręczny pionowy
pan uwzględnia bieżący offset przewinięcia, dzięki czemu można wrócić
do pierwszej i ostatniej strony bez zmiany zoomu. Kółko/trackpad obsługuje
albo natywny scroll, albo pan canvasa, nigdy obydwa jednocześnie.
Ctrl/Cmd+scroll (pinch touchpada na desktopie) powiększa dokument,
rezerwując sygnał przed natywnym Scrollable; zwykły scroll nie zoomuje.
Gesty pan palcem oraz przewijanie stron i minimapy respektują czułość
nawigacji; zoom i gesty narzędzi pozostają bez zmian.
W Move jeden palec przesuwa zaznaczony obraz/PDF niezależnie od preferencji
pisania palcem. Dwa kontakty nie transformują obiektu ani zamrożonego
viewportu; po tapnięciu poza pełną ramką zaznaczenie znika i zwykła
nawigacja canvasa wraca.
Po zakończeniu transformacji normalna nawigacja wraca. Stronę można przesuwać
poziomo dotykiem także wtedy, gdy jest węższa od viewportu; clamp pozwala jej
dojść od lewej do prawej granicy pasa, ale nigdy wejść pod margines. Bleed
pozostaje tylko pionowo. Overview przyjmuje kliknięcia poprzez Listener
na obszarze widocznym niezależnie od gestów scrolla minimapy; przenosi
widok do wskazanego fragmentu notatnika przy aktualnym powiększeniu
z uwzględnieniem scrolla minimapy, paddingu, pan i granic przesunięć.
Gest przeciągnięcia nadal przewija samą minimapę, a blokada transformacji
obiektu ignoruje wybór. Programowy scroll nie nadpisuje aktywnej strony.

- 38: `EditorScreen`; 56: `_EditorScreenState`.
- 57: `_logicalPageWidth`; 104: `_effectivePageScale` — skala okna pomnożona
  przez zoom użytkownika.
- 162: synchronizacja strony; 193: nawigacja do klikniętego obszaru.
- 300–670: gesty pan/zoom, blokada viewportu i transformacje;
  dotyk aktywnego obrazu nie uruchamia menu kontekstowego canvasa.
- 892–912: busy overlay, komendy importu/eksportu i clipboard oraz ustawienia.
- 1043: `_buildTransformedDocumentLayer` rozkłada warstwy w logicznym
  rozmiarze 820 px przed skalowaniem, żeby viewport nie obcinał prawej
  krawędzi.
- 1069: główny `build`; pasek tekstu jest renderowany na podstawie
  aktywnego `TextBlock`, niezależnie od starego `QuillController`; wspólna
  macierz `pageTransform` skaluje dokument.
- 1623: `_PageViewportClipper`; 1681: `_PageFramePainter`;
  1756: `_ProjectMiniMapOverlay`; Listener kliknięć minimapy;
  2175: `_ProjectMiniMapPainter` renderuje wyłącznie zwykły ink.

### `lib/features/editor/presentation/editor_commands.dart` (172 linie)

Skróty dokumentu są wyłączone podczas pisania w aktywnym bloku tekstu,
aby nie przechwytywały Delete ani skrótów schowka.
Komendy importu, kopiowania i eksportu; przy starcie zadania zapisu
przekazują aktualny `Theme.brightness` do wspólnego renderera PDF/PNG.

### `lib/features/editor/presentation/editor_settings_screen.dart` (726 linii)

Ustawienia wejścia, dwuczłonowy selektor `Light` / `Dark` w Visual:
wybór używa beżowych odcieni `divider`/`toolbar` w jasnym motywie
oraz `darkActive`/`darkToolbar` w ciemnym. Zaznaczona opcja ma
mocniejszą ramkę, bez czarnego lub białego tła. Zakładka System
ma suwak czułości nawigacji 0.5×–2.0×, a Visual globalną skalę
interfejsu 75%–150% z natychmiastowym podglądem. Oba suwaki nie
wyświetlają liczb ani etykiet wartości. Pozostałe sekcje
obsługują ustawienia tła i podgląd logów diagnostycznych.
Trzecia zakładka `Contact the creator` pokazuje formularz z systemem
oraz opisem błędu. Zgłoszenie nie wymaga konta; trafia do prywatnego
pliku serwera. Zalogowane konta wysyłają logi jako nadpisywane snapshoty.
  Na telefonach selektory System/Visual są pod etykietami; `SafeArea`
  chroni dolny obszar systemowych gestów.
`EditorController` jest opcjonalny: ustawienia globalne działają z pustego
katalogu i planera; tła i ustawienia rysika wymagają otwartego dokumentu.
Nagłówek ma wysokość 56 px, tytuł 18 px jak Projects i linię 1 px pod
paskiem; linia jest w body, nie w AppBar.bottom.

- 17: `EditorSettingsScreen`; 369: `_showErrorsDialog`;
  451: `_showDataIntegrityDialog`; 538: `_showOptimizationDialog`;
  624: `_BackgroundSection`.

- `lib/features/editor/presentation/contact_creator_tab.dart`:
  formularz zgłoszenia, identyczny wygląd pól jak w logowaniu.
  Test: `test/contact_creator_tab_test.dart`.

### `lib/features/editor/presentation/interaction/notebook_overview_navigation.dart` (55 linii)

`NotebookOverviewNavigation` (5) mapuje lokalny punkt oraz scroll minimapy
na współrzędne dokumentu i wyznacza docelowy scroll/pan zachowujący zoom.
`NotebookOverviewTarget` (50) przechowuje wynik nawigacji.

### Widgety edytora

- `lib/features/editor/presentation/widgets/busy_overlay.dart` (18): blokujący
  spinner długiej operacji. 3: `BusyOverlay`.
- `lib/features/editor/presentation/widgets/page_background_paint.dart` (133):
  render tła i kratki w bieżącym trybie wizualnym, także na ciemniejszej
  kartce #50514D; `RepaintBoundary` izoluje malowanie od tuszu;
  strony i board odświeżają go osobnym notifierem.
  6: `PageBackgroundPaint`;
  41: `PageBackgroundPreview`; 71: `_PageBackgroundPainter`.
- `lib/features/editor/presentation/widgets/editor_toolbar.dart` (1096):
  główny toolbar narzędzi, kolorów, gumek, kształtów, tła i eksportu;
  całość ma promień 12 px i pośrodku obszaru zwęża się do szerokości
  ikon, gdy mieszczą się w całości; przy braku miejsca przewija się poziomo.
  Szerokość dostępna dla toolbaru jest mierzona przez `LayoutBuilder`
  podczas resize, niezależnie od opóźnień w aktualizacji `MediaQuery`.
  Zewnętrzne marginesy na szerokim ekranie wynoszą po 52 px,
  wewnętrzne po 22 px; poniżej 600 px oba wynoszą po 8 px,
  a pionowy padding 3 px; przycisk zwijania pozostaje dostępny;
  ikony pobierają kontrast z motywu, próbki szarości pokazują ich
  aktualny kolor wyświetlania, a styl pozostaje lekki i obrysowy.
  Lasso używa gotowej ikony Material `highlight_alt_outlined`, która
  przedstawia zaznaczanie obszaru kursorem.
  Publiczny `EditorToolbar.pickColor` współdzieli pełny selektor HEX/RGB/B-W
  z edycją koloru ikon okładek folderów. Wywołanie opcjonalnego callbacku
  wyboru całej palety korzysta z promocji typu po sprawdzeniu null
  (bez zbędnego operatora `!`). W dark mode próbki Recent,
  podgląd, HEX oraz suwaki pracują na odwróconym kolorze widocznym,
  a przed zapisem wracają do wartości bazowej; wybór bez zmian jest bezstratny.
  Pod Recent dostępne są trzy palety: w trybie szybkich kolorów wybór
  zestawu podmienia całą trójkę; w trybie okładki folderu wybiera się
  pojedynczą próbkę bez ingerencji w kolory edytora.
  Pojedynczy tap szybkiego koloru wybiera go, dwuklik oraz długie
  przytrzymanie otwierają ten sam edytor palety.
  Kontroler HEX jest zwalniany dopiero
  po zakończeniu animacji zamykania dialogu, także przy zagnieżdżonej edycji.
  Po odczycie Recent selektor sprawdza osobno `context.mounted` i
  `navigator.mounted` przed odwołaniem do `NavigatorState.context`;
  chroni to dostęp do kontekstu na granicy asynchronicznej.
  14: `EditorToolbar`; 218: dialog tła; 342: selektor gumki;
  410: selektor kształtu; 550: `_colorDot`; 585: `pickColor`;
  952: `_EraserIcon`.
- `lib/features/editor/presentation/widgets/text_edit_toolbar.dart` (401):
  pasek formatowania aktywnego `TextBlock` współpracujący bezpośrednio z
  `EditableText`. Selektor czcionki obejmuje rozmiary 8–192; krótkie menu (do 280 px)
  otwiera się tuż pod dolną krawędzią paska i przewija pionowo, z prostą
  górną krawędzią i zaokrąglonymi dolnymi rogami.
  Wybór koloru używa wspólnego dialogu narzędzi i zachowuje
  ID bloku przez czas jego otwarcia, nawet przy utracie aktywnego zaznaczenia. Obsługuje realne formatowanie całego bloku: bold, italic,
  underline, strike, font, rozmiar, kolor, wyrównanie, reset stylu i usunięcie.
  Listy oraz formatowanie tylko zaznaczonego fragmentu są celowo pominięte,
  ponieważ obecny `EditableText` nie renderuje ich jako rich-text.
  Pasek używa takiego samego promienia 12 px: zwęża się do zawartości,
  pozostaje wycentrowany i przewija poziomo na wąskich ekranach.
  Na ekranach szerokich ma 52 px zewnętrznego i 22 px wewnętrznego
  marginesu bocznego; na telefonach 8 px + 8 px.
  oraz 2 px pionowego paddingu.
  9: `TextEditToolbar`; 43: `build`.

- `lib/features/editor/presentation/interaction/object_transform_engine.dart` (362):
  wspólny silnik move/resize dla obiektów nie-ink. Używa typów
  `HandlePosition` i `ResizeMode` z `flutter_box_transform`, ale po zmianach
  API 0.4.7 sam liczy geometrię logiczną, clamp i skalowanie, dzięki
  czemu działa niezależnie od zoomu dokumentu i nie dotyka stroke'ów.
  6: `ObjectTransformKind`; 8: `ObjectTransformSnapshot`;
  24: `ObjectTransformEngine`; 263: `_ObjectTransformSession`.
- `lib/features/editor/presentation/widgets/object_transform_hud.dart` (860):
  wspólna ramka transformacji dla tekstu i obrazów/PDF; używa gotowych
  `DefaultCornerHandle` i `DefaultSideHandle` z `flutter_box_transform`
  oraz wspólnego grabbera nad górną krawędzią do przesuwania obiektu.
  Grabber działa także wtedy, gdy środek ramki jest wyłączony z dragowania,
  np. podczas aktywnej edycji tekstu. Obrazy/PDF używają surowego drag jednym
  palcem, aby nadrzędny scroll nie przejmował ruchu; drugi kontakt zawiesza
  i anuluje ten drag bez skalowania obiektu. Grabber i uchwyty działają
  zawsze. Przytrzymanie anuluje pusty drag i otwiera menu kopiowania.
  Podgląd jest lokalny i
  usuwany przy anulowaniu/odmontowaniu; obsługa spóźnionych zdarzeń
  sprawdza `mounted` i czyści kontakty w `dispose()`. Dzięki temu
  nie ma `setState()` po usunięciu ramki podczas gestu.
  Dedykowane uchwyty używają surowych pointer events zamiast rozpoznawania
  pan, więc reagują od pierwszego ruchu
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
  14: `ObjectTransformHudStyle`; 55: `ObjectTransformHud`;
  117: `_ObjectTransformHudState`; 806: `_ObjectTransformFramePainter`.
- `lib/features/editor/presentation/widgets/shape_edit_overlay.dart`:
  `ShapeEditGeometry` udostępnia dwa uchwyty dla linii/strzałki, trzy
  dla trójkąta i strzałki blokowej oraz cztery dla
  prostokąta/kwadratu/elipsy/koła. `ShapeEditOverlay` przechwytuje
  gesty wyłącznie w obszarze figury/uchwytów, blokuje viewport podczas
  przesuwania i zmiany rozmiaru, zapisuje transformację jako undo/redo.

- `lib/features/editor/presentation/widgets/text_hud_block.dart` (583):
  podgląd używa tych samych zamienników Georgii co UI, ale nie narzuca
  ich blokom z indywidualnie wybranym fontem;
  aktywny `TextBlock` renderowany przez Flutter `EditableText`;
  Delete usuwa obiekt tylko przy pustym tekście, w przeciwnym razie
  pozostaje natywną edycją tekstu (znak po prawej stronie kursora). ramka,
  move/resize/scale są delegowane do wspólnego `ObjectTransformHud`; obrót
  jest wyłączony. Podczas edycji treści uchwyty resize i osobny grabber move
  pozostają aktywne, a środek ramki przepuszcza gesty do `EditableText`.
  Start transformacji zapisuje najnowszą treść, włącza blokadę viewportu
  i używa tej treści jako snapshotu resize, więc zmiana rozmiaru ani anulowanie
  gestu nie przywracają starszego tekstu. Kolor aktywnego tekstu jest
  wyznaczany z pierwszego formatowanego fragmentu Delta (lub bloku),
  a jego jasność odwracana w dark mode. Funkcja `textBlockAppearance`
  współdzieli metryki czcionki obu trybów. Aktywny tekst i podgląd Quill
  używają wspólnych metryk czcionki (Georgia, wysokość 1.25), dopasowanych
  wcięć i obramowania; granica skalowania ramką to 8–192.
  Nieaktywne teksty używają
  starego Quilla jako fallback.

### `lib/features/editor/presentation/widgets/drawing_canvas.dart` (4273 linii)

Dwa świadomie osobne canvasy ink, wspólna geometria rozpoznawania gestów,
lasso, handoff aktywnej kreski i pomiary wydajności.
  Kształty rozpoznane po przytrzymaniu pozostają w narzędziu bez Move,
  a figury z zakreślacza zachowują szerokość, półprzezroczystość i końcówki
  przy podglądzie, zapisie i eksporcie.
Promień kontaktu Androida nie jest wiarygodnym kryterium rozróżnienia
palca i dłoni. Gdy tryb Off zezwala na rysowanie palcem, pojedynczy
kontakt jest przyjmowany niezależnie od radiusMajor/radiusMinor;
blokada trybu On, opóźnienie początku gestu, brak kropek od tapnięć i
anulowanie multi-touch nadal obowiązują w obu canvasach. Rysik ma
pierwszeństwo, gdy pojedynczy kontakt dłoni pojawił się przed nim; canvasy
przyjmują zdarzenia rysika podczas nawigacji wielodotykowej, aby móc
bezpiecznie przejąć kontakt. Dwa palce bez rysika pozostają wyłącznie
nawigacją (pan/zoom), bez tworzenia ink. Wszystkie modyfikacje
gumki, włącznie ze scratch erase ze zmiennym promieniem, delegują dane do jednego
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

- 44: `_InkPerfLog`; geometria rozpoznawania scratch pozostaje przed
  deklaracjami canvasów, ale hit-test i cięcie są w `InkEraserEngine`.
- 656: `DrawingCanvas`; 678: `DocumentDrawingCanvas`.
- 895: `_DrawingCanvasState`; 2290: `_DocumentDrawingCanvasState`.
- 3783: `_InkPainter`; 3843: `_InkOverlayPainter`;
  4087: `_InkPageLayer`; 4134: `_PageInkPainter`.

- `lib/features/editor/presentation/widgets/selection_outline.dart` (32):
  wspólny painter przerywanego konturu dla lassa i gumki zakresowej;
  `dashPath` kompensuje skalę viewportu i nie zmienia źródłowej ścieżki.
  11: `dashedSelectionOutline`; 22: `paintSelectionOutline`.

### `lib/features/editor/presentation/widgets/page_overlay.dart` (3022 linie)

Interaktywna warstwa tekstu, obrazów i lassa nad ink; osobne warianty boarda
i dokumentu. Aktywny blok tekstu przechodzi do `TextHudBlock`: `EditableText`
oraz wspólny `ObjectTransformHud` dla move/resize/scale. Nieaktywne teksty
dla jednolicie sformatowanego tekstu korzystają z tego samego
`EditableText` w trybie tylko do odczytu, dzięki czemu zachowują identyczne
łamanie wierszy i pozycje znaków. Tekst o mieszanym formatowaniu nadal
korzysta z Quilla; w dark mode dostaje odczytową kopię Delta z odwróconymi
kolorami wszystkich fragmentów. Oryginalny
`QuillController` i zapisane Delta pozostają bez zmian. Aktywne obrazy/PDF
korzystają z tego samego `ObjectTransformHud`; obrót jest wyłączony, rogi skalują, boki zachowują
crop, a lasso/ink pozostają poza tym silnikiem.
W notebooku aktywna ramka korzysta z pełnego viewportu, żeby uchwyty obrazów
oraz stron PDF po imporcie reagowały również poza kartką. HUD obsługuje ruch
korpusu jednym palcem oraz rogi, krawędzie i grabber; dwa palce nie wykonują
transformacji. `imageTransformPreview` dotyczy tych gestów.
Normalizacja wymiarów pliku nie nadpisuje trwającego podglądu. Piksele obrazów/PDF są zawsze renderowane w warstwie tła przed
tuszem i tekstem, także gdy obraz jest aktywny; aktywna warstwa zawiera wtedy
tylko ramkę i uchwyty edycji. W trybie tekstu obrazy ignorują hit-test i nie
mogą przejąć kliknięcia przeznaczonego do wstawiania lub edycji tekstu.
W trybach rysunkowych (pióro, marker, gumki, kształty) overlay obiektów
nie uczestniczy w hit-teście; tekst oraz obrazy/PDF pozostają widoczne.
Lasso zachowuje swoje interakcje.
W Move nieaktywny obraz najpierw wymaga tapnięcia i zaznaczenia; nie korzysta
już z równoległego, starego drag/resize. Przytrzymanie aktywnego lub
nieaktywnego obrazu pokazuje wyłącznie akcję Copy, bez OCR i bez opóźnienia
zwykłego tapu. Tap wewnątrz pełnej, także obróconej ramki zachowuje
zaznaczenie; dopiero tap poza nią je kończy.
Operuje wyłącznie w logicznych współrzędnych strony/dokumentu; responsywną
skalę nadaje wspólny rodzic w `EditorScreen`, nie poszczególne bloki
overlayu. Pojedyncze wskazanie nieaktywnego Quilla jest stosowane po oknie
double tap, aby arena gestów Quilla zakończyła się przed podmianą widgetu na
`TextHudBlock`.

- 34: `PageOverlay`; 251: `DocumentPageOverlay`;
  313: `ActiveImageTransformHud`.
- aktywny tekst: `TextHudBlock`; fallback nieaktywnego tekstu:
  `_TextBlockWidget` / `_TextBlockWidgetState`.
  Akcje lassa korzystają z kompaktowego paska w kolorze toolbaru,
  z neutralnymi ikonami konturowymi i zachowaną obsługą akcji.
- 1627: `_ImageBlockWidget`; 1652: `_ImageBlockWidgetState`;
  2786: `_LassoSelectionWidget`; 2907: `LassoSelectionActionBar`;
  2966: `_LassoActionButton`.

## 9. Board

### `lib/features/board/presentation/board_screen.dart` (896 linie)

Jednostronicowa, swobodna tablica z pan/zoom, wspólnym kontrolerem i
warstwami tła/canvasu/overlayu; podczas aktywnej transformacji obiektu
ignoruje pointery nawigacyjne, trackpad i scroll, a kontroler blokuje zmianę
`viewPan/viewScale`. `BoardSceneBoundsResolver` zamraża prostokąt sceny
podczas move/resize, aby zmiany `contentBounds` nie przesuwały lokalnego
układu współrzędnych. Po zakończeniu gestu granice odświeżają się.
Nagłówek może otrzymać aktualną nazwę boarda od biblioteki bez resetu
edytora. Pasek tekstu jest wiązany z aktywnym `TextBlock`, a nie ze starym
`QuillController`. Główny toolbar i pasek tekstu respektują `showToolbar`
i unoszą się na nakładce nad canvasem, zamiast zmniejszać jego wysokość.
`showCompactTimer` wyświetla `CompactStudyTimer` w nagłówku po zwinięciu
panelu biblioteki.
Pan dotykowy boarda ma regulowaną czułość i próg gestu; pierwszy
palec po przekroczeniu progu trafia do aktywnych kontaktów nawigacji,
więc dołożony drugi palec zawsze przejmuje gest zamiast pozostawić
board bez przesuwania. Rysik, zoom i transformacje obiektów są
niezależne od tego ustawienia. Ctrl/Cmd+scroll na desktopie powiększa
tablicę, a zwykłe przewijanie nadal ją przesuwa.
Board ma stały boczny odstęp 16 px, ale nie ma marginesu u góry,
więc zawartość można swobodnie przesuwać za toolbar. Obszar roboczy
ma proste górne rogi i zaokrąglone dolne rogi (12 px) zarówno w dekoracji,
jak i w klipowaniu zawartości. Nagłówek ma
wyłączony tint podczas przewijania. Panele dziedziczą aktywną paletę.
Zaznaczony w Move obraz/PDF zamraża nawigację i granice sceny. Jeden palec
przesuwa obiekt, a dwa kontakty nie zmieniają obiektu ani canvasa.

- 31: `BoardScreen`; 49: `_BoardScreenState`.
- 75: `_buildBoardRect`; 85–378: obsługa pointerów i viewportu.
- 510: główny `build`; import/eksport i skróty przez `EditorCommands`.
- 755: `BoardSceneBoundsResolver` — stabilne granice sceny podczas gestu.
- 791: `_BoardPaintProbe`; 808: `_RenderBoardPaintProbe`;
  831: `_BoardZoomControls`.

## 10. Platformy, web i testy

- `tool/run_local_backend_web.sh`: uruchamia Flutter Web na
  `http://localhost:3000` z API `http://localhost:18080`; zdalny serwer
  wymaga tunelu SSH opisanego w `server/README.md`.
- `tool/website_widget_demo.dart`: osobny entry point Flutter Web dla
  publicznej strony wizytówkowej. Używa istniejących `EditorScreen`,
  `EditorToolbar`, `EditorController` i wydzielonej bazy IndexedDB demo;
  nie inicjuje AppScope, konta, synchronizacji ani backupu sieciowego.
  Kompiluj wyłącznie lokalnie, kopiując do publicznego repo wynik builda,
  a nie źródła Dart.
- `test/website_widget_demo_test.dart`: pusty notatnik demonstracyjny oraz
  przekazanie osobnej nazwy bazy danych do publicznego API otwierania.


- `data.md`: źródło prawdy dla lokalnego układu plików, trybów konta,
  backupu serwerowego, synchronizacji i znanych granic szyfrowania.
- `server/`: lustro kanonicznego backendu `NaNotateczki-serwer/main`;
  różnice sprawdza `tool/check_server_mirror.py`. Lekki stos
  PostgreSQL 17 + FastAPI + Caddy + opcjonalny
  Cloudflare Tunnel. API zawiera Argon2id/JWT/rotowane refresh tokeny,
  owner isolation, CAS/idempotencję, tombstones, change events, WebSocket
  oraz pending/upload/finalize dla zweryfikowanych snapshotów. Migracja SQL
  jest w `server/migrations/0001_initial.sql`; klient nie łączy się z 5432.
  `server/scripts/apply-migrations.sh` pilnuje rejestru i SHA-256 migracji,
  a `server/scripts/backup-server.sh` tworzy sprawdzony backup PostgreSQL i
  plików na osobny nośnik, opcjonalnie szyfrowany przez `age`.
  GitHub Actions uruchamia także prawdziwe HTTP E2E na odizolowanym
  PostgreSQL: migracje, konto, sync, scalanie edycji dwóch gości,
  feed hosta, PNG i verified backup.

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
- `web/flutter_bootstrap.js`: lokalny CanvasKit oraz PDF.js 4.6.82 z workerem
  i kompletem map znaków w `web/vendor/pdfjs/`; adresy względem `base href`,
  inicjalizacja globalnych opcji pdfx przed uruchomieniem Fluttera. Lokalny
  `fontFallbackBaseUrl` i `web/vendor/flutter-fonts/` zachowują pełną tabelę
  czcionek silnika, również emoji i inne alfabety, bez zmiany Gelasio w UI.
- `web/_headers`: MIME JS/WASM oraz rewalidacja plików startowych hostingu.
- `tool/vendor_flutter_fonts.py`: odtwarza komplet czcionek z tabeli SDK,
  zachowuje ścieżki, licencje, wersję silnika i sumy SHA-256.
- `tool/package_cloudflare_web.py`: sprawdza kompletność produkcyjnego builda,
  zgodność tabeli fontów z silnikiem i limity uploadu; z `build/web/` tworzy
  odchudzony `build/cloudflare-worker/` i ZIP. Pomija diagnostykę i nieużywane
  renderery, spłaszcza katalogi fontów z rewrite zachowującym ich adresy.
  `nanotateczki-release.json` identyfikuje całą paczkę.
- `wrangler.jsonc`: statyczny Worker z fallbackiem SPA; Flutter nie jest
  skryptem wykonywanym po stronie Workera.
- `test/cloudflare_web_package_test.py`: selekcja rendererów, zachowanie
  bajtów fontów po spłaszczeniu i limity plików uploadu.
- `test/web_runtime_assets_test.dart`: lokalne adresy startowe i kompletność
  dystrybucji PDF.js i czcionek silnika weryfikowana sumami SHA-256.
- `.github/scripts/test_web_local_assets.mjs`: gotowy build w izolowanym
  Chrome, zablokowane CDN-y; pierwsza klatka Fluttera, render PDF przez worker,
  mapa znaków i fonty emoji/JP/Arabic/math dla `/`, `/share/UID` i `/app/`;
  `WEB_BUILD_DIR` wskazuje wypakowaną paczkę, `WEB_ORIGIN` rzeczywisty serwer.
- `.github/scripts/test_cloudflare_worker.mjs`: dry-run Wrangler 4.156.1,
  walidacja dwóch reguł rewrite i nagłówków, lokalny Workers oraz Chrome;
  niezależny od konta Cloudflare, wykonywany w jobie web CI.

Testy pokrywają repozytorium i ochronę danych, backup, sync, flattening gumki,
indeks ink, benchmark renderowania, gesty tekstu, resize oraz start aplikacji:

- `test/notebook_repository_test.dart`: regresje powiadomień po atomowym
  restore/import, zapis, migracja legacy gumek, kontrola
  uprawnionych usunięć i nieoczekiwanej utraty danych,
  migracja v1→v2 usuwająca dane Index tab bez utraty stron.
- `test/local_backup_service_test.dart`:
  nowy i starszy format folderów, odtwarzanie okładek/Recent, backup
  i równoległy zapis folderów z wykonywaniem snapshotów.
- `test/app_error_log_test.dart`: grupowanie powtarzalnych błędów
  i odczyt liczników z zachowaniem zgodności starych logów.
- `test/editor_save_flush_test.dart` (63): wymuszenie dirty page save przed
  zamknięciem.
- `test/editor_controller_layering_test.dart`: regresje cofnięcia ostatniej
  kreski i jawnego usunięcia obrazu bez fałszywych incydentów; aktywne obrazy są
  dezaktywowane po wyborze narzędzia ink lub tekstu, a nowy tekst startuje
  zaznaczony w trybie edit; obraz ma dane inline, a przed zamknięciem
  testowej bazy następuje rzeczywisty zapis.
- `test/backup_eraser_flattening_test.dart` (109)
- `test/cloud_sync_service_test.dart` (84)
- `test/app_data_directory_test.dart`: bezstratna migracja wszystkich kategorii,
  świeża instalacja bez starego katalogu, zachowanie konfliktującego celu i
  usuwanie identycznego duplikatu dopiero po porównaniu SHA-256.
- `test/database_image_path_migration_test.dart`: relokacja zapisanych w
  SQLite ścieżek obrazów po przeniesieniu katalogu danych.
- `test/api_client_test.dart`: odrzucenie HTTP/sekretów w URL, Bearer/request
  ID i zachowanie struktury odpowiedzi 409.
- `test/diagnostics_upload_service_test.dart`: błędy HTTP 5xx i transportu
  trafiają do lokalnych `Errors` oraz do prywatnego snapshotu diagnostycznego
  na serwerze; duplikaty 5xx są grupowane, konflikt 409 ignorowany,
  a nieudana wysyłka diagnostyki nie generuje kolejnego raportu.
- `test/remote_backup_scheduler_test.dart`: odstęp bezczynności 15/30 s,
  nieblokujący upload podczas oczekiwania na serwer, weryfikacja przed exit
  oraz ograniczone oczekiwanie na zawieszony upload; backup po imporcie ze zdalnego urządzenia bez lokalnych kliknięć;
  nieudane uzgodnienie blokuje przestarzały snapshot.
- `test/editor_screen_responsive_layout_test.dart` i
  `test/board_scene_bounds_test.dart`: regresja Ctrl+scroll pinch touchpada,
  rozdzielona od zwykłego przewijania.
- `test/account_tombstone_bootstrap_test.dart`: po usunięciu na serwerze
  znany wcześniej dokument nie zostaje wskrzeszony po compact tombstone.
- `test/shared_editor_viewport_test.dart`: zachowanie lokalnej strony, zoomu
  i pan podczas odbioru obcych zmian.
- `test/one_shot_error_notice_test.dart`: błąd wyświetlany jednokrotnie
  i rearm po poprawnym połączeniu.
- `test/remote_backup_service_test.dart`: kompletny snapshot v2 z biblioteką
  i planerem, wymaganie potwierdzonego `verified` oraz zachowanie flagi dirty,
  gdy dane zmienią się podczas ręcznego `backupNow`, a także izolacja stanu
  i `deviceId` między osobnymi sesjami kont. Regresje etapu 9:
  envelope/checkpoint konta, odmowa przy niepotwierdzonym outboxie,
  wykrywanie zmiany preferencji w czasie capture i marker utraty bazy.
- `test/account_backup_recovery_regression_test.dart`: odrzucenie
  archiwalnego backupu starszego od zachowanego checkpointu operacji.
- `test/live_web_sync_service_test.dart`: pobranie wszystkich stron feedu po
  500 zdarzeń, ochrona kursora przed pominięciem równoległej zmiany,
  zachowanie zapisów pojawiających się w czasie bootstrapu konta,
  pasywne pobieranie notatnika z innego urządzenia bez lokalnych zapisów,
  brak przenoszenia outboxu i rewizji między kontami, natychmiastowe
  wysłanie kopii konfliktowej po odpowiedzi HTTP 409.
- `test/library_account_slot_test.dart`: centrowanie nazwy, podgląd i limit
  hasła, brak awatara w pasku konta (pozostaje w dialogu), wyrównanie
  statusu z nazwą, rozmiar ikony ustawień i odstępy przycisków;
  dostęp do konta w szerokim sidebarze
  i mobilnym drawerze, onboarding/rejestracja z powtórzeniem hasła, lokalna
  nazwa i inicjał, logowanie, ręczny backup, pierwsza polityka Web, zmiana
  hasła oraz kolejność zatrzymania usług przed wyczyszczeniem sesji.
  Sprawdza też osobne, nieruchome podpisy i obramowanie pól we wszystkich
  formularzach konta, również po wpisaniu tekstu. Dodatkowa regresja
  porównuje nagłówki paska i dialogów z timerem, opis statusu 12 px
  oraz wspólny `AppTypography.fontFamily` w obu motywach. Ręczna kontrola na Linux/web i w wąskim
  sidebarze jest opisana w `docs/TEST_MATRIX.md`.
- `test/account_session_controller_test.dart`: krótsze nowe hasła i logowanie
  istniejących kont, trwały profil lokalny bez sekretów, odtwarzanie sesji
  po restarcie, rotację refresh tokenu, logowanie offline bez dialogu,
  usuwanie odrzuconego tokenu, preferowany tryb i kontrakt zmiany hasła.
- `server/api/tests/`: nowe limity haseł, Argon2/JWT,
  integralność envelope, izolacja urządzeń w
  schemacie i brak publicznych portów bazy/API w Compose.
- `test/library_planner_test.dart`: kolory według statusu w obu motywach,
  zgodność Recent i ukończonych z paskiem folderów, `Opacity` całego
  odhaczonego wiersza, automatyczne sortowanie również ze starym
  ustawieniem, jasny Add task, poprawność nagłówka i bezpieczne Settings;
  wyrównanie daty i kontrolek, wielowierszowe zadania bez przesuwania
  checkboxa i symetryczne odstępy od zmiennego bloku akcji,
  responsywność, zapis i odczyt zadań,
  edycja, usuwanie, opcjonalny deadline, kolor statusów oraz widget canvasu;
  ikonę planera (kwadrat z tikiem) w drzewie folderów.
- `test/study_planner_controller_test.dart` i
  `test/study_planner_widget_test.dart`: wydarzenia kalendarza bez timera,
  powtarzanie, wydarzenia wielodniowe, brak wydarzeń w Upcoming,
  jasne obramowanie w sidebarze i wybór typu przez plus,
  wspólny zapis, edycja, usuwanie i zgodność starych wpisów.
- `test/library_sidebar_drag_drop_test.dart`: trwałe przenoszenie notatek i
  boardów między folderami, walidacja celu, zachowanie wyboru, przeciąganie
  na zwinięty folder i rozwinięcie go po upuszczeniu; foldery relokują całe
  poddrzewo, okładki i dokumenty, nie przyjmują własnego potomka ani kolizji,
  zwijają się podczas gestu i pozostają zwinięte po przeniesieniu; zgodność
  szerokości i zawartości przeciąganego wiersza, mocniejsze tło oraz blokada
  ruchu poziomego.
- `test/library_nested_folders_test.dart`: ścieżki folderów, migracja
  nazw jednopoziomowych, zapis/odczyt, rekurencyjna zmiana nazwy,
  usuwanie poddrzewa z dokumentami oraz podfoldery z dokumentami w katalogu;
  identyczne rozmiary i odstępy siatki folderów głównych i podfolderów,
  niezależnie od liczby dokumentów i szerokości ekranu.
- `test/library_controller_test.dart` (33)
- `test/library_catalog_test.dart` (971): rozmiary nazw folderów
  i dokumentów, kolor dominujący, serializacja
  stylu okładek, start katalogu, siatka notatek/boardów,
  brak palety w nagłówku folderu i edycja przez menu boczne,
  siatka dokumentów 1–5 kolumn, wspólna szerokość i górna krawędź
  miniatur oraz różna wysokość notatników i boardów,
  wspólny promień i zewnętrzny cień folderów i dokumentów w obu motywach,
  edycja dekoracji i kolorów z okrągłymi paletami i wspólnym Recent,
  bez bazowych próbek Cover color, zapis i odczyt historii,
  regresja widoczności ikon i dekoracji w obu motywach, kontur Lucide,
  responsywna siatka 1–5 kolumn, odrębne kolory hover/press oraz
  geometria menu po lewej od nazw folderów, notatek i boardów.
- `test/merged_ui_integration_test.dart`: brak dolnego SnackBara po
  zakończeniu sesji, zachowanie dialogu oceny, wspólny motyw katalogu/planera,
  wysokość i 1 px separator nagłówka planera i ustawień w obu motywach,
  dostęp do Settings przez katalog, ustawienia pustej biblioteki, nocne miniatury bez mutacji danych i repaint
  po zmianie motywu, kontrast planera/timera, pozycja menu względem
  prawej granicy sidebaru przy resize w obu motywach, maskowanie
  cienia na styku oraz wspólna czułość nowych scrollerów.
- `test/dialog_actions_test.dart`: kolory przycisków stopki w obu motywach
  oraz izolacja stylu od przycisków wewnątrz treści dialogu.
- `.github/workflows/cross_platform_tests.yml`: niezależny job `stylus-input`
  weryfikuje wyłącznie rysik/dłoń, bez zależności od formatowania planera.
  Macierz gestów działa w CI na trzech systemach desktopowych, Androidzie
  i symulatorach iOS;
  przeglądarka weryfikuje kontrakt zdarzeń (nie sprzętowy palm rejection).
- `.github/workflows/cross_platform_tests.yml`: osobny szybki job
  `adaptive-layout` dla regresji viewportów; pełny zestaw testów ma
  limit 3 minut na przypadek (wcześniej 10 minut), bez wyłączania testów.
- `test/support/pointer_contact_matrix.dart`: wspólne scenariusze Flutter
  dla notebooka i boarda, kontrola rysowania palcem, utrzymania własności
  kursora przez rysik, bliskiego/dalekiego kontaktu dłoni, anulowania
  gestów, braku kropek i skoków zapisanej geometrii. Porównanie długości
  odbywa się w pikselach ekranu, a dwupalczasta nawigacja ma osobne
testy, także gdy pierwszy palec zdążył rozpocząć kreskę. Test
notatnika mierzy łączną transformację strony i scroll dokumentu, bo gest
przesuwający stronę poza dozwolony pan przechodzi w przewijanie; kierunek
gestu jest dobrany tak, aby nie utknąć na górnym ograniczeniu. Kontakty
na testach natywnych są umieszczane tylko w części viewportu widocznej
w oknie aplikacji, nie na niewidocznej wysokości przewijanego dokumentu.
- `test/pointer_contact_matrix_test.dart`: natywna macierz widgetowa dla
  ekranu telefonu, wykonywana też na systemach desktopowych.
- `integration_test/pointer_contact_matrix_test.dart`: te same scenariusze
  na runtime Android/iOS/iPadOS oraz desktop Linux/Windows/macOS.
- `test/cross_platform/pointer_dispatch_contract_test.dart`: kontrakt
  Flutter PointerEvent (rodzaj, promień, cancel) uruchamiany także w Chrome.
- `test/android_finger_ink_test.dart`: regresja telefonu Android z dużym
  promieniem styku palca w obu edytorach, wyłączenie palca w trybie On,
  zachowany rysik, brak kropek przy wielodotyku i wznowienie po nim.
- `test/adaptive_platform_layout_test.dart`: bezpieczne górne i dolne
  marginesy systemowe, dostęp do drawer/edytora, układy 320/390/768/844/
  1024/1440 px i zachowanie kontrolera przy zmianie orientacji.
- `test/library_screen_responsive_layout_test.dart`: używa
  `useIsolatedNativeTestDocuments` i pamięciowego text storage także
  w testach popup i okładek, aby startup nie rzucał `MissingPluginException`,
  a natywne I/O uruchomione w FakeAsync nie blokowało `tearDownAll`.
  `test/library_screen_responsive_layout_test.dart`:
  szeroki układ, drzewo folderów i przełączanie widoczności toolbaru
  boarda/notebooka z kontrolką pod strzałką panelu; regresja pionowego
  centrowania i szerokości strzałek, cienia/obrysu i kierunku zwijania;
  wyśrodkowanie, zwężanie kapsułek, wysokość, odstępy boczne
  oraz przewijanie na wąskim ekranie; dynamiczny podział folderów,
  bezramkowego timera i paska konta, limit 45% z przewijaniem na małym
  ekranie, nagłówek timera w stylu Projects bez ikony zegara,
  wspólny `AppHeaderDivider` nad timerem,
  i aktualizacja mnożnika przewijania plików bez restartu; geometria,
  kolor i obsługa menu
  folderu, notebooka oraz boarda, a także poziomą zakładkę timera
  (pozycja po lewej, strzałki dół/góra, obrócone wymiary,
  proste dolne rogi stykające się z separatorem, ten sam profil
  cienia elevation 8 skierowany w prawo z alfą zmniejszoną do 30%,
  wspólny obrys i pełny hit-test w obu stanach)
  i menu dodawania (4 pozycje,
  wyrównanie do panelu i jednostronne zaokrąglenia), zgodność wielkości
  czcionki menu z nazwami dokumentów, brak ikon w menu dodawania,
  stykanie menu z prawą granicą całego sidebaru (w tym resize handle),
  prosty lewy brzeg, brak cienia i podziałki w miejscu styku,
  aktualizacja tytułu otwartego notebooka i boarda po zmianie nazwy bez
  utraty `EditorController`,
  ciągła linia pod nagłówkiem w katalogu, folderze, notebooku i boardzie,
  również po ukryciu panelu, brak podświetlenia Projects także po hover
  i zachowane przejście do katalogu głównego,
  czytelny kolor tekstu Cancel/Rename w rzeczywistych dialogach,
  kolor tła zgodny z głównym toolbarem (także gdy kolory
  `surfaceContainerLow` i `surfaceContainerLowest` są różne)
  oraz cień wyłącznie po zewnętrznych stronach menu.
- `test/touch_navigation_sensitivity_test.dart` (80):
  granice czułości i porównanie dystansów scrolla przy gestach palcem.
- `test/ink_activity_tracker_test.dart` (25): exit guard czeka na koniec
  aktywnego kontaktu rysika.
- `test/ink_spatial_index_test.dart` (49)
- `test/ink_eraser_engine_test.dart` (396): zwykła gumka, scratch erase,
  krótki bazgroł, ochronę sąsiednich kresek i limit dużego gestu,
  erase-stroke/area hit-test, precyzyjne fragmenty zakresu, undo/redo,
  migracja legacy gumek, pojedyncze punkty,
  kolizje ID i undo
- `test/ink_render_benchmark_test.dart` (220)
- `test/selection_outline_test.dart`: przerywane kontury otwarte i zamknięte,
  brak mutacji źródła oraz zgodność rozmiaru segmentów z zoomem
- `test/notebook_overview_navigation_test.dart`: kliknięcia widocznej minimapy,
  przełączanie strony, scroll minimapy bez nawigacji, wybór po przewinięciu,
  blokada transformacji, mapowanie współrzędnych i zachowanie skali.
- `test/editor_screen_responsive_layout_test.dart` (625):
  pełna wysokość canvasa pod pływającym toolbarem, położenie strony
  poniżej narzędzi i domyślne centrowanie poziome z zachowaniem ręcznego
  pan, wsuwanie strony pod pasek bez maskującego marginesu,
  rozszerzenie dolnej granicy klipu, stabilny kolor `AppBar`,
  minimapa na krótkim ekranie, regulacja scrolla stron i interaktywność
  narzędzi; przełączanie Grid/Lines bez powiadamiania całego edytora,
  aktualizacja wzoru na kartce i ignorowanie powtórnego identycznego wyboru;
  powiększony wielostronicowy notatnik przewija się od środka
  do obu końców bez utknięcia, pokazując przycisk Add page i dolny
  margines przy maksymalnym przewinięciu; brak procentowej nakładki przed
  i po powiększeniu; test tap/dwuklik/przytrzymanie szybkiego koloru, otwarcia
  selektora i zapisu nowego koloru.
- `test/editor_toolbar_color_picker_test.dart`: dark/light picker, odwrócone
  Recent i wartości RGB/HEX, suwak i zapis z zachowaniem koloru wizualnego,
  brak modyfikacji danych po zatwierdzeniu bez zmian; osobne widget testy
  dla obu motywów i jawna weryfikacja aktywnej jasności motywu.
  Dodatkowo sprawdza obecność i rendering trzech palet, wybór całego
  zestawu w edytorze i pojedynczego koloru w folderze w obu motywach
  oraz zachowanie zagnieżdżonego motywu podczas asynchronicznego otwarcia
  selektora kolorów na głównym navigatorze.
- `test/page_overlay_text_gestures_test.dart`: porównanie pozycji znaków,
  wierszy i ramki przed edycją, podczas niej i po niej (oba motywy),
  zachowanie Quill dla mieszanego formatowania, rozmiary 8–192,
  położenie, wysokość, przewijanie i kształt menu rozmiarów czcionki;
  blokowy toolbar
  tekstu, układ uchwytów i odwracanie kolorów starych bloków rich text
  w jasnym/ciemnym motywie bez modyfikowania zapisanych Delta,
  blokadę viewportu oraz brak zmian pan/zoom kontrolera podczas resize;
  dodatkowo rozdział stref dotyku uchwytów dla różnych rozmiarów ramek;
  tryb tekstu ignoruje obrazy pod kursorem, a resize nie gubi zmian;
  w trybach ink kliknięcia przechodzą przez tekst i obrazy/PDF; test
  wskazuje rzeczywisty cel dotyku obrazu, a nie wyliczoną pozycję;
  trafia w aktywny lub nieaktywny renderer tekstu, a oba warianty
  ignorują dotyk w trybie ink;
  regresja selektora koloru tekstu po utracie zaznaczenia oraz undo/redo;
  Delete usuwa znaki po prawej stronie kursora, nie usuwa niepustego
  bloku i usuwa cały obiekt dopiero po wyczyszczeniu tekstu
- `test/lasso_selection_action_bar_test.dart`: kompaktowy pasek lassa,
  kontrast i kolor przycisków w obu motywach oraz działanie kopiuj/usuń.
- `test/board_scene_bounds_test.dart`: stały układ współrzędnych
  boarda podczas resize/move, pełna wysokość canvasa pod toolbarem,
  proste górne i zaokrąglone dolne rogi canvasa oraz zgodność klipu,
  zachowanie viewportu po schowaniu narzędzi, kolor nagłówka i porównanie
  szybkości przesuwania palcem dla 0.5× i 2.0×.
- `test/shape_edit_test.dart`: brak synchronicznych powiadomień przy
  kończeniu transformacji; regresje rozpoznanych po przytrzymaniu linii,
  prostokąta i elipsy bez Move dla pióra i zakreślacza w notebooku i boardzie,
  zachowanie stylu zakreślacza, liczby uchwytów, zmian
  geometrii figur, proporcji kwadratu/koła, przesuwania, hit-testu,
  undo/redo oraz tymczasowego Move z powrotem do narzędzia
  w notebooku i boardzie; usuwanie aktywnej ramki obiektu i kształtu
  w trakcie gestu bez wywoływania powiadomień podczas unmount.
- `test/image_pdf_transform_regression_test.dart`: rogi skali i krawędzie crop
  poza kartką, zawsze aktywny drag jednym palcem i grabber, brak transformacji
  obiektu dwoma palcami, zamrożony canvas podczas zaznaczenia, zaznaczenie
  wyłącznie w Move i deselect dopiero po tapnięciu poza pełną ramką lub zmianie
  narzędzia, przytrzymanie z Copy bez OCR oraz undo/redo dla zdjęcia i PDF.
- `test/object_transform_engine_test.dart` (67): wspólna geometria
  move, corner-scale, side-resize i zachowanie historycznych kątów
- `test/resizable_frame_test.dart` (33)
- `test/app_scroll_behavior_test.dart`: brak pasków przewijania w całej
  aplikacji na desktopie przy zachowaniu przewijania dotykiem i kółkiem.
- `test/widget_test.dart` (20)
- `test/dark_mode_theme_test.dart`: rejestracja i dostępność ośmiu
  wariantów Gelasio w assetach oraz paleta dark, odwracanie jasności
  wszystkich barw HSL, alfa, zachowanie odcieni, przełącznik Visual,
  suwak skali interfejsu oraz podgląd suwaka czułości w System;
  oba bez liczbowych etykiet.
- `test/ui_scale_test.dart`: rozmiary logicznego viewportu i trafianie
  w przyciski przy powiększeniu oraz pomniejszeniu całego interfejsu,
  zachowanie bieżącej trasy po powrocie do skali 100%.


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
- `test/account_cross_device_backup_test.dart`: transfer zweryfikowanych
  notatników, preferencji konta, Recent i opóźnienia backupu na nowe
  urządzenie; odrzucenie uszkodzonego payloadu i błędnego ID przed zapisem,
  brak ponownego pobierania, ochrona lokalnej pracy i historii usunięć.
- `test/live_web_sync_service_test.dart`: lokalne daty z SQLite i ich
  odpowiedniki UTC nie tworzą kopii konfliktowych ani zbędnych zapisów;
  późniejsza edycja wysyła niezmieniony bazowy snapshot serwera.
- `test/account_tombstone_bootstrap_test.dart`: tombstone przy logowaniu
  usuwa stary UID, ale zachowuje lokalne edycje w osobnej kopii.
- `test/account_backup_recovery_regression_test.dart`: oryginalne bajty SHA,
  odrzucenie uszkodzeń, łączenie niepustej biblioteki i zadania kopii planera.
- `test/backup_payload_bytes_test.dart`: liczby, Unicode, escape'y i zakres
  top-level payloadu; działa także w Chrome.
- `test/notebook_conflicts_test.dart`: numeracja w obrębie folderu,
  nowe ID wszystkich obiektów i zachowanie treści/obrazów; import Local
  nie zmienia nazw bez konfliktu i ignoruje obce foldery/rodzaje.
- `test/web_share_routing_test.dart`: reguła 200 dla `/share/*` w
  `web/_redirects`, kopiowana do paczki hostingu Cloudflare.
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
  oczekujący na zakończenie kolejki I/O przed sprzątaniem.
  adapter PathProvider; opcjonalny pamięciowy tekstowy storage zapobiega
  zablokowaniu FakeAsync przez natywne I/O w testach widgetowych. Nie
  przekierowuje danych użytkownika.
  Testy geometrii biblioteki, edytora, adaptacyjnego layoutu i tekstowych
  overlayów korzystają z pamięciowego adaptera; rzeczywistą trwałość zapisu
  nadal weryfikują osobne zestawy repozytorium i `test/production/`.
- `.github/scripts/flutter_integration_retry.sh` i
  `.github/scripts/test_flutter_integration_retry.sh`: ponowny start testu
  Android wyłącznie po błędzie inicjalizacji DDS; osobny test regresji
  pilnuje, żeby asercje i powtarzające się awarie pozostały blokujące.
- `test/android_build_toolchain_test.dart`: test regresyjny progu wersji
  pluginu Kotlin Android >= 2.3.20 i użycia `compilerOptions` / JVM 17
  zamiast wycofanego `kotlinOptions.jvmTarget`.
- `test/production/storage_crash_recovery_test.dart`: atomiczne pliki
  ustawień: częściowe zapisy `.tmp`, odzyskiwanie `.previous`, błąd I/O
  i ponowny zapis oraz równoległe write'y jednego klucza; kontrolowane
  opóźnienie rozwiązania pierwszej ścieżki pilnuje kolejności wywołań.
- `test/production/backup_crash_recovery_test.dart`: symulacje awarii
  między rename manifestu, błędu dostępu do katalogu stron i przerwania
  backupu z zachowaniem starego kompletnego snapshotu.
- `test/notebook_repository_test.dart`: przenoszenie i zmiana geometrii
  obrazu między stronami bez fałszywego incydentu, undo/redo, blokowanie
  podejrzanych full/page-level zapisów oraz weryfikacja danych SQLite.
- `test/production/persistence_roundtrip_test.dart` (300): rich text z Delta,
  crop i bytes obrazów, dwie strony, dirty-page, równoległe zapisy, backup
  i przywrócenie do nowego SQLite; każdy test ma własny katalog dokumentów
  i fake `PathProviderPlatform`, bez zapisu do danych użytkownika. Test
  restore zamyka źródłowy `NotesDatabase` przed otwarciem docelowego,
  aby nie utrzymywać dwóch instancji Drift w tym samym isolate.
  Weryfikuje również trwałość ustawienia czułości nawigacji i skali UI,
  domyślne palety, ich utrwalanie, migrację fabrycznych kolorów
  (także zestawów z poprzedniej wersji) i
  zachowanie ustawionych ręcznie próbek. Test migracji czeka na zapis
  preferencji przed przejściem do następnej palety.
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
  Release uruchamia R8; nie wyłączaj shrinkingu dla całej aplikacji.
- `.github/scripts/android_emulator_preflight.sh`: sprawdza dostępne miejsce
  po instalacji AVD; emulator używa partycji 1536M, aby uniknąć
  wyczerpania miejsca runnera.
- `.github/scripts/android_emulator_tests.sh`: jedną komendą Flutter
  uruchamia 3 scenariusze bez trzykrotnej kompilacji; czeka na `adb` i
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
7. OCR jest wyłączony na wszystkich platformach; stare `ocrText` zachowuj dla
   zgodności danych. Import PDF na Linuxie używa `pdftoppm` (`poppler-utils`),
   a pozostałe platformy `pdfx`.
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


## Synchronizacja ustawień i natywne WebSocket

- `server/api/app/routers/account_settings.py` oraz
  `server/migrations/0007_account_settings.sql`: izolowany per konto
  magazyn preferencji, kontrola CAS i powiadomienie WebSocket;
  stan portowany również do repozytorium `NaNotateczki-serwer`.
- `server/api/app/main.py`: 3 MiB na żądania `libraryState` zgodnie z
  produkcyjnym API; `server/api/app/settings.py`: długoterminowy refresh
  konta (3650 dni), test w `server/api/tests/test_security.py`.
- `server/api/app/routers/realtime.py`: weryfikuje `Origin` w
  przeglądarce, dopuszcza brak `Origin` w kliencie natywnym;
  JWT pozostaje obowiązkowy. Regresja:
  `server/api/tests/test_native_realtime.py`.

## Uzupełnienia 2026-11-02: bezpieczne przywracanie i sesje

- `lib/app/app_scope.dart`: recovery backupu ma niezależną obsługę błędów;
  przy błędzie live sync nadal startuje, ale nie jest wysyłany potencjalnie
  niekompletny nowy backup; ponowienie po wznowieniu aplikacji.
- `lib/data/sync/account_session_controller.dart`: jawne wylogowanie
  trwale przywraca ekran wyboru trybu bez usuwania przypisania biblioteki.
- `lib/features/library/presentation/library_account_slot.dart`:
  `account-logout`, a przycisk `account-backup-now` bez ikony.
- `lib/features/editor/presentation/widgets/page_overlay.dart`:
  wpisy w edytorze Quill również oznaczają aktywność dla schedulera.
- `lib/data/sync/live_web_sync_service.dart`: remote tombstone usuwa
  oryginał bez kopii, jeśli nie ma oczekujących edycji; HTTP 409 przy
  usunięciu chroni lokalny niezapisany szkic jako numerowaną kopię.
- `test/remote_backup_scheduler_test.dart`: wymuszony pierwszy upload,
  po imporcie zdalnym automatyczny upload dopiero po 30 s bezczynności;
  test osobno sprawdza odmowę weryfikacji przy błędzie pull.
- `test/live_web_sync_service_test.dart`,
  `test/account_cross_device_backup_test.dart`,
  `test/remote_backup_scheduler_test.dart`,
  `test/library_account_slot_test.dart`,
  `test/account_session_controller_test.dart` oraz
  `test/account_settings_sync_service_test.dart`: nowe scenariusze regresji.
- `BACKUP_SYNC_ROADMAP.md`: kontrolna lista etapów ukończonych i pozostałych.
- Serwer `migrations/0009_account_settings_library_state.sql` dodaje
  brakującą kategorię `libraryState` do constraint; klient synchronizuje
  tę kategorię przez CAS i wymaga jej wdrożenia na serwerze.
- Serwer `api/app/routers/study_shares.py`: WebSocket subskrybuje sygnały
  zakończenia przed uwierzytelnieniem biletu, aby nie zgubić odwołania sesji.
  `api/tests/test_study_shares_flow.py`: test kolejności i zamknięcia
  okna wyścigu WebSocket. `server/api/app/routers/backups.py`
  porządkuje zweryfikowane snapshoty według czasu weryfikacji,
  z testem regresyjnym w `test_backup_validation.py`.

## 13. Wspólna edycja sesji Web

- `lib/data/sync/study_share_service.dart`: utworzenie, odzyskiwanie,
  przedłużanie i zakończenie sesji, uwierzytelniony bilet gościa i
  odrębną publikację trybu light/dark oraz stylu tła hosta bez
  zmiany rewizji treści; brak dostępu do konta autora.
  Zapis gościa zachowuje niezmienioną datę utworzenia z bazy serwera,
  nawet gdy edytor odczytał tę samą chwilę w lokalnej strefie czasowej.
- `lib/features/share/presentation/study_share_dialog.dart`: link,
  hasło, zakończenie i przedłużenie.
- `lib/features/share/presentation/study_share_capture.dart`: nakładka
  ostrzeżenia końca sesji bez kosztownych screenshotów PNG.
- `lib/features/share/presentation/study_share_guest_screen.dart`: logowanie
  hasłem, WebSocket, odnowienie połączenia, odcięcie dostępu i
  motyw aktualizowany zgodnie z hostem po `appearance_changed`.
- `lib/features/share/presentation/study_share_guest_editor.dart`:
  prawdziwy BoardScreen/NotebookScreen, zapis zmian do serwera,
  odtwarzanie scalonej wersji, retry i wznowienie zachowanego outboxu.
  Pasek zapisu jest ukryty; komunikaty pojawiają się tylko przy błędzie.
  Odbiór identycznych stron nie powoduje ponownego rysowania. 120 ms
  `sharedGuestPushDebounce` zapisuje lokalny outbox od razu, ale wysyła
  ustalony stan zamiast pełnego dokumentu po każdym callbacku.
- `lib/data/sync/study_share_guest_outbox.dart`: izolowany per link trwały
  zapis ostatniej niepotwierdzonej wersji, bez biletu lub hasła gościa.
  `test/study_share_guest_outbox_test.dart`: reload, izolacja i walidacja.
- `study_share_memory_db_stub.dart` i `study_share_memory_db_web.dart`:
  osobna baza SQLite w pamięci, bez podpinania biblioteki konta.
- `lib/data/sync/study_share_guest_vfs.dart`: rejestruje domyślny
  `InMemoryFileSystem` przed otwarciem SQLite WASM gościa; nie używa
  IndexedDB konta. Regresja: `test/study_share_guest_vfs_test.dart`
  (unit) i `test/study_share_guest_database_test.dart` (Chrome, prawdziwy WASM).
- `lib/data/sync/study_share_web_assets.dart`: poprawna absolutna ścieżka
  modułu SQLite WASM przy bezpośrednim otwarciu zagnieżdżonego /share/UID;
  test `study_share_web_assets_test.dart`.
- `lib/features/library/presentation/library_screen.dart`: aktywna sesja
  i jej odzyskanie po ponownym uruchomieniu. Zmiana epoki remote sync
  odtwarza widok kanwy ze zaktualizowanego oryginału. Host blokuje
  odbiór rewizji w aktywnej edycji i publikuje wygląd z debounce 120 ms.
- `lib/data/sync/shared_edit_conflicts.dart`:
  `hasRejectedSharedEdits` sprawdza, czy serwer potwierdził wszystkie
  zmodyfikowane przez gościa obiekty (z ignorowaniem zmian niezależnych).
- `test/study_share_http_test.dart`: motyw i tło bez zmiany rewizji.
- `test/live_web_sync_service_test.dart`: ochrona aktywnego pisania hosta.
- `server/api/tests/test_study_shares_flow.py`: walidacja wyglądu
  i autoryzacja właściciela bez migracji SQL (`edit_clock`).
- `test/shared_edit_conflicts_test.dart`: odrzucone edycje tekstu,
  kreski i usunięcia oraz scalanie niezależnych obiektów.
- `test/shared_edit_delivery_test.dart`: współdzielone dokumenty nie mogą
  wrócić do natychmiastowego wysyłania pełnego snapshotu po każdym zapisie.
- `lib/data/sync/live_web_sync_service.dart`: 90 ms debounce zwykłego sync,
  120 ms dla współdzielonego dokumentu,
  bazowe snapshoty do trójstronnego scalania zmian właściciela.
- `lib/features/editor/state/editor_controller.dart`: parametr
  `saveDebounce` – 100 ms w sesji, domyślnie 2 s poza sesją.
- `lib/features/notebook/data/notebook_repository.dart`: kontrolowany
  import potwierdzonej aktualizacji serwera i brak cichego nadpisania
  niesynchronizowanej pracy.
- `server/api/app/routers/study_shares.py`: dostęp i zapisy gości
  tylko do jednego UID, sprawdzanie bazowych rewizji w historii serwera
  oraz ochrona przed wieloma sesjami tego samego dokumentu;
  WebSocket gościa akceptuje natywny brak `Origin` wyłącznie z ważnym
  ticketem, a obcy browser Origin nadal blokuje;
  mikrosekundowe pierwszeństwo i blokada po zakończeniu.
- `server/api/app/routers/sync.py`: właściciel edytuje przez te same
  zasady scalania; dziennik zdarzeń otrzymuje scalony dokument. Usunięcie
  oryginału atomowo odbiera dostęp do aktywnej sesji.
- `server/migrations/0005_study_share_edit_clock.sql`: trwały zegar
  rozstrzygania konfliktów.
- `server/migrations/0006_change_events_document_revision.sql`:
  indeks historycznych rewizji służący walidacji wspólnej bazy zmian.
- `test/study_share_http_test.dart`: kontrakt HTTP gościa i odcięcie,
  przedłużanie i natychmiastowe żądanie zakończenia przed synchronizacją.
- `test/study_share_guest_socket_test.dart`: kody WebSocket oznaczające
  trwałe odebranie dostępu (bez nieskończonego reconnect).
- `test/live_web_sync_service_test.dart`: powrót zmian gości do
  oryginału właściciela, bez konfliktowych kopii bez potrzeby.
- `server/api/tests/test_study_shares_flow.py`: REST/WebSocket,
  edycja, izolacja, walidacja bazowych snapshotów, zapisy właściciela
  w feedzie, usunięcie oryginału, pojedyncza sesja i konflikty.
- Uwaga: outbox zapisuje ostatni niepotwierdzony snapshot per link;
  testy środowiskowe i wdrożenie nadal wymagają wykonania.
  Nie usuwać oznaczenia WIP.


### Stronicowanie konta i ochrona pamięci (2026-11-02)

- `lib/data/sync/live_web_sync_service.dart`: bootstrap wznawiany przez `next`
  oraz feed zmian przez `hasMore`, z kompatybilnością dla starszych API.
  Jedna odpowiedź może mieć 32 MiB przy dużej notatce. Pierwszy kursor
  bootstrapu zachowuje się do pobrania dalszych zmian REST.
- `lib/data/backup/remote_backup_service.dart`: recovery odczytuje komplet
  stron bootstrapu przed odtwarzaniem starego snapshotu.
- `test/sync_pagination_test.dart` i
  `test/account_backup_recovery_regression_test.dart`: wielostronicowe
  pobieranie, nieprzywracanie skasowanych dokumentów.
- `server/api/app/routers/sync.py`: maksymalnie 5 rekordów i miękki limit
  8 MiB na stronę; `server/api/tests/test_sync_pagination.py`.
- `server/api/app/routers/backups.py`: serializacja kosztownej finalizacji
  backupów, test `test_backup_finalization_memory.py`.
- `server/api/app/routers/study_shares.py`: zakończenie Share wysyła `ended`
  również po błędzie sprzątania prywatnego PNG; regresja
  `test_share_revoke_cleanup.py`.

## Synchronizacja kalendarza między urządzeniami

- `lib/features/planner/state/study_planner_controller.dart`:
  `StudySession.modifiedAt`, `syncRecords`, `applyRemoteRecords`,
  trwałe `tombstones` i zapis v2; potwierdzone zdalne usunięcie
  zastępuje lokalną edycję mimo różnic zegarów i nie dopuszcza odtworzenia UID.
- `lib/data/sync/planner_sync_service.dart`: stronicowane pobieranie,
  scalanie per ID według UTC i wysyłanie usunięć mimo późniejszej daty
  edycji ze starszego urządzenia. Nie wysyła lokalnych wpisów, jeśli
  serwer zwrócił tombstone.
- `lib/data/backup/remote_backup_service.dart`: snapshot
  `study_planner.json` dołącza tylko nieznane UID, po pobraniu wszystkich
  stron `/v1/planner/entries`, również tombstones; nie nadpisuje aktualnych
  wpisów ani lokalnych usunięć. Czas weryfikacji nie ustala priorytetu.
- `test/account_backup_recovery_regression_test.dart`: regresje
  opóźnionego backupu wobec lokalnych i serwerowych tombstones oraz
  odzyskiwania niezależnych wpisów bez nadpisywania lokalnych edycji.
- `lib/app/app_scope.dart`: inicjalizacja, listener zapisu, wznowienie
  i okresowe uzgadnianie; `live_web_sync_service.dart`: `planner_changed`.
- `test/planner_sync_controller_test.dart`: przypadki offline,
  ponownego uruchomienia i rozstrzygania konfliktów.
- `server/api/app/routers/planner.py`,
  `server/migrations/0008_planner_entries.sql`: osobne rekordy,
  właściciel konta, trwałe usunięcia, powiadomienia WebSocket.

- `test/planner_sync_service_test.dart`: dwie instalacje i wspólny backend,
  dodanie, edycja, usunięcie, konflikt offline oraz usunięcie przy zegarze
  drugiego urządzenia przesuniętym o kilka godzin.

### Weryfikacja wyjścia i błędów (2026-11-02)

- `lib/app/app_scope.dart`: `didRequestAppExit` blokuje zwykłe zamknięcie
  zalogowanego konta do `RemoteBackupScheduler.ensureVerifiedForExit`.
  `_ExitGuardOverlay` pokazuje spinner oraz Retry backup przy porażce.
  Przy detached i Web hidden uruchamia awaryjny best-effort upload.
  Nie gwarantuje dokończenia HTTP po zabiciu procesu.
- `lib/core/error/one_shot_error_notice.dart`: śledzi nowe incydenty
  usług per instancja; `library_account_slot.dart` nie odtwarza
  zastanych wcześniej komunikatów po otwarciu dialogu.

- `docs/ETAP_0_STAN_WYJSCIOWY.md`: stan wyjściowy zapisu, usuwania, backupu i share oraz granice weryfikacji.

### Ink Share v2 (2026-11-03)

- `lib/data/sync/share_ink_edit_adapter.dart`:
  `ShareInkEditAdapter.plan` przekłada ukończone zmiany stroke na
  create/delete/transform/set/reorder, a `decode` waliduje remote ink.
  Adapter jest opt-in i nie zastępuje jeszcze starego zapisu Share.
- `lib/data/sync/share_text_edit_adapter.dart`:
  plain-text CRDT; formatowane delty Quill wymagają osobnego protokołu.
- `lib/data/sync/operation_text_sequence.dart`:
  copy-on-write atomów i rygorystyczna walidacja rankingu.
- `test/share_ink_edit_adapter_test.dart` oraz testy sekwencji tekstu:
  ink, gumka, transformacje, kolor, z-order, Unicode, wsady i korupcja.

- `lib/data/sync/operation_gateway.dart` i
  `lib/data/sync/sync_engine.dart`: opcjonalny ulotny `guestTicket` dla
  REST/WebSocket operacji v2, parowany z `shareId`; nigdy nie używa
  JWT konta gościa zamiast biletu. Regresje w
  `test/operation_gateway_test.dart`.

- `SyncEngine.onShareEnded`: powiadomienie po WebSocket `ended` lub
  HTTP 410 zatrzymuje wznawianie sesji i zachowuje outbox.
  Regresja: `test/sync_engine_test.dart`.


## Etapy 7–8 (2026-11-03, infrastruktura opt-in)

- `lib/core/storage/storage_namespace_manager.dart`:
  `StorageNamespace` tworzy osobne przestrzenie Local, konto i gość
  Share (SQLite, IndexedDB, pliki, assety); `StorageNamespaceManager`
  serializuje przejścia i unieważnia opóźnione żądania. Test:
  `test/storage_namespace_manager_test.dart`.
- `lib/core/storage/text_storage_io.dart` i
  `lib/data/drift/notes_database_connection_io.dart`: obsługują bezpieczne
  zagnieżdżone katalogi baz/plików. Stare dane `notes.sqlite` nadal
  pozostają domyślną przestrzenią uruchomienia.
- `lib/data/sync/planner_revision_ledger.dart`:
  per wpis CAS, podpis treści bez `modifiedAt`, reguły tombstones
  i wykrywanie konfliktów. `PlannerSyncService(useRevisions: true)`
  używa opt-in `/v2/planner/entries`, potwierdza trwałe rewizje
  i chroni niedostarczone edycje. Testy:
  `test/planner_revision_ledger_test.dart`,
  `test/planner_revision_sync_service_test.dart`.
- `study_planner_controller.dart`: `revisionAuthoritative` dla
  zatwierdzonych rekordów v2, dotychczasowa ścieżka v1 bez zmiany.
- `lib/data/sync/operation_protocol.dart`: nowe `task.create/set/move/delete`
  w domenie `@library`; test `test/operation_protocol_test.dart`.
- Backend kanoniczny `NaNotateczki-serwer/main`: migracje
  `0011_planner_revisions.sql`, `0012_task_tombstones.sql`,
  `planner_v2.py` (CAS + idempotencja), projekcja `folder.*`
  z walidacją drzewa i `task.*` per UID. W `server/` jest lustro.
- `docs/ETAP_7_8_STORAGE_PLANNER.md`: granica bezpieczeństwa.
  **Nie włączać namespaców przy loginie ani sync planera v2 przed
  bezstratną migracją etapu 11.** Stage 7 import/kopiowanie i aktywny
  sync folderów/zadań zależą od tej migracji. Testy nieuruchomione
  w środowisku bez SDK.

## Etap 9 — backup i odtwarzanie (częściowo wdrożony)

- `docs/ETAP_9_BACKUP_RECOVERY.md`: zasady snapshotów z checkpointem,
  zidentyfikowane granice starego protokołu, scenariusze weryfikacji.
- Serwer kanoniczny: `api/app/routers/backups.py` w
  `NaNotateczki-serwer/main`, z testem
  `api/tests/test_backup_validation.py` (weryfikacja właściciela i kursora).
- Replay operacji v2 i snapshoty per dokument pozostają zablokowane do
  migracji etapu 11; testy E2E to etap 12.


## Etap 10 — koordynacja wyjścia i wylogowania (2026-11-03)

- `lib/core/storage/shutdown_coordinator.dart`: 30 s na lokalny flush,
  sync, verified backup, stop usług i koniec sesji; awarie lokalnego
  zapisu blokują także offline logout.
- `lib/app/app_scope.dart`: osłona exit Retry / Cancel / Exit offline,
  niezwolniony gest lub zapis blokuje zamknięcie do czasu utrwalenia.
- `lib/features/library/presentation/library_account_slot.dart`:
  blokada zmiany konta przed stop() writerów; brak fałszywego retry po
  skutecznie wykonanym lokalnym logout bez łączności z serwerem.
- `lib/data/sync/account_session_controller.dart`: usunięcie refresh
  tokenu musi się zakończyć sukcesem przed zmianą sesji.
- `test/shutdown_coordinator_test.dart`,
  `test/account_session_controller_test.dart`: regresje timeout,
  kolejność stop, awaria keyringu i offline revoke.
- `docs/ETAP_10_SHUTDOWN.md`: ograniczenia platformowe i weryfikacja.

## Etap 11 — weryfikowany staging danych legacy (bez cutover)

- `tool/stage11_migrate.py`: offline, Linux/native; SHA-256,
  zgodność powiązania konta, zachowanie oryginalnej SQLite i WAL
  w `legacy_sqlite/`, staging do `local/` lub `accounts/<hash>/`,
  pełne sprawdzenie listy plików, manifest staged-not-activated.
- `tool/test_stage11_migrate.py`: 19 regresji m.in. staging konta,
  profile, nowe źródła, osierocone assety, symlinki, resume i WAL.
- `docs/ETAP_11_MIGRATION.md`: **produkcja v1→v2 nadal nieaktywna**.
  AppScope i Web nie wykonują cutover; wymagane etapy 7/12/13 i migracja
  serwerowego protokołu z trwałą blokadą starszych writerów.

## Etap 12 — nowe testy, akceptacja nadal otwarta (2026-11-03)

- `test/task_tombstone_migration_test.dart`: regresje SQLite v6,
  trwałe task.delete i migracja v5 → v6, także kompatybilność
  stagingu etapu 11.
- `test/production/stage12_operation_stress_test.dart`: 1000 dopisków,
  1000 usunięć, odtworzenie SQLite po restarcie, outbox i tombstones,
  retransmisja ACK oraz rollback i ciągłość aktora.
- Kanoniczny backend `NaNotateczki-serwer/main`:
  `api/tests/test_stage12_real_stack.py`,
  `compose.stage12.yaml` i `scripts/run-stage12-real.sh`.
  Izolowany PostgreSQL 17, prawdziwe routery FastAPI/WebSocket,
  operacje i feed, share/revoke, delete/transform, tekst CRDT,
  Undo/Redo, rollback batcha i izolacja kont.
- `integration_test/stage12_live_api_test.dart`: opt-in dwa silniki
  Flutter synchronizujące dopiski i usunięcia z prawdziwym API v2 przez
  lokalny serwer HTTP i PostgreSQL, bez testu rzeczywistych gestów.
- Etap 13: `server/migrations/0013_account_protocol_fence.sql`,
  `server/api/app/account_protocol.py`, `server/scripts/stage13-activate-empty-canary.sh`
  — trwałe, domyślnie v1, nieodwracalne przełączenie WYŁĄCZNIE pustego
  konta testowego; blokada HTTP 409 zapisu v1 na koncie v2 i odwrotnie.
  Również `server/api/app/routers/study_shares.py` odrzuca stary PUT
  gościa po przełączeniu właściciela. Regresje:
  `server/api/tests/test_account_protocol_fence.py`,
  `server/api/tests/test_share_protocol_fence.py`,
  `server/scripts/tests/test_stage13_canary_activation.py`.
  Runner Flutter E2E zakłada testowego właściciela v2 w disposable PostgreSQL.
- `docs/ETAP_12_TESTS.md`: uruchomienie i otwarte kryteria. Testy
  backendowe nie zastępują Flutter↔API v2 testów dwóch urządzeń ani
  nieaktywnego cutover etapu 11; brak SDK/Dockera nie oznacza zaliczenia.


## Etap 14 — finalizacja warunkowa (2026-11-04)

- `lib/app/unsupported_account_protocol_screen.dart`: po wykryciu
  nieobsługiwanego konta v2 blokuje edycję w starszym kliencie, zachowuje
  lokalne dane i udostępnia wylogowanie. Typowany błąd
  `AccountProtocolNotSupported` w `api_client.dart` odróżnia to od
  awarii sieci. Regresje: `test/api_client_test.dart` i
  `test/unsupported_account_protocol_screen_test.dart`.

- docs/ETAP_14_FINALIZACJA.md: inwentarz active v1 i opt-in v2,
  reguły bezpiecznego usuwania legacy oraz nierozwiązane bramki
  etapów 11–13. Etap 14 jest częściowy, bez produkcyjnego cutover.
- server/scripts/stage13-status.sh: poprawiono delimiter DO $$ / END $$;
  kanoniczna wersja w NaNotateczki-serwer/main.
- NaNotateczki-serwer/main: scripts/stage14-retirement-audit.sh wykonuje
  wyłącznie odczytowy raport PostgreSQL, zwraca 75 przy blokadzie;
  scripts/tests/test_stage14_retirement_audit.py obejmuje regresję
  poprawnego SQL i fail-closed audytu. Nowe pliki nie są kopiowane
  do lustra server/, ponieważ canonical backend jest źródłem prawdy.
- LiveWebSyncService i StudyShareGuestEditor wciąż obsługują realny v1.
  SyncEngine, ShareOperationProjection i importery legacy muszą zostać
  zachowane. Nie usuwać v1, timera, debounce ani lustra backendu
  przed pełną migracją namespace + E2E + odcięciem starych klientów.

- Kanoniczny serwer: `scripts/stage14-reset-test-account-v2.sh` —
  atomowy destrukcyjny reset wyłącznie wskazanego konta testowego,
  bez zmiany jego loginu i hasła. Guardy API na v2 blokują stare
  mutacje settings/planner/share/backup. Lustro czterech zmienionych
  routerów jest zgodne z repo kanonicznym. Regresje serwerowe:
  `scripts/tests/test_stage14_reset_test_account.py`,
  `api/tests/test_stage14_reset_legacy_write_fences.py`.
  Bez pełnego przełączenia edytora Flutter na SyncEngine
  reset pozwala jedynie na próby API v2, nie na użytkowanie aplikacji.

- `ApiClient.ensureLegacyAccountProtocol` i `AppScope._startAccountSync`:
  przed recovery i legacy sync sprawdza `GET /v1/auth/protocol`;
  konto v2 nie może uruchomić klienta v1. Jedynie 404 starego API
  zachowuje kompatybilność, inne błędy nie przełączają writera.
  Regresje: `test/api_client_test.dart`; backend: auth.py
  kanoniczny i mirror, `test_account_protocol_fence.py`.
