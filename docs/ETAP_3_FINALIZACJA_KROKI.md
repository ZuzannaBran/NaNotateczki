# Etap 3 — finalizacja integracji edytora v2

## Stabilne ID w wielokrotnym Undo/Redo — 2026-11-06

Usunięte obiekty/strony są odtwarzane pod nowymi ID, ale pozostałe
snapshoty historii pamiętały wcześniejsze tożsamości. Redo następnego
gestu mogło przez to kasować i tworzyć ponownie już odtworzoną kreskę
lub stronę. Kontroler po udanym commicie przenosi mapowanie nowych ID
do obu stosów historii. Zachowuje operationId cofanych gestów i nie
zmienia snapshotów przy błędzie transakcji.

Rozszerzony test szybkich gestów wykonuje Undo/Undo/Redo/Redo dla dwóch
kresek i dla utworzenia strony z kreską. Sprawdza stabilność już
odtworzonego ID oraz dokładny przyrost outboxu: tylko nowa kreska,
bez zbędnego delete/create strony lub wcześniejszego obiektu.
Wymusza też błąd SQLite podczas odtwarzania i bezpieczne ponowienie.
Nowe testy pozostają do potwierdzenia w kolejnym odczycie Actions.

## Odtwarzanie osadzonych mediów w Undo — 2026-11-06

Writer odzyskuje potwierdzenie istniejącego assetu Quill z dziennika
tego samego dokumentu. Sprawdza niezmienność potwierdzeń i trwałe bajty
(SHA-256, MIME, rozmiar), stage'uje je przed transakcją i zapisuje nową
scoped referencję przed odtworzeniem atomów. Dotyczy Undo usunięcia
samego embedu, całego tekstu i strony, również po restarcie bez bufora.
Obiekty/strony po tombstone nadal otrzymują nowe ID. Nie potrzeba sieci
ani nowej kolejki/schematu. Obce dokumenty i niezweryfikowane URL nie
są źródłem odzyskiwania; nowe importy wymagają osobnego stagingu.

`editor_v2_quill_asset_recovery_test.dart` zawiera sześć scenariuszy
obraz/PDF × embed/blok/strona na plikowej SQLite, powtarzane
Undo/Redo/Undo oraz odmowę obcego zakresu i uszkodzonego BLOB.
Dodano go do lokalnego zestawu etapu 3 i automatycznie zbieranego CI.
Testy tego przyrostu wymagają odczytu wyniku w następnym uruchomieniu.

## Potwierdzony CI i powiązania Undo/Redo — 2026-11-06

Przebieg `42134609370` dla `1d867df` zakończył się sukcesem:
formatowanie, analiza Darta, natywne regresje i próg pokrycia.
Backend `42128518866` również jest zielony. To potwierdza wcześniejsze
regresje lokalnego zapisu, mediów, restartów i kalendarza; nie stanowi
zaliczenia pominiętych platform ani E2E.

Undo/Redo przekazuje teraz `revertsOperationId` do wszystkich operacji
odwrotnego wsadu. Wskazuje końcową operację cofanej grupy; jej zależności
obejmują wcześniejsze operacje tego gestu. Kolejne Redo wskazuje koniec
Undo, a ponowne Undo — koniec Redo. Każdy wsad dostaje nowe operationId.
Aktywny gest Quill pamięta ostatni zatwierdzony autosave, także gdy
zakończenie edycji nie wymaga już zapisu. Edycja o zerowym efekcie nadal
nie tworzy Undo. Nie zmienia to formatu protokołu ani schematu SQLite.

Rozszerzone regresje kontrolera obejmują ink, Quill po dwóch autosave'ach
i cykl Undo/Redo/Undo; test writera odrzuca brakującą zależność,
sprawdza zachowanie dokumentu/outboxu i ciągłość actorSeq po ponowieniu.
Wynik nowych testów należy odczytać w następnym uruchomieniu Actions.
Historia Undo po restarcie i rebase dwóch klientów pozostają otwarte.

## Wynik CI po przyroście offline — 2026-11-06

