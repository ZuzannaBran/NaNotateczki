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
