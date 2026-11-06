# Etap 3 — finalizacja integracji edytora v2

## Ochrona zapisu przed limitem historii — 2026-11-06

W kontrolerze zakończony gest przekraczający budżet kodowania
checkpointu nie zatrzymuje lokalnego zapisu i outboxu. Zeruje historyczne
Undo/Redo pod bieżącym head, żeby nie odwracać starszego gestu po
niezarejestrowanej zmianie. Błędy zakresu, checksumy lub referencji
mediów pozostają krytyczne. Test regresyjny kontrolera przechodzi
przez prawdziwą transakcję v2 z wstrzykniętym limitem kodeka.
Weryfikacja Flutter/CI wymaga wyniku GitHub Actions.

## Integracja lokalnej historii kontrolera — 2026-11-06

Poprzedni przebieg aplikacji `42213343174` (commit `45eb3d9a`)
jest zielony, podobnie jak backend `42160118098`.
W `EditorController` podłączono odczyt checkpointu aktora przy starcie
oraz zapis obu stosów w atomowym callbacku `writeNotebookChange`.
Granice Quill kończone po wcześniejszych autosave nie tworzą
fikcyjnej operacji, ale utrwalają historię na bieżącej głowie dziennika.
Undo/Redo zapisuje nowe operacje i remapowane ID, a odzyskane
stany historyczne są dekodowane dopiero po wybraniu inverse.
Regresja plikowego SQLite: edycja → restart → Undo → Redo.
Wymagane potwierdzenie analizy i testów Flutter w CI; flagi v2
ani produkcyjnego cutover nie zmieniono.


## Limit historii i metadata-only inverse — 2026-11-06

Najpierw sprawdzono Actions `42210246686` dla `dce1bf6`: generator,
format, analiza, 974 zaliczone testy (2 pominięte), pokrycie 70,78%.
Naprawa palet `003ae91` również zielona. Backend `42160118098` bez błędów.

`EditorHistoryBudgetExceeded` rozróżnia przekroczenie limitu rozmiaru od
uszkodzonych/scoped danych. `fitToByteBudget` zachowuje największy
mieszczący się sufiks historii: najpierw usuwa najstarsze Undo, potem
najdalsze Redo. Wyszukiwanie binarne ogranicza liczbę kosztownych kodowań.
Nie zmienia wejściowych stosów ani scope/head; w ostateczności zachowuje
pustą historię zamiast blokować samą operację dokumentu. Błędy integralności
nie są przechwytywane jako limit. Wywołanie redukcji musi być jawne;
samo dodanie API nie zmienia jeszcze zachowania kontrolera.

`EditorHistoryNotebookCodec.remapIdentities` kopiuje metadane i zmienia
jedynie ID stron/obiektów. Nie ładuje BLOB-ów i nie odczytuje SQLite;
Delta, asset ID i dokument pozostają takie same. Waliduje scope i kolizje.
Istniejący scenariusz delete → checkpoint → restart → nowy inverse →
restart Redo używa teraz tego remapu zamiast ręcznego kopiowania modeli.

Dodano 6 testów pure Dart dopasowania obu stosów, granicy UTF-8,
największego zachowanego sufiksu i typów błędów; 1 regresję transakcji
SQLite (redukcja historii zachowuje treść i outbox) oraz 2 regresje remapu,
w tym wykonanie przy zamkniętej bazie. Wszystkie 12 testów formatu historii
i ich analiza przeszły lokalnie. Testy Flutter są kierowane do Actions
wyłącznie aplikacji; nie czekamy na wynik. Nie zmieniono schematu ani API
sieciowego.

Następna sesja: sprawdzić Actions, potem podłączyć zapis/odczyt stosów w
`EditorController`. Korzystać z jawnego dopasowania budżetu i remapu
metadanych w callbacku transakcji, zmieniać pamięć UI dopiero po commicie.
Nadal wymagane są testy rzeczywistego kontrolera po restarcie, autosave,
Undo/Redo i błędach zapisu; flaga opt-in i etap 3 pozostają otwarte.

## Kodek notebooka i zweryfikowanych mediów historii — 2026-11-06

Najpierw zdiagnozowano `42202704002`: generator Drift, analiza i 15 testów
historii przeszły; jedynym błędem był wyścig testu palet. Poprawka
`003ae91` jest wypchnięta. Jej ponowienia nie odczytywano w tej sesji.
Backend `42160118098` nadal zielony; bez zmian i ponawiania.

