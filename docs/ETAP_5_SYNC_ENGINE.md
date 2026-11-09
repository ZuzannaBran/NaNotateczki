# Etap 5 — silnik synchronizacji operacji v2

## Atomowa odpowiedź ACK i kontrola aktora (2026-11-09)

W przebiegu 42595806151 aplikacji przeszło 16/17 zadań;
pozostała wyłącznie poprawka formatowania jednego testu.
Backend 42595781685 przeszedł w całości. Wprowadzono
dokładny diff formattera przed nową serią zmian.

SyncEngine przekazuje cały zestaw receiptów do jednej
transakcji SQLite przez OperationStore.acknowledgeBatch.
Przy awarii zapisu potwierdzenia, rozbieżnym powtórnym
ACK, nieznanym lub zdalnym-only operationId, duplikacie
kursora, błędnej kolejności actorSeq czy przekroczeniu
2^53-1 nie wolno usunąć żadnej operacji z paczki.
Weryfikacja działa również dla alternatywnych gatewayów
i lokalnego store, a nie tylko dla klienta HTTP.

Po stronie serwera validate_batch_receipts kontroluje
wszystkie receipt przed session.commit(): kompletność,
operationId, poprawny status, unikalny numer globalnego
kursora, bezpieczny zakres liczbowy i monotoniczne kursory
wewnątrz aktora. Niewłaściwe ACK kończy transakcję błędem
bez emisji potwierdzenia. Backend i mirrory app/dev mają
taką samą implementację i testy kontraktu.

Nie zmieniono zapisu v1, schematu SQLite/Drift ani
komunikacji legacy. Pełny rebase zmian tego samego obiektu
wraz z object.move oraz migracja stage-11 nadal
wymagają osobnego wdrożenia.

## Rebase niezależnych page.delete i integralność ACK (2026-11-09)

W przebiegu 42591095132 przechodziło 16/17 zadań (backend
42591078056 zielony). Pozostała kontrola formattera dwóch
testów; zastosowano dokładny diff CI bez zmiany logiki.

Rozszerzono V2OutboxConflictPolicy o page.delete dla
rozłącznych stron i niezależnych danych dokumentu: page.set,
document.set, stroke.create, ink/Quill set/format/insert/delete
na innych stronach. Nie wolno usuwać strony z równoległą zmianą
tej samej strony, object.move, page.create, inną destrukcyjną
operacją lub asset attach/detach. Regresje: 32 grupy testów
polityki i cztery REST/SQLite z utrzymaniem kursora/outboxu,
w tym lokalne i zdalne page.delete oraz konflikt tytułu.

Dodatkowo w HttpOperationGateway i SyncEngine odrzucane są
różne operationId z tą samą pozycją ACK; nie można dzięki
sfałszowanemu lub wadliwemu potwierdzeniu usunąć dwóch
lokalnych intentów. Testy sprawdzają brak ACK w storage
i zachowanie oryginalnych operationId.

Na backendzie reduktor v2 przygotowuje kopię zmienianego
węzła przed walidacją: folder.create/move/set, task.create/move,
object.move/create, asset.attach/detach i text.insert/delete/format.
Niepowodzenie walidacji nie może pozostawić częściowych zapisów
nawet w pamięci, a zweryfikowany sukces przechowuje właściwe
wersje i wywołuje istniejącą atomową transakcję PostgreSQL.
Rangi scalar/asset/move sprawdzają teraz zakresy i format UUID
oprócz typów; testy są w obu repozytoriach.

Dla production v1 nic się nie zmienia. Pełny rebase konfliktów
tego samego obiektu oraz migracja starych danych nadal wymagają
kolejnych etapów i przejścia całej macierzy CI.

## Etap 5: tworzenie stron obok outboxu offline (2026-11-09)

W przebiegu CI 42587383593 przeszło 16 z 17 zadań, w tym Android,
iOS na iPhonie i iPadzie, Linux, Windows, macOS, Web oraz Linux E2E
z realnym backendem. Jedyna porażka: trzy drobne odchylenia od
standardowego formattera Dart; uwzględniono dokładny diff.
Na samym CI nie stwierdzono regresji SQLite ani backendu.

