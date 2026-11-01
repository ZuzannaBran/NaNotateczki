# Dane NaNotateczki

Ten dokument jest źródłem prawdy dla lokalnego zapisu, migracji, backupu
serwerowego i synchronizacji. Lokalny Drift/SQLite pozostaje podstawą pracy
offline również po zalogowaniu.

## Tryby danych

- Przy pierwszym uruchomieniu użytkownik jawnie wybiera rejestrację, logowanie
  albo tryb lokalny. `localOnly` wymaga wyłącznie lokalnej nazwy użytkownika
  i nie wykonuje żadnego połączenia z API.
- `account` powstaje dopiero po jawnym logowaniu. Samo logowanie nie wysyła
  lokalnych notatek.
- Backup zdalny wymaga osobnego wywołania
  `RemoteBackupScheduler.enableForSignedInAccount()`.
- Synchronizacja Web wymaga jawnego `LiveWebSyncService.start(...)` z wyborem:
  `uploadLocal`, `downloadRemote` albo `mergeSafely`. Pierwsze dwie opcje
  odmawiają działania, jeśli mogłyby nadpisać niepustą bibliotekę.
- Panel konta uruchamia backup dopiero po poprawnym logowaniu, a na Web
  wymaga od użytkownika wyboru jednej z trzech polityk przed startem live
  sync. Przy wylogowaniu najpierw zatrzymuje live sync i backup, a dopiero
  potem czyści sesję przechowywaną w pamięci.
- `account_profile.json` przechowuje ukończenie onboardingu,
  preferowany tryb, lokalną nazwę, ostatnią nazwę użytkownika oraz `boundUserId`.
  Raz przypisane dane lokalne nie mogą zostać użyte z innym kontem bez
  osobnego profilu przeglądarki lub instalacji. Nie zawiera hasła,
  access tokenu ani refresh tokenu. Odnawialny token jest przechowywany
  oddzielnie przez `flutter_secure_storage` (systemowy magazyn
  sekretów/kluczy; na Web zaszyfrowany magazyn przeglądarki).
  Przy restarcie klient sprawdza tożsamość z `boundUserId`, loginem i
  adresem API, następnie wywołuje `POST /v1/auth/refresh`, utrwala
  rotowany token i dopiero wtedy przywraca sesję. Nie utrwala hasła
  ani access tokenu. Brak sieci nie czyści tokenu i nie blokuje lokalnej
  biblioteki; odrzucenie odnowienia unieważnia zapisany token.
  Onboarding uruchamia się tylko przy pierwszej konfiguracji profilu,
  nie przy każdym ponownym uruchomieniu aplikacji.

## Dane lokalne na platformach natywnych

Wewnętrzne pliki są w prywatnym `Application Support` danej platformy,
w podkatalogu `data`. Na obecnym Linuksie jest to:

```text
~/.local/share/com.example.program/data/
├── notes.sqlite                         główna baza Drift
├── notes.sqlite-{wal,shm,journal}       pliki robocze SQLite, jeśli istnieją
├── app_prefs.json                       ustawienia aplikacji
├── account_profile.json                 tryb i lokalna nazwa, bez tokenów
├── editor_prefs.json                    ustawienia edytora
├── shared_recent_colors.json            historia kolorów
├── library_folders.json                 foldery, okładki i zadania planerów
├── study_planner.json                   sesje i wydarzenia
├── server_backup_preferences_<hash>.json  czas bezczynności przed backupem
├── server_device_<hash>.json            identyfikator urządzenia per konto
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
Zmiana nazwy, przeniesienie do innego folderu lub usunięcie rodzica obejmuje
całe poddrzewo; operacja aktualizuje także ścieżki `Notebook.folder` i okładki.

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
- Access token pozostaje wyłącznie w pamięci; rotowany refresh token
  jest przechowywany przez `flutter_secure_storage` na tym samym originie.
  Web wymaga bezpiecznego kontekstu HTTPS (localhost do testów).
  Współdzielenie profilu przeglądarki i skrypty działające na tym
  originie pozostają ryzykiem; XSS wymaga odrębnej ochrony.
  Zmiana hasła i wylogowanie czyszczą utrwalony token.
- Kursor, rewizje, outbox, stan UI backupu oraz identyfikator urządzenia są
  izolowane według `userId`. Cała lokalna biblioteka jest przypisywana do
  pierwszego konta (`boundUserId`); zmiana konta na tej samej instalacji jest
  blokowana, ponieważ wspólne SQLite/IndexedDB nie izoluje notatek. Stary nieprzypisany `server_device.json` nie jest
  używany do nowych backupów.
- WebSocket przenosi wyłącznie mały sygnał zmiany. Pełny, trwały stan jest
  zawsze pobierany przez REST z kursorem `change_events`.
- Przy przywróceniu konta na starcie natywny scheduler backupu wraca
  do działania. Pierwszy sync Web nadal wymaga jawnego wyboru polityki;
  samo odnowienie tokenu nie rozpoczyna synchronizacji.

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

### Lokalny test HTTP

Wariant `server/compose.local.yaml` wystawia API na `127.0.0.1:18080`,
włącza lokalną rejestrację i dopuszcza origin `http://localhost:3000`.
Klienta Web uruchamia `bash tool/run_local_backend_web.sh`. Przy pracy
z innego komputera najpierw otwórz tunel
`ssh -L 18080:127.0.0.1:18080 UZYTKOWNIK@SERWER`.
Instrukcje migracji i sprawdzenia komunikacji są w `server/README.md`.

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
   nie wcześniej niż po 5 minutach. Zmieniony snapshot wysyła po ustalonym
   okresie bezczynności (domyślnie 2 minuty, zakres 30 s–30 min); aktywny
   rysik, mysz i klawiatura przesuwają termin. Preferencja jest lokalna i
   odrębna dla każdego konta. Serializacja i SHA-256 na platformach natywnych
   działają poza głównym isolate. Przycisk `Back up now` jawnie oznacza snapshot jako wymagany i uruchamia go
   od razu.