`EditorHistoryNotebookCodec` zamraża pełne metadane notebooka/boarda,
strony, kolejność warstw, ink i plain/Quill przed pierwszym await.
Media są reprezentowane tylko przez trwałe scoped referencje: ID assetu,
SHA-256, MIME i rozmiar, bez BLOB, base64, ścieżek plikowych i URL.
Najwcześniejszy receipt utrzymuje stabilność starej granicy po kolejnym
imporcie identycznych bajtów. Odtwarzanie sprawdza format, scope,
integralność, sygnaturę pliku i trwałe potwierdzenie w dzienniku dokumentu.
Sprawdzenie działa po usunięciu widocznego obrazu/PDF/Quill, bez zapisu
bazy lub samodzielnego przywracania tombstone. Daty są kanonicznym UTC.

Dodano 16 regresji natywnego, plikowego SQLite: round trip i restart,
plain text, Quill, image/PDF, crop/obrót i kolejność warstw, izolacja
scope, uszkodzony/brakujący BLOB, sprzeczne receipts, URL, niedozwolone
pola/wersje/ID/geometria, budżet UTF-8, mutacje wejścia podczas await,
stabilność aliasów i niezależne kopie bajtów. Scenariusz integracyjny
zapisuje checkpoint w transakcji usunięcia, restartuje SQLite, wykonuje
nowy inverse pod nowymi ID i po kolejnym restarcie odczytuje stos Redo.
To test writera/kodeka/store, **nie** jeszcze test przycisku kontrolera.

Lokalnie sprawdzono formatowanie 285 plików Dart, składnię Bash i diff.
Testy Flutter i pełna analiza są kierowane do Actions tylko aplikacji,
bez czekania na wynik (lokalnie brak SDK Flutter). Nie zmieniono schematu
SQLite v8 ani protokołu.

**Następny spójny krok po sprawdzeniu Actions:** podłączyć do kontrolera
odczyt checkpointu dla trwałego aktora dokumentu i atomowy zapis stosów
w `onCommittedInTransaction` przy gestach, domykaniu autosave i Undo/Redo.
Przenosić stosy/remap ID dopiero po commicie. Stan przed/po musi mieć
zamrożone, zweryfikowane media; path-only import materializować przed
callbackiem (bez I/O plikowego w transakcji). Trzymać metadane stosów,
a wybrany notebook inverse dekodować przy użyciu, zamiast ładować
50 kopii BLOB-ów przy starcie. Wymagane testy rzeczywistego kontrolera
po restarcie, błędzie zapisu i przy nowym local/remote head. Domknąć
obsługę limitu całego checkpointu bez blokowania niezwiązanej treści.
Historia UI po restarcie pozostaje otwarta; v2 nadal opt-in, bez cutover.

## Naprawa niestabilnego testu preferencji — 2026-11-06

Actions `42202704002` dla `2077f27`: generator Drift, format i analiza
przeszły. Wszystkie 15 nowych testów checkpointów i SQLite przeszło.
Przebieg zakończył się 956 zaliczonymi, 2 pominiętymi i 1 błędnym testem:
`previous factory swatches migrate by position in every palette` odczytał
jeszcze domyślną paletę po stałym opóźnieniu 50 ms.

`EditorController.preferencesReady` udostępnia rzeczywisty koniec odczytu
i migracji. Testy preferencji czekają na tę granicę zamiast timeoutu.
Nowa regresja blokuje odczyt w PathProvider, sprawdza niezakończone Future,
zwalnia bramkę i kontroluje dokładną migrację palety i wybranego koloru.
Backend `42160118098` pozostaje zielony. Ponowienie dotyczy tylko analizy
i natywnych testów aplikacji; wynik odczytać w kolejnej sesji.

## Trwałe checkpointy historii — fundament (2026-11-06)

Na początku potwierdzono Actions `42197652976` dla `8d30275`:
format, analiza, 942 zaliczone testy (2 pominięte), pokrycie 70,28%.
Potwierdza to poprzedni import HUD/Quill i scenariusze dwóch plikowych
baz po utracie ACK. Backend `42160118098` pozostaje zielony.

