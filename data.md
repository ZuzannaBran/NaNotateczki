# Dane NaNotateczki

## Bariera montowania edytora konta (2026-11-06)

`AppScope` nie pokazuje produkcyjnego `LibraryScreen` zalogowanemu
użytkownikowi przed potwierdzeniem wersji protokołu serwera. Oddzielne
warunki zwalniają ekran po zweryfikowanym v1 lub po pełnym starcie runtime
v2 dla właściwego konta. W razie braku połączenia i braku potwierdzonej
wersji blokuje edycję, zamiast tworzyć snapshot v1 konta v2.
Retry ponawia sprawdzenie wersji, Log out pozwala opuścić ekran blokady.
Nie włącza to globalnego cutover ani nie zmienia izolacji kont.


## Weryfikacja obrazu przed przeniesieniem i usunięciem (2026-11-06)

Przed move/object.delete/page.delete obraz inline musi zachować
SHA-256 bajtów zgodny z unikalnym scoped assetem. Korupcja zatrzymuje
transakcję i pozostawia operacje, tombstones i outbox bez zmian.
Legacy file-backed images są poza nową ścieżką do osobnej migracji.

## Tekst Quill — zachowanie końcowych białych znaków (2026-11-06)

W `TextBlock.text` przechowywany jest tekst bez jednego strukturalnego
znaku `\n` na końcu Quill Delta, ale z wszystkimi innymi spacjami,
tabulatorami oraz świadomie wpisanymi nowymi liniami. `trimRight()`
nie może być używane przy synchronizacji kontrolera, CRDT i projekcji.
To poprawka zapisu v2 bez przełączania legacy v1 na nowy silnik.


## Catch-up po uwierzytelnieniu WebSocket v2 (2026-11-06)

`SyncEngine` żąda REST catch-up zarówno po `operations_changed`, jak
po `authenticated`. Początkowy odczyt REST może zakończyć się przed
subskrypcją serwera, a podczas reconnect mogły powstać nowe operacje.
Samo otwarcie transportu nie dowodzi pełnej subskrypcji; potwierdzenie
serwera zamyka tę lukę bez czekania na polling co 45 sekund. Wiadomość
pozostaje wyłącznie wskazówką: nie zapisuje treści ani nie przesuwa kursora.
Niezmienione pozostają generation token, debounce i walidacja REST.
Regresja z lokalnym WebSocket sprawdza pierwsze połączenie i restart
silnika bez `operations_changed`, ręcznego sync ani pomocy timera.


## Nieaktualne inverse po zdalnym commicie (2026-11-06)

Undo/Redo najpierw sprawdza checkpoint na aktualnej głowie dziennika.
Zdalny commit unieważnia stare stosy nawet wtedy, gdy odpowiadający mu
patch UI jeszcze nie dotarł. Druga kontrola działa w transakcji inverse:
operacja bezpośrednio poprzedzająca nowy batch musi być głową tego samego
checkpointu. Zmiana podczas dekodowania mediów wycofuje cały inverse,
łącznie z projekcją, tombstones, actorSeq i outboxem. Dopiero po rollbacku
kontroler odrzuca stare stosy, zachowując widok do dostarczenia patcha.
ACK ani echo istniejącej operacji nie dopisuje głowy i nie kasuje historii.
Nowy gest po odebraniu patcha zaczyna historię od zdalnie potwierdzonego
stanu; nie może cofnąć starszego utworzenia strony z cudzą zawartością.

## Natywne media i historia v2 (2026-11-06)

Import obrazu z pliku lub bajtów i renderowanych stron PDF zamraża
własne bajty w `ImageBlock` przed mutacją kontrolera i transakcją historii.
Plik w `images/` pozostaje prywatnym cache'em; jego usunięcie przed commitem
nie usuwa źródła v2. Odczyt natywnego obrazu sprawdza istniejący limit
protokołu 64 MiB przed alokacją; pusty lub większy plik nie zmienia
notatnika ani dziennika. Writer nadal weryfikuje sygnaturę, SHA-256 i MIME
oraz zapisuje BLOB z operacjami w jednej transakcji. Kodek checkpointu
odczytuje wyłącznie te trwałe, scoped bajty i nie wykonuje plikowego I/O.

Odbudowa cache'u v2 zachowuje bajty w modelu i nie generuje operacji,
nowego asset ID ani kroku Undo. Gdy oba modele zawierają takie same
niepuste bajty oraz MIME/ext, zmiana samej lokalnej ścieżki nie jest
podmianą treści. Path-only legacy i puste tablice nadal wymagają zgodnej
ścieżki; zmiana bajtów lub typu wymaga zweryfikowanego nowego assetu.
Ścieżka legacy zachowuje dotychczasowe pliki bez inline BLOB w modelu.

Nieudany zapis v2 wyłącza `canUndo/canRedo` i powiadamia toolbar przez
`historyRevision`; udana ponowna próba odświeża dostępność historii po
wyczyszczeniu dirty flags. Nie wolno stosować inverse do niezapisanego,
zablokowanego gestu. Testy natywnego kontrolera są kierowane do Actions.

## Połączenie checkpointów z kontrolerem (2026-11-06)

Właścicielem checkpointu jest `SyncEngine.actorIdForDocument(uid)`, czyli
niezmieniony SHA-256 z JSON `[actorId, checkpointScope, documentId]`.
To ten sam aktor, który faktycznie trafia do `operations.actor_id`.
`SyncEngine.actorId` jest wyłącznie seedem urządzenia/konta i nie może
być użyty jako `editor_history.owner_id`. Zmiana naprawia wywołującego,
nie zmienia istniejącego formatu ID ani sekwencji dziennika. Różne
dokumenty tego samego konta zachowują niezależne historie i actorSeq.

Jeżeli kompletny stan notebooka przekracza limit kodowania pojedynczej
granicy historii, kontroler utrwala sam gest i outbox, resetując Undo/Redo
do pustego checkpointu o aktualnej głowie. Nie wolno cofać zapisu notatnika
z powodu wyłącznie limitu pamięci historii, ani zachowywać historii
odwracającej operacje sprzed nieprzechwyconego gestu. Błędy checksum,
tożsamości i brakujące media nadal blokują commit.



Kontroler opt-in v2 odczytuje historię aktora po otwarciu dokumentu,
ale nie hydratatuje wszystkich historycznych mediów. Każda granica
gestu, autosave tekstu oraz Undo/Redo zapisuje checkpoint przez
`onCommittedInTransaction`. Stosy UI zmieniają się dopiero po udanym
commicie operacji i historii. Ograniczenie 50 gestów / 4 MiB usuwa
najstarsze granice, nie treść notatnika. Odtwarzanie konkretnego
inverse weryfikuje bajty na żądanie; zmienione UID po tombstone
są przenoszone przez metadata-only remap. Zły checksum/scoping
blokuje nadpisanie historii, a nie zastępuje jej pustym snapshotem.


