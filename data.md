# Dane NaNotateczki

Ten dokument jest źródłem prawdy dla lokalnego zapisu, migracji, backupu
serwerowego i synchronizacji. Lokalny Drift/SQLite pozostaje podstawą pracy
offline również po zalogowaniu.

## Tryby danych

- Przy pierwszym uruchomieniu użytkownik jawnie wybiera rejestrację, logowanie
  albo tryb lokalny. `localOnly` wymaga wyłącznie lokalnej nazwy użytkownika
  i nie wykonuje żadnego połączenia z API.
- Konto powstaje dopiero po jawnym logowaniu. Na Linuxie, Web, Androidzie
  i iOS aplikacja automatycznie uruchamia bezpieczne scalanie `mergeSafely`,
  zawsze sprawdzając najnowszy zweryfikowany backup przy logowaniu i starcie
  zapamiętanej sesji, a następnie odtwarzając brakujące dane.
- Odtwarzanie backupu dołącza brakujące notatniki, pomija identyczne,
  a odmienną wersję zachowuje w tym samym folderze z pierwszym wolnym
  numerem `(1)`, `(2)` itd. Kopia ma nowe UID i ID wszystkich obiektów.
  Nie zastępuje istniejącego notatnika; pierwszeństwo nad backupem mają
  zdarzenia synchronizacji i tombstones. Foldery są łączone, a zadania
  konfliktowego planera trafiają pod UID jego kopii. Backup jest pobierany
  i weryfikowany przy każdym starcie konta; ponowny import już przetworzonego
  identyfikatora jest pomijany, chyba że system stwierdzi utratę lokalnej
  bazy SQLite. Puste konto po świadomym usunięciu nie oznacza utraty bazy.
  Błąd odzyskiwania jest logowany, nie blokuje live sync i blokuje wysyłkę
  potencjalnie niekompletnego snapshotu do czasu poprawnego odzyskania.
- Scheduler backupu włącza się dopiero po inicjalizacji konta i sync.
  Po wylogowaniu aplikacja zatrzymuje sync i backup przed wyczyszczeniem sesji.
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
  Onboarding uruchamia się tylko przy pierwszej konfiguracji profilu
  i po jawnym wylogowaniu. Przycisk `Log out` unieważnia odświeżanie sesji,
  czyści poświadczenia, zachowuje przypisanie lokalnej biblioteki do konta
  i wraca do wyboru trybu. Serwer wydaje nowe rotowane refresh tokeny
  domyślnie na 3650 dni; uprawnienia mogą zostać odwołane po zmianie hasła
  lub przez administratora.

### Kontrakt przejścia Local → Account (wymaganie; wdrożenie w toku)

Przy pierwszym świadomym przejściu z Local do konta użytkownik musi
wybrać `Add local data to this account` albo `Keep local data separate`.
Do czasu wyboru nie wolno uruchomić automatycznego importu, backupu
ani synchronizacji danych Local do konta. Magazyn Local musi pozostać
niezależny i dostępny po powrocie do Local. Istniejące instalacje
z danymi już przypisanymi do `boundUserId` wymagają bezpiecznej migracji
bez automatycznego uznania tych danych za Local.

**Po wybraniu importu: ustawienia konta są nadrzędne**, w tym preferencje
aplikacji i edytora, motyw, kolory, Recent i serwerowa polityka backupu.
Lokalne ustawienia pozostają wyłącznie w zachowanym profilu Local.
Lokalne notatniki i foldery są dołączane bez nadpisywania stanu konta;
kolizje nazw dokumentów w tym samym folderze rozwiązują `(1)`, `(2)`
itd., z trwałą mapą źródłowych UID dla idempotentnego ponawiania.

**Kalendarz i Study Sessions łączą się addytywnie**: zachować wszystkie
istniejące wydarzenia i sesje konta, dodać brakujące z Local, bez
nadpisywania postępu, terminów, statusów ani informacji o powtarzaniu
wpisów konta. Nazwy wydarzeń/sesji mogą się powtarzać. Jeśli źródłowy
identyfikator jest już wykorzystany przez inny wpis, importer nadaje
przenoszonemu wpisowi nowy identyfikator i aktualizuje powiązania.
Ta sama operacja importu powtórzona po awarii nie dodaje kopii tych
samych wpisów. Serwerowe tombstones nie są omijane przez stary backup;
intencjonalnie importowany lokalny wpis musi otrzymać własną tożsamość
i rewizję. Zadania powiązane z notatnikiem/mapą folderów zachowują
odniesienia po mapowaniu UID. Kompletność i atomowość migracji wymagają
testów na Linux/Web/Android/iOS; to nie jest jeszcze gwarancja działania.