`V2OutboxConflictPolicy.canApply` pozwala przyjąć zdalne
`page.create` obok lokalnych `document.set`, `page.set` innych
stron i niezależnych operacji obiektowych na istniejącej stronie.
Działa też odwrotna kombinacja z lokalnym `page.create` oraz
zdalnymi metadanymi. Nie przepuszcza równoległego tworzenia stron
(zależna kolejność), zmian tego samego UID, destrukcyjnych
usunięć, `object.move` ani operacji na dopiero tworzonej stronie.
Zmiany nadal są zatwierdzane w dotychczasowej transakcji SQLite.

27 testów polityki konfliktów obejmuje nowe granice tworzenia stron,
a testy REST/SQLite sprawdzają kursor, lokalny outbox, tworzenie
strony przy lokalnym ink i metadanych oraz brak duplikatów po
restarcie plikowej SQLite. Kolizja UID zatrzymuje kursor bez
nadpisania strony. Pełny rebase move/delete i cutover v1/v2
pozostają niedostępne.

## Natywna biblioteka i kolejne bezpieczne scalanie (2026-11-09)

Najnowszy przebieg 42582273859: analiza i formatowanie Dart są
zielone, Linux z realnym backendem v2 i backend API także; większość
czerwonych platform otrzymywała niepoprawną odpowiedź zamiast natywnego
artefaktu sqlite3. Suma otrzymanej treści była identyczna na różnych
architekturach, a oczekiwane SHA-256 różne. Ponawianie trzy razy
nie rozwiązywało problemu. Nie zmieniamy sum kontrolnych.

W pubspec.yaml ustawiono hook sqlite3 3.x na `source: system`,
korzystający z bibliotek już dostarczanych przez wtyczkę
sqlite3_flutter_libs 0.5.x lub system operacyjny. Nie zmieniano
schematu Drift, danych ani wersji protokołu. CI sprawdza natywną
bibliotekę, transakcje, JSON, FTS5, zapis WAL i ponowne otwarcie
pliku. Na mobilnych OS integracje nadal potrzebują potwierdzenia
na nowym buildzie. Czysty test Bash kontroluje konfigurację hooków.

V2OutboxConflictPolicy dopuszcza teraz operacje obiektów podczas
lokalnego document.set/page.set, symetrycznie do istniejącej reguły
zdalnych metadanych. Każdy lokalny intent pozostaje w outboxie,
bez zmiany actorSeq i kolejności ACK. Destrukcyjne usunięcia
i wspólne pola nadal blokują niebezpieczne scalanie.

Jedno assetId można wykorzystać dla dwóch różnych właścicieli
tylko gdy oba asset.attach niosą identyczny, pełny i zweryfikowany
receipt: SHA-256, MIME, długość i identyfikator. Wspólne ID przy
różnych bajtach, obrazach bez receipt albo embedach pozostaje
blokowane. Regresje Dart obejmują 22 przypadki polityki oraz
dwa nowe scenariusze REST/SQLite z niezależnym outboxem.

Etap 5 i migracja v1 → v2 nadal nie są zamknięte. Zmiany muszą
przejść pełną macierz CI; produkcyjne przełączenie pozostaje opt-in.

## CI infrastruktury i korekta reduktora (2026-11-09)

Przebieg 42579587105 na 39069bb wykazał rozbieżności formattera
w czterech plikach Dart (poprawione według dokładnego diffu CI).
Backend 42579584141 zakończył się sukcesem.

