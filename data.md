# Dane NaNotateczki

Ten dokument jest źródłem prawdy dla lokalnego zapisu, migracji, backupu
serwerowego i synchronizacji. Lokalny Drift/SQLite pozostaje podstawą pracy
offline również po zalogowaniu.

## Tryby danych

- `localOnly` jest trybem domyślnym. Nie wymaga konta i nie wykonuje żadnego
  połączenia z API.
- `account` powstaje dopiero po jawnym logowaniu. Samo logowanie nie wysyła
  lokalnych notatek.
- Backup zdalny wymaga osobnego wywołania
  `RemoteBackupScheduler.enableForSignedInAccount()`.
- Synchronizacja Web wymaga jawnego `LiveWebSyncService.start(...)` z wyborem:
  `uploadLocal`, `downloadRemote` albo `mergeSafely`. Pierwsze dwie opcje
  odmawiają działania, jeśli mogłyby nadpisać niepustą bibliotekę.

## Dane lokalne na platformach natywnych

Wewnętrzne pliki są w prywatnym `Application Support` danej platformy,
w podkatalogu `data`. Na obecnym Linuksie jest to:

```text
~/.local/share/com.example.program/data/
├── notes.sqlite                         główna baza Drift
├── notes.sqlite-{wal,shm,journal}       pliki robocze SQLite, jeśli istnieją
├── app_prefs.json                       ustawienia aplikacji
├── editor_prefs.json                    ustawienia edytora
├── shared_recent_colors.json            historia kolorów
├── library_folders.json                 foldery, okładki i zadania planerów
├── study_planner.json                   sesje i wydarzenia
├── server_device.json                   losowy identyfikator urządzenia
├── server_sync_state_<hash>.json        kursor, rewizje i mały outbox konta
├── storage_layout.json                  raport migracji układu
├── images/                              trwałe obrazy/PDF-y notatek
├── local_backup/                        lokalny backup v6 i historia
├── deleted_notebooks/                   archiwa przed usunięciem
├── data_integrity_incidents/            dowody zablokowanych zapisów
└── legacy/                              nieużywane dane dawnego Isar
```

Foldery logiczne zapisują się w `library_folders.json` jako ścieżki
`Folder główny/Podfolder`. Jednopoziomowe dotychczasowe nazwy pozostają
niezmienione. Kolumna `Notebook.folder` w SQLite przechowuje tę samą
ścieżkę, więc zagnieżdżanie nie wymaga migracji schematu Drift.
Zmiana nazwy lub usunięcie rodzica obejmuje całe poddrzewo.

Ręczne eksporty JSON/PDF/PNG pozostają w `Dokumenty`, ponieważ są plikami
użytkownika, a nie wewnętrznym stanem programu. Katalog danych na
Linuksie/macOS ma prawa `700`; na pozostałych systemach ochronę katalogu
zapewnia sandbox/profil użytkownika systemu.

### Migracja starego układu

`prepareAppDataDirectory()` działa przed odczytem logów i otwarciem SQLite.
Kopiuje każdy znany plik do pliku tymczasowego, opróżnia bufor, porównuje
rozmiar i SHA-256, wykonuje atomową zmianę nazwy i dopiero wtedy usuwa źródło.
Różnego istniejącego pliku docelowego nigdy nie nadpisuje; konflikt zapisuje
w `storage_layout.json`. Po przeniesieniu `images/` start bazy zmienia stary
prefiks ścieżek obrazów na nowy katalog.

Jednorazowe narzędzie administracyjne:

```bash
dart run tool/migrate_local_data.dart \
  --support /home/USER/.local/share/com.example.program \
  --legacy /home/USER/Dokumenty
```

Przed uruchomieniem aplikacja musi być zamknięta. Narzędzie nie przyjmuje
katalogu głównego ani całego katalogu domowego jako celu.

## Dane w Web

- Drift używa SQLite WASM w IndexedDB.
- Małe ustawienia, outbox identyfikatorów i kursor są w `localStorage`.
- Token dostępu i refresh token są wyłącznie w pamięci procesu; po pełnym
  zamknięciu przeglądarki trzeba zalogować się ponownie.
- WebSocket przenosi wyłącznie mały sygnał zmiany. Pełny, trwały stan jest
  zawsze pobierany przez REST z kursorem `change_events`.