## Docelowe zasady migracji Local → konto (jeszcze NIE wdrożone)

Obecna implementacja nadal wykorzystuje wspólne `notes.sqlite` i klucze
plików `localOnly`/konta, automatycznie wywołuje `mergeSafely` po loginie.
Nie wolno uznawać tej implementacji za bezpieczną separację. Przed nowym
flow logowania konieczna jest osobna przestrzeń danych dla Local i każdego
konta oraz atomowa migracja poprzedniego magazynu.

Przy pierwszym logowaniu użytkownik wybiera, czy zachować całość Local
w izolacji, czy **skopiować** dane do konta. Izolacja pozostawia Local
nienaruszone (wraz z kalendarzem, sesjami nauki, plikami, assetami,
ustawieniami i backupami) i pokazuje wyłącznie dane serwerowe na koncie.
Po powrocie do Local otwiera się ten sam lokalny magazyn.

Przy kopiowaniu stosować następujący priorytet:

- **Ustawienia konta zawsze są autorytatywne**. Nie przenosić
  lokalnych preferencji ponad ustawienia i domyślne wartości konta:
  motywu, ustawień edytora, kolorów recent, parametrów backupu
  oraz innych preferencji.
- **Wydarzenia kalendarza i Study Sessions się dodają**: zachować
  wszystkie istniejące rekordy konta, następnie dołączyć lokalne
  wydarzenia, cykliczne wpisy, sesje planowane i ukończone, postęp,
  czasy i terminy. To nie jest podmiana całego `study_planner.json`.
  Takie same tytuły albo godziny nie oznaczają automatycznej kolizji.
  W razie kolizji ID różnych rekordów wydać nowe, zachować relacje
  serii i checkpoint mapowania; drugi import nie może tworzyć duplikatów.
- **Dokumenty i foldery**: zachować już istniejące obiekty konta;
  przenoszone dokumenty przy kolizji tytułu w tym samym folderze
  dostają `(1)`, `(2)` itd. W innym folderze wolno zachować nazwę.
  Kopie wymagają własnego UID i ID obiektów, obrazy/PDF muszą pozostać
  czytelne. Nie przenosić aktywnych sesji udostępniania linkiem.

Warunkiem zatwierdzenia transferu są zweryfikowana synchronizacja
i trwały checkpoint źródło → cel. Awaria podczas kopiowania nie może
usunąć Local ani powtórnie importować danych.

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
- Przy przywróceniu zapamiętanego konta na wszystkich platformach aplikacja
  ponownie uruchamia synchronizację i backup. WebSocket służy także na
  platformach natywnych; trwałe dane są pobierane przez REST.
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
2. Snapshot zawiera notatniki z bajtami obrazów, foldery/zadania,
   `study_planner.json`, `app_prefs.json`, `editor_prefs.json`,
   `shared_recent_colors.json` i preferencję bezczynności backupu konta.
3. Klient liczy SHA-256, tworzy rekord `pending`, wysyła maksymalnie 64 MiB i
   wywołuje `finalize`.
4. Serwer ponownie sprawdza rozmiar, SHA-256, format, urządzenie i checksumę
   payloadu; dopiero potem wykonuje atomowy rename i ustawia `verified`.
   Klient przy odzyskiwaniu sprawdza oryginalne bajty payloadu, ponieważ
   ponowne kodowanie JSON w innym środowisku może zmienić zapis liczb.
   Starszy wariant checksumy kompaktowego JSON pozostaje obsługiwany.