Dodatkowe niepowodzenia platform wynikały z HTTP 504 dla Gradle
oraz nieprawidłowych sum SHA-256 przy pobieraniu natywnego SQLite.
Testy nie mogą akceptować innej sumy ani pomijać kompilacji.
W CI dodano do trzech prób wyłącznie przy tych błędach, z zachowaniem
pierwotnego zakończenia niepowodzeniem dla zwykłych testów.
Gradle 8.14 pobiera teraz dystrybucję z downloads.gradle.org
bez pośredniego przekierowania do GitHub Releases.
Weryfikację podpisanego iOS Release zastąpiono prawdziwym
xcodebuild Release na fizyczny SDK z CODE_SIGNING_ALLOWED=NO;
w CI nie ma profilu deweloperskiego. Nie potwierdza to eksportu IPA.

W regule konfliktów wycofano dopuszczanie object.transform i
object.reorder dla bloku tekstowego: obecny reducer SQLite obsługuje
w tym przypadku geometrię przez object.set. Niepoprawny zdalny patch
nie może wyprzedzać lokalnego outboxu. Test
test/v2_outbox_conflict_policy_test.dart sprawdza obie odmowy,
zachowując dozwoloną kombinację text.insert + object.set.

Kontraktowy test Bash jest w
.github/scripts/test_flutter_transient_network_retry.sh.
Zweryfikowano go lokalnie przez mocki: hash → retry, HTTP 504 →
retry, trwały błąd → odmowa, asercja testu → odmowa. Testy
Flutter i Xcode nadal wymagają wyników nowego CI. Aplikacja
pozostaje opt-in; pełnego rebase i cutover nie wdrożono.

## Rozszerzony rebase i integralność (2026-11-09)

Wynik poprzedniego CI 42527261951: 16/17 zadań zielonych, w tym
iPad; nieudane było wyłącznie formatowanie nowych testów. Dokładny
format obu plików odtworzono z diffu CI przed dalszymi zmianami.

V2OutboxConflictPolicy dopuszcza teraz niezależną geometrię i edycję
atomów tego samego bloku tekstowego (insert/delete/format i
object.set dla bezpiecznych pól). Rezerwacja assetId
obejmuje także image object.create i dwa embedy w tym samym bloku,
aby nie dopuścić do niejawnej kolizji podczas pracy offline.
Wspólne pola, zmiany kontenera i destrukcyjne usunięcia nadal
wymagają pełnego rebase.

Testy regresyjne obejmują 16 grup reguł konfliktu, ponowne
otwarcie plikowej SQLite z niepotwierdzoną kreską, trzy niezależne
operacje w outboxie, konflikt metadanych i tekst Quill z jednoczesną
zmianą geometrii. Kursor i outbox nie mogą zostać nadpisane.

RGA Quill w Dart oraz Python odrzuca wadliwy rank atomu, kotwicę
i metadane attributeVersions przed formatowaniem. Różne kolejności
dostarczenia używają tej samej deterministycznej precedencji.
Zmieniono także lustrzane źródła backendu w drzewie aplikacji.

Etap 4: backend ma zielone wcześniejsze CI, ale nowa poprawka
wymaga przebiegu. Etap 5: pozostają migracja kont v1, pełny rebase
move/delete, Share/Planer v2 i bezpieczny produkcyjny cutover.
Nie włączać produkcyjnego v2 ani nie usuwać zapisu v1.

## Kolejny pakiet rebase + diagnostyka (2026-11-08)

Czysty moduł V2OutboxConflictPolicy oddziela decyzję o bezpiecznym
scaleniu od transportu. Dopuszcza zdalne document.set/page.set
z rozłącznymi zmianami obiektow i innych pól metadanych. Rozłączne
pola tego samego obiektu oraz niezależne text.insert/text.delete/
text.format na atomach Quill mogą przejsc bez przepisywania outboxu.
Zachowane sa kotwice CRDT i porządek aktora.

Wspólny atrybut, wspolny atom, kolizja assetId (również wewnątrz
Quill embed), kotwica wymagająca niepotwierdzonego atomu, zmiana
kontenera lub usuniecie danych blokuje dalszy cursor do pełnego rebase.
Nie ma fallbacku do snapshotow v1.

