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

`writeLocalBatch` zatwierdza jeden złożony gest (np. zaznaczenie z wieloma
obiektami) atomowo: wszystkie projekcje, actorSeq i wpisy outboxu albo
wszystkie są wycofywane. To fundament przyszłego `EditorOperationBridge`,
a nie jeszcze przełączenie edytora produkcyjnego.

Przy odbiorze z serwera operacja, projekcja i checkpoint są zatwierdzane
razem. ACK usuwa z outboxu wyłącznie potwierdzony identyfikator. Duplikat
tego samego envelope nie wykonuje ponownie projekcji. Snapshot nie może
mieć kursora starszego niż ACK tego dokumentu ani cofać najnowszego
zapisanego checkpointu snapshotu. Nadal wymaga to kompletnego dowodu
spójności projekcji i zdalnego checkpointu przed aktywacją produkcyjną. Tombstone blokuje
ponowne użycie ID usuniętego dokumentu, strony lub obiektu.
Referencje nowych assetów używają niekolizyjnego klucza strony i obiektu
w istniejącej kolumnie TEXT. Stare referencje bez strony pozostają zachowane;
nie wolno ich automatycznie usuwać podczas importu ani GC.

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

## Granice przyczynowości

Zależności automatycznie obserwowanych aktorów są redukowane wyłącznie,
gdy zapisany łańcuch jednoznacznie dowodzi, że wcześniejszy frontier
jest osiągalny z późniejszego. Jawne zależności, poprzednik aktora
i `revertsOperationId` nigdy nie są usuwane. Ponad 256 **niezależnych**
frontierów nadal wymaga rozszerzenia protokołu i nie jest obcinane:
operacja lokalna nie przechodzi do dziennika zamiast utraty przyczynowości.

## Przygotowanie przejścia edytora (częściowe)

Dodano `EditorOperationBridge`, który przekłada zatwierdzoną zmianę
strony na `LocalOperationDraft` używając istniejących adapterów ink/tekst.
`SyncEngine.writeLocalBatch` zapisuje cały gest w jednej transakcji
przed planowaniem wysyłki i waliduje wszystkie payloady zawczasu.

Most obsługuje teraz zweryfikowane embedy Quill oraz wymianę
obrazu/PDF przy znanym starym asset ID.
Konwersja Quill zachowuje końcowy znak `\\n` jako atom CRDT, choć
edytor przechowuje przycięte `TextBlock.text`; rozbieżna treść
Delta nadal blokuje operację. Sekwencja osadzonego zasobu to
`object.create → asset.attach → text.insert`; usunięcie referencji
poprzedza `asset.detach`. Wymiana istniejącego obrazu używa
`asset.attach → object.set(assetId) → asset.detach`. Nieweryfikowany
zasób, błędny MIME, zewnętrzny URL oraz brak trwałego ID starego assetu
powodują odmowę planowania całego gestu. `verifiedAssets` jest
indeksowane po ID bloku obrazu lub po ID assetu dla embedu Quill.
To wyłącznie planowanie operacji, **nie dowód istnienia uploadu**:
warstwa wywołująca musi osobno sprawdzić potwierdzenie z asset gateway.

Poprawiono istniejącą historię `EditorController`: Undo/Redo zachowuje
ID strony po zmianie aktualnej strony, a usunięcie strony unieważnia jej
stare wpisy historii. Jest to naprawa bezpieczeństwa w aktywnym edytorze
v1, **nie** obsługa operacyjnego Undo/Redo v2 z tombstones.

To NIE jest produkcyjny cutover. Brakuje integracji z `EditorController`,
trwałego odwzorowania/rebase atomów CRDT przy każdej edycji Quill,
bezpiecznego Undo/Redo tożsamości z tombstones, zdalnej projekcji
SQLite i odtworzenia po restarcie. Nie wolno włączać jednocześnie
writerów v1 i v2 ani usuwać snapshotowego zapisu przed zakończeniem
tych prac. Testy wymagają uruchomienia przez Flutter/Dart; samo dodanie
regresji nie oznacza ich zaliczenia.
