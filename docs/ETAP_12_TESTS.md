# Etap 12 — weryfikacja zapisu i synchronizacji

## Pakiet 1 — kontrakty operacji i PostgreSQL (2026-11-09)

- Dart i Python: kompletne 300 UUID w dependencies po roundtripie
  i checkpoint restart; identyczny budżet 128 KiB, błąd ponad limit
  bez zwiększenia actorSeq ani obcinania listy.
- Regresje w obu reduktorach: ten sam wynik LWW/Undo/tombstone,
  Quill format/color, wstawienie za usuniętym atomem.
- PostgreSQL: osobny test transakcji blokowanych tym samym globalnym
  advisory lock, a następnie porównanie kolejności zatwierdzeń i
  przypisanych cursor.
- Realne API i baza: 300 niezależnych parent operationId w jednym
  późniejszym document.set, bez utraty zależności, powtórny ACK
  pozostaje duplicate bez wzrostu revision/cursor.
- Testy stage12 wykonują się wyłącznie z
  `NN_STAGE12_REAL_DB=1` i lokalną izolowaną bazą. W innym środowisku
  są pomijane, a nie uznawane za zaliczone.

## Rejestr kolejności warstw przy przenoszeniu v2 (2026-11-09)

Poprawiono `EditorSqliteProjector._moveObject`: przeniesienie obiektu
nie może nadpisać `sortIndex` ustawionego przez `object.reorder`
o wyższej randze `(clock, actor, seq, operationId)`. Projekcja
SQLite zachowuje wygrywającą pozycję, zgodnie z serwerowym
`_merge` (LWW), również gdy najpierw dotrze zmiana warstwy.
Dotyczy kreski, obrazu i bloku tekstowego.

Test SQLite sprawdza oba porządki poprawnych zdarzeń, brak
duplikatu UID, checkpoint, outbox i idempotencję powtórnego feedu.
Test Python obejmuje obie kolejności oraz rangę zapisaną
w projekcji. Testy obu repozytoriów mają ten sam kod.
Pełny rebase tego samego UID w różnych kontenerach nadal
wymaga osobnej implementacji; produkcyjnego cutover nie włączono.


## Dodatkowe regresje etap 5 (2026-11-09)

- Test silnika odrzuca cztery uszkodzone strony feedu (rozbieżny
  page cursor, powtórzony cursor, puste hasMore, przekroczenie 2^53-1)
  przed jakimkolwiek zapisem do SQLite lub przesunięciem checkpointu.
- Test polityki i REST/SQLite: nowa strona przy lokalnym usunięciu
  odrębnej kreski; zachowane tombstone, outbox i pojedynczy remote page.
- Po zbudowaniu sprawdzić ręcznie również wznowienie na innym urządzeniu
  i offline delete + remote create, bez odzyskania usuniętej kreski.
  To jest scenariusz ręczny, nie zaliczony test automatyczny.

## Walidacja ranków wspólnych pól i Quill (2026-11-09)

Ostatni app CI 42617311998: 16/17 zadań zielonych,
w tym iPad, iPhone, Linux real v2, Android i pozostałe platformy.
Jedyna porażka: format testu, poprawiony dokładnym patchem CI.
Backend 42617279446 zielony. Testy NOWYCH zmian pozostają
niepotwierdzone do kolejnego przebiegu Actions.

test/v2_outbox_conflict_policy_test.dart (45 grupy): wspólny
document/page title, width, sortIndex i ink points mogą przejść
na podstawie LWW. Quill text.format tych samych atomów i atrybutów
rozstrzyga per-attributeVersions; text.delete/insert i assetId
pozostają chronione. Dodatkowe blokady nie dopuszczają
snapshotowego text, ocrText, image multi-field transforms i
zmian zawartości jednocześnie z move tego samego UID.

test/editor_v2_account_startup_test.dart (33 scenariusze): realne
REST mock + SQLite, porównanie lokalnego i zdalnego rank tytułu
oraz stroke width, przyjęcie powtórnego format Quill i
przeniesienie zbioru points jako jednej jednostki. Niezależnie
od wyniku rank przegrane operacje nie znikają z lokalnego outboxu,
a checkpoint odnotowuje zdalny event. Test tekstu weryfikuje
usunięcie bold przez nowszy format, bez utraty italic.