Nowe testy jednostkowe test/v2_outbox_conflict_policy_test.dart
sprawdzają metadane, CRDT, kolejnosc, konflikty i media. Testy
test/editor_v2_account_startup_test.dart zawieraja dodatkowe REST +
SQLite przypadki równoległych zmian strony i Quill, sprawdzając
outbox oraz brak duplikacji po powtórnym pull.

Macierz iPad po 20 minutach bez ukończenia testu przerywa oczekiwanie
zamiast po 30 minutach i zapisuje diagnostyke symulatora (logi,
procesy, ekran). To narzędzie do ustalenia przyczyny zawieszenia,
a nie potwierdzenie naprawy uruchomienia.

Backend etapu 4 zaliczyl CI 42511643976. Aplikacja pozostaje opt-in:
migracja starszych kont, pelny rebase move/delete i produkcyjny
cutover nadal sa niedokończone. Testy tego pakietu wymagają CI.

## Niezależne metadane i atomy przy zaległym outboxie (2026-11-08)

W opt-in v2 'document.set' i 'page.set' mogą zostać odebrane podczas
lokalnych oczekujących edycji obiektów bez podmiany ich zawartości.
Zdalne usunięcia i równoczesne zmiany tych samych metadanych nadal
wstrzymują kursor do rebase. Dla tego samego bloku Quill formatowanie
może minąć oczekujący insert/delete wyłącznie na rozłącznych atomach.
Outbox pozostaje niezmieniony; nie wykonuje się żadnego snapshotowego
zapisania dokumentu. Nowe regresje REST/SQLite w
'test/editor_v2_account_startup_test.dart' wymagają potwierdzenia w CI.
Nie włączać globalnego cutover.

## Przyrost rebase niezależnych obiektów — 2026-11-08

Runtime konta v2 aplikuje zdalną operację obiektu przy lokalnym outboxie
gdy wszystkie oczekujące operacje dotyczą innych UID albo rozłącznych
pól `object.set`, `object.transform`, `object.reorder` tego samego
UID (bez `assetId`). Dzięki temu zmiana geometrii kreski i niezależna
zmiana koloru/szerokości nie blokują wzajemnie kursora. Kolizja ID
assetu na różnych obiektach nadal jest traktowana jako konflikt.
SQLite zatwierdza patch i envelope bez modyfikowania lokalnego outboxu.
Zmiany kontenera, współdzielonego pola lub assetu blokują kursor do
pełnego rebase. Test HTTP/SQLite obejmuje offline ink, rozłączne
zmiany koloru, szerokości, punktów kształtu i kolejności warstw,
a także konflikt wspólnej szerokości.
Dodatkowy przypadek Quill dopuszcza `text.format` tego samego bloku
wyłącznie dla rozłącznych ID atomów lub rozłącznych nazw atrybutów.
Wspólny atrybut tego samego atomu zatrzymuje kursor bez nadpisania
lokalnego formatowania. Regresja obejmuje zachowanie bold + italic
i odrzucenie konkurencyjnego usunięcia bold.
Nie włączać produkcyjnego cutover na podstawie tego przyrostu.

## Regresje Dart, Android i izolacja testów iOS (2026-11-08)

Pełny przebieg 42503975095 ujawnił kolizję importu `isNull` w teście
startu konta v2; import Drift ograniczono do `LazyDatabase` oraz
`QueryExecutor`. Pełny przebieg 42507495400 ujawnił, że `LazyDatabase`
używany w dwóch regresjach nie może zostać ukryty przez import z `show`.
Testy pointerów na Androidzie wykryły rozpoczęty zapis ink po zamknięciu
testowej bazy SQLite. Fixture zapisuje notatnik przed uruchomieniem
edytora, wywołuje `flushPendingSaves` przed `dispose` i dopiero potem
zamyka Drift. Dodatkowa regresja sprawdza trwałość ostatniej kreski.