## Lokalne checkpointy historii v2 (2026-11-06, SQLite v8)

Addytywna migracja v7→v8 dodaje surową tabelę `editor_history`:
`document_id`, `owner_id`, `head_operation_id`, `payload_json`,
`checksum_sha256`; klucz to dokument i jego trwały lokalny aktor.
Głowa jest referencją do `operations` (RESTRICT przy usunięciu).
Checkpoint zawiera wersjonowane stosy Undo/Redo oraz deduplikowane stany
SHA-256, maksymalnie 50 gestów / 4 MiB UTF-8. To wyłącznie lokalne
metadane odzyskiwania, bez wysyłki przez API i bez użycia
`document_snapshots`, backupu lub odtwarzania legacy snapshotów.

`fitToByteBudget` jawnie przygotowuje mniejszy checkpoint: usuwa najstarsze
Undo, następnie najdalsze Redo, zachowując najbliższe kroki i scope/head.
Może zwrócić puste stosy, ale nie usuwa notatki, operacji ani outboxu.
`EditorHistoryBudgetExceeded` odróżnia limit zasobów od niepoprawnego
formatu, scope lub checksum. Wyłącznie limit można obsłużyć redukcją
historii; pozostałych błędów nie wolno w ten sposób maskować.
`remapIdentities` kodeka kopiuje wyłącznie metadane i zmienia typed ID
stron/obiektów, bez odczytu BLOB-ów lub SQLite. Zachowuje tekst Delta,
asset ID i zakres dokumentu; odrzuca kolizje. To granica przygotowania
inverse, nie operacja przywracająca wiersze. Kontroler preview używa go
wewnątrz transakcyjnego zapisu Undo/Redo; produkcyjny cutover jest otwarty.

Zapis przez `onCommittedInTransaction` należy do tej samej transakcji co
projekcja i outbox. Błąd wycofuje również operacje i actorSeq. Callback
może domknąć już zapisany autosave bez nowej operacji. Magazyn sprawdza
własność lokalnych operacji, dokument, checksum i aktualną głowę; obca
operacja lub tombstone blokuje zapis, nowsza głowa unieważnia odczyt
starej historii. Błąd odczytu nie nadpisuje dokumentu ani outboxu.

`EditorHistoryNotebookCodec.encode/decode` zapisuje wersjonowane metadane
notebooka/boarda, kolejność stron i warstw, ink, plain text oraz Delta
Quill. Obrazy/PDF i embedy mają wyłącznie scoped asset ID i receipt;
JSON nie zawiera bajtów, base64 ani ścieżek. Daty są normalizowane do UTC.
Wspólne bajty mogą mieć kilka ID: kodek wybiera najwcześniejszy trwały
receipt, więc późniejszy import nie zmienia starej granicy historii.

Encode zamraża metadane i fingerprinty mediów przed pierwszym await.
Wymaga już utrwalonych, zweryfikowanych bajtów; path-only import trzeba
materializować przed tą granicą. Decode zamraża wejście, waliduje format
i zakres, sprawdza receipt w dzienniku tego dokumentu, SHA-256, MIME,
rozmiar i sygnaturę BLOB. Działa również po usunięciu widocznego właściciela.
Nie wykonuje HTTP, plikowego I/O ani zapisów SQLite. Nie przywraca sam
obiektu w bazie: inverse nadal musi być nową operacją z nowym UID.

Zdalny commit unieważnia stare inverse jeszcze przed odroczonym patchem
UI. Zwykły lokalny zapis porównuje głowę checkpointu z głową sprzed
własnego wsadu, wewnątrz tej samej transakcji. Rozbieżność opróżnia
historię, zachowując operacje, projekcję i outbox. Do udanego dostarczenia
patcha kolejne gesty są trwale zapisywane z pustą historią; Undo/Redo
pozostaje zablokowane. Flaga oczekiwania nie blokuje samego retry patcha.
Po jego dostarczeniu nowe gesty mogą mieć normalne inverse. Restart
czyta aktualną projekcję SQLite; checkpoint nie legalizuje starego stanu
pozbawionego zdalnej treści. HTTP/SQLite regresja dwóch klientów obejmuje
ten wyścig, ponowne otwarcie bazy i zbieżność po Undo/Redo.

Stosy `EditorController` są podłączone w opt-in v2. Przy starcie zachowują
metadane checkpointów, a notebook wybranej operacji odwrotnej dekodują
przy użyciu, bez hydratacji 50 kopii mediów. Aktualne regresje kontrolera
po restarcie wymagają potwierdzenia CI; produkcyjny cutover jest otwarty.

## Lokalny zapis mediów v2 (2026-11-06, opt-in)

Nowy import inline używa `EditorController.prepareInlineAsset` dla
aktywnego bloku i `EditorV2OperationWriter.stageQuillAsset`. Typ jest
rozpoznawany z sygnatury bajtów zgodnie z walidatorem serwera
(PNG/JPEG/WebP/PDF), limit wynosi 64 MiB. Przygotowanie zwraca wyłącznie
`asset:<UUID>`, nie wykonuje HTTP ani nie tworzy operacji przed zmianą
Delta. Normalny gest Quill zapisuje attach, BLOB, atomy i outbox atomowo;
rejestr stagingu jest zwalniany dopiero po udanym commicie.
Podgląd nowego embedu czyta zweryfikowany staging w tym samym dokumencie
przed autosave, a następnie scoped BLOB z SQLite. Nie zapamiętuje błędu
spowodowanego samym oczekiwaniem na pierwszy commit.
Clipboard aktywnego Quill v2 podłącza import obrazów z bajtów oraz
kontrolowany HTML/rich paste przez `pasteQuillHtml` i `QuillPastePlan`.
Domyślny parser clipboard Quilla jest wyłączony: aplikacja sprawdza całą
Delta przed zastąpieniem zaznaczenia. Zachowuje tekst i formatowanie;
nowe media wymagają data URI, sygnatury PNG/JPEG/WebP/PDF i wspólnego
limitu 64 MiB. HTML konwerter obsługuje obrazy. Przycisk aktywnego Quilla
`Insert image or PDF into text` używa `insertQuillFile` i tego samego planu
z bajtów; PDF jest osadzony w tekście. Picker native sprawdza długość pliku
przed odczytem, Web korzysta z bytes. Przycisk obsługuje także prosty HUD v2;
legacy pozostaje bez zmian. HUD pożycza swój TextEditingController na czas
montażu. Import sprawdza całą TextEditingValue i model, zachowuje resztę
Delta i przekazuje kursor do nowego Quilla dopiero po poprawnym przyroście.
Anulowanie pozostawia HUD; pisanie przed importem zachowuje własne Undo.
Ctrl/Cmd+V i menu Paste używają tej samej walidacji. Surowe PNG/JPEG mają
limit strumienia 64 MiB, bez syntezy plików z URI schowka. Niepoprawna
selekcja UTF-16 lub zmiana kompozycji IME anuluje import.
Ścieżka pliku pochodzi wyłącznie z jawnego wyboru użytkownika;
HTTP, ścieżki w clipboardzie i nieznane embedy są odrzucane.
Kopiowanie między instancjami Quilla korzysta z jego wewnętrznej Delta,
ale referencje `asset:` muszą przejść kontrolę zakresu dokumentu, MIME,
rozmiaru i bajtów (również przed pierwszym autosave). Stare zdarzenie po
zmianie aktywnego bloku, treści, zaznaczenia albo właściciela widgetu jest
anulowane. Odmowa nie kasuje zaznaczenia ani nie tworzy operacji.
Parser HTML 1.5.3 był już zależnością transytywną; jest teraz zależnością
bezpośrednią bez zmiany wersji. Legacy zachowuje swój clipboard.
Nie włącza to protokołu v2 w produkcji.

