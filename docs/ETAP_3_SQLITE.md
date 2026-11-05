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
stare wpisy historii. Jawne usunięcie całej strony z zawartością przekazuje
do zabezpieczenia `NotebookRepository` jej ID; nieoznaczony ubytek
pozostaje blokowany. Regresje: `editor_controller_layering_test.dart`. Jest to naprawa bezpieczeństwa w aktywnym edytorze
v1, **nie** obsługa operacyjnego Undo/Redo v2 z tombstones.

### Kolejny przyrost implementacji — opt-in (2026-11-05)

Dodano `EditorSqliteProjector` bez zmiany schematu Drift. Zatwierdzone
operacje stron i ink aktualizują ich docelowe rekordy SQLite; usunięcie
ostatniej strony jest blokowane. Usunięcie strony z obrazem/PDF lub
embedem Quill lub rekordami `asset_references` jest odrzucane
do chwili obsługi detach assetów
(regresje w `test/editor_sqlite_projector_test.dart`).
Dla tekstu `object.create` i
`object.set` modyfikują typed rows, natomiast
`text.insert/delete/format` odtwarzają atomy CRDT z dziennika,
nakładają operację i zapisują `text` oraz Delta Quill. Replay
`OperationStore.textAtoms` zachowuje także tombstones atomów.
Operacje zdalne mogą używać tego samego callbacku
`EditorSqliteProjector.apply` w transakcji `OperationStore.applyRemote`.
Poprzedzające operacje, projekcja i outbox pozostają atomowe.
Metoda replay jest ograniczona do 50000 tekstowych envelope'ów,
bez niebezpiecznej kompaktacji; długie historie wymagają przyszłych
snapshotów/checkpointów CRDT.

`EditorV2OperationWriter` wiąże most z `SyncEngine.writeLocalBatch`
i tą samą instancją `NotesDatabase`; odczytuje trwałe atomy przed
przygotowaniem edycji, nie tworzy pustych wsadów i nie wywołuje
`NotebookRepository.saveNotebook`. `writeNotebookChange` scala zmiany
wielu stron w jedną transakcję. Niezmieniona kreska może
przechodzić między stronami przez `object.move`, z korektą sortIndex
bez ponownego tworzenia i tombstone. Modyfikacja treści kreski w ramach
przenoszenia i przenoszenie tekstu nadal są odrzucane.
Przeniesienie istniejącego obrazu jest możliwe tylko bez zmiany
bajtów/MIME i przy trwałym scoped `asset_references` — ten sam
atomowy commit przenosi rekord assetu na docelową stronę, bez kopiowania
ani kasowania pliku. Geometria obrazu może zmienić się przez
następujące po `object.move` `object.set`. Rozbieżny początkowy Delta Quill nie może nadpisać atomów
z trwałej projekcji. Projektor odmawia też kasowania ID, jeśli ten sam
identyfikator istnieje w kilku warstwach. Nowe testy:
`test/editor_sqlite_projector_test.dart` i
`test/editor_v2_operation_writer_test.dart`, obejmujące rollback,
offline outbox, ink, formatowanie, restart i idempotentny remote replay.
Nie były wykonane w środowisku bez SDK Flutter/Dart.

**Granice:** projektor odrzuca tworzenie/usuwanie/wymianę
assetów `image/pdf`, embedy Quill, `asset.attach/detach`,
`document.create` i przenoszenie tekstu. Ink `object.move` zachowuje
ID bez attached assetów, a obraz `object.move` wymaga trwałej
referencji; żaden z nich nie odłącza ani nie usuwa pliku.