Przebieg `42132119898` przeszedł formatowanie i analizę Darta oraz 841
testów (2 pominięte); cztery testy nie przeszły. Nowe regresje aktora,
Quill, autosave, katalogu, offline mediów i restartów przeszły.
Backend `42128518866` zakończył się sukcesem.

Naprawa czterech regresji: test CRUD sprawdza kolejkę konkretnego
dokumentu i trwały tombstone zamiast globalnego porządku różnych aktorów;
test przełączania widoku planuje zajęcia od początku godziny, aby końcówka
doby nie zamieniała ich w miniaturowy blok bez etykiety. Krótkie bloki
kalendarza zachowują teraz barwę completed/review. Test obu motywów
wymusza jednominutowe sesje, więc regresja jest niezależna od pory CI.
Ponowny przebieg celuje w analizę i testy natywne; nie uruchamia innych
platform. Wynik należy sprawdzić na początku następnej pracy.

Stan na 2026-11-05. Aktywna produkcja pozostaje na v1. Każdy przyrost
jest realizowany na `NaNotateczki/dev`. Żaden punkt nie może być
uznany za zaliczony na podstawie samego dodania testu.

## Naprawa P0 — 6 listopada 2026

Logi `42115891175` ujawniły błąd parsera w `_v2ActorId` oraz
zdublowaną końcówkę `app_scope.dart`, która blokowała wszystkie buildy.
Usunięto duplikat, zachowując nowszą ścieżkę z trwałym aktorem i oczekiwaniem
na `enableAccountOperations`. Odczyt aktora wydzielono do
`persistent_operation_actor.dart`; brak ID przy niewysłanych, opóźnionych
lub zablokowanych operacjach odmawia startu bez zmiany danych.
Test restartu używa pliku SQLite i potwierdza ciągłość actorSeq.

Naprawiono też formatowanie czterech plików wskazanych przez CI oraz
nowej regresji usuwania strony. `dart format` parsuje już cały projekt.
Analiza i testy Flutter wymagają potwierdzenia dla tego przyrostu.
Serwer: poprawiono test przegrywającego move po usunięciu strony;
lokalnie 272 testy przeszły, 8 scenariuszy PostgreSQL pominięto.

Granica zakresu: najpierw pełny lokalny zapis edytora v2 (etap 3),
następnie rebase dwóch klientów, synchronizacja całego konta i cutover
(etap 4). Starsze sekcje C/D zawierają również te późniejsze warunki;
nie wymagają przedwczesnej aktywacji flagi ani usunięcia v1.

### Przenoszenie Quill z embedami — implementacja

`EditorSqliteProjector._moveObject` przenosi teraz scoped referencje
Quill razem z blokiem. Przed zmianą sprawdza trwałe bajty i ich SHA-256,
kompletność referencji embedów oraz brak docelowego właściciela.
Nie tworzy nowych atomów, nie wysyła ponownie assetu i nie usuwa BLOB.
Regresje w `editor_v2_operation_writer_test.dart` obejmują obraz i PDF,
dwukrotne użycie jednego assetu, sformatowaną Delta, geometrię i trwałą
tożsamość atomów po utracie bufora, brak referencji oraz rollback
wsadu, w którym po przeniesieniu występuje błędna geometria.
Wynik testów tego przyrostu pozostaje do odczytania w następnym CI.

### Granica gestu tekstowego — implementacja

Autosave Quill zapisuje lokalne operacje podczas pisania, lecz nie dodaje
osobnego Undo przy każdym debounce. Kontroler przechowuje stan sprzed
edycji i dołącza go do końcowego checkpointu gestu. Koniec edycji zachowuje
historię również wtedy, gdy treść była już zatwierdzona w SQLite i nie ma
nowych operacji do zapisania. Powrót do oryginalnej treści i Delta nie
dodaje pustego Undo. Przejście bezpośrednio do innego bloku najpierw
zamyka poprzedni gest.
Regresje `editor_controller_v2_test.dart` czekają na rzeczywisty lokalny
commit dwóch autosave'ów, następnie sprawdzają pojedyncze Undo/Redo oraz
edycję o zerowym efekcie. Wykonanie testów Flutter potwierdza następne CI.

### Ustawienia katalogu v2 — implementacja

