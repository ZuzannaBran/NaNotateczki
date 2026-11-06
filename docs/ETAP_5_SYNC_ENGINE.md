# Etap 5 — silnik synchronizacji operacji v2

## Catch-up pierwszej subskrypcji i reconnect — 2026-11-06

Potwierdzenie `authenticated` uruchamia teraz tę samą ścieżkę REST co
`operations_changed`. Domyka wyścig między początkowym GET a subskrypcją
i odzyskuje zmiany po przerwie socketu bez czekania na polling. Kursor
nadal zmienia się wyłącznie po transakcyjnym zatwierdzeniu feedu.
`test/sync_engine_test.dart` używa prawdziwego lokalnego WebSocket,
jawnie opóźnia odpowiedź auth do zakończenia pierwszego GET i sprawdza
dwa połączenia silnika bez dalszej wskazówki. Regresja wymaga Flutter CI.


Status: **silnik i transport zapisane; nie jest to przełączenie produkcyjne**.
Włączenie dla istniejących notatników wymaga kontrolowanej migracji z etapu
11. Serwer v2 celowo odrzuca zapis do UID zarządzanego przez v1, więc
automatyczne włączenie w `AppScope` bez migracji groziłoby utratą zmian.

## Implementacja

- `SyncEngine` przyjmuje `OperationStore`, transport, stabilne `actorId`,
  unikalny `checkpointScope` magazynu i callback projekcji.
- `writeLocal` atomowo zapisuje operację, outbox i projekcję w SQLite.
  Interfejs może wcześniej pokazać gest optymistycznie, ale nie powinien
  potwierdzać trwałego zapisu przed zakończeniem transakcji.
- Wysyłka zachowuje `actorSeq`, stosuje paczki do 50 operacji i 800 KiB
  payloadu oraz maksymalnie 3 niezależnych aktorów jednocześnie.
  Wyjście powyżej 1 MiB jest dodatkowo blokowane w transporcie.
- Odpowiedź ACK jest walidowana w całości przed usunięciem pozycji z outboxu.
  Przerwane HTTP może być ponowione z tymi samymi `operationId`.
- Odbiór przez stronicowane `GET /v2/operations` korzysta wyłącznie z
  trwałego kursora. Kursora nie podnosi się do ACK własnego POST.
  Echo własnej operacji nie uruchamia ponownie projekcji.
- Kursor globalny przesuwa się wyłącznie do ostatniej **ciągłej** pomyślnie
  odtworzonej pozycji. Późniejsze, niezależne dokumenty mogą zostać
  utrwalone wcześniej, a przy ponowieniu są rozpoznawane po `operationId`.
- Callback projekcji otrzymuje **wszystkie** lokalne operacje oczekujące dla
  dokumentu, również z odroczonym retry. Implementacja konkretnego
  edytora ma łączyć zmiany per ID/pole i rebazować te operacje na bieżącym
  stanie, nie podmieniać całego dokumentu snapshotem.
- WebSocket v2 wysyła tylko wskazówkę `operations_changed`.
  REST zawsze weryfikuje stan po reconnect, na foreground i co 45 sekund.
- Błędy sieci, 409 `CAUSAL_GAP` i brak ACK zachowują outbox. Retry ma
  wykładniczy backoff z jitterem; błędy nieobsługiwanych operacji nie
  usuwają danych. Nieudana operacja opóźnia dalsze ruchy jej aktora, nie
  wszystkich innych aktorów.
- Dla już zaakceptowanej operacji zdalnej dotyczącej usuniętego UID
  SQLite zachowuje wpis historii, ale nie odtwarza obiektu.
- Lokalny `actorSeq` i frontier obserwowanych aktorów są odczytywane
  w jednej transakcji przed utworzeniem ruchu.
- `stop()` anuluje timery i socket, czeka na aktywny przebieg oraz
  unieważnia spóźnione odpowiedzi przez generation token.
- 401 może uruchomić przekazany callback `refreshAuthentication` i
  jednokrotnie ponowić to samo żądanie.

## Integracja po przygotowaniu migracji

1. Zainicjalizować trwały `actorId` i odizolowany `checkpointScope`
   we właściwym magazynie konta, Local albo Share.
2. Stworzyć `HttpOperationGateway(apiClient)` i `SyncEngine`, w przypadku
   konta z `refreshAuthentication: session.refresh`.
3. Zastąpić wywołania mutujące SQLite w edytorze transakcjami
   `engine.writeLocal(..., apply: ...)` oraz dodać domenowy reducer
   `applyRemote` aktualizujący konkretne rekordy, z rebase outboxu.
4. Dopiero po migracji UID odłączyć stare `LiveWebSyncService` / v1 writer
   dla tych dokumentów. Nigdy nie uruchamiać obu writerów dla tego samego UID.
5. Share ma wykorzystać ten sam silnik po wprowadzeniu odrębnego magazynu
   gościa i reducerów tekstu, assetów oraz gestów w etapie 6.
6. Ukończyć testy prawdziwego Flutter + PostgreSQL + WebSocket na dwóch
   urządzeniach, zanim zostanie przełączony produkcyjny ruch.

