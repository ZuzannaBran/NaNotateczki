# Etap 10 — zamykanie, wylogowanie i zachowanie lokalnych zmian

Status: po pakiecie 7 z 2026-11-12 — wspólny pipeline dla logout,
shutdown i wznowienia. Nie stanowi produkcyjnej aktywacji etapu 11.

## Zmiany

- Wspólny ShutdownCoordinator wykonuje kolejno: lokalne utrwalenie,
  synchronizację, zweryfikowany backup, zatrzymanie usług i wylogowanie.
  Obowiązuje limit 45 s dla AppScope, nie osobne nieograniczone limity na HTTP.
- Zamknięcie aplikacji sprawdza lokalne zapisy, ink i aktualne operacje
  zapisu; po błędzie daje Retry / Cancel. Wyjście bez sieci pojawia się
  tylko po poprawnym utrwaleniu lokalnych zmian.
- LiveWebSyncService.flushPersistedOutbox ponownie sprawdza wynik
  trwałego zapisu kolejki. Błąd ukryty wcześniej przez obsługę
  błędów w tle teraz blokuje zakończenie sesji. Regresja w
  test/live_web_sync_service_test.dart.
- Dialog wylogowania po błędzie zdalnym udostępnia Retry, Stay signed in
  lub Log out offline. Offline nie wysyła notebooka jako backupu i nie
  kasuje lokalnej kolejki; początkowy outbox pozostaje powiązany z
  dotychczasowym kontem.
- Przed usunięciem lokalnych poświadczeń live sync i backup muszą
  zatrzymać aktywnych writerów. Jeżeli stop się nie kończy, wylogowanie
  odmawia przejścia do następnego konta.
- Zdalne odwołanie sesji podczas zwykłego wylogowania ma maksymalnie
  5 sekund. Brak dostępnego serwera nie oznacza automatycznego
  odwołania istniejącego tokenu na serwerze.
- Testy: test/shutdown_coordinator_test.dart — kolejność, timeout,
  serializacja współbieżnych prób, awarie lokalnego zapisu, brak sieci,
  zatrzymanie writerów przed usunięciem sesji.

## Granice i dalsze prace

- Dla logout offline ciągłe żądania sieciowe mogą nadal działać po
  wystąpieniu TimeoutException. Shutdown wymaga await stop(), zanim
  oczyści poświadczenia; jeśli stop nie odpowiada, użytkownik pozostaje
  zalogowany. Nie obiecywać gwarantowanego zamknięcia procesu przez OS.
- Stage 11/13 nadal muszą włączyć produkcyjny cutover. Separacja Local /
  konto A / konto B już używa namespace; sam koordynator nie zastępuje
  testów migracji historycznych danych.
- Nie aktywuje globalnie v2 i nie usuwa historii.
- Wymagane testy Flutter/Dart, multi-account, sztuczny brak sieci,
  restart podczas zapisu oraz prawdziwy serwer PostgreSQL/WebSocket.
  Przebieg GitHub Actions uruchamia się na jawne żądanie użytkownika.

Na serwerze nie ma teraz poleceń do wykonania.

## Domknięcie bezpieczeństwa tokenu

- Wylogowanie nie przełącza już sesji przed pomyślnym usunięciem refresh
  tokenu z magazynu sekretów. Błąd keyringu pozostawia konto aktywne;
  możliwa jest bezpieczna ponowna próba.
- Niepowodzenie serwerowego revoke nie przywraca lokalnego tokenu.
  Jeśli token został już usunięty, interfejs nie pokazuje fałszywego
  dialogu sugerującego, że użytkownik nadal jest zalogowany.
- Regresje w test/account_session_controller_test.dart obejmują
  awarię usuwania poświadczeń i brak sieci podczas revoke.

---

## Uzupełnienie pakietu 7 — 2026-11-12

## Kontrakt

1. Gest musi zostać zakończony przed flush. Zapis musi zakończyć wszystkie
   lokalne future writerów. Nie twórz nowej operacji z samego autosave.