SQLite v8 dodaje oddzielną, lokalną tabelę `editor_history`, indeksowaną
przez dokument i trwałego aktora tego dokumentu. `EditorHistoryCheckpoint`
zapisuje oba stosy, deduplikuje wspólne stany SHA-256 i waliduje wersję,
zakres, tożsamości oraz limity 50 gestów / 4 MiB UTF-8. Nie jest snapshotem
autorytatywnego dokumentu ani payloadem synchronizacji. `EditorHistoryStore`
odrzuca nieistniejące/obce/zdalne operacje, dokument z tombstone i zapis
przy nieaktualnej głowie dziennika. Nowa operacja lokalna lub zdalna
unieważnia starszy checkpoint przy odczycie; uszkodzony checksum zgłasza
błąd bez zmiany dokumentu, outboxu ani wiersza historii.

Opcjonalny `onCommittedInTransaction` przechodzi przez writer, SyncEngine
i OperationStore. Działa po wszystkich operacjach gestu, wewnątrz tej
samej transakcji i przed powiadomieniem UI/backupu. Błąd checkpointu
wycofuje projekcję, numerację aktora i outbox. Pusty wsad jest dozwolony
wyłącznie z callbackiem: umożliwi końcową granicę już autosave'owanego
tekstu bez sztucznej operacji. Callback nie wykonuje HTTP, plikowego I/O
ani mutacji UI; listę zatwierdzanych operacji otrzymuje tylko do odczytu.

Dodano 6 testów formatu i 9 testów natywnego SQLite/writera: restart,
rollback dwóch operacji i retry bez luki actorSeq, rollback po zapisie
checkpointu, metadata-only autosave, izolacja aktora/dokumentu, korupcja,
nowa głowa lokalna/zdalna, tombstone i migracja v7→v8 bez utraty dziennika.
Lokalnie przeszło 6 testów czystego Darta i ich analiza, próba SQL
(schemat, rollback, FK), formatowanie 283 plików Dart oraz składnia skryptu.
Pełna analiza, build_runner i testy Flutter są kierowane do Actions
wyłącznie aplikacji; ich wyniku nie odczytujemy w tej sesji.

**Do następnego kroku:** magazyn nie jest jeszcze wywoływany przez
`EditorController`. Przygotować codec stanów notebooka z referencjami do
zweryfikowanych assetów zamiast powielania BLOB/ścieżek; następnie podłączyć
atomowe zapisy przy gestach, końcu autosave, Undo/Redo oraz odtworzenie
stosów podczas inicjalizacji. Dodać test rzeczywistego kontrolera po
zamknięciu/otwarciu SQLite, z usunięciem i odtworzeniem image/PDF/Quill
oraz nowymi UID po tombstone. Historia UI po restarcie nadal nie jest
ukończona. Flaga pozostaje wyłączona; etap 3 i produkcyjny cutover otwarte.

## Importy i rich paste prostego HUD — 2026-11-06

Przed kodem potwierdzono `42185379376` dla `1f48022`: formatowanie,
analiza, 921 zaliczonych testów (2 pominięte), pokrycie 70,35%.
Oba scenariusze dwóch baz po utracie ACK są już zielone. Backend
`42160118098` nadal zielony i nie wymaga ponowienia.

Przycisk importu jest dostępny także w zwykłym HUD v2. HUD pożycza
kontroler tekstu tylko na czas montażu. Wspólna walidacja porównuje całą
TextEditingValue, treść Delta, blok i właściciela; zmiana tekstu,
zaznaczenia, kompozycji IME lub wymiana/unmount kontrolera anuluje import.
Dopiero po pełnej walidacji powstaje tymczasowa Delta Quill. Normalna
ścieżka aktualizacji i checkpointów zapisuje zmianę bez snapshotów v1.
Przejście do Quilla przenosi rzeczywisty kursor, jest jednorazowe i dotyczy
dokładnej Delta. Obejmuje również import zwykłego HTML o jednolitym stylu.
Anulowanie pickera pozostawia tę samą instancję HUD i zaznaczenie.
Wcześniejsze pisanie i import mają oddzielne granice Undo. Sprawdzane są
UTF-16/emoji; zaznaczenie rozcinające parę surogatów jest odrzucane.

