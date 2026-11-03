# Etap 12 — weryfikacja zapisu i synchronizacji

Status: **zestawy testów dodane, niezaliczone środowiskowo; etap 12 NIE jest
zamknięty**. Nie włączać jeszcze produkcyjnego cutover v1 → v2.

## Zestawy uruchamialne

**SQLite/Flutter** — `test/production/stage12_operation_stress_test.dart`.
Prawdziwy plik SQLite przez Drift i 1000 dodanych oraz 1000 usuniętych
obiektów. Kontrola operacji, outboxu i tombstone po zamknięciu i ponownym
otwarciu SQLite, idempotentny ACK, atomowy rollback lokalnej projekcji i
brak zużycia `actorSeq` przy niepowodzeniu.

Na komputerze testowym z Flutter SDK:

```bash
flutter pub get
flutter test test/production/stage12_operation_stress_test.dart
flutter test test/operation_store_test.dart test/sync_engine_test.dart \
  test/share_operation_projection_test.dart
dart analyze
flutter test
```

**FastAPI/PostgreSQL/WebSocket** — kanoniczny serwer,
`api/tests/test_stage12_real_stack.py`, uruchamiany przez
`scripts/run-stage12-real.sh`. Używa prawdziwego PostgreSQL 17,
migracji 0001–0012, routerów FastAPI i połączeń WebSocket. Nie podmienia
bazy ani WebSocket mockiem. Obejmuje:

- 1000 kolejnych dopisków + 1000 usunięć i weryfikację feedu z kursorem;
- retransmisję tego samego `operationId`, fałszywą zmianę treści pod
  tym samym ID, niepełny batch i brakującą zależność;
- odwróconą kolejność pakietów w jednym batchu, rollback całej transakcji;
- konto A / konto B, izolację snapshotu i feedu mimo tego samego UID;
- równoczesne wstawienia tekstu w odwrotnej kolejności;
- dwóch aktorów Share, powiadomienia owner/guest WebSocket, konflikt
  delete/transform i natychmiastowy brak zapisu po revoke;
- Undo/Redo jako nowe operacje, usunięcie strony i zakaz
  późniejszego dopisania do tombstone;
- reconnect WebSocket i pobranie brakujących operacji przez REST.

Zestaw odmawia działania poza jawnie utworzoną, lokalną bazą
`nanotateczki_stage12_test`. Runner uruchamia **osobny, jednorazowy
kontener PostgreSQL**, osobny projekt Compose, port tylko na 127.0.0.1,
a po zakończeniu usuwa testowy serwer danych i środowisko Pythona.
Nie używa `/srv/nanotateczki`, bazy produkcyjnej ani jej wolumenów.

Uruchom **na komputerze testowym**, nie na serwerze produkcyjnym:

```bash
cd NaNotateczki-serwer
bash scripts/run-stage12-real.sh
# Krótsza weryfikacja bez 2000 operacji:
bash scripts/run-stage12-real.sh --quick
# Pełny test dwóch klientów Flutter przez rzeczywiste API/WS/SQL:
NN_STAGE12_FLUTTER_ROOT=../NaNotateczki bash scripts/run-stage12-real.sh
```

Wymagane: Docker Compose v2, Python 3 z `venv`, dostęp do pakietów
Pythona i obrazu `postgres:17-alpine`. Jeśli brakuje tych zależności,
uruchomienie kończy się błędem — nie traktować go jako PASS.

W teście Share v2 bilety i sesję tworzy bezpośrednio izolowana baza,
ponieważ publiczne utworzenie sesji dotyczy jeszcze dokumentów v1.
To **nie** potwierdza ścieżki host „Create link” → guest v2 ani migracji
istniejących sesji. Nie włączać bez tego przełączenia w produkcji.

## Otwarta macierz akceptacyjna

| Grupa planu | Automatyzacja | Nadal konieczne |
| --- | --- | --- |
| A — zapis | SQLite + PostgreSQL: 1000+1000, ACK, rollback | asset disk-full, backup/import równoległy z edycją, crash w momencie COMMIT |
| B — Share | operacje/tombstones, tekst CRDT, WebSocket/reconnect, revoke | prawdziwy Flutter host + guest, opóźnienia, gesty i brak migania |
| C — konta | backend A/B i wcześniejsze testy namespace | pełny Local → A → B → A → Local w uruchomionej aplikacji, import dwukrotny |
| D — awarie | rollback SQLite, błędy REST, reconnect | kill procesu / DB, pełny dysk, rollback migracji, backup historyczny |
| E — platformy | natywny Flutter test, backend E2E | Linux, Windows, macOS, Android, iOS, Web i testy krzyżowe na urządzeniach |

Testy starszych modułów (backup, migracja 11, planner, shutdown, share,
operacje) pozostają wymagane. Nie zostały automatycznie uruchomione samym
zapisaniem nowych testów.

## Naprawiony brak z wcześniejszych etapów

Zidentyfikowano niespójność: serwer migracją 0012 akceptował
`task.delete`, ale lokalna SQLite v5 dopuszczała tombstones tylko
dla document/page/object/folder. `OperationStore` nie uwzględniał
`OperationTarget.task`. Wdrożono SQLite v6: nowa kategoria
`task` w tabeli, migracja zachowująca stare rekordy, obsługa
usuwania i ochrony przed ponownym użyciem UID, regresje
`test/task_tombstone_migration_test.dart` dla nowej bazy i
aktualizacji v5 → v6. Etap 11 rozpoznaje teraz pliki z `user_version=6`.

Zmiana dotyczy tylko lokalnego schematu SQLite aplikacji.
Nie dodawano nowej migracji SQL backendu, bo
`0012_task_tombstones.sql` już to obsługuje.

## Blokery do pełnego zaliczenia

1. Etap 11 pozostawia dane w stanie `staged-not-activated`; publiczny
   cykl migracji i cutover dla istniejących kont nadal nie jest aktywny.
2. Dodano `integration_test/stage12_live_api_test.dart` (dwa rzeczywiste
   silniki Flutter + REST v2 + PostgreSQL + WebSocket), uruchamiane przez
   `NN_STAGE12_FLUTTER_ROOT`; wyniku jeszcze nie zweryfikowano. Nadal brak
   kontrolowanego scenariusza dwóch urządzeń z obserwacją migania i gestów.
3. Wymagane są kontrolowane testy uszkodzenia assetu, braku miejsca,
   restartu serwera w trakcie COMMIT, starego backupu po usunięciu UID i
   przerwanej migracji. Wykonywać je wyłącznie na danych testowych.
4. Matryca platform oraz testy dwóch prawdziwych urządzeń pozostają
   do rzeczywistego wykonania. Wyniki należy odnotować osobno dla
   każdego OS i wariantu połączenia.

Nie uruchamiać GitHub Actions bez polecenia użytkownika. Nie wdrażać
tych testów ani zmian protokołu na produkcyjnym serwerze. Etap 13
wymaga osobnej procedury backupu, migracji i kontrolowanego rolloutu.