2. Outbox SQLite, UUID, actorSeq i checkpoint należą do namespace konta.
   Nigdy nie kasuj ich przy błędzie HTTP, backupu lub zamknięciu.
3. Po lokalnym zapisie spróbuj synchronizacji v2 (również outbox deferred).
   Następnie zsynchronizuj planner i ustawienia konta oraz zweryfikuj backup.
4. Przed zmianą loginu zamknij WS, odczekaj HTTP in-flight, zatrzymaj
   schedulery i dopiero potem zmień credentials / namespace.
5. Przy błędzie lub przekroczeniu limitu 45 s pokaż etap, udostępnij
   ponowienie. Jeśli lokalny zapis powiódł się, użytkownik może wybrać
   bezpieczne wylogowanie/wyjście offline. Jeśli transport nie może zostać
   w pełni zatrzymany, nie przełączaj namespace. Przy lokalnym błędzie
   opcja offline jest zabroniona.
6. Logowanie na to samo konto zachowuje SQLite, kolejkę operacji i ich
   pierwotne identyfikatory; `SyncEngine` podejmuje delivery/replay.
   Nie włączaj produkcyjnego v2 przed etapem 11.

## Regresje automatyczne

- `test/shutdown_coordinator_test.dart`: etapy, timeout, wielokrotne
  wywołanie, offline, zakaz wylogowania przed ukończeniem stop.
- `test/account_session_controller_test.dart`: nieudany drenaż,
  wylogowanie offline, ponowny login po restarcie, dysk pełny,
  brak odwołania tokenu przy niezapisanych operacjach.
- `test/planner_sync_service_test.dart` i
  `test/account_settings_sync_service_test.dart`: zamknięcie czeka
  na stare żądania, nie modyfikuje nowego namespace.
- `test/account_protocol_editor_gate_test.dart` i
  `test/unsupported_account_protocol_screen_test.dart`: przyciski
  offline pojawiają się tylko po bezpiecznym lokalnym flush.
- `test/cross_platform/save_and_exit_test.dart` i
  `test/sync_engine_test.dart`: zapis gestu, outbox, replay po restarcie.

## Akceptacja na rzeczywistych urządzeniach (niezautomatyzowana)

1. Linux, Windows i macOS: rozpocznij rysowanie, poproś o zamknięcie,
   dokończ gest. Sprawdź komunikaty etapu, wznowienie i brak duplikatów
   po restarcie.
2. Android i iOS: wyjdź do tła, przywróć aplikację; sprawdź zapisany
   ostatni zakończony gest. Zabij proces systemowo w chwili rysowania:
   zatwierdzone operacje muszą pozostać, lecz niedokończony gest nie
   jest objęty gwarancją OS.
3. Web: zamknij kartę podczas aktywnego uploadu i uruchom aplikację
   ponownie. Zweryfikuj trwałość IndexedDB i powtórzenie zaległego outboxu.
   `beforeunload` nie gwarantuje asynchronicznego backupu.
4. Konto A (v2): przerwij sieć przy synchronizacji, wyloguj się offline.
   Zaloguj na konto B i sprawdź brak danych A. Wróć do A, przywróć
   sieć i sprawdź zgodność operacji, UID, actorSeq, assetów, planera,
   folderów i checkpointu z urządzeniem nr 2.
5. Przy wywołaniu logout symuluj: brak dysku, HTTP timeout, błąd ACK,
   zablokowany upload i brak zaufanego backupu. Każda awaria musi mieć
   jawny komunikat i możliwość ponowienia bez utraty danych.
6. Na dwóch rzeczywistych urządzeniach jednocześnie edytuj dokument,
   wyloguj jedno w trybie offline, zaloguj ponownie i potwierdź brak
   utraty/duplikatów na obu urządzeniach.

Zaliczanie macierzy CI nie oznacza wykonania powyższej akceptacji ręcznej.