Aktualizacje istniejących pól stron, kresek, obrazów i tekstu są
rozstrzygane w lokalnej projekcji zgodnie z serwerowym rank
`(logicalClock, actorId, actorSeq, operationId)`. Wersje pól pochodzą
z niekompaktowanego dziennika `operations`, a nie z kolejności HTTP.
Regresje obejmują odwróconą kolejność przyjęcia, niezależne pola i
remis zegara. To NIE rozwiązuje jeszcze konfliktów jednoczesnych
`object.move`, pełnego rebase ani kompaktacji wersji. Odtworzenie
wersji pola ma limit 50000 operacji na ID i wymaga przyszłej
materializowanej projekcji dla długiej historii. `EditorController` ma teraz
opcjonalny parametr `operationWriter`; jeśli został podany, `_save`,
`_saveDirtyPages` i flush używają wyłącznie kolejki operacyjnej v2
z utrwalonym baseline, bez wywołania `saveNotebook` ani
`saveNotebookPages`. `NotebookRepository.registerOperationWriter`
rezerwuje UID na czas pracy kontrolera i blokuje legacy writery,
import, restore, metadata i delete na zajętym dokumencie. Zwolnienie
własności następuje dopiero po opróżnieniu kolejki przy dispose.
Regresja: `test/editor_controller_v2_test.dart`.
W trybie opt-in Undo/Redo jest celowo wyłączone; wymaga osobnego
odwzorowania inverse intents oraz nowych identyfikatorów przy
tombstone. Nie wolno po prostu odtworzyć usuniętego UID.

To NIE jest produkcyjny cutover. Aktywne konto nadal zapisuje v1.
Przed przełączeniem należy zakończyć obsługę assetów, pokrycie
wszystkich działań `EditorController`, bezpieczny Undo/Redo,
remote sync z rebase/LWW, aktualizację metadanych dokumentów oraz
powiadamianie UI/backupu po v2 commit, migrację dokumentów/outboxu,
wsparcie platform i testy E2E.
Nie wolno włączać jednocześnie writerów v1 i v2 ani usuwać snapshotowego
zapisu przed zakończeniem tych prac.

Powtórzony odczyt już dostarczonej obcej operacji nie wywołuje
ponownego callbacku UI w tej samej sesji `SyncEngine` (maksymalnie
4096 zapamiętanych ID). Po nieudanym callbacku powiadomienie można
ponowić; po restarcie silnika pamięć powiadomień jest czyszczona.
Regresja: `test/sync_engine_test.dart`. Nie zastępuje to trwałego
stanu odtworzenia warstwy UI ani rebase konfliktów.

Dodatkowo istnieje `EditorV2RemotePatchDispatcher`, przekazywany
jako callback `SyncEngine.onRemoteCommitted`. Po commicie SQLite odczytuje
rzeczywisty docelowy obiekt lub stronę i aktualizuje wyłącznie ten fragment
kontrolera. Ruch `object.move` odzwierciedla w źródle i celu bez
ponownego montowania całego edytora, a dostarczenie `sortIndex`
zachowuje kolejność ink, tekstu i obrazów. Jeśli trwa lokalny gest, zwraca
błąd i silnik może ponowić callback. Nie dotyczy to jeszcze
automatycznego przełączania kont w `AppScope` ani LWW/rebase.
Test: `test/editor_v2_remote_patch_dispatcher_test.dart`.

### Ręczna weryfikacja, gdy dostępne będzie środowisko Flutter

1. W izolowanym katalogu konta utworzyć notebook z dwiema stronami
   i aktywować jedynie opt-in writer v2 na dokumencie testowym.
2. Offline dopisać i skasować stroke, edytować Quill (w tym styl),
   uruchomić Undo/Redo w docelowej integracji i ponownie uruchomić app.
   `operations`, `operation_outbox` i tabela obiektów muszą być spójne.
3. Przesłać wsad do API, zerwać połączenie przed ACK, ponowić;
   powtórny ACK nie może ponownie odmalować obiektu.
4. Na drugim urządzeniu odbierać niezależną zmianę. Po konflikcie
   nie wolno nadpisać lokalnego outboxu ani wrócić do starego snapshotu.
5. Sprawdzić usunięcie elementu i strony; żaden backup v1 nie może
   przywrócić tombstone. Powtórzyć po restartach i na Web/Android/iOS/Linux.

Testów ręcznych ani automatycznych nie uznajemy za wykonane.