`LibraryScreen._openCatalogSettings` nie pomija już kontrolera edytora
tylko z powodu aktywnego runtime v2. Przekazuje operacyjny writer,
zachowując ustawienia rysika i wyglądu bez uruchamiania writera v1.
`library_v2_settings_test.dart` sprawdza rzeczywisty ekran, dwukrotne
otwarcie/zamknięcie, tożsamość writera, blokadę snapshotu i brak
zbędnych operacji. Test dołączono do celowanej weryfikacji etapu 3;
wynik Flutter pozostaje do potwierdzenia w CI.

### Lokalny zapis obrazów/PDF bez sieci — implementacja

Usunięto upload poprzedzający lokalny gest. Writer lokalnie tworzy digest
i stage'uje bajty, a projector utrwala je w istniejącym
`operation_asset_bytes` w tej samej transakcji co operacje i outbox.
Niewysłane `asset.attach` jest trwałym znacznikiem oczekującego uploadu.
Runtime konta przez `SyncEngine.prepareLocalOperations` wysyła pliki
przed zależnymi operacjami (również przy wysyłaniu bezpiecznego prefiksu).
Sprawdza digest/MIME/rozmiar bajtów z SQLite oraz potwierdzenie serwera.
Nie usuwa fizycznych bajtów przy usunięciu obiektu/strony; brak ACK
pozwala powtórzyć content-addressed PUT po restarcie.

Dodano `editor_v2_offline_media_test.dart`: dwa typy mediów × pozostawienie
lub usunięcie obiektu przed restartem, plikowa SQLite, uszkodzenie BLOB,
odmowa wysyłki offline i upload przed operacjami po odzyskaniu sieci.
Ten sam scenariusz gubi ACK po przyjęciu operacji, zamyka i ponownie
otwiera plik SQLite, a następnie odbiera echo serwera. Sprawdza opróżnienie
outboxu i brak duplikacji identyfikatorów, także po lokalnym usunięciu medium.
Dodano lokalny scenariusz 20 stron z ink, sformatowanym Quill i obrazami/PDF:
po usunięciu pięciu stron restart ma zachować cały zakodowany dokument
oraz identyczną kolejkę operacji. Wykonanie wymaga potwierdzenia w CI.
Zmieniono stary test oczekujący uploadu przed zapisem: lokalny commit ma
teraz zero żądań HTTP, a błędny receipt nie usuwa jego outboxu.
Formatowanie zweryfikowano lokalnie; testy Flutter wymagają wyniku CI.
Automatyczne wykrywanie nowych embedów w Delta, transport po przeniesieniu
między urządzeniami i pełne E2E pozostają niezamknięte.

## Integracja z 5 listopada 2026 — nadal niezamknięty etap 3

- Dodano opt-in `EditorV2AccountRuntime` dla konta o potwierdzonym
  protokole v2; flagę `NN_ENABLE_V2_ACCOUNT` domyślnie wyłączono.
- Produkcyjny kontroler edytora otrzymuje writer v2 po aktywacji,
  a `NotebookRepository` nie wysyła tworzenia, rename i delete
  dokumentów v2 przez legacy snapshots.
- Po commicie operacji v2 wysyłane jest powiadomienie o aktualizacji
  strony / dokumentu, co umożliwia odświeżenie cache i backupu.
  Dodano test regresyjny `notebook_repository_v2_account_test.dart`.
- Bez lokalnego Flutter/Dart testy pozostają **nieuruchomione**.
- Brakuje pełnego rebase, offline transferu mediów, zamknięcia
  Quill, przełączenia całej aplikacji i testów E2E.
  Nie wolno włączać flagi na rzeczywistych danych użytkownika.

## A. Integralność istniejącego zapisu v2 — pierwszeństwo

- [x] Jeden transakcyjny commit projekcji Drift, actorSeq i outboxu.
- [x] Opt-in `EditorController` bez równoległego `saveNotebook`.
- [x] Trwała blokada v1 dla UID mającego historię operacji v2.
- [x] Korekty remote UI, stron, ink, z-order, podstawowego tekstu Quill.
- [x] Ink `object.move`; obraz `object.move` tylko z referencją assetu.
- [ ] `page.delete` usuwa zweryfikowane obrazy/Quill i ich scoped
  referencje atomowo; nadal odrzuca obce, niepowiązane i brakujące assety.
  Dodano regresję dla współdzielonego assetu: kasowanie strony usuwa tylko
  jej scoped referencję, zachowując referencję drugiej strony. Wymaga
  wykonania testów i analizy statycznej.