### Konto i zmiana hasła

- Rejestracja używa loginu (3–32 znaki: litery ASCII, cyfry i _) oraz hasła
  8–128 znaków; logowanie akceptuje
  istniejące hasła 1–256 znaków. Nowe hasło też ma 8–128 znaków.
  Powtórzenie hasła jest walidowane lokalnie.
- Zmiana hasła wywołuje uwierzytelnione
  `POST /v1/auth/change-password` z `currentPassword` i `newPassword`.
  Powtórzenie nowego hasła nie jest wysyłane do API.
- Po sukcesie `204` serwer zwiększa `auth_version` i unieważnia refresh
  tokeny, wydane JWT oraz połączenia WebSocket. Wymaga to migracji
  `0002_auth_version.sql` i `0003_username.sql`. Klient zatrzymuje live
  sync i backup, czyści sesję z pamięci i magazynu sekretów oraz wymaga
  ponownego logowania.
- Użytkownik może przełączać się między profilem lokalnym i kontem z poziomu
  ustawień konta. Przejście do trybu lokalnego zatrzymuje usługi sieciowe
  przed wyczyszczeniem sesji.

### Synchronizacja dwóch przeglądarek

- Zapis używa `expectedRevision` i `Idempotency-Key`; serwer wykonuje CAS.
- Sukces i wpis `change_events` powstają w jednej transakcji PostgreSQL.
- `409 Conflict` nigdy nie nadpisuje po cichu. Klient zachowuje osobny
  dokument z dopiskiem `Conflict`, a następnie stosuje stan serwera.
- Usunięcia są tombstonami. Outbox znika dopiero po potwierdzonym commicie.
- Po reconnect klient zawsze wywołuje `/v1/sync/changes?after=<cursor>`.
- Na Web po wznowieniu aplikacji i zapasowo co 45 sekund (10 sekund po błędzie)
  weryfikuje zmiany przez REST, niezależnie od częstotliwości backupów.
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
- PostgreSQL: niezmienne migracje w `server/migrations/` (w tym
  `0003_username.sql`); zastosowanej
  migracji nie edytuje się, tylko dodaje następną.


## Współdzielona sesja nauki Web

Sesja jest tylko sposobem na wyświetlenie kanwy na żywo zaproszonym
osobom; nie jest alternatywnym magazynem dokumentów ani nowym właścicielem
notatnika. Projekt, jego UID, folder, wszystkie strony i lokalny backup
pozostają w bibliotece autora. Udostępnianie nie usuwa ani nie przenosi
oryginalnego projektu.

Właściciel musi być zalogowany i mieć włączoną synchronizację Web.
Przed utworzeniem linku i przed ręcznym zakończeniem sesji aplikacja
wykonuje flush edytora i repozytorium, czeka na synchronizację z kontem,
a w przypadku błędu/pending odmawia potwierdzenia zapisu. Backend dodatkowo
weryfikuje, że udostępniany dokument jest aktywnym rekordem konta
`synced_notebooks`. Zakończenie sesji tylko blokuje bilety gości i kasuje
chwilowy obraz PNG; nie dotyka rekordu notatnika.

Zaproszenie jest linkiem `/share/<session UUID>` oraz osobno
przekazanym hasłem, bez obowiązku zakładania konta. Hasło sesji ma hash
Argon2id; bilet uczestnika jest wyłącznie w pamięci przeglądarki i pozwala
pobierać jedynie prywatny obraz udostępnionej kanwy. Nie udostępnia
biblioteki, SQLite ani tokenów konta autora. Uczestnicy mają wyłącznie
podgląd. Obraz aktualizuje się przez WebSocket i chroniony REST.
Sesja wygasa po 4 godzinach; w ostatnich 5 minutach właściciel dostaje
ostrzeżenie i może przedłużyć o kolejne 4 godziny bez zmiany linku.