5. Błąd nie usuwa wcześniejszego poprawnego snapshotu. Scheduler ponawia próbę
   nie wcześniej niż po 5 minutach. Zmieniony snapshot wysyła po ustalonym
   okresie bezczynności (domyślnie 2 minuty; opcje: 30 s, 1 min,
   2 min, 5 min, 15 min i 30 min); aktywne kliknięcia, przewijanie, rysik i pisanie (także edytor Quill
   z klawiaturą ekranową) przesuwają termin. Hover, otrzymane aktualizacje
   serwera i zdarzenia z ukrytej karty nie resetują licznika. Wznowienie
   aplikacji nie resetuje czasu bezczynności; natywny system może jednak
   wstrzymywać same timery w tle. Preferencja jest synchronizowana per konto. Serializacja i SHA-256 na platformach natywnych
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
- `409 Conflict` nigdy nie nadpisuje po cichu. Przy konflikcie
  rzeczywistych edycji klient zachowuje numerowaną kopię lokalnego szkicu.
  Tombstone bez oczekujących lokalnych edycji usuwa dokument na urządzeniu
  bez tworzenia kopii. Wersja serwera pozostaje oryginałem.
- Usunięcia są tombstonami. Outbox znika dopiero po potwierdzonym commicie.
- Po reconnect klient zawsze wywołuje `/v1/sync/changes?after=<cursor>`.
- Na wszystkich platformach po wznowieniu aplikacji i zapasowo co 45 sekund
  (10 sekund po błędzie) weryfikuje zmiany przez REST. Ścieżki obrazów
  przesyłanych przez konto są neutralne względem systemu plików urządzenia.
- Daty `createdAt` i `updatedAt` w protokole sync są normalizowane do UTC;
  lokalna strefa zwrócona przez SQLite nie oznacza zmiany dokumentu.
  Bazowy snapshot pozostaje identyczny z odpowiedzią serwera. Jeśli data
  utworzenia się nie zmienia, PUT zachowuje jej oryginalny zapis, aby
  nie naruszyć ochrony niezmiennych metadanych współdzielonego dokumentu.
- Feed jest stronicowany po 500 zdarzeń; klient pobiera wszystkie pełne
  strony, zanim zacznie wysyłać lokalny outbox.

## Synchronizacja preferencji konta

Na Linuxie, Web, iOS i Androidzie ustawienia `app_prefs.json`,
`editor_prefs.json`, `shared_recent_colors.json` oraz preferencja
`server_backup_preferences_<hash>.json` są synchronizowane niezależnie
od snapshotów urządzeń przez `/v1/account-settings`.
Każda kategoria ma oddzielną rewizję i atomowy zapis CAS.
Po logowaniu konto jest źródłem ustawień, lecz przed pierwszym importem
dotychczasowy stan lokalny jest zachowywany w
`account_preimport_<hash>.json`. Klient pamięta ostatnią
potwierdzoną rewizję i zawartość w
`account_settings_cursor_<hash>.json`, dzięki czemu nie wysyła
starych wartości przy ponownym uruchomieniu. Równoległe modyfikacje
tej samej kategorii nie nadpisują się po cichu: klient zachowuje
lokalny stan i rejestruje konflikt.
Odpytywanie odbywa się przy starcie, po zmianie, wznowieniu aplikacji
i co 45 sekund. Brak nowego endpointu na starej wersji serwera
nie może blokować synchronizacji notatników ani tworzenia backupu.
Serwer wymaga migracji `0007_account_settings.sql`. Synchronizacja folderów,
okładek i zadań wykorzystuje dodatkową kategorię `libraryState`, wymagającą
migracji `0009_account_settings_library_state.sql`. Klient uzgadnia JSON
z użyciem ostatniego potwierdzonego stanu jako wspólnej bazy; usuwa elementy
pominięte po znanej rewizji i zachowuje różne lokalne edycje zadania jako
kopię z numerem `(1)`. Nie stosuje nadpisania pliku, jeżeli powstały nowe
lokalne zmiany w trakcie żądania REST. Operacje równoległe wymagają nadal
pełnych testów end-to-end z PostgreSQL i dwoma klientami.

Foldery i zadania występują również w snapshotach backupu, ale ich
bieżące metadane są uzgadniane przez rewizjonowaną kategorię
`libraryState` w `/v1/account-settings`. Zdarzenia i Study Sessions mają
niezależny feed per wpis. Dla folderów i zadań odświeżenie odbywa się
po zmianie, wznowieniu oraz okresowo; nie jest jeszcze gwarantowany
natychmiastowy odbiór każdej zmiany między urządzeniami.

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