Ctrl/Cmd+V i menu Paste HUD korzystają z kontrolowanego rich clipboardu.
Przy braku rich danych pozostaje natywna ścieżka tekstu. PNG/JPEG ze
schowka są odczytywane z limitem 64 MiB; strumień kończy się błędem przy
przekroczeniu limitu, bez otwierania URI jako plików. Nowe embedy mają
podgląd ze zweryfikowanego bufora jeszcze przed autosave; po commicie
odczyt przechodzi na scoped BLOB. Eliminuje to zapamiętanie błędu odczytu
SQLite, zanim nowy attach zdąży się utrwalić. Granica dokumentu pozostaje
sprawdzana; nowe URL-e nie są źródłem bajtów.

Dodano 18 regresji Flutter/kontrolera/SQLite: przejście HUD → Quill dla
image/PDF w jasnym i ciemnym motywie, kursor, Undo/Redo, nieaktywny lub
wymieniony kontroler, IME, niezgodny model, uniform paste, Unicode i
podgląd przed/po commicie. Dodano 3 testy czystego Darta dla strumieni
(kopia chunków, limit, pusty strumień, błąd źródła i walidacja przed odczytem).
Lokalnie przeszło 55 testów czystego Darta na produkcyjnym kodzie oraz
analiza testu planu; formatowanie 279 plików Dart i składnia skryptu są
poprawne. Testy Flutter oraz pełna analiza tego przyrostu wymagają Actions,
bez czekania na wynik. Flaga v2 pozostaje wyłączona. Historia po restarcie,
pełne E2E PostgreSQL i produkcyjny cutover nadal nie są ukończone.

Ręczne sprawdzenie wejścia platformowego po zielonym CI: w zwykłym polu
zaznaczyć środek tekstu, wkleić PNG przez Ctrl/Cmd+V i menu Paste, następnie
HTML z formatowaniem. Zweryfikować zachowanie reszty tekstu i Undo.
Powtórzyć zmianę zaznaczenia podczas odczytu schowka oraz anulowanie
pickera PDF. To scenariusz ręczny, nie deklaracja zaliczenia platform.

## Regresja utraconego ACK — 2026-11-06

Przebieg `42180248467` dla `030456f` przeszedł formatowanie i analizę,
zaliczył 919 testów (2 pominięte), ale oba scenariusze dwóch baz zatrzymały
się na błędnym oczekiwaniu globalnego `lastError` po utracie ACK.
SyncEngine zapisuje retry danego aktora; końcowy drain może wyczyścić
przejściowy globalny błąd. `pending()` bez `includeDeferred` celowo pomija
jeszcze niewysyłalne operacje.
Test sprawdza teraz faktyczne przyjęcie wszystkich ID przez transport,
utratę odpowiedzi, identyczny trwały outbox z `includeDeferred: true`
i licznik attempts/status queued pierwszego wpisu retry. Nie osłabia
sprawdzeń restartu, braku duplikatów i późniejszego ACK. Kod produkcyjny
nie został zmieniony w tej poprawce. Wynik ponowienia odczytać w kolejnej
sesji; ponawiamy wyłącznie analizę/natywne testy aplikacji. Backend zielony.

## Import pliku do aktywnego Quilla — 2026-11-06

Na początku sesji potwierdzono zielone Actions `42175319331` dla
`7bef9f0`: format, analiza, 900 testów (2 pominięte), pokrycie 70,22%.
Potwierdza to poprzedni import inline, toolbar i rich paste, w tym
regresje Quill/SQLite. Backend `42160118098` dla `6b0da04` również zielony;
nie wymaga zmiany ani ponowienia.

Pasek aktywnego Quilla v2 ma teraz przycisk `Insert image or PDF into text`.
`insertQuillFile` odczytuje pojedynczy PNG/JPEG/WebP/PDF przez istniejący
FilePicker. Na native sprawdza metadane i rzeczywistą długość przed
wczytaniem pliku; na Web używa bajtów, bez dostępu do niedostępnego path.
Typ pochodzi z sygnatury. `QuillPastePlan.fromMediaBytes` kopiuje sprawdzone
bajty bez pośredniego base64. Wspólny `_replaceQuillSelection` zachowuje
kontrole zakresu, tekstowego budżetu i lifecycle clipboardu. Zastępuje
tylko uchwycone zaznaczenie, a zwykła mutacja Quill zapisuje asset i tekst
jedną istniejącą ścieżką v2. PDF pozostaje embedem, bez renderowania go
na osobne obrazy/strony canvasa. Legacy i prosty HUD zachowują dotychczasowy
interfejs; przycisk dotyczy aktywnej instancji Quilla.

