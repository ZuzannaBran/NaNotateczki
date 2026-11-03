# Etap 3 — lokalny dziennik operacji SQLite

## Zakres

Migracja Drift `schemaVersion: 2 → 5` jest addytywna. Obejmuje
kolejne migracje v2→v3, v3→v4 (tombstones z pageId) oraz v4→v5
(trwały status blocked w outboxie). Zachowuje
`notebook_rows`, `page_rows`, `text_block_rows`,
`image_block_rows` i `ink_stroke_rows`.

Nowe tabele: `operations`, `operation_outbox`, `operation_ack`,
`object_tombstones`, `sync_checkpoints`, `document_snapshots`,
`asset_references` i `operation_actor_state`.

Nowy kod w `lib/data/sync/operation_store.dart` zapisuje operację,
projekcję obiektu, monotoniczną sekwencję aktora i outbox w jednej
transakcji SQLite. Rzutowanie operacji i zapis plików assetów są obowiązkiem
wywołującego: projekcja musi pisać przez tę samą instancję
`NotesDatabase`, a asset musi być wcześniej trwale zapisany i mieć SHA-256.

Przy odbiorze z serwera operacja, projekcja i checkpoint są zatwierdzane
razem. ACK usuwa z outboxu wyłącznie potwierdzony identyfikator. Duplikat
tego samego envelope nie wykonuje ponownie projekcji. Snapshot nie może
mieć kursora starszego niż ACK tego dokumentu ani cofać najnowszego
zapisanego checkpointu snapshotu. Nadal wymaga to kompletnego dowodu
spójności projekcji i zdalnego checkpointu przed aktywacją produkcyjną. Tombstone blokuje
ponowne użycie ID usuniętego dokumentu, strony lub obiektu.

Natywne połączenie SQLite używa WAL i `synchronous=FULL`. Backup bazy
wymaga uwzględnienia WAL/SHM albo użycia spójnego SQLite backup API; nie
wolno kopiować samego `notes.sqlite` przy aktywnych zapisach.

`NotebookRepository` aktualizuje istniejące rekordy stron i obiektów
zamiast usuwać i odtwarzać wszystkie rekordy przy każdym zapisie. Rekordy
celowo usunięte są kasowane w tej samej transakcji.

## Granica aktywacji

To warstwa utrwalania dla nowego protokołu. Dotychczasowe ścieżki
`saveNotebook`, backup i share nadal korzystają z legacy snapshot-sync.
Nie wolno twierdzić, że każda obecna mutacja edytora trafia do
`operations` dopóki etap 5 nie przełączy wszystkich wywołań na
`OperationStore.writeLocal` z właściwymi payloadami i aktorem.

Nie uruchamiać wysyłania tego outboxu przez stare API v1. Stare snapshoty
nie są automatycznie przerabiane na zdarzenia. Operacji zatwierdzonych
nie usuwamy ani nie kompaktujemy bez zweryfikowanego snapshotu i gwarancji,
że żaden klient nie potrzebuje ich identyfikatorów/zależności.
Fizyczne usuwanie osieroconych assetów również wymaga bezpiecznego GC.

Tabele są utworzone za pomocą `customStatement` Drift (raw SQL), więc
nie zmieniają istniejących klas `Table` ani `notes_database.g.dart`.
Po przejściu na generowane mapowania tabel należy uruchomić
`dart run build_runner build` i dopiero wtedy zatwierdzić wynik.

## Weryfikacja lokalna

```bash
dart format lib/data/drift/notes_database.dart \
  lib/data/drift/notes_database_connection_io.dart \
  lib/data/drift/operation_schema.dart \
  lib/data/sync/operation_store.dart \
  lib/features/notebook/data/notebook_repository.dart \
  test/operation_store_test.dart \
  test/notebook_incremental_update_test.dart
dart analyze
flutter test test/operation_store_test.dart
flutter test test/notebook_incremental_update_test.dart
flutter test test/notebook_repository_test.dart
```

Testy zawierają rollback po błędzie projekcji, idempotentne ponowienie,
ACK, tombstones, checkpoint, immutable snapshot, restartowe migracje v2→v5
oraz wykrywanie niepotrzebnych DELETE podczas zapisu stron.

Dodatkowa ręczna próba crash-recovery: zapisać lokalne operacje offline,
wymusić zabicie procesu po zatwierdzonym COMMIT, uruchomić aplikację ponownie
i porównać `operations`, `operation_outbox` oraz widoczną projekcję.
Analogicznie wykonać crash przed COMMIT: nie może pozostać żadna z tych
trzech części. Po awarii systemu zbadać `PRAGMA quick_check`
i `PRAGMA foreign_key_check` na Linuxie, Androidzie oraz Web.