## Serwer

Kod wdrożeniowy znajduje się w `server/`. PostgreSQL i API są dostępne tylko
w prywatnej sieci Compose. Caddy wiąże port `8080` wyłącznie do
`127.0.0.1`; publiczne HTTPS ma kończyć Cloudflare Tunnel.

```text
/srv/nanotateczki/
├── .env                         sekrety, prawa 600, poza Git
├── compose.yaml
├── Caddyfile
├── api/                         FastAPI, jeden worker
├── migrations/0001_initial.sql
├── postgres-init/
├── data/backups/<owner UUID>/   niezmienne snapshoty verified
├── web-dist/                    publiczny build Flutter Web
└── backups/                     kopie całego serwera na czas wysyłki offsite
```

### Backup urządzenia

1. Klient opróżnia aktywne zapisy, odrzuca backup przy uszkodzonych rekordach
   i buduje format `nanotateczki-server-backup` v2.
2. Snapshot zawiera notatniki z bajtami obrazów, foldery/zadania oraz pełny
   `study_planner.json`.
3. Klient liczy SHA-256, tworzy rekord `pending`, wysyła maksymalnie 64 MiB i
   wywołuje `finalize`.
4. Serwer ponownie sprawdza rozmiar, SHA-256, format, urządzenie i checksumę
   payloadu; dopiero potem wykonuje atomowy rename i ustawia `verified`.
5. Błąd nie usuwa wcześniejszego poprawnego snapshotu. Scheduler ponawia próbę
   po 5 minutach i normalnie wysyła co 30 minut tylko po zmianach.

### Synchronizacja dwóch przeglądarek

- Zapis używa `expectedRevision` i `Idempotency-Key`; serwer wykonuje CAS.
- Sukces i wpis `change_events` powstają w jednej transakcji PostgreSQL.
- `409 Conflict` nigdy nie nadpisuje po cichu. Klient zachowuje osobny
  dokument z dopiskiem `Conflict`, a następnie stosuje stan serwera.
- Usunięcia są tombstonami. Outbox znika dopiero po potwierdzonym commicie.
- Po reconnect klient zawsze wywołuje `/v1/sync/changes?after=<cursor>`.
- Feed jest stronicowany po 500 zdarzeń; klient pobiera wszystkie pełne
  strony, zanim zacznie wysyłać lokalny outbox.

## Zabezpieczenia

- wyłącznie HTTPS/WSS poza localhostem; brak bezpośredniego połączenia
  Fluttera z PostgreSQL;
- hasła Argon2id, access JWT 10 minut, losowe rotowane refresh tokeny, w bazie
  tylko ich SHA-256; ponowne użycie unieważnia sesje użytkownika;
- `owner_id` zawsze pochodzi z tokenu, nie z payloadu; złożony FK pilnuje, że
  backup i urządzenie mają tego samego właściciela;
- ścisły Origin WebSocketu, uwierzytelnienie w 5 sekund i zamknięcie po
  wygaśnięciu JWT;
- limity 16 MiB dla dokumentu i 64 MiB dla snapshotu, request ID, rate limit
  logowania, nieuprzywilejowany/read-only kontener API;
- załączniki i backupy nie są publicznym katalogiem Caddy.

HTTPS szyfruje transmisję, ale obecna wersja nie zapewnia E2EE ani
szyfrowania plików na dysku serwera. Przed danymi innych użytkowników należy
włączyć szyfrowanie całego nośnika lub warstwę szyfrowanych backupów offsite,
ustalić odzyskiwanie kluczy i przeprowadzić audyt prawny/bezpieczeństwa.

Backup całego serwera wykonuje `server/scripts/backup-server.sh` na osobny
nośnik. Zawiera `pg_dump -Fc`, pliki snapshotów i manifest SHA-256; po
ustawieniu `BACKUP_AGE_RECIPIENT` zapisuje tylko końcowe archiwum zaszyfrowane
narzędziem `age`. Skrypt nie wdraża retencji i nie zastępuje testu odtworzenia.

## Wersjonowanie

- SQLite: `NotesDatabase.schemaVersion`.
- Backup lokalny: manifest v6.
- Backup serwerowy: envelope v2.
- PostgreSQL: niezmienne migracje w `server/migrations/`; zastosowanej
  migracji nie edytuje się, tylko dodaje następną.