Anulowany picker, nieaktywny blok, read-only, zmiana tekstu/zaznaczenia,
zamknięty widget i przegrany równoległy import nie mogą nadpisać treści.
Błędne typy, bajty, liczba plików, ścieżki i limity nie tworzą attach.
Dodano 5 testów czystej logiki, 14 regresji kontrolera/pickera/widżetu
oraz 2 scenariusze dwóch niezależnych, plikowych SQLite (image/PDF).
Te ostatnie łączą produkcyjne gatewaye HTTP, SyncEngine, writer i dispatcher:
import offline → restart → upload przed operacjami → utrata ACK → drugi
restart → echo bez repaintu → pobranie z kontrolą checksum → usunięcie
na drugim urządzeniu → Undo pod nowym ID z tym samym assetem. Sprawdzają
również niezmieniony zoom/pan i tożsamość sąsiedniego tekstu. Transport
HTTP jest kontrolowany w teście; nie jest to pełne E2E PostgreSQL.

Lokalnie: 52 testy czystego Darta na produkcyjnym kodzie przeszły, analiza
pliku testu planu bez uwag, formatowanie 279 plików Dart i składnia
skryptu weryfikacji poprawne. Nowe testy Flutter/SQLite/widget i pełna analiza
pozostają do wykonania w Actions, bez czekania na wynik. Zmieniona jest
wyłącznie aplikacja; CI ograniczamy do analizy i testów natywnych.
Następna sesja zaczyna od Actions. Historia Undo/Redo po restarcie,
pełne E2E i produkcyjny cutover pozostają otwarte; przejście HUD opisano
w nowszym przyroście powyżej. Nie aktywowano flagi i nie usunięto v1.

## Kontrolowany rich paste — 2026-11-06

Najpierw naprawiono analizę z `42168819661` w commicie `6bcfbaf`.
Wynik nowego przebiegu nie był odczytywany w tej sesji.
Backend `42160118098` pozostaje zielony; nie wymaga zmiany ani ponowienia.

`pasteQuillHtml` przejmuje clipboard aktywnego Quilla v2. Konwerter HTML
zachowuje formatowanie; `QuillPastePlan` waliduje insert-only Delta,
atrybuty, limit tekstu oraz łączny budżet bajtów przed mutacją dokumentu.
Obrazy z data URI trafiają przez istniejący staging i normalny zapis gestu;
powtórzenie tego samego źródła nie duplikuje pliku. Plan obsługuje również
PDF w Delta. Picker do aktywnego Quilla dodano w kolejnym przyroście
opisanym powyżej; konwersja HTML object/embed nie jest obsługiwana.

Wewnętrzne kopiowanie Quill zachowuje Delta i istniejące asset ID, także
przed pierwszym autosave. Writer sprawdza zakres dokumentu, typ, rozmiar
i integralność bajtów. Clipboard HTTP/file i nieznane embedy są odrzucane
bez kasowania zaznaczenia; nie pobieramy plików z sieci. Zmiana bloku,
kontrolera, treści, zaznaczenia lub zamknięcie widgetu anuluje opóźniony
paste. Callbacki są związane z konkretną instancją kontrolera.

Lokalnie zaliczono 47 testów na produkcyjnym kodzie czystego Darta:
12 nowych testów planu i konwersji HTML oraz regresje adaptera tekstu,
protokołu i stylów. Zależności runnera dopasowano do locka aplikacji. Formatowanie wszystkich
278 plików Dart i składnia skryptu weryfikacji również przeszły.
Dodano 13 integracyjnych regresji Quill/SQLite: formatowanie, deduplikacja,
Undo/Redo po wyczyszczeniu bufora, odmowa całego paste, wyścigi lifecycle,
wewnętrzna kopia przed autosave i weryfikacja trwałych referencji/bajtów.
Ich wykonanie oraz pełna analiza Flutter wymagają Actions. Nie przedstawiamy
ich jako lokalnie zaliczonych. Ponowienie CI obejmuje aplikację, bez backendu
i niezmienionych buildów platform; wyniku nie czekamy.

Następna sesja: najpierw wyniki Actions, następnie brakujące wejścia mediów
w interfejsie i pozostałe wymagania etapu 3. Trwała historia Undo/Redo po
restarcie, pełne E2E i cutover nadal nie są ukończone. Flaga pozostaje off.