Przebieg 42507495400 powtórzył zawieszenie drugiego procesu `flutter test`
na iPhone i iPad po poprawnym Xcode build, mimo restartu symulatora.
Skorygowano strategię: `native_platform_matrix_test.dart` rejestruje
scenariusze smoke, lifecycle i pointer jako oddzielne grupy w JEDNYM
procesie testowym, bez ponownego instalowania/debugowania aplikacji.
Izolowane `setUpAll` testów dokumentów nie obejmuje scenariusza smoke.
Skrypt uruchomieniowy ma test kontraktu (jedno wywołanie, wymagany
`--dart-define`, propagacja błędów). Przyczyna natywnego zawieszenia
nie jest jeszcze potwierdzona; weryfikacja iOS CI pozostaje obowiązkowa.

## Stop bez blokady handshake i seryjny restart — 2026-11-06

`stop()` współdzieli trwającą operację i nadal czeka na aktywny REST.
Pomocniczy WebSocket dostaje żądanie zamknięcia przez
`requestRealtimeChannelClose`; zakończenie close nie jest warunkiem
drenażu. `IOWebSocketChannel` po zamknięciu przed nieudanym handshake
może nigdy nie zakończyć tego Future. Spóźnione udane połączenie zostaje
zamknięte przez wcześniej zlecony close; błędy cleanupu są izolowane.

`start(isCurrent:)` czeka na poprzedni stop i ponownie sprawdza właściciela
przed nową generacją. Runtime przekazuje ten warunek z bootstrapu konta.
Anulowanie lub dispose podczas oczekiwania nie uruchamia nowego REST.
Opcjonalny `connectRealtime` pozwala opóźnić handshake prawdziwego kanału
w regresjach, bez zastępowania implementacji WebSocketu atrapą.

Trzy testy cleanupu zaliczono lokalnie w czystym Darcie na produkcyjnym
helperze i rzeczywistym `web_socket_channel`. Pięć regresji silnika
sprawdza stop/restart, zachowanie outboxu, spóźniony błąd, anulowanie
i dispose. Regresja runtime sprawdza anulowanie podczas starego drenażu.
Te testy Flutter wymagają potwierdzenia w kolejnym natywnym Actions.

## Catch-up pierwszej subskrypcji i reconnect — 2026-11-06

Potwierdzenie `authenticated` uruchamia teraz tę samą ścieżkę REST co
`operations_changed`. Domyka wyścig między początkowym GET a subskrypcją
i odzyskuje zmiany po przerwie socketu bez czekania na polling. Kursor
nadal zmienia się wyłącznie po transakcyjnym zatwierdzeniu feedu.
`test/sync_engine_test.dart` używa prawdziwego lokalnego WebSocket,
jawnie opóźnia odpowiedź auth do zakończenia pierwszego GET i sprawdza
dwa połączenia silnika bez dalszej wskazówki. Regresja wymaga Flutter CI.


Status: **silnik i transport zapisane; nie jest to przełączenie produkcyjne**.
Włączenie dla istniejących notatników wymaga kontrolowanej migracji z etapu
11. Serwer v2 celowo odrzuca zapis do UID zarządzanego przez v1, więc
automatyczne włączenie w `AppScope` bez migracji groziłoby utratą zmian.

## Implementacja

- `SyncEngine` przyjmuje `OperationStore`, transport, stabilne `actorId`,
  unikalny `checkpointScope` magazynu i callback projekcji.
- `writeLocal` atomowo zapisuje operację, outbox i projekcję w SQLite.
  Interfejs może wcześniej pokazać gest optymistycznie, ale nie powinien
  potwierdzać trwałego zapisu przed zakończeniem transakcji.
- Wysyłka zachowuje `actorSeq`, stosuje paczki do 50 operacji i 800 KiB
  payloadu oraz maksymalnie 3 niezależnych aktorów jednocześnie.
  Wyjście powyżej 1 MiB jest dodatkowo blokowane w transporcie.
- Odpowiedź ACK jest walidowana w całości przed usunięciem pozycji z outboxu.
  Przerwane HTTP może być ponowione z tymi samymi `operationId`.
