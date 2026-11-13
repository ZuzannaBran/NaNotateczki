# Etap 9 — pakiet 6: backup operacyjny i odzyskiwanie

## Architektura i granica v1/v2

- Konto v1 nadal używa `RemoteBackupService` i `/v1/backups`
  (envelope `version: 2`); tej historii nie wolno wczytywać jako operacji v2.
- Konto v2 korzysta z `V2BackupRecoveryService` oraz `/v2/backups`
  (envelope `version: 3`, `protocol: operations-v2`).
  `AppScope` wybiera tę ścieżkę tylko po zweryfikowanym przypisaniu konta
  do v2; nie włącza globalnie cutover.
- Backup v2 zawiera `schemaVersion`, `accountId`, `deviceId`,
  `operationCheckpoint: {account:<uid>: cursor}`, SHA-256 całego pliku,
  SHA-256 oryginalnych bajtów payloadu, `operationHistory` wraz z
  oryginalnymi `operationId`, `actorSeq`, `causalCursor` i tombstones,
  a także bibliotekę, planner, ustawienia, Recent i preferencje backupu.
- `notebooks: []` jest celowe: dokumenty odtwarza reduktor operacyjny,
  a nie odrębna kopia serializowana przez stary writer. Zmiana strony lub
  gestu nie powoduje kodowania wszystkich niezmienionych notatników.
- Assety są identyfikowane po SHA-256; nowe archiwum przechowuje
  `assetBlobs[sha] = {sizeBytes, mediaType, storage: verified-v2}`.
  PDF/PNG/JPEG/WebP pozostają w istniejącym magazynie
  `assets-v2/<owner>/...`. Serwer sprawdza właściciela, rozmiar,
  MIME i pełne SHA-256 każdego pliku przed `verified`. Nie przesyła się
  tych samych dużych bajtów w każdej kolejnej kopii. Starsze archiwa v3
  z `bytesBase64` są również walidowane i odtwarzane.
- **Warunek odtwarzalności:** backup całego serwera musi zachowywać
  również `assets-v2` (sam JSON archiwum z referencjami nie wystarczy
  przy utracie serwera/assetów). Uszkodzony/brakujący asset wstrzymuje
  recovery zamiast produkować pusty obraz.

## Spójność i izolacja

1. Poczekaj na zapis lokalny i synchronizację v2; sprawdź brak
   niewysłanych (również deferred/blocked) operacji w outboxie.
2. Porównaj trwały lokalny checkpoint z serwerowym. Odczytaj zweryfikowany
   feed od zera do dokładnie tego kursora, bez zmiany ID i kolejności.
   Weryfikuj po zakończeniu capture, że checkpoint, outbox, konto
   oraz pliki preferencji/planera nie uległy zmianie.
3. POST pending → PUT treści z SHA-256 i ograniczeniem rozmiaru →
   serwerowa walidacja zgodności całej historii z rzeczywistym
   `document_operations` właściciela → atomowa publikacja `verified`.
   Przerwany PUT nie tworzy zweryfikowanego pliku.
4. Nowy, naprawdę pusty profil nie importuje starego backupu.
   Zgłoszony reset/utrata SQLite lub marker `pending` uruchamia recovery,
   zanim zacznie się edycja i synchroniczna mutacja v2.
5. Wybierz najnowsze poprawne archiwum, zweryfikuj oba SHA-256, format,
   schemat, checkpoint oraz każdą operację i referencję assetu;
   pobierz assety przez `/v2/assets/<sha>` z weryfikacją bajtów.
6. Zapisz marker `pending`, a potem replay kopert przez
   `OperationStore.applyRemote` z tym samym projektorem SQLite/Library,
   jedną transakcją na operację. Po restarcie porównaj już utrwalone
   koperty z tym samym archiwum i zacznij replay od pierwszej brakującej.
   Jeżeli catch-up zdążył przesunąć kursor dalej, nie cofaj go.
   Nie zmieniaj oryginalnych ID ani aktorów.
7. Sprawdź SQLite `quick_check`, dokładny checkpoint, odbuduj
   nieautorytatywne cache biblioteki. Synchronizuj kolejne operacje przez
   `SyncEngine` przed odblokowaniem edytora. Nowszy tombstone nie może
   wskrzesić wcześniejszego UID. Oznacz marker `complete` dopiero
   po udanym catch-up i po skasowaniu znacznika odzyskiwania SQLite.
8. Istniejącej bazy z nowszym checkpointem nie nadpisuj starszym
   backupem. Pending lokalny outbox blokuje recovery, a zmiana
   namespace/konta wstrzymuje dalszą pracę.

Scheduler zachowuje ustawienia 15/30/60/120/300/900/1800 sekund,
30 sekund domyślnie. Snapshot nadal ma limit 64 MiB i maksymalnie
100000 kopert w pełnym archiwum; przekroczenie daje jawny błąd i
nie usuwa żadnych danych. Aby skalować dalej, potrzebne będą
przyrostowe archiwa bazowe, nie ucinanie historii.

## Testy wprowadzone w pakiecie 6

- `test/v2_backup_recovery_test.dart`: capture historii bez v1,
  brak SQLite, identyczne ID po replay, restart w środku replay,
  starszy backup, uszkodzony asset, zerwany upload / brak miejsca,
  niewysłany outbox, usunięcie UID po archiwum.
- `api/tests/test_backup_v2.py`: walidacja prefiksu,
  owner/checkpoint, autentyczność operacji i assetów.
- `api/tests/test_backup_v2_pipeline.py`: przerwany upload,
  odrzucenie wadliwego finalize, atomowa publikacja verified.
- Lustro `server/api/` musi pozostać identyczne z kanonicznym
  `NaNotateczki-serwer/main`.

Pakiety 7–11 i produkcyjny cutover pozostają osobnymi bramkami.
Nie usuwać writerów v1 ani nie włączać `OPERATIONS_V2_WRITE_MODE=all`
na podstawie samego wdrożenia backupu.