test/editor_sqlite_projector_test.dart: dwa odwrócone porządki
dostarczenia dla notebook/page title, ink object.set width
oraz object.transform points.
Każdy wynik ma identyczne strony, geometry, checkpoint,
bez ponownego zapisu lub kasowania lokalnego intentu.

test/operation_text_sequence_test.dart: formatowanie tego samego
atrybutu w obu kolejnościach z null, potwierdzenie niezmienności
wcześniejszego grafu atomów. Python test_operation_projection.py:
oba porządki dla metadata, stroke scalar, Quill null oraz points.

Test ręczny po dopuszczeniu v2 na dwóch urządzeniach: obie
osoby offline zmieniają title/width/format tego samego elementu;
po reconnect i restarcie obie widzą wynik zwycięskiej rangi,
bez dubli i bez zgubionych operacji. Ruch i zmiana zawartości
tego samego UID nadal muszą blokować automatyczne scalenie.

## Historia ACK, przenoszenie i flake iPad (2026-11-09)

Ostatni app CI 42602433069: 15/17 poprawnych.
Błąd Dart: tylko format dwóch plików; zastosowano
dokładny patch formattera. iPad E2E: po zakończonym
buildzie Xcode proces nie wyświetlił wyników testu
i przekroczył limit 20 minut. Nie uznano tego za
udany przebieg; iPhone, Android E2E i Linux v2 E2E
przeszły. Backend CI 42602398631 zielony.
Kolejny push uruchomi nową pełną macierz.

OperationStore testuje ponowne wykorzystanie
server_sequence w późniejszej paczce przez inny
operationId, zamianę kursora między aktorami oraz
cofnięcie relacji actorSeq↔cursor. Test plikowego
SQLite sprawdza trwałość blokady po restarcie
i późniejsze poprawne ACK. Odrzucony ACK nie może
opróżnić outboxu.

Testy V2OutboxConflictPolicy sprawdzają pary
przeniesień niezależnych UID, blokadę wspólnego
UID i konflikt page.delete dla obu końców.
REST/SQLite: remote ink move z offline bookmarkiem
i pending ink move z niezależną zmianą nazwy strony;
weryfikują stronę docelową, zapis kursora i outbox.
Po stronie Python: równoległe obiekty o jednakowym
sortIndex, różna kolejność dostarczenia, deterministyczne
z-order oraz fail-closed feed cursor.

Scenariusz ręczny: offline na urządzeniu A zmień
bookmark strony i położenie kreski X; na urządzeniu B
przenieś niezależną kreskę Y do drugiej strony.
Po online i restarcie obie tożsamości oraz kolejność
powinny zostać zachowane. Równoczesny move + edycja
tej samej kreski ma zatrzymać odbiór do rozstrzygnięcia,
nie zastępować lokalnej treści.

## Regresje transakcji ACK i granic feed (2026-11-09)

CI 42595806151: 16/17 zielonych, formatter zgłosił
jedyny błąd; jego dokładny diff wprowadzono.

test/operation_store_test.dart: obie operacje zachowane,
gdy drugi ACK jest niepoprawny albo zapis SQL zostaje
przerwany; po zamknięciu SQLite i restarcie dalej są
w outboxie z oryginalnym ID. Następny poprawny ACK
zwalnia je jednocześnie. Ponowne potwierdzenie nie
tworzy duplikatów. Walidacja odrzuca remote-only ID,
przestawioną kolejność actorSeq, duplikat kursora
i wartości poza 2^53-1.

test/sync_engine_test.dart: transport ze zduplikowanym,
malejącym lub zbyt dużym kursorem nie opróżnia outboxu.
Triggery SQLite wymuszają awarię drugiego INSERT ACK
w ramach realnego syncNow; cała paczka pozostaje dostępna
i jest wysyłana ponownie po usunięciu błędu.
test/operation_gateway_test.dart: fałszywy ACK oraz
przepełniony cursor feed zatrzymują parsowanie przed
zmianą checkpointu.

api/tests/test_operation_stage4.py po stronie backendu
weryfikuje unikalność i kolejność ACK, osobne aktory,
błędny status, brak wpisu, fałszywy operationId i
wartość większą od 2^53-1. Kontrola następuje
przed session.commit i jest lustrzana w repo aplikacji.

Nie uruchamiano lokalnie dart format/analyze/flutter test
(brak narzędzi Dart i Flutter w dostępnym środowisku).
Walidację nowych regresji należy potwierdzić w CI.

## Testy page.delete, atomowości i kursora ACK (2026-11-09)