## Wspólna edycja sesji Web

Właściciel udostępnia istniejący notebook lub board na 4 godziny.
Link `/share/<UUID>` i hasło 1–128 znaków pozwalają gościowi edytować
**wyłącznie ten dokument** bez konta. Token gościa nie daje dostępu
do folderów, innych notatek, backupów ani API właściciela. Dane gościa
są trzymane w osobnej bazie SQLite WASM w pamięci, a nie w IndexedDB konta.
Ostatni niepotwierdzony snapshot i zweryfikowana wersja bazowa są zapisywane
dodatkowo pod kluczem specyficznym dla linku w magazynie tekstowym
(przeglądarkowy localStorage). Po ponownym podaniu hasła przywracana jest
wersja oczekująca i ponawiana próba scalenia. Bilet i hasło nie są
utrwalane. Limit pojemności localStorage i zamknięcie karty przed lokalnym
zapisem pozostają ryzykiem i są sygnalizowane w interfejsie.

Każda potwierdzona zmiana trafia w transakcji PostgreSQL do istniejącego
`synced_notebooks` pod **oryginalnym UID i folderem**; zmiana nie tworzy
osobnego pliku lub dokumentu. Zapis powiadamia klientów przez WebSocket,
a odpytywanie zapasowe służy wyłącznie na wypadek utraty połączenia.
Gdy sesja jest aktywna, edytor zapisuje zakończony ruch po 20 ms,
host uruchamia synchronizację bez dodatkowego debounce, a gość wysyła
zapisane zmiany po dodatkowych 35 ms. Dodatkowy 2-sekundowy cooldown
rysika nie obowiązuje dla shared session; nie wolno jednak zapisywać
niezakończonego gestu. Powiadomienia WebSocket pobudzają odbiorców
natychmiast, a poprzedni request nie może zgubić nowego ruchu.
Nie jest to gwarancja latencji Internetu, Cloudflare czy renderowania.
Synchronizacja treści nie przenosi stanu viewportu: host i każdy gość
zachowują własną stronę, zoom, pan i pozycję scrolla. Gdy w trakcie
gestu nadejdzie rewizja, odbiór jest odroczony bez odmontowania edytora.

Serwer weryfikuje `baseRevision` i `baseNotebook` względem
niezmiennej historii `change_events`; indeks na rewizję pochodzi z migracji
`0006_change_events_document_revision.sql`. Tylko jedna aktywna sesja
może dotyczyć konkretnego UID. Właściciel usuwa oryginał i jednocześnie
unieważnia sesję w tej samej transakcji. Feed właściciela zapisuje
scalony stan dokumentu, nie stan pojedynczego żądania.

Serwer scala zmiany niezależnych obiektów (kreski, pola tekstowe, obrazy)
bez nadpisywania ich. Gdy ten sam obiekt zmieniono jednocześnie, wygrywa
wcześniejszy czas przyjęcia przez serwer z dokładnością do mikrosekund.
W identycznej mikrosekundzie rozstrzyga większy rozmiar zmiany względem
wspólnej wersji początkowej. Rozstrzygnięcia są utrwalane w
`study_shares.edit_clock` (migracja `0005_study_share_edit_clock.sql`).
Zegary urządzeń nie są używane. Zmiany lokalne w konflikcie z
potwierdzonymi z serwera wymagają bezpiecznego rozdzielenia, nigdy
cichego usuwania treści.

Po restarcie strony właściciel może odzyskać aktywną sesję z API;
po stronie gościa ponowne wejście wymaga podania hasła. Przedłużenie
w ostatnich 15 minutach dodaje 4 godziny i zachowuje link oraz bilety.
Ręczne zakończenie unieważnia bilety niezwłocznie, nawet gdy zapis
lokalny jest zablokowany. Po wygaśnięciu serwer zwraca HTTP 410
i żadne nowe operacje nie są przyjmowane. WebSocket subskrybuje sygnały
zakończenia przed sprawdzeniem biletu; zapobiega to utracie zdarzenia
`ended` przy równoczesnym odebraniu dostępu.

### Granica bezpieczeństwa niedokończonego wdrożenia