- Odbiór przez stronicowane `GET /v2/operations` korzysta wyłącznie z
  trwałego kursora. Kursora nie podnosi się do ACK własnego POST.
  Echo własnej operacji nie uruchamia ponownie projekcji.
- Kursor globalny przesuwa się wyłącznie do ostatniej **ciągłej** pomyślnie
  odtworzonej pozycji. Późniejsze, niezależne dokumenty mogą zostać
  utrwalone wcześniej, a przy ponowieniu są rozpoznawane po `operationId`.
- Callback projekcji otrzymuje **wszystkie** lokalne operacje oczekujące dla
  dokumentu, również z odroczonym retry. Implementacja konkretnego
  edytora ma łączyć zmiany per ID/pole i rebazować te operacje na bieżącym
  stanie, nie podmieniać całego dokumentu snapshotem.
- WebSocket v2 wysyła tylko wskazówkę `operations_changed`.
  REST zawsze weryfikuje stan po reconnect, na foreground i co 45 sekund.
- Błędy sieci, 409 `CAUSAL_GAP` i brak ACK zachowują outbox. Retry ma
  wykładniczy backoff z jitterem; błędy nieobsługiwanych operacji nie
  usuwają danych. Nieudana operacja opóźnia dalsze ruchy jej aktora, nie
  wszystkich innych aktorów.
- Dla już zaakceptowanej operacji zdalnej dotyczącej usuniętego UID
  SQLite zachowuje wpis historii, ale nie odtwarza obiektu.
- Lokalny `actorSeq` i frontier obserwowanych aktorów są odczytywane
  w jednej transakcji przed utworzeniem ruchu.
- `stop()` anuluje timery i socket, czeka na aktywny przebieg oraz
  unieważnia spóźnione odpowiedzi przez generation token.
- 401 może uruchomić przekazany callback `refreshAuthentication` i
  jednokrotnie ponowić to samo żądanie.

## Integracja po przygotowaniu migracji

1. Zainicjalizować trwały `actorId` i odizolowany `checkpointScope`
   we właściwym magazynie konta, Local albo Share.
2. Stworzyć `HttpOperationGateway(apiClient)` i `SyncEngine`, w przypadku
   konta z `refreshAuthentication: session.refresh`.
3. Zastąpić wywołania mutujące SQLite w edytorze transakcjami
   `engine.writeLocal(..., apply: ...)` oraz dodać domenowy reducer
   `applyRemote` aktualizujący konkretne rekordy, z rebase outboxu.
4. Dopiero po migracji UID odłączyć stare `LiveWebSyncService` / v1 writer
   dla tych dokumentów. Nigdy nie uruchamiać obu writerów dla tego samego UID.
5. Share ma wykorzystać ten sam silnik po wprowadzeniu odrębnego magazynu
   gościa i reducerów tekstu, assetów oraz gestów w etapie 6.
6. Ukończyć testy prawdziwego Flutter + PostgreSQL + WebSocket na dwóch
   urządzeniach, zanim zostanie przełączony produkcyjny ruch.

## Regresje dodane do repo

- `test/operation_store_test.dart`: causal frontier, tombstone no-op.
- `test/sync_engine_test.dart`: trwały optimistic commit, ACK utracony po
  zatwierdzeniu na serwerze, własne echo, rebase, błędna projekcja jednej
  pozycji przy poprawnej pozycji innego dokumentu, retry i actorSeq.
- `test/operation_gateway_test.dart`: JSON v2, Bearer, niepełne ACK,
  uszkodzony feed oraz prawidłowy kursor.

## Granice weryfikacji

W tym środowisku nie ma lokalnego SDK Flutter/Dart ani dostępu do kontenera
PostgreSQL użytkownika. Nie uruchomiono `dart analyze`, `flutter test`
ani testów E2E; nie traktować samych nowych testów jako zaliczonych.
Nie uruchomiono ręcznie GitHub Actions. Weryfikacja w kodzie obejmuje
zgodność pól z API v2 serwera i brak zmian w produkcyjnej ścieżce v1.