Ostatni app CI 42591095132: 16/17 zadań zielonych, jedyny
błąd formatowania testów. Backend CI 42591078056 zielony.
Dokładne poprawki formattera wprowadzono przed pakietem.

Nowe regresje polityki v2: rozłączne page.delete podczas
offline document.set, page.set, stroke.create i Quill oraz
blokady tej samej strony, nowych stron, object.move, media
i destrukcyjnych zdarzeń. REST/SQLite w
test/editor_v2_account_startup_test.dart kontroluje, że
usunięcie drugiej strony nie zjada lokalnego tytułu, bookmarka
ani kreski; lokalne page.delete nie blokuje tytułu innej strony;
kolizja zatrzymuje cursor zamiast niszczyć outbox.

test/operation_gateway_test.dart i test/sync_engine_test.dart:
dwa różne operationId ze wspólnym cursor w potwierdzeniu
zwracają błąd, pozostawiając lokalny outbox i bez ACK.
Poprawna paczka dwóch różnych cursor przechodzi.

Python API: nieudany folder.move z cyklem, folder.create z
sierotą, task.create/move ze złym plannerUid, obiekt przeniesiony
przy skorumpowanych versions, odłączanie aktywnego assetu,
Quill embed i niepoprawny image asset nie modyfikują stanu
reducera po odmowie. Parametryczne przypadki sprawdzają
ujemne i niepoprawne persisted ranks. Backend + mirror zawierają
te same testy. Kontrola nie potwierdza jeszcze pełnego
cutover ani migracji starych dokumentów.

Scenariusz ręczny: dwa urządzenia z kontem v2 opt-in,
dwie strony, pierwsze offline zmienia tylko stronę A,
drugie usuwa stronę B. Po połączeniu ma pozostać A z edycją,
bez B i bez podwójnych assetów, a cursor/outbox i ponowne
otwarcie pliku muszą być spójne. Konflikt na stronie B ma
zatrzymać synchronizację do rozstrzygnięcia, nie usuwać
lokalnego edytowanego tekstu.

## Odporność projekcji PostgreSQL i nowych stron (2026-11-09)

Przebieg 42587383593: 16/17 zielonych, jedyny błąd formatowania
trzech plików. Dokładną poprawkę uwzględniono przed nowymi testami.

Dodano regresje po stronie serwera dla uszkodzonych `versions`,
`assetVersions`, `lastMove.rank` i historycznych pól assetów
należących do innych obiektów. Wadliwa ranga nie może zostać
potraktowana jako starsza wersja i po cichu nadpisana; testy
sprawdzają brak zmiany stanu także przy uszkodzeniu nieedytowanego
pola. Walidacja nie może ominąć księgi trwałych receiptów.
Testy uruchamia macierz backendu i kopia Python w repo aplikacji.

Testy Dart: pięć nowych scenariuszy z `page.create` i
różnymi operacjami offline, dwa scenariusze REST/SQLite dla
strony z równoległym bookmarkiem, tytułem i kreską, restart bazy
z niedostarczonym outboxem, a także konflikt istniejącego UID.
Kursor nie może ominąć kolizji ani wyczyścić lokalnych operacji.

Do testu ręcznego: na dwóch urządzeniach otworzyć to samo
konto v2 opt-in, odłączyć pierwsze, zmienić tytuł strony
i dorysować kreskę, na drugim dodać nową stronę, a następnie
połączyć pierwsze. Zweryfikować UID, kolejność stron, obecność
kreski i outbox po ponownym uruchomieniu. Testu ręcznego bez
urządzeń nie oznaczamy jako zaliczonego.

## Natywny SQLite i symetryczne metadata/outbox (2026-11-09)

CI 42582273859 wyjaśnił wieloplatformowe błędy: powtarzany błąd
SHA-256 przy pobieraniu natywnego artefaktu sqlite3. Hook
`source: system` korzysta z wcześniej dostarczonego SQLite,
bez wyłączania integralności pobranych plików. Zweryfikować
macOS/Linux/Windows przez nowy test
`test/sqlite_system_library_test.dart`: transakcja, rollback,
JSON, FTS5, WAL, zamknięcie pliku, restart i deduplikacja ID.
Android/iOS nadal wymagają nowej kompilacji i próby na urządzeniu.