Obraz/PDF jest weryfikowany lokalnie przez SHA-256, rozmiar i MIME,
a następnie zapisany wraz z `asset.attach` i outboxem w jednej transakcji
SQLite. `operation_asset_bytes` przechowuje również bajty zwykłych obrazów,
nie tylko embedów. Usunięcie obiektu lub strony nie usuwa tych BLOB-ów:
niepotwierdzona operacja może nadal wymagać wysłania pliku po restarcie.

Niepotwierdzone `asset.attach` w istniejącym outboxie stanowi trwałą
informację o oczekującym uploadzie; nie powstaje druga kolejka.
Runtime konta przed wysłaniem wsadu operacji odczytuje zweryfikowane bajty
z SQLite i wykonuje idempotentny PUT `/v2/assets/<sha256>`. Nieprawidłowe
potwierdzenie uploadu lub brak sieci wstrzymuje transport operacji,
zachowując lokalny dokument. Po utracie ACK można bezpiecznie powtórzyć
PUT; wyłącznie potwierdzenie operacji usuwa ją z outboxu.
Schemat SQLite pozostaje bez zmian. Pełny cutover i automatyczne
przygotowanie wszystkich wariantów embedów Quill pozostają do ukończenia.

Przy odtwarzaniu embedów Quill writer może ponownie użyć assetu
z historii `asset.attach` tego samego dokumentu. `localAssetReceipt`
sprawdza zgodność wszystkich utrwalonych potwierdzeń dla danego ID,
a bajty z SQLite przechodzą ponowną kontrolę SHA-256, MIME i rozmiaru.
Nowa scoped referencja powstaje w transakcji przed `text.insert`.
Usunięcie samego embedu, bloku albo strony nie usuwa bajtów potrzebnych
Undo. Nie daje to dostępu do assetów innego dokumentu ani do ścieżek/URL.

Zmiana stylu przez toolbar v2 nakłada tylko żądane atrybuty na istniejącą
Delta. Nie odbudowuje embedów ze zwykłego tekstu i nie usuwa
niezwiązanych stylów innych fragmentów. Kanoniczne fragmenty nadal
są zapisywane przez `text.format` z tymi samymi ID atomów i assetów.

## Przegląd v2 konta (2026-11-05)

W `AppScope` istnieje odizolowana, opcjonalna ścieżka operacyjnego
edytora dla konta już oznaczonego na serwerze jako v2.
Wymaga jawnego `--dart-define=NN_ENABLE_V2_ACCOUNT=true` i
odmawia uruchomienia, jeśli lokalna baza zawiera wciąż dokument v1.
Tworzenie dokumentów, tytuły, folder dokumentu i usuwanie
korzystają z `EditorV2OperationWriter`; aktywny edytor zapisuje
operacje i przyjmuje przyrostowe patche, bez legacy snapshotów.
Backup lokalny dostaje powiadomienie po commicie operacji.
Planer, Share i stary remote backup nie zostały przełączone.
Konflikt bez pełnego rebase blokuje odbiór zamiast nadpisywać.
Ścieżka jest testowa, domyślnie wyłączona. Brak zaliczenia
E2E i testów platform; produkcyjny cutover **nie jest zakończony**.

## Aktualny stan cutover (2026-11-04)

Od czystej instalacji tryby Local i każde konto mają oddzielne SQLite
oraz magazyny plikowe; Web ma odrębne IndexedDB i prefiksy localStorage.
`account_profile.json` pozostaje globalnym selektorem. Login/logout zmienia
aktywny magazyn po flush i zatrzymaniu writerów, bez automatycznego importu.
Nie aktywuje to jeszcze SyncEngine v2 ani Share v2: stare API v1 wciąż działa.
Dane sprzed resetu nie są automatycznie kopiowane do nowej struktury.

Źródło prawdy o statusie finalizacji: docs/ETAP_14_FINALIZACJA.md.
Etapy 11–13 nie zakończyły jeszcze migracji produkcyjnej. Native i Web
nadal uruchamiają aktywny zapis v1; SyncEngine v2 jest opt-in, a
server/ pozostaje zgodnościowym lustrem backendu dla testów. Usuwanie
tych ścieżek przed bezstratnym cutover grozi utratą danych.
Historyczne opisy poniżej dokumentują także stare ścieżki v1 i ich
kontrakt — nie oznaczają aktywacji v2 ani zgody na restoreDeleted.
Kanoniczny serwer NaNotateczki-serwer/main ma tylko odczytowy
scripts/stage14-retirement-audit.sh; kod 0 nie zastępuje akceptacji
E2E i weryfikacji zaległych kolejek na urządzeniach.

Nowy klient wykonuje uwierzytelnioną sondę `GET /v1/auth/protocol`
przed legacy recovery i sync. Konto z markerem v2 nie uruchamia
writerów v1; stan lokalny pozostaje zachowany. Samo wykrycie v2
nie oznacza jeszcze włączenia nowego edytora operacyjnego.

Ten dokument jest źródłem prawdy dla lokalnego zapisu, migracji, backupu
serwerowego i synchronizacji. Lokalny Drift/SQLite pozostaje podstawą pracy
offline również po zalogowaniu.

## Etap 2 — obsługa embedów Quill (2026-11-04)

Protokół operacji v2 dopuszcza w `text.insert` pojedynczy atom
`U+FFFC` z `embed: {"image": "asset:<assetId>"}` albo
`embed: {"pdf": "asset:<assetId>"}`. Poprzedzająca operacja
`asset.attach` wymaga ukończonego transportu pliku SHA-256. Projekcja
sprawdza obecność assetu przy tym samym obiekcie tekstowym i jego MIME.
Nie wolno odłączać assetu wykorzystywanego przez widoczny embed. Najpierw
należy usunąć atom przez `text.delete`. Ścieżki lokalne i URL zewnętrzne
nie są akceptowane jako referencje do embedów.

