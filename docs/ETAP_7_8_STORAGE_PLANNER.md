# Etapy 7–8: zakres wdrożony i granica aktywacji (2026-11-03)

## Etap 7 — przestrzenie danych

- `StorageNamespace` rozdziela nazwy SQLite, ścieżki assetów i klucze
  plików Local, kont (SHA-256 identyfikatora) i gości Share.
- `StorageNamespaceManager` serializuje przełączanie. Generation fence
  odrzuca odpowiedzi związane z poprzednią przestrzenią.
- Natomiast aktualny `AppScope` **nadal otwiera legacy notes.sqlite**.
  Nowa przestrzeń nie jest włączona w produkcyjnym logowaniu.
- Istniejący zakaz logowania do drugiego konta w
  `AccountSessionController` **pozostaje celowo aktywny**. Usunięcie
  go bez rozdzielenia kontrolerów, plików i całej bazy grozi przeciekiem
  danych konta A do B.
- `text_storage_io.dart` obsługuje zagnieżdżone ścieżki, a natywne
  SQLite może otwierać pliki wewnątrz przestrzeni; nowa baza nie uznaje
  starego backupu za sygnał awarii.
- Tokeny nadal trzyma odrębny secure storage; nie kopiujemy ich z Local.

**Zależne od etapu 11:** migracja istniejących SQLite/WAL/assetów i
ustawień, jawny import kopiujący Local → konto, idempotentne mapy UID,
atomowe przełączenie AppScope/Providerów i wielokrotna zmiana kont.
Do zakończenia tej migracji nie wolno używać nowych przestrzeni do
otwierania istniejących bibliotek ani zdejmować blokady drugiego konta.

## Etap 8 — kalendarz, foldery i ustawienia

- Kanoniczny serwer dodaje `0011_planner_revisions.sql` i
  `/v2/planner/entries`: rewizje CAS, idempotencja `operationId`,
  tombstones, priorytet usunięcia i czas nadany przez serwer. Odpowiedzi
  nie zależą od `modifiedAt` ustawionego na urządzeniu.
- `PlannerRevisionLedger` przechowuje zaakceptowaną rewizję i sygnaturę
  treści bez pola `modifiedAt`; konflikt równoległych edycji nie usuwa
  lokalnego wpisu. `PlannerSyncService(useRevisions: true)` obsługuje
  ten kontrakt i klucz checkpointu wyłącznie w przestrzeni konta.
- Usunięcie zatwierdzone przez serwer wygrywa; niezapisane lokalne
  dopiski do usuniętego UID trafiają do `planner_conflicts.json`
  danej przestrzeni. Nie służy ono do ponownego utworzenia starego UID.
- Serwerowa projekcja operacji folderów v2 odrzuca osieroconych rodziców,
  cykle przenoszenia i usunięcie rodzica, który nadal ma dzieci.
- `task.create/set/move/delete` mają odrębne UID i tombstones, a migracja
  `0012_task_tombstones.sql` rozszerza dozwolone typy. Nadal nie są
  podłączone do produkcyjnej listy zadań.
- Dotychczasowa synchronizacja ustawień oparta na CAS pozostaje bez zmian.

**Zależne od etapu 11:** przełączenie istniejących planerów na v2 po
zainicjalizowaniu ledgerów z aktualnego serwera, przypisanie stabilnych
UID folderom i pełne zastąpienie `library_folders.json` operacjami
folderów/zadań. Obecne ścieżki folderów i zadania w JSON nie używają
jeszcze nowej projekcji. Bez tego nie można uznać całego etapu 8 za
funkcjonalnie zamknięty. W etapie 13 trzeba wykonać migrację SQL przed
włączeniem klienta v2.

## Testy dodane

- `test/storage_namespace_manager_test.dart`
- `test/planner_revision_ledger_test.dart`
- `test/planner_revision_sync_service_test.dart`
- `server/api/tests/test_planner_revisions.py`
- `server/api/tests/test_operation_projection.py` — cykle folderów

Testy automatyczne **nie zostały uruchomione w tej sesji**: środowisko
nie posiada SDK Flutter/Dart ani checkoutu repozytorium. Nie uruchamiano
GitHub Actions. Dla wdrożenia produkcyjnego wymagane są scenariusze
Local → A → B → A → Local, dwa urządzenia, retry po utracie ACK,
restart podczas migracji oraz test PostgreSQL (nie tylko mock HTTP).