Nowe regresje `test/v2_outbox_conflict_policy_test.dart`:
symetria niezależnych metadanych, usunięcia wstrzymujące pull,
równoczesne atomy Quill i reużycie tylko identycznego receipt
asset.attach na niezależnych obiektach. REST/SQLite w
`test/editor_v2_account_startup_test.dart` odtwarza zdalny
stroke.create + object.set przy lokalnym page.set oraz zdalny
object.set przy dwóch lokalnych zmianach document.set/page.set.
Kursor i pending outbox pozostają kontrolowane po kolejnych pull.

Po stronie PostgreSQL `test_stage2_assets.py` weryfikuje
wspólne, zweryfikowane receipty, zakaz niezgodnych danych i
niezmienność projekcji po odmowie, także przy historycznym
stanie bez księgi receiptów.

Nowe automatyczne scenariusze wymagają wyniku z Actions.
Przy ręcznej weryfikacji na rzeczywistym urządzeniu należy
sprawdzić istniejący dokument po aktualizacji bibliotek SQLite,
w tym PNG/PDF, Quill i offline outbox. Bez tej weryfikacji
nie potwierdzać produkcyjnego cutover.

## Powtarzanie błędów infrastruktury CI (2026-11-09)

Przebieg 42579587105:
- sqlite3 3.3.3: suma pobranej biblioteki różniła się od sumy
  producenta jednocześnie dla Linux, macOS, Android i iOS; zakaz
  wyłączania SHA-256 lub traktowania tego jako poprawnego testu.
- Android Gradle 8.14: HTTP 504 z przekierowania GitHub Releases.
- iOS device Release: bezpłatny runner nie ma profilu podpisującego,
  więc sprawdzany jest unsigned xcodebuild Release, a nie IPA.
- Dart: wyłącznie formatowanie, poprawione zgodnie z diffem.

Skrypt flutter_transient_network_retry.sh ponawia tylko błędy
Hash of downloaded file libsqlite3 oraz HTTP 502/503/504, maksymalnie
trzy próby. Po ostatniej lub przy błędzie logiki/testu zwraca
niepowodzenie. test_flutter_transient_network_retry.sh odtwarza
przejściowe i trwałe błędy oraz weryfikuje bezpośredni URL Gradle
i wyłączone podpisywanie w zadaniu kompilacji Release iOS.

Powtarzalny test manualny po CI: zainstalować build aplikacji z
rzeczywistym SQLite na Androidzie i iOS, utworzyć offline dokument,
wykonać zmianę tekstu i kreski, zamknąć proces, uruchomić ponownie,
sprawdzić dane, outbox i późniejszy ACK po połączeniu. Bez sprzętu
nie oznaczać tego testu jako zaliczonego.

Status: **zestawy testów dodane, niezaliczone środowiskowo; etap 12 NIE jest
zamknięty**. Nie włączać jeszcze produkcyjnego cutover v1 → v2.

## Rzeczywiste kontrolery edytora — 2026-11-06

`integration_test/stage12_live_api_test.dart` korzysta teraz z dwóch
`EditorV2AccountRuntime`, produkcyjnych kontrolerów, projectorów i
writerów oraz dwóch plików SQLite. Usunięto pomocniczą tabelę testową.
Scenariusz w jednym procesie Flutter/Linux sprawdza:

- rzeczywisty gest kontrolera i automatyczny odbiór przez WebSocket
  w czasie krótszym niż polling, z zachowaniem lokalnego viewportu;
  przed uploadem nadajnika odbiorca jest ponownie uruchamiany, aby
  cały 15-sekundowy deadline wyprzedzał kolejny polling;
- rich Quill z PNG oraz prawidłowym PDF, restart przed pierwszym uploadem,
  te same operationId outboxu, checksumy/bajty i formatowanie po odbiorze;
- skasowanie strony z mediami offline, restart autora usunięcia i propagację;
- dwa cykle Undo z Redo pomiędzy nimi: nowe UID, zachowaną cudzą kreskę,
  dokładnie poprawne scoped referencje oraz brak osieroconych referencji;
- zgodność identyfikatorów aktywnych stron ze snapshotem PostgreSQL.

Test używa wyłącznie lokalnego HTTP, jednorazowego właściciela v2
z runnera oraz osobnego PostgreSQL. Nie zastępuje gestów UI na dwóch
fizycznych urządzeniach, Share host/guest ani macierzy wszystkich OS.