## Typ wyniku callbacku clipboard — 2026-11-06

Przebieg `42168819661` dla `b4d3dac` przeszedł formatowanie, ale analiza
zatrzymała się na niejednoznacznej inferencji `tester.runAsync`: callback
zwraca `Future<String?>`, a kontekst wymagał `Future<String>`.
Test określa teraz `runAsync<String?>` jawnie. Dodano również odmowę
starego callbacku po opuszczeniu aktywnego bloku: `null` i niezmieniona
Delta, przed ponownym prawidłowym importem. Zestaw Flutter nie został
w tym przebiegu uruchomiony; ponowienie dotyczy tylko analizy/natywnych
regresji aplikacji. Wynik należy odczytać w następnej sesji.

## Toolbar bez spłaszczania rich text — 2026-11-06

`updateActiveTextStyle` dla v2 nie odbudowuje już Delta z `before.text`.
Dotychczasowa ścieżka mogła zamienić obraz/PDF na niepowiązany znak
U+FFFC i ujednolicić niezwiązane formatowanie. `patchQuillStyle` nakłada
tylko wskazane pola na istniejące inserty. Zachowuje embedy, linki,
niezmieniane kolory/fonty/dekoracje i atrybuty akapitów. Wynik scala
równoważne fragmenty, aby kolejna edycja zgadzała się z trwałymi atomami.
Protokół i schemat nie zmieniły się; legacy zachowuje swoją ścieżkę.

Lokalnie zaliczono pięć testów czystej funkcji: kolory/różne style,
akapity, czyszczenie i kanonizacja, Unicode/współdzielone embedy oraz
odmowa niepoprawnej Delta. Regresje SQLite image/PDF sprawdzają zmianę
fontu bez ujednolicania kolorów, color/font/alignment/clear, Undo/Redo,
te same atom ID i wyłącznie text.format/object.set — bez przepisywania
treści, attach/detach lub ponownego tworzenia obiektów.
Te integracyjne regresje wymagają potwierdzenia w kolejnym Actions.

## Potwierdzone regresje i nowy import inline — 2026-11-06

Przebieg `42160667069` dla `e4b1cfc` przeszedł formatowanie, analizę,
862 testy (2 pominięte) i próg pokrycia: 69,95%. Potwierdza wcześniejsze
przyrosty inverse, ID historii, mediów, edycji Quill i typing → delete.
Backend `42160118098` dla `6b0da04` również zakończył się sukcesem.

Nowy lokalny import `prepareInlineAsset`/`stageQuillAsset` przyjmuje
bajty, rozpoznaje PNG/JPEG/WebP/PDF i sprawdza typ oraz limit 64 MiB.
Nie wykonuje HTTP ani przedwczesnego zapisu operacji. Zwraca kanoniczną
referencję `asset:`; zwykły gest tekstowy utrwala attach, BLOB, atomy
i outbox w jednej transakcji. Rollback zachowuje staging do retry,
a udany commit zwalnia rejestrację również pod kluczem asset ID.

W tym wcześniejszym przyroście podłączono clipboard obrazów aktywnego
Quill v2. Kontrolowany HTML/rich paste dodano w przyroście opisanym na
górze dokumentu; kolejny przyrost dodaje picker PDF aktywnego Quilla.

Nowe regresje: cztery formaty, niezmienność kopii bajtów, brak operacji
przed gestem, Undo/Redo po wyczyszczeniu bufora, restart pliku SQLite
i outboxu, zły typ/rozmiar/zakres oraz rollback attach z ponowieniem.
Test widgetowy używa rzeczywistego callbacku clipboard i sprawdza
osadzony obraz w Delta i SQLite. Lokalnie zaliczono cztery testy bufora
na produkcyjnym kodzie przez runner czystego Darta oraz formatowanie
273 plików. Testy SQLite/widget tego przyrostu wymagają wyniku kolejnego
Actions; nie były uruchamiane lokalnym Flutterem.

## Bieżący punkt przekazania — 2026-11-06

Instrukcje repozytorium znajdują się w `CZAT.md` i `AGENTS.md`.
Najpierw odczytać Actions aktualnego `dev`. Poprzedni przyrost do
`e4b1cfc` został potwierdzony zielonym przebiegiem `42160667069`;
rich paste potwierdzono przebiegiem `42175319331` (900 passed, 2 skipped).
Nowy picker i test dwóch baz wymagają odczytu aktualnego wyniku.
W razie błędu najpierw naprawić regresję; nie ponawiać niezmienionych platform.