## Regresje dodane do repo

- `test/operation_store_test.dart`: causal frontier, tombstone no-op.
- `test/sync_engine_test.dart`: trwały optimistic commit, ACK utracony po
  zatwierdzeniu na serwerze, własne echo, rebase, błędna projekcja jednej
  pozycji przy poprawnej pozycji innego dokumentu, retry i actorSeq.
- `test/operation_gateway_test.dart`: JSON v2, Bearer, niepełne ACK,
  uszkodzony feed oraz prawidłowy kursor.

## Granice weryfikacji

W tym środowisku nie ma lokalnego SDK Flutter/Dart ani dostępu do kontenera
PostgreSQL użytkownika. Nie uruchomiono `dart analyze`, `flutter test`
ani testów E2E; nie traktować samych nowych testów jako zaliczonych.
Nie uruchomiono ręcznie GitHub Actions. Weryfikacja w kodzie obejmuje
zgodność pól z API v2 serwera i brak zmian w produkcyjnej ścieżce v1.

## Poprawki infrastruktury — 3 listopada 2026

- Walidacja `*.create` wymaga `value`, a `*.set` wymaga `properties`.
  Nieobsługiwane teksty i assety są odrzucane przed trwałym zapisem.
- ActorId w `SyncEngine` jest izolowany per namespace i dokument; obce
  dokumenty nie pojawiają się w zależnościach.
- Undo/Redo automatycznie zawiera `revertsOperationId` w zależnościach.
- SQLite v4 zachowuje tombstones i rozróżnia pageId.
- Nieudany pull nie blokuje push. Przy 409/413/422 w dużej paczce klient
  próbuje pierwszą operację, nie pomijając złej sekwencji.
- Retry wybiera najwcześniejszy termin, Share v2 przenosi nagłówek
  `X-Share-Id` i pole `shareId` w WebSocket.

**Niedokończone:** domenowe reduktory, migracja namespace, przełączenie
produkcji i testy prawdziwego Flutter/PostgreSQL/WebSocket.

## Status odrzuconych operacji — SQLite v5

Odrzucone permanentnie operacje HTTP 403/410/413/422 i nieprzyczynowe
409 nie są już bez końca retransmitowane. `operation_outbox` przechowuje
status `blocked` i `last_error`. Późniejsze operacje tego samego aktora
nie wyprzedzają zablokowanej; nadal można je odczytać przez
`pending(includeDeferred: true)` w celu ręcznej naprawy.

Przed produkcyjnym przełączeniem wymagana jest obsługa odzyskiwania
zablokowanego łańcucha w UI i test migracji v4 → v5 na istniejącej bazie.


## Audyt kontraktu v2 — 3 listopada 2026

- Serwer i Dart dopuszczają puste `value` dla nowego, pustego obiektu,
  lecz `properties` przy aktualizacji nie może być puste.
- Odrzucane są nieznane klucze payloadu oraz próby zmiany `id` lub
  `uid` przez operacje właściwości.
- Walidacja identyfikatorów klienta odrzuca znaki sterujące i zbyt długie
  ID przed trwałym zapisem; lokalny dziennik nie przyjmuje zależności
  wskazujących operację innego dokumentu.
- Zmiany są objęte testami regresyjnymi kontraktu i transakcji.
  Nie wykonano w tej sesji lokalnego Flutter/Dart ani E2E PostgreSQL.
  Przełączenie v1 na v2 nadal wymaga migracji namespace i reducerów.

## Uzupełnienie: odświeżanie widoku po zatwierdzeniu operacji

- `SyncEngine.onRemoteCommitted` jest wywoływane **po** zatwierdzeniu
  transakcji `OperationStore.applyRemote` i **przed** przesunięciem
  checkpointu odbioru. Wcześniejszy callback `applyRemote` służy wyłącznie
  do trwałych zmian w SQLite; nie może modyfikować kontrolera Flutter.
- Jeśli UI chwilowo nie może bezpiecznie nałożyć patcha (np. aktywny gest),
  callback powinien zgłosić błąd. Kursor zostanie zachowany, operacja
  odtworzona, a callback ponowiony. Powtórzenie musi być idempotentne.
- Echo własnej operacji, także po wcześniejszym ACK i ponownym odczycie
  starego kursora, jest rozpoznawane przez trwałą kolumnę
  `operations.source = local` i nie uruchamia odświeżenia UI.
- Po udanym pełnym przebiegu `lastError` zostaje wyczyszczony.
- Regresje: `test/sync_engine_test.dart` sprawdza odczyt zatwierdzonej
  projekcji w callbacku, ponowienie po odmowie UI oraz własne echo po ACK.

**Wciąż zablokowane:** produkcyjny `LiveWebSyncService` nie może zostać
zastąpiony dla UID v1 przed migracją z etapu 11. Potrzebne jest również
kontrolowane przełączenie writerów, separacja z etapu 7 oraz testy E2E
(etapy 12–13). Nowy callback nie jest sam w sobie przełączeniem produkcji.