Job `v2-controller-e2e` w Actions uruchamia istniejący
`server/scripts/run-stage12-real.sh` i ten test na Linuxie/Xvfb.
Pełny workflow obejmuje go automatycznie; marker
`[ci:failed-only] [ci:v2-e2e]` wybiera analizę/testy natywne i ten stos,
bez budowania pozostałych platform. `--quick` pomija tylko osobny stress
1000+1000 backendu. Dotychczasowe natywne regresje są zielone w `42255399051`;
wynik nowego scenariusza i poprawki WS jest nadal do sprawdzenia.

## Zestawy uruchamialne

**SQLite/Flutter** — `test/production/stage12_operation_stress_test.dart`.
Prawdziwy plik SQLite przez Drift i 1000 dodanych oraz 1000 usuniętych
obiektów. Kontrola operacji, outboxu i tombstone po zamknięciu i ponownym
otwarciu SQLite, idempotentny ACK, atomowy rollback lokalnej projekcji i
brak zużycia `actorSeq` przy niepowodzeniu.

Na komputerze testowym z Flutter SDK:

```bash
flutter pub get
flutter test test/production/stage12_operation_stress_test.dart
flutter test test/operation_store_test.dart test/sync_engine_test.dart \
  test/share_operation_projection_test.dart
dart analyze
flutter test
```

**FastAPI/PostgreSQL/WebSocket** — kanoniczny serwer,
`api/tests/test_stage12_real_stack.py`, uruchamiany przez
`scripts/run-stage12-real.sh`. Używa prawdziwego PostgreSQL 17,
migracji 0001–0012, routerów FastAPI i połączeń WebSocket. Nie podmienia
bazy ani WebSocket mockiem. Obejmuje:

- 1000 kolejnych dopisków + 1000 usunięć i weryfikację feedu z kursorem;
- retransmisję tego samego `operationId`, fałszywą zmianę treści pod
  tym samym ID, niepełny batch i brakującą zależność;
- odwróconą kolejność pakietów w jednym batchu, rollback całej transakcji;
- konto A / konto B, izolację snapshotu i feedu mimo tego samego UID;
- równoczesne wstawienia tekstu w odwrotnej kolejności;
- dwóch aktorów Share, powiadomienia owner/guest WebSocket, konflikt
  delete/transform i natychmiastowy brak zapisu po revoke;
- Undo/Redo jako nowe operacje, usunięcie strony i zakaz
  późniejszego dopisania do tombstone;
- reconnect WebSocket i pobranie brakujących operacji przez REST.

Zestaw odmawia działania poza jawnie utworzoną, lokalną bazą
`nanotateczki_stage12_test`. Runner uruchamia **osobny, jednorazowy
kontener PostgreSQL**, osobny projekt Compose, port tylko na 127.0.0.1,
a po zakończeniu usuwa testowy serwer danych i środowisko Pythona.
Nie używa `/srv/nanotateczki`, bazy produkcyjnej ani jej wolumenów.

Uruchom **na komputerze testowym**, nie na serwerze produkcyjnym:

```bash
cd NaNotateczki-serwer
bash scripts/run-stage12-real.sh
# Krótsza weryfikacja bez 2000 operacji:
bash scripts/run-stage12-real.sh --quick
# Pełny test dwóch klientów Flutter przez rzeczywiste API/WS/SQL:
NN_STAGE12_FLUTTER_ROOT=../NaNotateczki bash scripts/run-stage12-real.sh
```

Wymagane: Docker Compose v2, Python 3 z `venv`, dostęp do pakietów
Pythona i obrazu `postgres:17-alpine`. Jeśli brakuje tych zależności,
uruchomienie kończy się błędem — nie traktować go jako PASS.

W teście Share v2 bilety i sesję tworzy bezpośrednio izolowana baza,
ponieważ publiczne utworzenie sesji dotyczy jeszcze dokumentów v1.
To **nie** potwierdza ścieżki host „Create link” → guest v2 ani migracji
istniejących sesji. Nie włączać bez tego przełączenia w produkcji.

## Otwarta macierz akceptacyjna

| Grupa planu | Automatyzacja | Nadal konieczne |
| --- | --- | --- |
| A — zapis | SQLite + PostgreSQL: 1000+1000, ACK, rollback | asset disk-full, backup/import równoległy z edycją, crash w momencie COMMIT |
| B — Share | operacje/tombstones, tekst CRDT, WebSocket/reconnect, revoke | prawdziwy Flutter host + guest, opóźnienia, gesty i brak migania |
| C — konta | backend A/B i wcześniejsze testy namespace | pełny Local → A → B → A → Local w uruchomionej aplikacji, import dwukrotny |
| D — awarie | rollback SQLite, błędy REST, reconnect | kill procesu / DB, pełny dysk, rollback migracji, backup historyczny |
| E — platformy | natywny Flutter test, backend E2E | Linux, Windows, macOS, Android, iOS, Web i testy krzyżowe na urządzeniach |