- [ ] `object.delete` dla obrazu/Quill usuwa scoped referencję w tej
  samej transakcji; niezweryfikowany media object blokuje operację.
  Kod dodany, ale wymaga wykonania testów i analizy statycznej.
- [x] LWW właściwości na podstawie trwałej historii operacji.
- [ ] Zweryfikować pełną spójność replay CRDT, formatowania i kolejności
  operacji, także po restarcie i przy równoczesnych edycjach.
- [ ] Zablokować każdą operację powodującą osierocone referencje
  do obrazu, PDF lub osadzonego assetu Quill.
- [ ] Uruchomić `dart analyze` i wąskie testy v2. Nie używać Actions
  do czasu zakończenia etapu 3 (chyba że użytkownik zezwoli).

Warunek zamknięcia A: rollback nie gubi danych ani aktora; ACK nie
odmalowuje; konflikt nie nadpisuje trwającego gestu; restart odtwarza
ten sam stan i trwały outbox.

## B. Kompletny łańcuch plików i Quill

- [ ] Lokalny projector Quill: trwała tabela `operation_asset_bytes`,
  scoped `asset.attach`, walidacja `text.insert`, odczyt po restarcie.
  Implementacja oraz test dodane; brak uruchomionych testów Flutter.


- [ ] Lokalna podmiana obrazu: attach → object.set → detach przy
  zweryfikowanym uploadzie, z wersjonowaniem pola `assetId` i rollbackiem.
  Kod dodany; prefetch po restarcie oparty na trwałym attach receipt.
  Wymaga testów Flutter i podłączenia gateway w AppScope.


1. Zdefiniować kanoniczne powiązanie `assetId` ↔ SHA-256 ↔
   bajty/pliki na urządzeniu dla Linux, Android, iOS i Web.
2. Ukończony, sprawdzony upload przed `asset.attach`; pobranie
   zweryfikowanych bajtów przed zdalnym renderem.
3. `object.create` obrazu/PDF, `asset.attach`, `object.set`,
   `asset.detach` i `object.delete` muszą mieć jednoznaczny,
   atomowy porządek na serwerze i w lokalnej projekcji.
4. Quill: upload, attach, insert, delete i detach embedów bez
   osieroconych assetów i bez kasowania nadal używanych plików.
5. Testy podmiany/usuń/przenieś, zerwania sieci, ponowienia ACK,
   błędnego SHA-256 oraz ponownego otwarcia notatnika.

Warunek zamknięcia B: bez utraty treści, bez niezweryfikowanych
referencji, bez duplikatów i bez nieodwracalnego kasowania pliku.

## C. Undo/Redo i rozstrzyganie konfliktów

1. Jedna operacja odwrotna na gest (`revertsOperationId`).
2. Ponowne utworzenie po tombstone ma nowy UID; starego UID nie wolno
   wskrzesić. Usuwanie i redo nie mogą omijać walidacji.
3. Odtwarzanie strony, zmiany Quill oraz usuwania bloku w Undo/Redo.
4. Jednoczesne zmiany pola, text atoms, `object.move`, usunięcia
   strony i offline queue — deterministyczny rebase.
5. Testy obu kolejności dostarczenia i dwóch klientów, również przy
   utracie połączenia przed ACK.

Warunek zamknięcia C: ten sam stan na obu urządzeniach i po restarcie,
bez konfliktowych kopii w zwykłym przebiegu.

## D. Integracja produkcyjna i wyłączenie v1

1. Domknąć wszystkie produkcyjne `EditorAction`, strony i zapis
   preferencji/metadanych na operacyjny v2 lub świadomie odseparować.
2. Podłączyć `SyncEngine` i dispatcher do aktywnego edytora, bez
   remountu, przesunięcia zoomu/pan ani dodatkowego snapshot save.