Produkcja nadal korzysta z writerów v1. Podłączenie edytora do
`OperationStore` jest osobnym etapem 3; bez niego obsługa embedów nie
stanowi jeszcze gwarancji synchronizacji E2E.

## Tryby danych

- Przy pierwszym uruchomieniu użytkownik jawnie wybiera rejestrację, logowanie
  albo tryb lokalny. `localOnly` wymaga wyłącznie lokalnej nazwy użytkownika
  i nie wykonuje żadnego połączenia z API.
- Konto powstaje dopiero po jawnym logowaniu. Na Linuxie, Web, Androidzie
  i iOS zwykły start uruchamia synchronizację konta, ale nie importuje
  archiwalnego backupu. Recovery verified backup jest osobną ścieżką
  uruchamianą tylko po wykrytej utracie bazy. Samo istnienie pustej
  biblioteki ani pierwsze otwarcie nowego magazynu nie oznacza utraty.
- Odtwarzanie backupu dołącza brakujące notatniki, pomija identyczne,
  a odmienną wersję zachowuje w tym samym folderze z pierwszym wolnym
  numerem `(1)`, `(2)` itd. Kopia ma nowe UID i ID wszystkich obiektów.
  Nie zastępuje istniejącego notatnika; pierwszeństwo nad backupem mają
  zdarzenia synchronizacji i tombstones. Foldery są łączone, a zadania
  konfliktowego planera trafiają pod UID jego kopii. Backup jest pobierany
  i weryfikowany tylko przy awaryjnym odzyskiwaniu; ponowny import już
  przetworzonego identyfikatora jest pomijany, chyba że system stwierdzi utratę lokalnej
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

Dla wyczyszczonych instalacji Local i każde konto mają odrębne SQLite
oraz pliki/klucze Web. Na logowaniu nie jest już automatycznie mieszany
lokalny notatnik z kontem; stara migracja dla instalacji z danymi nadal
wymaga jawnej, atomowej decyzji i konwersji (jeszcze niedostępna).

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