Wspólna edycja Web nadal jest WIP: gość przechowuje bazę roboczą
w pamięci, ale niepotwierdzony snapshot jest utrwalany w localStorage.
Nie gwarantuje to odzyskania edycji jeszcze niezapisanej lokalnie,
przekraczającej limit magazynu lub wykonanej podczas nagłego zakończenia
procesu przed zakończeniem zapisu. Przed włączeniem produkcyjnym wymagane są testy Flutter,
FastAPI, PostgreSQL, równoczesna edycja w dwóch przeglądarkach oraz testy
odzyskiwania i latencji. Na serwerze wymagane są migracje 0004, 0005 i 0006.


## Calendar i Study Sessions: per-entry sync

`study_planner.json` v2 przechowuje `modifiedAt` w UTC, dane wpisów
i nieusuwalne znaczniki `tombstones`. Stary format v1 jest odczytywany;
brak timestampu oznacza znacznik epoch, a nie fikcyjną nową edycję.
Po zalogowaniu, lokalnej zmianie, wznowieniu i co 45 sekund klient pobiera
stronicowany stan `GET /v1/planner/entries` i wysyła nowsze lokalne wpisy
do `PUT /v1/planner/entries/{id}`; WebSocket `planner_changed`
wywołuje natychmiastowe uzgodnienie. Usunięcia są trwałymi tombstones.
W obrębie jednego ID wygrywa późniejszy znacznik modyfikacji, osobne ID
scalają się niezależnie. Zegar odliczający sesji nie generuje zapisu
w każdej sekundzie, tylko przy zmianach stanu. Po błędzie połączenia wpisy
pozostają w pliku i są ponawiane. Przy zmianach offline na dwóch urządzeniach
kolejność zależy od poprawnego ustawienia zegara UTC obu systemów.
Wymagana migracja PostgreSQL: `0008_planner_entries.sql`.

## Wyjście i dodatkowa reguła usunięcie–edycja (2026-11-02)

Po zalogowaniu domyślny automatyczny backup następuje po 30 sekundach
bezczynności, do wyboru także 15/60/120/300/900/1800 sekund.
Przed każdym zdalnym snapshotem aplikacja uzgadnia najpierw wszystkie
zmiany notatników, ustawień konta i planera z serwerem. Niepowodzenie
synchronizacji blokuje wysłanie nieaktualnego snapshotu; zachowuje
oczekujący backup do ponowienia. Brak własnych zmian nie zatrzymuje
WebSocket ani awaryjnego pobierania feedu co 45 sekund. Zmiany pobrane
z innego urządzenia również oznaczają backup jako oczekujący, bez
resetowania czasu bezczynności. Brak różnic w obu kierunkach oznacza,
że nie trzeba tworzyć kolejnej identycznej kopii. Ustawienie
jest zapamiętywane lokalnie i synchronizowane na konto.
Normalne zamknięcie natywnej aplikacji próbuje najpierw opróżnić lokalne
zapisy, uzgodnić live sync i uzyskać zweryfikowany snapshot serwerowy.
W czasie uploadu widoczny jest spinner. Jeśli upload się nie uda, aplikacja
pozostaje otwarta i proponuje Retry backup. Wymuszone zakończenie przez
system, awaria zasilania oraz zamknięcie karty Web NIE są gwarantowanym
miejscem na końcowe HTTP; przy detached i Web hidden jest tylko
best-effort flush, potem retry przy następnym uruchomieniu.

Tombstone pozostaje autorytatywny wobec starego backupu i urządzenia bez
niepotwierdzonych edycji. Jeśli drugie urządzenie posiada oczekującą
rzeczywistą zmianę, po otrzymaniu tombstone wykonuje jawny retry
`restoreDeleted` z aktualną rewizją CAS. Po zaakceptowaniu przez serwer
przywrócony zostaje oryginalny UID i folder dla wszystkich urządzeń,
bez kopii `(1)`. Zwykłe odtworzenie backupu nie wysyła tego znacznika.
Kolejność przyjęcia na serwerze, nie arbitralny czas backupu, rozstrzyga
konkurujące operacje. Wspólna sesja udostępniania zakończona przez
usunięcie nie jest automatycznie przywracana wraz z dokumentem.