## Poprawki infrastruktury — 3 listopada 2026

- Walidacja `*.create` wymaga `value`, a `*.set` wymaga `properties`.
  Nieobsługiwane teksty i assety są odrzucane przed trwałym zapisem.
- ActorId w `SyncEngine` jest izolowany per namespace i dokument; obce
  dokumenty nie pojawiają się w zależnościach.
- Undo/Redo automatycznie zawiera `revertsOperationId` w zależnościach.
- SQLite v4 zachowuje tombstones i rozróżnia pageId.
- Nieudany pull nie blokuje push. Przy 409/413/422 w dużej paczce klient
  próbuje pierwszą operację, nie pomijając złej sekwencji.
- Retry wybiera najwcześniejszy termin, Share v2 przenosi nagłówek
  `X-Share-Id` i pole `shareId` w WebSocket.

**Niedokończone:** domenowe reduktory, migracja namespace, przełączenie
produkcji i testy prawdziwego Flutter/PostgreSQL/WebSocket.

## Status odrzuconych operacji — SQLite v5

Odrzucone permanentnie operacje HTTP 403/410/413/422 i nieprzyczynowe
409 nie są już bez końca retransmitowane. `operation_outbox` przechowuje
status `blocked` i `last_error`. Późniejsze operacje tego samego aktora
nie wyprzedzają zablokowanej; nadal można je odczytać przez
`pending(includeDeferred: true)` w celu ręcznej naprawy.

Przed produkcyjnym przełączeniem wymagana jest obsługa odzyskiwania
zablokowanego łańcucha w UI i test migracji v4 → v5 na istniejącej bazie.


## Audyt kontraktu v2 — 3 listopada 2026

- Serwer i Dart dopuszczają puste `value` dla nowego, pustego obiektu,
  lecz `properties` przy aktualizacji nie może być puste.
- Odrzucane są nieznane klucze payloadu oraz próby zmiany `id` lub
  `uid` przez operacje właściwości.
- Walidacja identyfikatorów klienta odrzuca znaki sterujące i zbyt długie
  ID przed trwałym zapisem; lokalny dziennik nie przyjmuje zależności
  wskazujących operację innego dokumentu.
- Zmiany są objęte testami regresyjnymi kontraktu i transakcji.
  Nie wykonano w tej sesji lokalnego Flutter/Dart ani E2E PostgreSQL.
  Przełączenie v1 na v2 nadal wymaga migracji namespace i reducerów.

## Uzupełnienie: odświeżanie widoku po zatwierdzeniu operacji

- `SyncEngine.onRemoteCommitted` jest wywoływane **po** zatwierdzeniu
  transakcji `OperationStore.applyRemote` i **przed** przesunięciem
  checkpointu odbioru. Wcześniejszy callback `applyRemote` służy wyłącznie
  do trwałych zmian w SQLite; nie może modyfikować kontrolera Flutter.
- Jeśli UI chwilowo nie może bezpiecznie nałożyć patcha (np. aktywny gest),
  callback powinien zgłosić błąd. Kursor zostanie zachowany, operacja
  odtworzona, a callback ponowiony. Powtórzenie musi być idempotentne.
- Echo własnej operacji, także po wcześniejszym ACK i ponownym odczycie
  starego kursora, jest rozpoznawane przez trwałą kolumnę
  `operations.source = local` i nie uruchamia odświeżenia UI.
- Po udanym pełnym przebiegu `lastError` zostaje wyczyszczony.
- Regresje: `test/sync_engine_test.dart` sprawdza odczyt zatwierdzonej
  projekcji w callbacku, ponowienie po odmowie UI oraz własne echo po ACK.

**Wciąż zablokowane:** produkcyjny `LiveWebSyncService` nie może zostać
zastąpiony dla UID v1 przed migracją z etapu 11. Potrzebne jest również
kontrolowane przełączenie writerów, separacja z etapu 7 oraz testy E2E
(etapy 12–13). Nowy callback nie jest sam w sobie przełączeniem produkcji.