Testy starszych modułów (backup, migracja 11, planner, shutdown, share,
operacje) pozostają wymagane. Nie zostały automatycznie uruchomione samym
zapisaniem nowych testów.

## Naprawiony brak z wcześniejszych etapów

Zidentyfikowano niespójność: serwer migracją 0012 akceptował
`task.delete`, ale lokalna SQLite v5 dopuszczała tombstones tylko
dla document/page/object/folder. `OperationStore` nie uwzględniał
`OperationTarget.task`. Wdrożono SQLite v6: nowa kategoria
`task` w tabeli, migracja zachowująca stare rekordy, obsługa
usuwania i ochrony przed ponownym użyciem UID, regresje
`test/task_tombstone_migration_test.dart` dla nowej bazy i
aktualizacji v5 → v6. Etap 11 rozpoznaje teraz pliki z `user_version=6`.

Zmiana dotyczy tylko lokalnego schematu SQLite aplikacji.
Nie dodawano nowej migracji SQL backendu, bo
`0012_task_tombstones.sql` już to obsługuje.

## Blokery do pełnego zaliczenia

1. Etap 11 pozostawia dane w stanie `staged-not-activated`; publiczny
   cykl migracji i cutover dla istniejących kont nadal nie jest aktywny.
2. `integration_test/stage12_live_api_test.dart` obejmuje teraz rzeczywiste
   kontrolery, media, pliki SQLite i restarty przez REST/WS/PostgreSQL.
   Job Linux dodany, ale jego wynik wymaga potwierdzenia. Nadal brak
   scenariusza dwóch fizycznych urządzeń z obserwacją migania i gestów.
3. Wymagane są kontrolowane testy uszkodzenia assetu, braku miejsca,
   restartu serwera w trakcie COMMIT, starego backupu po usunięciu UID i
   przerwanej migracji. Wykonywać je wyłącznie na danych testowych.
4. Matryca platform oraz testy dwóch prawdziwych urządzeń pozostają
   do rzeczywistego wykonania. Wyniki należy odnotować osobno dla
   każdego OS i wariantu połączenia.

Nie uruchamiać GitHub Actions bez polecenia użytkownika. Nie wdrażać
tych testów ani zmian protokołu na produkcyjnym serwerze. Etap 13
wymaga osobnej procedury backupu, migracji i kontrolowanego rolloutu.

## Korekta etapów 11–13: trwały tryb konta

Nowa migracja backendu `0013_account_protocol_fence.sql` dodaje
trwały marker v2 konta i blokuje każde v1 PUT/DELETE po jego aktywacji,
także dla nowego UID. Konto bez markera nie może wykonać v2 batch.
Zestaw `test_stage12_real_stack.py` bada tę barierę na prawdziwej bazie.
`run-stage12-real.sh` tworzy oddzielne konto v2 w disposable PostgreSQL
i przekazuje jego token do `stage12_live_api_test.dart`.
Dotychczasowa rejestracja kont testowych bez markera pozostaje w trybie v1.

Regresje PostgreSQL potwierdzają też, że konto v1 nie może pisać do
planera v2, a aktywne konto może zapisać i usunąć wpis planera, zweryfikować
backup po nowszym usunięciu dokumentu i odczytać wyłącznie własne archiwum.
Tombstones dokumentów v1/v2 i planera zapisują SQL `NULL`, nie JSON `null`,
żeby spełnić warunki integralności schematu.

Testy nowej bariery (Python, po pobraniu zależności):

```bash
python -m pytest -q api/tests/test_account_protocol_fence.py \\
  api/tests/test_stage13_rollout.py
python3 -m unittest discover -s scripts/tests -p 'test_stage13*.py'
```

**Niezmienione blokady:** pełne dwuurządzeniowe gesty host/gość,
transfer Local→A→B, pełna migracja istniejących dokumentów i test
backup/restore na osobnym środowisku. Nie publikować canary na produkcji,
dopóki nie ma rzeczywistych wyników tych testów.
