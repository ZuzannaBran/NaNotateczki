# Etap 10 — zamykanie, wylogowanie i zachowanie lokalnych zmian

Status: koordynator i ścieżki wylogowania/zamykania połączone.
Nie stanowi to produkcyjnej aktywacji migracji etapów 7/11.

## Zmiany

- Wspólny ShutdownCoordinator wykonuje kolejno: lokalne utrwalenie,
  synchronizację, zweryfikowany backup, zatrzymanie usług i wylogowanie.
  Obowiązuje łączny limit 30 s, nie osobne nieograniczone limity na HTTP.
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
- Stage 11/13 nadal muszą przełączyć bazę, pliki planera i namespace
  między Local / konto A / konto B. Dopóki app używa notes.sqlite,
  sam koordynator nie gwarantuje pełnej izolacji przestrzeni.
- Żaden dodatkowy kod nie przełącza operacji v2 ani nie usuwa historii.
- Wymagane testy Flutter/Dart, multi-account, sztuczny brak sieci,
  restart podczas zapisu oraz prawdziwy serwer PostgreSQL/WebSocket.
  Nie wykonano ich w środowisku bez SDK. Nie uruchamiać GitHub Actions.

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