Backend `6b0da04` dodaje sześć kontraktów inverse mediów i tombstones.
Lokalnie po tym przyroście: 278 passed, 8 skipped (PostgreSQL).
Nie zastępuje to E2E Flutter ↔ HTTP ↔ PostgreSQL.
Po zielonym CI kontynuować trwałą historię po restarcie oraz pełne E2E.
HUD i importy opisano w nowszym przyroście na górze dokumentu.
Rebase dwóch klientów, synchronizacja całego konta i aktywacja flagi
pozostają kolejnym etapem. Produkcja nadal korzysta z v1.

## Kolory aktywnego Quill bez mutowania Delta — 2026-11-06

Nowa aktywna ścieżka Quill v2 korzysta z `customStyleBuilder` do
przeliczenia koloru na ciemny motyw podczas renderowania. Kopia display
nieaktywnego tekstu nie jest przeliczana ponownie. Wspólna regresja
widgetowa sprawdza rzeczywiste TextSpan w obu motywach, a następnie
niezmieniony atrybut koloru w SQLite i pełne odtworzenie Delta przez Undo.
Formatowanie sprawdzono lokalnie; wynik testów Flutter pozostaje do
odczytu z Actions w następnym uruchomieniu.

## Ponowna analiza po testach historii — 2026-11-06

Przebieg `42144008139` dla `c6d8db3` przeszedł formatowanie,
ale zatrzymał się na dwóch ostrzeżeniach `unnecessary_non_null_assertion`
w regresji typing → delete. Callback korzysta teraz z lokalnej,
sprawdzonej zmiennej Completer bez zbędnego `!`. Zestaw testów nie
został w tym przebiegu uruchomiony. Ponowienie obejmuje wyłącznie
analizę i testy natywne; wynik należy sprawdzić w następnej sesji.

## Usunięcie aktywnego tekstu przed autosave — 2026-11-06

`deleteTextBlock` w v2 nie odrzuca już granicy aktywnej edycji.
Przed usunięciem zatwierdza jej checkpoint przez istniejące
`_applyAction`. Inaczej szybkie pisanie → usuń mogło cofnąć usunięcie
do starej treści sprzed autosave, tracąc ostatni szkic.

Testy kontrolera obejmują usunięcie zarówno przed pierwszym autosave,
jak i po nim. Sprawdzają Undo usunięcia do najnowszej treści, Undo edycji
do oryginału i obie operacje Redo, ze stabilnym ID odtworzonego bloku.
Nie zmieniono ścieżki legacy. Wynik nowych regresji wymaga kolejnego
odczytu Actions; nie oznacza zamknięcia całego etapu 3.

## Produkcyjna edycja złożonego Quill v2 — 2026-11-06

Aktywacja tekstu v2 z mieszanym formatowaniem lub embedem korzysta
teraz z istniejącego edytora Quill zamiast pola spłaszczającego Delta
do zwykłego tekstu. Wspólna walidacja jednolitego stylu rozstrzyga
zarówno podgląd, jak i aktywację. Stabilne klucze zachowują kontroler
między podglądem a edycją; aktywna sesja pozostaje w Quill również,
gdy użytkownik uprości treść do jednego stylu. Prosty tekst nadal
korzysta z dotychczasowego HUD. Nie przełącza to konta na v2.

`page_overlay_v2_quill_edit_test.dart` łączy rzeczywisty PageOverlay,
QuillController, writer i SQLite. Sześć scenariuszy (tekst mieszany,
obraz, PDF × jasny/ciemny motyw) sprawdza edycję, zachowanie Delta,
referencji i bajtów oraz Undo. Jest też przejście do jednolitego tekstu
bez wymiany aktywnego kontrolera. Testy dodano do zestawu etapu 3;
wynik wykonania pozostaje do odczytu w następnej sesji.

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

- [x] Quill embed renderer `VerifiedQuillEmbedBuilder` dodany do edytora
  v2; testy widgetowe zaliczone w `42175319331`, bez aktywacji cutover.

- [x] Widget regression `test/verified_quill_embed_builder_test.dart`:
  osadzony PDF i odmowa zewnętrznego URL; zaliczona w `42175319331`.

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