3. Podłączyć backup i jego harmonogram do rzeczywistych commitów
   operacji, respektując tombstones.
4. Sprawdzić staging, lokalną migrację v1→v2, serwerowy protokół i
   jednoznaczną blokadę wersji dla konta.
5. Testy jednostkowe, integracyjne, E2E dwóch klientów, restartów,
   offline i wszystkich platform. GitHub Actions tylko po
   zakończeniu etapu albo za wyraźną zgodą użytkownika.
6. Dopiero po zaliczeniu testów aktywować v2 i usunąć przestarzałe
   produkcyjne writery v1.

Warunek zamknięcia D: aplikacja działa na v2 w produkcji; nie istnieje
równoległy snapshot writer. Każde usunięcie i nowy obiekt są
propagowane na wszystkie urządzenia.

## Zasady pracy

- Żadnej fałszywej deklaracji o zaliczeniu testów bez ich wykonania.
- Każda naprawa błędu wymaga testu regresyjnego.
- Nie tworzyć kopii (1) w rutynowych konfliktach; wyłącznie krytyczna
  sytuacja grożąca utratą danych.
- Kod fail-closed i opt-in nie oznacza gotowego produkcyjnego cutover.
- Nie uruchamiać GitHub Actions bez wyraźnego upoważnienia użytkownika.

- [ ] Quill embed renderer `VerifiedQuillEmbedBuilder` dodany do edytora
  v2, wymaga testów widgetowych Flutter przed cutover.

- [ ] Widget regression `test/verified_quill_embed_builder_test.dart`:
  obsługa osadzonego PDF i odmowa odczytu zewnętrznego URL.
  Test dodany, nie uruchomiony (brak lokalnego SDK Flutter).

## Lokalna kontrola przed przełączeniem

```bash
bash tool/verify_stage3_local.sh
```

Skrypt nie modyfikuje kodu i nie uruchamia GitHub Actions.
Warunkiem jest lokalnie zainstalowany Flutter/Dart.
Zaliczony test na jednej platformie nie daje automatycznie zgody na
przełączenie kont, backupów i współdzielenia na v2. Wyniki muszą zostać
zarejestrowane po rzeczywistym uruchomieniu.

## Weryfikacja analizy Darta — 5 listopada 2026

Przebieg `42067981768` potwierdził brak błędów formatowania, lecz
`dart analyze` zatrzymał się na ośmiu błędach w testach: sześciu
brakujących `dependencies` w `OperationEnvelope`, kolizji
`isNotNull` oraz niepoprawnym `const` w teście projekcji.
Naprawy wprowadzono w `3c5d494`; wynik ponownej analizy i testów
wymaga rzeczywistego przebiegu CI. Nie odblokowuje to migracji v2.

## Regresje po pierwszym pełnym zestawie testów (2026-11-05)

Analiza Darta przeszła w przebiegu `42069076051`; zestaw testów
zgłosił siedem niepowodzeń. Skorygowano test konstrukcji stron
(wymagane `page.create` przed dalszymi mutacjami), skonfigurowano
izolowany katalog dla obrazu, zastąpiono nieprawdziwy checksum
obliczeniem SHA-256, zaktualizowano oczekiwania migracji do SQLite v7,
a pomocniczy generator zdarzeń tekstowych testuje Undo z monotonicznym
zegarem. W teście synchronizacji uwzględniono także echo dwóch lokalnych
operacji, stąd checkpoint 3. Ponowny wynik CI pozostaje do weryfikacji.

Drugi przebieg `42070224438` przeszedł analizę Darta i 821 testów,
ale zakończył się jednym błędem: `image move preserves the asset and
never recreates its ID`. Przyczyną było przygotowanie scenariusza przez
legacy zapis, a następnie sprawdzanie bajtów oraz referencji SQLite v2.
Commit `9a51cb7` przygotowuje obraz od początku przez zweryfikowane
`asset.attach` v2, po czym przenosi go i usuwa bez utraty bajtów.
Aktualny `dev` zawiera tę poprawkę; wymagany jest jeszcze przebieg CI
dla commitu co najmniej `9a51cb7` przed uznaniem regresji za zamkniętą.