Kanoniczny kod wdrożeniowy znajduje się w repozytorium
`NaNotateczki-serwer/main`. Katalog `server/` aplikacji jest lustrem
zgodności używanym przez istniejące testy, a nie niezależnym backendem. PostgreSQL i API są dostępne tylko
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
   i buduje format `nanotateczki-server-backup` v2. SQLite i checkpoint
   odczytuje w jednej transakcji; sprawdza, czy pliki ustawień/planera nie
   zmieniły się podczas tego odczytu. Nie wysyła archiwum z lokalnym outboxem
   zawierającym niepotwierdzone operacje; outbox pozostaje nietknięty.
   Nowy envelope v2 zawiera `accountId`, `schemaVersion` i
   `operationCheckpoint`. Serwer waliduje zgodność z właścicielem;
   starsze poprawne archiwa v2 nadal można odzyskać.
   Podczas recovery do istniejącej bazy archiwum nie może cofnąć
   trwale zapisanego checkpointu lokalnego. Reset bazy zezwala
   na odzyskiwanie bez starego lokalnego kursora.
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
   okresie bezczynności (domyślnie 30 sekund; opcje: 15 s, 30 s, 1 min,
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
  Tombstone usuwa oryginalny UID. Tylko rzeczywiście odmienna niesłana
  edycja daje kopię konfliktową; usunięty UID nie odradza się automatycznie.
  Legacy flaga `restoreDeleted` jest ignorowana, również w zapisanym outboxie.
- Usunięcia są tombstonami. Outbox znika dopiero po potwierdzonym commicie.
- Trójstronne scalanie tej samej rewizji łączy niezależne dopiski,
  usunięcia i edycje obiektów bez tworzenia dodatkowych dokumentów.
  Baza JSON dokumentu i rewizja są utrwalane razem po każdym sync.
  Web automatycznie pobiera konto bez wyboru trybu Local.
- Po reconnect klient zawsze wywołuje `/v1/sync/changes?after=<cursor>`.
- Na wszystkich platformach po wznowieniu aplikacji i zapasowo co 45 sekund
  (10 sekund po błędzie) weryfikuje zmiany przez REST. Ścieżki obrazów
  przesyłanych przez konto są neutralne względem systemu plików urządzenia.
- Daty `createdAt` i `updatedAt` w protokole sync są normalizowane do UTC;
  lokalna strefa zwrócona przez SQLite nie oznacza zmiany dokumentu.
  Bazowy snapshot pozostaje identyczny z odpowiedzią serwera. Jeśli data
  utworzenia się nie zmienia, PUT zachowuje jej oryginalny zapis, aby
  nie naruszyć ochrony niezmiennych metadanych współdzielonego dokumentu.
- Feed zmian jest stronicowany maksymalnie po 5 zdarzeń i 8 MiB (pojedynczy
  dokument może przekroczyć miękki limit strony). Odpowiedź zawiera
  `hasMore`, a klient pobiera wszystkie strony. Bootstrap jest także
  stronicowany przez `next` (UID), żeby nie wczytywać całego konta jedną
  odpowiedzią. Odtwarzanie backupu pobiera komplet stron, w tym tombstones,
  przed rozstrzygnięciem o importowaniu starego dokumentu.

## Kontrola czasu urządzenia przy starcie konta

Po zalogowaniu i wznowieniu zapisanej sesji aplikacja odczytuje
`GET /v1/time` z własnego serwera. Endpoint zwraca milisekundy epoki
UTC bez cache; klient liczy różnicę od środka czasu żądania, mierząc
RTT monotonicznym `Stopwatch`. Przy różnicy większej niż 60 sekund
+ połowa RTT pokazuje 15-sekundowy SnackBar i zapisuje zdarzenie w
`AppErrorLog` (wysyłanym przez diagnostics). Pomiary o RTT ponad
10 sekund oraz skoki zegara podczas żądania są odrzucane.
Niedostępność sieci nie blokuje startu ani lokalnej pracy.
Porównanie działa jednak tylko przy poprawnym czasie serwera
(zalecana synchronizacja NTP). `DateTime.now().toUtc()` eliminuje
różnice stref, ale nie koryguje zegara urządzenia. Ostrzeżenie nie
zmienia reguł CAS/tombstones ani samo nie ustawia zegara.

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


## SQLite v6 — dziennik operacji (etapy 3–5 i poprawka etapu 12)

Legacy `EditorController.deleteLastPage` przekazuje jawnie usunięty page ID
do `NotebookRepository.saveNotebook`. Zabezpieczenie integralności może
dopuścić ubytek całej wskazanej strony bez mylenia go z uszkodzeniem
snapshotu. Każde nieoznaczone usunięcie pozostaje blokowane i logowane.
Nie zmienia to produkcyjnego protokołu sync v1 ani nie aktywuje v2.

Lokalna baza Drift jest migrowana addytywnie z v2 do v6. Migracja v3 → v4
odtwarza pageId z operacji usuwającej obiekt i zachowuje tombstones.
Migracja v4 → v5 dodaje trwały status `blocked` i opis błędu do outboxu,
bez usuwania operacji. Dalsza sekwencja tego samego aktora pozostaje
zatrzymana do świadomej naprawy; inni aktorzy nie są blokowani.
Migracja v5 → v6 przebudowuje jedynie tabelę `object_tombstones`, dodaje
kategorię `task`, zachowuje wszystkie wcześniejsze usunięcia i dziennik
operacji. `OperationStore` blokuje ponowne użycie skasowanego UID zadania.
`OperationStore`
zapisuje projekcję i operację z outboxem w jednej transakcji, a odbiór
zdalny zapisuje operację, projekcję i checkpoint w jednej transakcji.
ID oraz potwierdzenia muszą przetrwać ponowną wysyłkę i restart.
Tombstones blokują ponowne użycie usuniętego UID w nowym protokole.

Natywne SQLite pracuje z WAL i `synchronous=FULL`. Przy backupie bazy
nie wolno pomijać niezatwierdzonych stron WAL. Asset jest najpierw
utrwalany na dysku z checksumą, a następnie referencjonowany w transakcji;
nie wolno go fizycznie kasować przed potwierdzonym checkpointem GC.

**Przygotowanie lokalnej projekcji edytora v2 (opt-in, 2026-11-05):**
`EditorSqliteProjector` aktualizuje strony, ink i plain-text Quill
bezpośrednio w istniejących tabelach Drift w transakcji `OperationStore`.
`OperationStore.textAtoms` odtwarza trwałą sekwencję CRDT tekstu
z `operations` (zależności i atomowe tombstones nie są kompaktowane).
`EditorV2OperationWriter` spina `EditorOperationBridge` z
`SyncEngine.writeLocalBatch`, wymagając tej samej instancji bazy.
`EditorController(operationWriter: ...)` wybiera go opcjonalnie
zamiast wywołań legacy saveNotebook/saveNotebookPages. Kontroler
utrzymuje potwierdzony baseline i serializuje zapisy; repozytorium
rezerwuje UID za pomocą `registerOperationWriter` i blokuje stare
snapshoty, import, restore, metadata i delete na zajętym UID.
Po zapisaniu pierwszej operacji trwały dziennik `operations` dodatkowo
blokuje v1 przez `_requireLegacyWritable` także po zamknięciu edytora,
utworzeniu nowego repozytorium i restarcie aplikacji. Każdy legacy
writer ponawia kontrolę wewnątrz transakcji, a automatyczna migracja
legacy gumki nie może przepisywać strony z v2 operacjami.
W opt-in v2 Undo/Redo tworzy nowe operacje odwrotne na podstawie
zatwierdzonych lokalnych stanów (do 50 w bieżącej sesji). Odtwarzane
strony i obiekty otrzymują nowe identyfikatory zamiast ponownego użycia
trwałych tombstones. Równoległy gest podczas inverse nie jest nadpisywany,
lecz blokuje dalszy commit do rozstrzygnięcia. Historia Undo/Redo nie jest
jeszcze trwała między restartami; nie stanowi mechanizmu recovery.
Obsługuje już tworzenie nowych obrazów/PDF z potwierdzonych transferów
przez `VerifiedEditorAssetBuffer`: `object.create` zapisuje wyłącznie
metadane w dzienniku, a dopiero `asset.attach` zapisuje bajty do
`image_block_rows.bytes` i trwałą referencję w tej samej transakcji.
`OperationAssetGateway.uploadAndStage/downloadAndStage` weryfikuje
SHA-256, rozmiar i MIME poza transakcją. `SyncEngine.prepareRemoteOperation`
może przygotować pobranie przed lokalnym `applyRemote`, tak aby brak
assetu nie przesunął kursora. Zapisane bajty nie zależą od życia
bufora; jest to rozwiązanie opt-in, potencjalnie kosztowne dla dużych
obiektów BLOB.
W trybie opt-in obsługuje już podmianę zweryfikowanych obrazów/PDF
przez `asset.attach → object.set(assetId) → asset.detach`, a także
ich usuwanie i atomowe usuwanie stron z prawidłowymi referencjami.
Przy przekazanym `OperationAssetGateway` zwykłe wstawienie lub podmiana
obrazu przygotowuje automatyczny upload i zweryfikowany bufor **przed**
otwarciem transakcji. Brak gateway, błędny checksum lub przestarzały
receipt blokują całą operację bez snapshotowego zapisu awaryjnego.
Świeży notatnik może zostać utworzony bez v1 przez
`EditorV2OperationWriter.writeCreateNotebook`: `document.create`,
`page.create` i ewentualna zawartość są zatwierdzane w jednej transakcji
SQLite wraz z actorSeq i outboxem. `document.set` aktualizuje tytuł
i folder, a `writeDeleteNotebook` usuwa lokalną projekcję i zachowuje
tombstone w trwałym dzienniku. Produkcyjny `AppScope` nadal nie
wykorzystuje tych metod, więc nie stanowią cutover.
Nie usuwa fizycznych plików. `prepareRemoteMedia` może ponownie
pobrać zawartość po restarcie na podstawie receipt z dziennika;
aktywny `AppScope` jeszcze tego nie konfiguruje.
Przenoszenie niezmienionego bloku Quill między stronami działa przez
`object.move`, z zachowaniem pierwotnej historii CRDT indeksowanej po
identyfikatorze obiektu w całym dokumencie. Osadzone assety Quill,
równoczesne przenoszenie i zmianę treści, zakładanie dokumentów v2
oraz pełny rebase nadal blokuje. `asset.detach` usuwa tylko referencje, których
nie używa bieżący Quill; nie usuwa bajtów ani aktywnych obrazów. Niezmieniona kreska może być przeniesiona między
stronami przez `object.move` bez usuwania jej ID. Obraz może być
przeniesiony wyłącznie przy niezmienionych bajtach/MIME i trwałej
scoped referencji assetu: jedna transakcja aktualizuje pageUid,
sortIndex i `asset_references`, nigdy nie usuwa oryginalnego pliku.
Aktualizacje pojedynczych pól mają rank `(clock, actor, seq, ID)`
wyliczony z trwałego dziennika, niezależnie od kolejności dostarczenia.
Nadal brakuje konfliktów jednoczesnych move i materializacji wersji
dla długiej historii.
`EditorV2RemotePatchDispatcher` wprowadza zatwierdzone zdalne zmiany
pojedynczego obiektu/strony po SQLite commit, a zajęty edytor blokuje
callback do ponowienia bez odmalowywania całego dokumentu.
Produkcja nadal nie przekazuje do `EditorController` tego writera
ani nie wiąże dispatcher z aktywnym `AppScope`.
Wielokrotne odczytywanie atomów z pełnego dziennika ma ograniczenie
wydajnościowe; wymagane będą sprawdzone checkpointy tekstu.
Ta implementacja nie daje zgody na uruchomienie v2 dla kont produkcyjnych.

**Granica kompatybilności:** istniejące zapisy snapshotowe nie zostały
jeszcze przepięte do `OperationStore`. W etapie 5 należy wymagać jego
transakcyjnego użycia przez wszystkie mutacje lokalne oraz uniemożliwić
równoczesny zapis starym i nowym protokołem tego samego dokumentu.
`operations` nie wolno automatycznie czyścić na podstawie samego ACK;
potrzebne są potwierdzone snapshoty i bezpieczna retencja zależności.

Szczegóły i scenariusze: `docs/ETAP_3_SQLITE.md`.

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
Host synchronizuje jasny/ciemny motyw i styl tła (Plain, Grid, Lines oraz
odstęp) przez osobne `PUT /v1/study-shares/{id}/appearance`. API zapisuje
ten stan w `study_shares.edit_clock['_appearance']` (bez migracji SQL)
i rozsyła `appearance_changed` po WebSocket. Gość pobiera wygląd przez
`GET /document` niezależnie od rewizji treści. Zwykły pasek potwierdzeń
zapisu został usunięty; błędy nadal są wyświetlane.

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
Host ponawia odbiór po 120 ms, dopóki trwa lokalna edycja, zamiast
chwilowo podmieniać widoczne fragmenty.

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
Dla aktywnych wpisów tego samego ID wygrywa późniejszy znacznik
modyfikacji w UTC, osobne ID scalają się niezależnie. Potwierdzone usunięcie
jest trwałym tombstone: ma pierwszeństwo nawet nad edycją z zegara
ustawionego w przyszłość, a stare PUT nie mogą przywrócić tego samego ID.
UTC usuwa różnicę stref, ale nie rozbieżność zegarów urządzeń; pełne
rozstrzyganie równoległych aktywnych edycji nadal wymaga rewizji/CAS.
Zegar odliczający sesji nie generuje zapisu w każdej sekundzie, tylko
przy zmianach stanu. Po błędzie połączenia wpisy pozostają w pliku
i są ponawiane.
Wymagana migracja PostgreSQL: `0008_planner_entries.sql`.

## Pierwszeństwo live sync nad asynchronicznym backupem

Nowa ścieżka startu sprawdza trwały marker otwarcia bazy per konto:
nowy magazyn bez markera uruchamia normalną synchronizację, natomiast
brak wcześniej otwieranej SQLite/IndexedDB z markerem albo potwierdzona
kwarantanna uruchamia awaryjne odzyskiwanie. Marker jest zapisywany
dopiero po inicjalizacji konta. Recovery następnie uruchamia synchronizację;
nie promuje automatycznie checkpointu historycznego backupu ponad aktualny
kursor serwera. Zwykłe logowanie nie skanuje archiwów.

**Ograniczenie etapu 9:** produkcyjny edytor nadal używa starego
protokołu snapshotowego, dopóki etap 11 nie przeprowadzi migracji operacji.
Pełny replay operacji v2 ponad snapshotem i oddzielne content-addressed
assety backupu wymagają tej migracji; nie wolno przedstawiać ich jako
wdrożonych. Szczegóły w `docs/ETAP_9_BACKUP_RECOVERY.md`.



Ważna jest chwila lokalnej edycji i przyczynowa rewizja danych, nie czas
zweryfikowania ani wysłania snapshotu backupu. Backup jest archiwum
awaryjnym, a nie operacją edycji wpisów konta. Po restarcie urządzenia
live-sync na serwerze wraz z tombstones jest autorytatywny. Podczas
odzyskiwania starego `study_planner.json` backup może dołączyć jedynie
wpisy o identyfikatorach nieobecnych zarówno w bieżącym planie lokalnym,
jak i w pełnym stronicowanym feedzie planera na serwerze (w tym tombstones).
Nie zastępuje lokalnych edycji ani usunięć i zachowuje niezależne wpisy
z backupu.
W żadnym razie nie wolno ustalać pierwszeństwa poprzez `verifiedAt`.
Dla dwóch niepowiązanych edycji offline same zegary UTC nadal nie
gwarantują deterministycznej kolejności; wymagany jest protokół CAS
na poziomie poszczególnych wpisów.

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
potwierdzonej nowszej tożsamości. Historyczna flaga `restoreDeleted` jest
ignorowana przez serwer i nie upoważnia do przywrócenia skasowanego UID.
Rzeczywista, niepotwierdzona edycja drugiego urządzenia musi pozostać
zachowana lokalnie do jawnego rozstrzygnięcia; nie wolno jej bezgłośnie
skasować ani użyć starego backupu do odtworzenia oryginalnego UID.
Dopiero świadome utworzenie nowej tożsamości może prowadzić do nowego
dokumentu. Wspólna sesja udostępniania zakończona przez usunięcie
nie jest automatycznie przywracana.

### Ochrona usunięć przed archiwalnym backupem

Przy odzyskiwaniu verified snapshotu nie wolno dołączać całej historycznej listy folderów ani okładek. Dopisywane są tylko ścieżki (z przodkami) dokumentów faktycznie odzyskanych po sprawdzeniu aktualnych tombstones; zadania można przenieść wyłącznie dla ich zmapowanych UID. Wylogowanie i przejście konta do Local wymagają najpierw opróżnienia zapisów, synchronizacji oraz potwierdzenia końcowego backupu, a w razie błędu pozostawiają aktywną sesję i jej kolejkę.

## Potwierdzenia share i granice kolejności

Host nie może instalować zaakceptowanej rewizji udostępnionego dokumentu
podczas aktywnego gestu ani przy nieskończonym zapisie lokalnym.
Potwierdzenie serwera nie oznacza automatycznie, że nowa rewizja została
już pokazana. Klient zachowuje ostatnią widoczną bazę i rebazuje kolejny
lokalny zapis na rewizji zaakceptowanej, unikając usuwania dopisków gościa.
Różnica w samym `updatedAt` bez różnicy stron nie powinna wywoływać
ponownego importu i migania.

Serwerowy `GET /v1/time` służy dziś do oceny dryfu zegara.
Wspólny absolutny czas niezależny od zegarów urządzeń nie istnieje bez
synchronizacji i granicy błędu pomiaru. Aktualna reguła konfliktu share
nadal rozstrzyga równoczesne zmiany tego samego obiektu kolejnością
przyjęcia na serwerze; nie należy przedstawiać jej jako kolejności
fizycznych ruchów na urządzeniach. Pełna gwarancja pracy lokalnej i
równoczesnej wymaga operacji per obiekt, identyfikatorów aktorów i zegarów
logicznych/CRDT oraz inkrementalnego renderingu, bez globalnego
podmieniania snapshotów. To wymaga osobnej migracji protokołu.

## Protokół operacji v1 — etap 1 (przygotowany, nieaktywny)

`lib/data/sync/operation_protocol.dart` opisuje zamiar użytkownika oddzielnie
od aktualnego snapshotu i backupu. Operacja ma stabilny `operationId`,
`actorId`, rosnący `actorSeq`, `logicalClock`, zależności, typ i payload.
`documentId`, `pageId` i `objectId` odwołują się do trwałych ID, nie do
pozycji na ekranie. Nowy model nie jest jeszcze podłączony do Drift ani
API v1. Nie interpretować go jako ukończonej migracji lub naprawy share.
Specyfikacja: `NaNotateczki-serwer/docs/OPERATION_PROTOCOL_V1.md`.

## Porządkowanie operacji v1 — etap 2 (nieaktywne)

`OperationActorClock` używa licznika logicznego Lamporta bez wall-clock.
`CausalOperationBuffer` nie wykonuje operacji z brakującym poprzednikiem
aktora ani z brakującymi zależnościami. Identyczne retransmisje są
idempotentne, ale powtórne wykorzystanie ID/actorSeq z innym payloadem jest
błędem protokołu. Dla tego samego pola wygrywa para logicClock/actorId/
actorSeq/operationId; tombstone nie pozwala wskrzeszać usuniętego UID.
Nowy bufor waliduje cały zestaw gotowych operacji przed zatwierdzeniem
zmian w pamięci. Wadliwa zaległa operacja zostaje odizolowana, bez utraty
poprawnego potwierdzenia. Checkpoint etapu 2 przechowuje komplet zaakceptowanych
operacji i identyfikatory odrzuconych; nie wolno zastępować go samym licznikiem
aktora ani kompaktować bez trwałego indeksu ID. Zegar aktora zachowuje
zaobserwowane zależności również po odtworzeniu i wiąże aktora
z jednym dokumentem. Pokryte przyczynowo frontiery są redukowane;
ponad 256 niezależnych zależności nadal zatrzymuje zapis, zamiast
cichego obcięcia.
Backend posiada opt-in API v2 po etapie 4 i trwały outbox etapu 5.
Klient nadal nie ma domenowych reducerów ani migracji produkcyjnej.
Dotychczasowa synchronizacja
API v1 i share nadal działają na snapshotach. Nie przełączać użytkowników
na protokół operacji przed migracją i testami end-to-end.


## Share v2 — etap 6 (warstwa przygotowana, migracja nieaktywna)

Istnieją reduktory zmian konkretnych obiektów, nakładka lokalnych
niepotwierdzonych operacji, CRDT tekstu z tymi samymi zasadami w Dart i
FastAPI oraz trwały SQLite WASM gościa izolowany przez parę
`shareId` + trwałe `guestActorId`. Identyfikator aktora musi przetrwać
reload w ramach tego samego uprawnienia; zmiana grant/ticket wymaga
jawnego wznowienia lub migracji kolejki, nie cichego przejęcia.
`EditorController` ma metodę nałożenia pojedynczej zatwierdzonej zmiany
bez resetowania widoku. To **nie jest jeszcze produkcyjny kanał Share**:
legacy `StudyShareGuestEditor` i `LiveWebSyncService` nadal korzystają
z JSON snapshotów. Serwer prawidłowo blokuje v2 dla tych UID do czasu
bezpiecznej migracji z etapu 11. Nie uruchamiać dwóch writerów naraz.
Nowy kanał nie synchronizuje jeszcze Quill delta formatting ani assetów
PDF/obrazów; podgląd nietrwałych fragmentów kreski wymaga integracji.
Szczegóły: `docs/ETAP_6_SHARE_OPERATIONS.md`.

## Operacyjny silnik v2 — etap 5, bez przełączenia produkcyjnego

`SyncEngine` i `HttpOperationGateway` obsługują trwały dziennik SQLite,
kolejkę operacji, stronicowany odbiór po kursorze, ACK bez ponownej projekcji,
REST po reconnect oraz powiadomienia WebSocket. Nowy lokalny ruch jest
zapisywany atomowo z projekcją, zależnościami przyczynowymi i actorSeq.
Odrzucony lub utracony ACK nie usuwa niepotwierdzonych danych. Opóźnione
zdalne operacje dotyczące trwałych tombstones są rejestrowane bez
wskrzeszania obiektów.

**Ta warstwa nie zastępuje jeszcze produkcyjnego `LiveWebSyncService`.**
Backend v2 odrzuca UID zapisane dotychczasowym API v1; do czasu etapu 11
nie wolno uruchamiać dwóch writerów dla jednego dokumentu. Etap 6 musi
dostarczyć domenowe projektory obiektów i CRDT/OT dla tekstu, a etap 7
osobne przestrzenie aktora/outboxu dla kont, Local i gościa. Szczegóły
implementacyjne i niewykonane testy E2E: `docs/ETAP_5_SYNC_ENGINE.md`.


## Infrastruktura etapów 7–8 (2026-11-03, niewłączona produkcyjnie)

`StorageNamespace` definiuje docelowe oddzielne lokalne bazy i magazyny:
`local/`, `accounts/<SHA-256 identyfikatora>/` i
`shares/<SHA-256 sesji i aktora>/`. Natywne SQLite i text storage obsługują
zagnieżdżone ścieżki; webowy magazyn SQLite otrzymuje osobny identyfikator
IndexedDB dla każdej przestrzeni. `StorageNamespaceManager` unieważnia
opóźnione odpowiedzi sieciowe i po nieudanym przełączeniu pozostaje
nieaktywny, zamiast ujawniać niepełne dane jako prawidłową bibliotekę.

**Uwaga:** `AppScope` dla czystych instalacji otwiera odrębne namespace
Local i każdego konta. Starsze dane z katalogu głównego nie są importowane.
Automatyczne kopiowanie Local do konta pozostaje zabronione do czasu
wdrożenia jawnego importu i weryfikacji danych.

Serwer `NaNotateczki-serwer/main` udostępnia opt-in
`/v2/planner/entries` (migracja `0011_planner_revisions.sql`):
porównywanie rewizji CAS, trwałe tombstones oraz identyfikatory operacji
umożliwiające bezpieczny retry. Nowy `PlannerRevisionLedger` i
`PlannerSyncService(useRevisions: true)` zachowują checkpoint w magazynie
konta i nie porównują konfliktów według czasu urządzeń. Stary
`PlannerSyncService` pozostaje domyślny. Migracja
`0012_task_tombstones.sql` rozszerza operacyjny dziennik v2 o usunięcia
pojedynczych zadań. Projekcja `folder.*` pilnuje braku cykli, a `task.*`
wprowadza niezależne operacje per UID.

Pełna integracja drzew folderów, listy zadań i importu Local → konto
wymaga nadania istniejącym danym stabilnych identyfikatorów i atomowej
migracji w etapie 11. Dotychczasowe `library_folders.json` i
`study_planner.json` nie są zastępowane automatycznie.
Opis granic: `docs/ETAP_7_8_STORAGE_PLANNER.md`.


### Etap 11: przygotowanie odizolowanych magazynów (bez przełączenia)

Natywny skrypt offline tool/stage11_migrate.py kopiuje i weryfikuje SHA-256
starej SQLite, WAL, istniejących assetów, preferencji, danych planera,
tombstones i outboxu do izolowanego katalogu Local lub przypisanego konta.
Odrzuca błędny identyfikator konta, uszkodzoną bazę i brakujące assety.
Pozostawia nietknięte wszystkie źródła i zapisuje manifest
staged-not-activated. Aplikacja wciąż używa wspólnego notes.sqlite.
Przełączenie AppScope, Web/IndexedDB, import Local→konto i migracja serwera
v1→v2 NIE są jeszcze ukończone; nie uruchamiać dwóch writerów ani nie
usuwać danych źródłowych. Szczegóły: docs/ETAP_11_MIGRATION.md.


### Etap 10 — shutdown, sesje i trwały outbox

ShutdownCoordinator ogranicza cały proces zamknięcia i wylogowania do
30 sekund. Kolejność: lokalny zapis, synchronizacja, verified backup,
zatrzymanie live writerów, wylogowanie. Wyjście offline nie wysyła
snapshotu, ale jest dozwolone wyłącznie po bezpiecznym utrwaleniu
lokalnych danych; outbox i checkpointy pozostają na dysku.
Po błędzie zatrzymania aktywnego writera nie wolno czyścić sesji.
Zdalne odwołanie tokenu podczas wylogowania ma timeout 5 s; bez sieci
nie jest gwarantowane zdalne unieważnienie poświadczenia.
Testy i granice: docs/ETAP_10_SHUTDOWN.md.

### Etap 11 — stale staging

Kopia przygotowana przez tool/stage11_migrate.py jest tylko stagingiem.
Przed jej ponownym użyciem trzeba ponownie sprawdzić SHA-256 każdego
pliku źródła; zmianę źródła traktować jako blokadę cutover, a nie
zezwolenie na zastąpienie nowszego SQLite starszym stagingiem.
Nie aktywować staged namespace ani v2 API bez kontrolowanej migracji
serwera, modelu operacyjnego, tokenów oraz testów E2E.

## Bezpieczna bariera v1/v2 — etap 13 (2026-11-04)

Po migracji SQL 0013 `account_sync_protocol` wskazuje konto świadomie
aktywowane dla nowego protokołu operacji. Brak wiersza oznacza v1.
Backend sprawdza marker pod transakcyjną blokadą właściciela na v1
PUT/DELETE i na v2 batch. Sama flaga `OPERATIONS_V2_WRITE_MODE` nie
przenosi konta, a API v2 ma domyślnie blokadę zapisu.
Narzędzie `scripts/stage13-activate-empty-canary.sh` działa jedynie dla
zupełnie pustego konta testowego przy wyłączonym API.

Nie istnieje jeszcze produkcyjna migracja istniejących dokumentów v1,
assetów, checkpointów oraz lokalnego outboxu do v2. `AppScope` otwiera już odrębne magazyny dla czystych instalacji, ale
wciąż używa `LiveWebSyncService` v1. Przełączenie silnika operacyjnego,
Share v2 i aktywny import Local do konta pozostają otwartymi blokadami.
NIE uruchamiać tego narzędzia na realnych danych i nie używać starej
wersji API po aktywacji konta v2.


## Stage 2 v2 — tekst formatowany i pliki (2026-11-04)

Nowe reduktory protokołu, ale **nie produkcyjny cutover**:
- `text.insert` przechowuje opcjonalne atrybuty Quill; `text.format`
  aktualizuje per-atom atrybuty według rankingu Lamport. Usunięcie stylu
  używa `null`. `OperationTextSequence.renderDelta` odtwarza formatowanie.
- `object.move` przenosi obiekt z `pageId` do `toPageId`, zachowując
  pozostałe właściwości. Porządek na stronie określa `sortIndex`
  i stabilny identyfikator obiektu.
- `OperationAssetGateway` przesyła obrazy PNG/JPEG/WebP i PDF po SHA-256.
  Backend zapisuje pliki w `/data/assets-v2/<owner>/<prefix>/<sha256>`.
  `asset.attach` wymaga zweryfikowanego pliku i rekordu właściciela
  `verified_assets`; `asset.detach` usuwa wyłącznie referencję.
  Po pobraniu klient ponownie sprawdza checksum oraz rozmiar.
- Serwer wymaga dodatkowej **migracji 0014_verified_assets.sql** przed
  wdrożeniem API. Zastosowanie jej nie aktywuje konta v2.
- Przy konwersji edycji Quill terminalny znak nowej linii pozostaje
  w atomach CRDT, nawet jeśli `TextBlock.text` jest zapisany z trimRight.
  Rozbieżna treść Delta jest odrzucana.
- `EditorOperationBridge` może planować osadzane obiekty Quill z
  kanoniczną referencją `asset:<id>` i ukończonym, zweryfikowanym
  uploadem. Bez tego przerywa planowanie. Wymiana obrazu/PDF wymaga
  trwałego ID poprzedniego assetu i oddzielnego nowego assetu.
  To nadal nie jest aktywna ścieżka produkcyjna; edytor zapisuje v1
  do zakończenia i weryfikacji pełnego kroku 3.

Nie wolno usuwać aktywnych writerów v1 ani włączać v2 dla kont produkcyjnych
tylko z powodu dodania tej migracji i reduktorów.

**SQLite v7 (2026-11-05):** nowa tabela `operation_asset_bytes` przechowuje
checksumowane BLOB obrazów i PDF osadzonych w Quill. `asset.attach` na
obiekcie tekstowym atomowo zapisuje bajty i scoped referencję;
`text.insert` wymaga jej przed użyciem embeda, a `asset.detach` usuwa
tylko referencję. Bajty pozostają do późniejszego GC i są dostępne
przez `verifiedTextAssetBytes` po restarcie i wyczyszczeniu bufora.
Migracja v6→v7 jest addytywna; render Quill embedów w aktywnym edytorze
i pełne E2E nadal wymagają osobnej weryfikacji.

W trybie opt-in v2 Quill obraz jest renderowany przez `Image.memory`
na podstawie zweryfikowanego BLOB; PDF pokazuje oznaczenie osadzonego
pliku (nie strony PDF). Brak assetu pokazuje ikonę błędu.
