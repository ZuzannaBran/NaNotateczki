# Finalny plan wdrożenia zapisu i synchronizacji NaNotateczki

**Wersja: 4 listopada 2026. Etapy 0–14 (łącznie 15 etapów).**

**To jest plan wdrożeniowy, nie potwierdzenie wykonania etapów.** Stan faktyczny w repozytoriach i status testów mają pierwszeństwo przed listą zadań.

Cel: zastąpić obecne mechanizmy zapisu jednym spójnym systemem, w którym zmiany są trwałe, usunięcia nie są cofane przez stare dane, współdzielenie działa płynnie, a konta mają całkowicie odseparowane magazyny.

Architekturę oprzemy na mechanizmach sprawdzonych w [Figma](https://www.figma.com/blog/how-figmas-multiplayer-technology-works/?utm_source=chatgpt.com), [Replicache](https://doc.replicache.dev/concepts/how-it-works?utm_source=chatgpt.com) i [Yjs](https://docs.yjs.dev/api/document-updates?utm_source=chatgpt.com). Nie będziemy kopiować całych bibliotek bez sprawdzenia ich zgodności z Flutterem.




Zakres wdrożenia

15 etapów (0–14)

Aplikacja

Flutter / Drift

Serwer

FastAPI / PostgreSQL

Synchronizacja

Operacje / WebSocket

## Stan zastany i strategia wejścia (zweryfikowano 2026-11-04)

- `NaNotateczki/dev`: oddzielne magazyny Local/kont na czystych instalacjach oraz opt-in infrastruktura `OperationStore`, `SyncEngine`, `ShareOperationProjection` są przygotowane. **Produkcja edytora, właściciel i gość Share nadal zapisują przez v1**.
- `NaNotateczki-serwer/main`: istnieją API v2 i migracje przez `0013_account_protocol_fence.sql`; marker konta v2 blokuje starsze write'y v1. Domyślny v2 write jest wyłączony. Marker sam nie konwertuje danych ani edytora.
- Dane testowe PostgreSQL i lokalne zostały wskazane jako usunięte. **Dla rzeczywiście pustego magazynu nie migrujemy historycznych dokumentów; nadal musimy sprawdzić każdy aktywny magazyn, cache, asset, outbox, dawny klient i konto osobno.** Nie interpretować pustej biblioteki jako automatycznej zgody na pominięcie kontroli.
- `docs/ETAP_11_MIGRATION.md`, `docs/ETAP_12_TESTS.md`, `docs/ETAP_14_FINALIZACJA.md` oraz backend `docs/STAGE13_PRODUCTION_ROLLOUT_PL.md` wskazują brak kompletnego cutover v2 i niezaliczone E2E.
- **Zakaz produkcyjnego przełączenia:** do momentu kompletnej obsługi gestów, Quill, obrazów/PDF, planera, folderów, backupu, odtwarzania i Share oraz potwierdzenia testów. Nie włączać równocześnie writerów v1 i v2 dla tego samego UID.

## Bramki decyzyjne (obowiązujące niezależnie od numeracji etapów)

| Bramka | Wymaganie | Dopuszczalna decyzja |
| --- | --- | --- |
| G1 — lokalny zapis | Każda akcja edytora generuje trwałą operację i projekcję w jednej transakcji; assety mają integralność | Rozpocząć testy synchronizacji |
| G2 — integracja | Native/Web, Share host/guest, planner, foldery, rich text i assety korzystają z v2 bez snapshotowego writera | Uruchomić testy prawdziwego stosu |
| G3 — E2E | Zaliczone realne SQLite + Flutter + FastAPI + PostgreSQL + WebSocket i testy gestów na dwóch klientach | Dopuścić izolowany canary |
| G4 — migracja/izolacja | Konta oznaczone v2 nie mają czynnych writerów v1; puste konta potwierdzone; istniejące dane przeszły pełną migrację; outboxy bez strat | Przełączyć pojedyncze konto |
| G5 — eksploatacja | Zweryfikowane odtworzenie backupu, monitoring, rollback kompatybilny z v2, zgoda na rollout | Stopniowo udostępniać v2 |
| G6 — wycofanie | Nie istnieje czynny klient ani zapis v1; wszystkie kolejki rozliczone, testy przechodzą | Dopiero usunąć legacy |

## Etap 0. Ustalenie stanu wyjściowego i lokalna weryfikacja

Priorytet: krytyczny. Bez tego nie będzie wiadomo, czy nowe zmiany powodują regresje.

- Przeczytać aktualne `CZAT.md`, `data.md` i `PROJECT_MAP.md`.
- Sprawdzić najnowsze commity na `NaNotateczki/dev` i `NaNotateczki-serwer/main`.
- Naprawić niezdefiniowany `notifyChanges` w `notebook_repository.dart`.
- Naprawić wszystkie błędy formatowania Darta.
- Ujednolicić serwer znajdujący się w obu repozytoriach — jednym źródłem prawdy powinno zostać `NaNotateczki-serwer`.
- Usunąć rozbieżność dotyczącą `restoreDeleted`.
- Wykonać lokalne testy bazowe Fluttera i Pythona, odróżniając błędy kompilacji od błędów funkcjonalnych.
- Udokumentować aktualne zachowanie usuwania, tworzenia dokumentów, backupów i share.
- Nie usuwać jeszcze starej implementacji.

Kryterium zakończenia: kod kompiluje się, wszystkie nowo wykryte błędy mają testy regresyjne, a obie strony korzystają z tego samego kontraktu API.

## Etap 1. Zaprojektowanie nowego modelu danych

Obecnie dokumenty i ich pełne snapshoty są zbyt mocno związane z mechanizmem synchronizacji. Trzeba rozdzielić trzy rzeczy:

1. Stan dokumentu — aktualna zawartość widoczna w aplikacji.
2. Dziennik operacji — historia zmian prowadzących do tego stanu.
3. Backup — punkt kontrolny umożliwiający odzyskiwanie.

### Zadania

- Zdefiniować jeden model operacji obowiązujący na wszystkich platformach.
- Nadać każdemu dokumentowi, stronie i obiektowi stabilny identyfikator.
- Każda operacja otrzymuje:
  - `operationId` — globalnie unikalny identyfikator;
  - `actorId` — identyfikator urządzenia/instancji edytora;
  - `actorSeq` — rosnący numer ruchu na danym urządzeniu;
  - `documentId` i `objectId`;
  - `type` i `payload`;
  - `dependencies` — znane wcześniejsze operacje;
  - `logicalClock` — znacznik zegara logicznego;
  - `schemaVersion` — wersja formatu.
- Zdefiniować operacje dla kresek, tekstów, obrazów, stron, folderów i metadanych.
- Zdefiniować osobne operacje tworzenia i usuwania.
- Zdefiniować zachowanie Undo/Redo jako nowych operacji, a nie cofania historii serwera.
- Oddzielić zawartość dokumentu od lokalnego viewportu, zoomu i zaznaczenia.
- Opisać reguły konfliktów dla każdej kategorii obiektu.

### Przykładowe operacje

| Operacja           | Znaczenie                     |
| ------------------ | ----------------------------- |
| `stroke.create`    | Dodanie kreski                |
| `object.delete`    | Usunięcie konkretnego obiektu |
| `object.transform` | Przesunięcie lub skalowanie   |
| `text.insert`      | Dopisanie tekstu              |
| `text.delete`      | Usunięcie fragmentu tekstu    |
| `page.create`      | Dodanie strony                |
| `page.delete`      | Usunięcie strony              |
| `document.delete`  | Usunięcie dokumentu           |
| `object.reorder`   | Zmiana kolejności warstw      |

Kryterium: każda akcja edytora może zostać zapisana, odtworzona i powtórnie przetworzona bez uszkodzenia dokumentu.

## Etap 2. Nowy system kolejności zmian

To fundament całej przebudowy.

### Zadania

- Wprowadzić monotoniczny licznik `actorSeq` dla każdej instancji.
- Zapisywać zależności przyczynowe między operacjami.
- Stosować deterministyczny porządek przy operacjach niezależnych; Hybrid Logical Clock jest opcją tylko wtedy, gdy jego kontrakt jest identyczny w Dart i Pythonie (czas ścienny nie wyznacza prawdy o kolejności).
- Wymagać od serwera zachowania kolejności operacji danego aktora.
- Operacje otrzymane przed ich zależnościami przechowywać w kolejce, zamiast wykonywać w niewłaściwej kolejności.
- Rozstrzygać niezależne operacje według jawnej, deterministycznej polityki.
- Używać czasu serwera do diagnostyki i dodatkowego porządkowania, nie jako jedynego kryterium.
- Przetestować urządzenia z zegarami przesuniętymi o minuty, godziny i dni.
- Usunąć ograniczenie reprezentacji ponad 256 niezależnych zależności: zastosować skalowalny frontier/indeksowanie przyczynowe lub bezpieczną kompaktację z dowodem pokrycia. **Nie ucinać zależności i nie traktować obecnego fail-closed jako ukończonego rozwiązania.** Dodać test 257+ niezależnych aktorów i restart.
- Przy projektowaniu globalnego kursora PostgreSQL uwzględnić kolejność *commitów*: samo `BIGSERIAL`/`nextval()` nie gwarantuje, że późniejszy COMMIT ma większy numer od wcześniejszego. Zapewnić punkt serializacji zatwierdzania lub równoważny, dowiedziony algorytm watermarku.

### Reguły konfliktów

- Dwa różne obiekty dodane równocześnie → oba zostają.
- Przesunięcie A i zmiana koloru A → obie operacje zostają.
- Dwa ruchy zmieniające tę samą właściwość → wygrywa reguła deterministyczna uwzględniająca przyczynowość.
- Usunięcie obiektu i równoczesna edycja → usunięcie wygrywa; późniejsza, świadoma rekreacja wymaga nowej operacji i identyfikatora.
- Usunięcie dokumentu → trwały tombstone, którego nie może wycofać starsze urządzenie lub backup.

Ważne: fizycznej kolejności dwóch niezależnych gestów wykonywanych offline nie da się ustalić idealnie. Gwarantujemy natomiast kolejność ruchów każdego urządzenia, zależności przyczynowe i identyczny końcowy wynik na wszystkich klientach.

## Etap 3. Przebudowa lokalnej bazy SQLite

Stan 2026-11-06: opt-in kontroler zapisuje lokalne checkpointy Undo/Redo
w transakcji gestu i odczytuje je po restarcie dla aktora dokumentu.
Natywne obrazy i renderowane strony PDF zachowują bajty przed tą granicą;
odbudowa cache'u nie tworzy operacji. Dodano rzeczywisty przepływ dwóch
kontrolerów/plików SQLite przez FastAPI/PostgreSQL/WebSocket: media offline,
restart i usuwanie strony z Undo/Redo. Linux E2E ma osobny job; jego wynik
oraz najnowsze regresje pozostają do potwierdzenia w CI.
Etap i produkcyjny cutover pozostają otwarte; bieżące wykonanie i następne
bramki: [ETAP_3_FINALIZACJA_KROKI.md](ETAP_3_FINALIZACJA_KROKI.md).

Nie wymieniamy Drift. Wykorzystujemy jego transakcje do atomowego utrwalania danych i operacji.




### Nowe tabele

| Tabela               | Funkcja                        |
| -------------------- | ------------------------------ |
| `operations`         | Trwały dziennik operacji       |
| `operation_outbox`   | Operacje oczekujące na wysyłkę |
| `operation_ack`      | Potwierdzenia serwera          |
| `object_tombstones`  | Usunięte obiekty               |
| `sync_checkpoints`   | Kursory i potwierdzone rewizje |
| `document_snapshots` | Punkty kontrolne dokumentów    |
| `asset_references`   | Referencje obrazów i PDF       |

### Zadania

- Dodać nowe tabele w `notes_database.dart`.
- Podnieść `schemaVersion`.
- Napisać migrację Drift.
- Wygenerować pliki przez `build_runner`.
- Utworzyć centralną usługę `OperationStore`.
- Jedna transakcja zapisuje równocześnie zmianę obiektu i operację w outboxie.
- Zablokować przypadki, w których stan się zmienia, ale operacja nie zostaje utrwalona.
- Zastąpić pełne kasowanie i ponowne wstawianie stron aktualizacjami konkretnych rekordów.
- Wprowadzić kolejkę zapisów per dokument.
- Zabezpieczyć SQLite przed jednoczesnym zapisem starszego i nowszego stanu.
- Zweryfikować poprawność WAL, commitów i odtwarzania po awarii.
- Wprowadzić okresowe kompaktowanie potwierdzonych operacji, ale nigdy nie usuwać niepotwierdzonych lub potrzebnych do odtworzenia.
- Obrazy i PDF przechowywać jako osobne assety z checksumami; operacje mają zawierać referencje.
- Zdefiniować kolejność `upload asset → walidacja checksumy → zatwierdzenie referencji` i odzyskiwanie osieroconych assetów bez ich zbyt wczesnego usuwania.

Kryterium: po zabiciu aplikacji w dowolnym momencie można odtworzyć cały ostatni trwale zatwierdzony lokalnie stan.

## Etap 4. Przebudowa backendu PostgreSQL

Repozytorium: `NaNotateczki-serwer`, gałąź `main`.

### Zadania

- Dodać nową migrację SQL bez zmieniania wcześniejszych migracji.
- Utworzyć tabelę `document_operations`.
- Utworzyć tabelę `actor_checkpoints`.
- Utworzyć materializowany aktualny stan dokumentów.
- Dodać trwałe tombstones.
- Dodać unikalność `(actorId, actorSeq)` oraz `operationId`.
- Dodać globalną, transakcyjnie uporządkowaną sekwencję zdarzeń.
- Zapewnić atomowość: operacja, stan dokumentu i pozycja w dzienniku zatwierdzane w jednej transakcji.
- Weryfikować właściciela, uprawnienia share i zależności operacji.
- Odrzucać niepoprawne identyfikatory, spreparowane operacje i próby odtworzenia usuniętych obiektów.
- Obsłużyć duplikaty bez ponownego wykonania operacji.
- Obsłużyć retransmisję po utracie odpowiedzi HTTP.
- Zapewnić, że przerwany commit nie pozostawia częściowo zapisanego dokumentu.
- Dodać indeksy potrzebne do odczytu operacji według dokumentu i kursora.
- Zachować dotychczasowe uprawnienia oraz odwoływanie linków share.

### Nowe API v2

- `POST /v2/operations/batch` — zatwierdzanie operacji.
- `GET /v2/operations?after=...` — odczyt brakujących operacji.
- `GET /v2/documents/{id}/snapshot` — odczyt stanu początkowego.
- `GET /v2/sync/checkpoint` — odczyt kursora i potwierdzeń.
- `WS /v2/realtime` — natychmiastowe powiadomienia lub strumień operacji.

Dokładne nazwy endpointów mogą zostać dostosowane do aktualnego API; kontrakt zachowania pozostaje taki sam.

Kryterium: serwer niezależnie od liczby klientów zawsze produkuje jeden spójny stan i nie wykonuje operacji dwukrotnie.

## Etap 5. Jeden silnik synchronizacji dla całej aplikacji

To etap zastępujący dotychczasową synchronizację pełnych dokumentów.

### Zadania

- Utworzyć `SyncEngine` odpowiedzialny za operacje, potwierdzenia i odbiór.
- Lokalna operacja natychmiast zmienia interfejs.
- Operacja jest zapisywana trwale przed uznaniem jej za bezpiecznie utrwaloną.
- Outbox wysyła operacje w kolejności per aktor.
- Wysyłka działa paczkami, żeby ograniczyć obciążenie serwera.
- Potwierdzenia usuwają z kolejki wyłącznie zatwierdzone operacje.
- Utrata odpowiedzi powoduje ponowienie z tym samym identyfikatorem.
- WebSocket dostarcza nowe operacje albo sygnał pobrania brakujących.
- Po reconnect klient pobiera brakujące operacje od ostatniego potwierdzonego kursora.
- Kursor przesuwa się dopiero po trwałym zastosowaniu operacji lokalnie.
- Serwerowe potwierdzenie własnej operacji nie powoduje jej ponownego wykonania ani podmiany całego dokumentu.
- Nowe operacje lokalne są nakładane na aktualny stan serwera (rebase).
- Zmiany jednego dokumentu nie mogą blokować synchronizacji pozostałych.
- Ograniczyć liczbę równoległych synchronizacji i wprowadzić kontrolowany retry/backoff.
- Włączyć integrację `EditorController` / `NotebookRepository` z trwałym `OperationStore`: każda ścieżka zapisu (ink, gumka, tekst, obraz/PDF, transformacja, Undo/Redo, strona) musi korzystać z operacji v2. Bez tego etap 5 pozostaje infrastrukturalny, nie funkcjonalny.
- Weryfikować zgodność wersji protokołu per konto przed startem usług; klient nieobsługujący v2 nie może rozpocząć zapisu v1 ani usunąć outboxu.
- Obsłużyć pracę offline bez ograniczania edycji.

Kryterium: dwa urządzenia po rozłączeniu i ponownym połączeniu uzyskują identyczny dokument bez utraty niezależnych zmian.

## Etap 6. Przebudowa Share na operacje przyrostowe

To osobny, szczególnie ważny etap, wykorzystujący silnik z etapu 5.

### Zadania

- Host i gość korzystają z tego samego modelu operacji.
- Gość posiada własny trwały outbox, odizolowany od danych konta.
- Usunąć przesyłanie pełnego JSON dokumentu przy każdej zmianie.
- Usunąć globalne podmienianie canvasa po odebraniu rewizji.
- Odbierać i aktualizować tylko zmienione obiekty.
- Wprowadzić lokalną warstwę operacji oczekujących, której starsza odpowiedź serwera nie może nadpisać.
- Oddzielić wizualizację gestu od jego ostatecznego zatwierdzenia.
- Podczas rysowania można wysyłać nietrwałe fragmenty kreski dla płynnego podglądu.
- Po zakończeniu gestu wysyłać trwałą operację zawierającą finalną kreskę.
- W razie utraty połączenia tymczasowy podgląd ma zniknąć tylko tam, gdzie nie został zatwierdzony; lokalny autor zachowuje swoją operację.
- Przesunięcia i skalowanie propagować jako zmiany konkretnych właściwości.
- Nie resetować widoku, zoomu ani aktywnej strony.
- Nie odmontowywać `EditorController` podczas synchronizacji.
- Obsłużyć równoczesne edycje tego samego pola tekstowego; dla treści tekstu użyć spójnego kontraktu CRDT w Dart i Pythonie. Obowiązkowo zaprojektować formatowanie **Quill rich-text**, atrybuty, style, puste akapity, Unicode oraz migrację istniejącego `deltaJson` bez utraty formatowania. Nie zastępować CRDT operacją `object.set` zawierającą całą treść.
- Rozdzielić synchronizację wyglądu hosta od zawartości dokumentu.
- Zachować limit jednej aktywnej sesji na dokument, uprawnienia, wygasanie i natychmiastowe odwołanie dostępu.
- Po zakończeniu share wszystkie zatwierdzone zmiany pozostają w oryginalnym dokumencie.
- Zaimplementować tworzenie linku Share v2 z UI hosta, bezpieczny bilet gościa, wygaśnięcie/revoke i osobny magazyn gościa, a nie tylko testowe bilety tworzone w bazie.
- Podglądy aktywnych gestów traktować jako nietrwały kanał prezentacji; nie mogą modyfikować potwierdzonej projekcji ani outboxu.

Kryterium: dwie osoby mogą równocześnie pisać, usuwać i przesuwać obiekty bez migania, resetowania widoku lub znikania poprawnych, niezależnych zmian.

## Etap 7. Całkowita separacja kont i trybu Local

### Docelowy układ

Magazyny NaNotateczki

`local/` — niezależny tryb lokalny

`accounts/<hash-A>/` — konto A

`accounts/<hash-B>/` — konto B

`shares/<session-id>/` — gość

Każda przestrzeń ma własną bazę, assety, outbox i checkpointy. Web używa analogicznie oddzielnych baz IndexedDB.

### Zadania

- Wprowadzić `StorageNamespaceManager`.
- Osobna baza danych i pliki dla każdego konta.
- Osobna baza dla Local.
- Izolować kolory, ustawienia, kalendarz, zadania, sesje, assety i kolejki.
- Przechowywać tokeny osobno od danych dokumentów.
- Przy zmianie konta zatrzymać poprzednie usługi i odłączyć poprzednią bazę.
- Odrzucać spóźnione odpowiedzi sieciowe po zmianie konta.
- Otwierać wyłącznie magazyn aktualnie zalogowanego użytkownika.
- Nie usuwać danych konta A przy logowaniu na B.
- Przechowywać dane Local bez zmian przy korzystaniu z kont.
- Zaprojektować jawny import Local → konto. W czystej instalacji nadal zaoferować wybór `Add local data to this account` / `Keep local data separate` tylko gdy rzeczywiście występują dane Local.
- Import kopiujący, nie przenoszący dane Local.
- Duplikaty nazw rozwiązywać sufiksami `(1)`, `(2)`.
- Import kalendarza i Study Sessions ma być addytywny i idempotentny.
- Ustawienia konta mają zawsze pierwszeństwo.
- Zabezpieczyć import przed przerwaniem w połowie.
- Zapobiec globalnemu cache między kontami: przy zmianie przestrzeni unieważnić generacje asynchronicznych odpowiedzi, kontrolery, notifiery, background writery i zasoby Web IndexedDB.

Kryterium: można wielokrotnie przełączać Local → A → B → A → Local, a każda przestrzeń zachowuje dokładnie swoje dane.

## Etap 8. Migracja planera, folderów i ustawień na spójne reguły

- Zastąpić porównywanie `modifiedAt` z zegarów urządzeń przez rewizje i operacje.
- Zachować identyfikatory wydarzeń i sesji.
- Wprowadzić operacje dodawania, edycji i usuwania wpisów.
- Zachować cykliczność, historię Study Sessions i stan timera.
- Zabezpieczyć skasowane wydarzenia przed odtworzeniem.
- Foldery i zadania synchronizować na poziomie obiektów, a nie całego `library_folders.json`.
- Zmiana nazwy lub przeniesienie folderu aktualizuje powiązania, nie tworzy kopii dokumentu.
- Zapobiec cyklom w strukturze folderów przy równoczesnym przenoszeniu.
- Ustawienia konta uzgadniać przez rewizje/CAS.
- Import ze starego formatu zachować jako mechanizm migracyjny, nie równoległy system zapisu.

Kryterium: edycje i usunięcia kalendarza, folderów, zadań oraz ustawień synchronizują się zgodnie z tymi samymi podstawowymi zasadami co dokumenty.

## Etap 9. Nowy mechanizm backupu i odtwarzania

### Zadania

- Backup przestaje uczestniczyć w normalnym rozstrzyganiu konfliktów.
- Snapshot powstaje z jednego spójnego, zatwierdzonego stanu.
- Każdy snapshot zawiera `schemaVersion`, checkpoint operacji, checksumę i identyfikator konta.
- Niepotwierdzone lokalne operacje zostają zachowane niezależnie.
- Snapshoty są niezmienne po utworzeniu.
- Weryfikacja SHA-256 obejmuje dokumenty i assety.
- Starszy backup nie może nadpisać nowszego checkpointu.
- Przy odzyskiwaniu najpierw odtwarzać snapshot, potem późniejsze operacje.
- Odrzucać próbę wskrzeszenia UID z tombstone.
- Nie wykonywać automatycznego importu archiwalnego backupu przy każdym logowaniu.
- Wykrywać rzeczywistą utratę lokalnej bazy, zamiast traktować pustą bibliotekę jako błąd.
- Zachować regulowane 15/30/60 sekund i pozostałe okresy bezczynności.
- Domyślny okres: 30 sekund.
- Ograniczyć koszt serializacji, unikając przetwarzania niezmienionych assetów.
- Przetestować backup w trakcie intensywnego rysowania i usuwania.
- Snapshot/restore w v2 musi sprawdzić assety, checkpoint, tombstones i odtworzyć późniejszy dziennik; dopiero potem można odblokować normalny writer. Nigdy nie przestawiać checkpointu do tyłu przy odzyskiwaniu na istniejącym magazynie.

### Kopie awaryjne `(1)`

Numerowane kopie nie mogą powstawać przy każdym konflikcie synchronizacji.

Dopuszczamy je wyłącznie wtedy, gdy istnieje rzeczywiste ryzyko utraty niepotwierdzonych danych, którego nie da się rozwiązać przez dziennik operacji — np. uszkodzona baza, nieodtwarzalna migracja albo niemożliwy do scalenia szkic.

Przy zwykłych równoległych dopiskach i usunięciach nie tworzymy dodatkowych plików.

## Etap 10. Poprawne wylogowanie, zamknięcie i zmiana konta

### Zadania

- Jeden wspólny `ShutdownCoordinator`.
- Najpierw zakończyć aktywny gest i lokalny zapis.
- Trwale opróżnić lokalne kolejki do SQLite.
- Następnie spróbować synchronizacji z serwerem.
- Wykonać końcowy zweryfikowany backup, jeśli jest potrzebny.
- Wyświetlać jedno czytelne okno procesu, nie kolejne nakładające się spinnery.
- Wprowadzić skończony timeout całego procesu, np. 30 sekund.
- Po timeout pokazać wybór: ponów, anuluj wylogowanie lub wyloguj z zachowaniem lokalnej kolejki.
- Nigdy nie usuwać niewysłanych operacji tylko z powodu wylogowania.
- Po zalogowaniu na to samo konto wznowić dokładnie tę samą kolejkę.
- Po zalogowaniu na inne konto poprzednia kolejka pozostaje w jego magazynie.
- Nie blokować normalnego zamknięcia przez niekończący się upload.
- Dodać diagnostykę, która dokładnie wskazuje etap zatrzymania procesu.

Kryterium: po zamknięciu lub wylogowaniu dane są bezpieczne lokalnie, proces ma ograniczony czas, a nieudana synchronizacja może zostać wznowiona bez duplikatów.

## Etap 11. Bezpieczna migracja dotychczasowych danych

Migracja powinna być oddzielnym, kontrolowanym procesem. **Wariant pustych danych testowych:** pomiń historyczne importy, ale potwierdź brak UID v1, kolejki offline i lokalnych profili *na każdym urządzeniu*; następnie załóż świeży stan v2. Dla niepustych kont zachowaj pełną procedurę poniżej.

1. Utworzyć zweryfikowany backup całej istniejącej bazy, WAL i assetów.
2. Zdefiniować wersję starego i nowego schematu.
3. Wprowadzić migrację lokalnego magazynu kont/Local.
4. Zamienić istniejące dokumenty na stan początkowy nowego modelu.
5. Zbudować początkowe checkpointy operacji.
6. Przenieść istniejące tombstones i zapamiętane operacje offline.
7. Zweryfikować liczbę dokumentów, stron, obiektów, assetów i ich checksumy.
8. Wykryć osierocone referencje i niespójne rekordy.
9. Zachować stary magazyn tylko do odczytu do zakończenia migracji.
10. Migracja musi być idempotentna i wznawialna.
11. W razie błędu nie przełączać użytkownika na niekompletny magazyn.
12. Przetestować migrację z różnych historycznych wersji danych.
13. Nie dopuszczać jednoczesnego zapisu starego klienta snapshotowego i nowego klienta operacyjnego do tego samego dokumentu.

Kryterium: migracja zakończona poprawnie albo całkowicie wycofana; bez stanu częściowego.

## Etap 12. Kompletny system testów

Ważne: nie wystarczą testy z atrapami serwera. Trzeba uruchomić prawdziwe Flutter + FastAPI + PostgreSQL + WebSocket.

### A. Testy zapisu

- 1000 kolejnych dopisków.
- 1000 usunięć.
- Dopisek po usunięciu innego obiektu.
- Undo/Redo po synchronizacji.
- Zapis podczas backupu.
- Zapis podczas importowania operacji.
- Restart w trakcie transakcji.
- Uszkodzona odpowiedź API i retry.
- Przepełniony magazyn i nieudany zapis assetu.

### B. Testy współdzielenia

- Dwa urządzenia rysują jednocześnie.
- Dwie osoby zmieniają ten sam tekst.
- Jedna usuwa, druga przesuwa.
- Jedna usuwa stronę, druga dopisuje na niej.
- Szybkie rysowanie z opóźnieniami sieci.
- Pakiety dostarczone w zmienionej kolejności.
- Duplikaty pakietów.
- Zerwane WebSocket.
- Restart hosta i gościa.
- Wygaśnięcie sesji podczas pisania.
- Brak migania niezmienionych i lokalnie oczekujących obiektów.
- Niezależny zoom, pan i aktywna strona.

### C. Testy wielokontowe

- Local → konto A → konto B.
- Powrót do A.
- Powrót do Local.
- Import Local dwukrotnie bez duplikatów.
- Równoległe otwarcie tego samego konta na dwóch urządzeniach.
- Zmiana konta podczas nieukończonego HTTP.
- Brak przecieków danych, tokenów i kolejki między kontami.

### D. Testy awaryjne

- Odłączenie internetu w trakcie zapisu.
- Restart serwera podczas transakcji.
- Zabicie aplikacji podczas backupu.
- Odtworzenie starego backupu po usunięciu dokumentu.
- Zegar urządzenia przesunięty o 24 godziny.
- Brak miejsca na dysku.
- Brak odpowiedzi na logout.
- Restart w połowie migracji.

### E. Testy platformowe

Linux, Windows, macOS, Android, iOS i Web — w zakresie dostępnych środowisk. Dodatkowo testy krzyżowe Linux ↔ Web, Android ↔ Web oraz iOS ↔ Web.

### Warunki zaliczenia

Do testów dodać przypadki: 257+ niezależnych zależności, commit serwera w odwrotnej kolejności przydzielonych sekwencji, formatowany tekst Quill, brakujący asset, pusta i niepusta migracja oraz wygaśnięcie Share podczas niezakończonego gestu. Wynik testów pomocniczych bez prawdziwego stosu nie wystarcza do G3.


- Zero utraconych zatwierdzonych operacji.
- Zero ponownego wykonania identycznej operacji.
- Zero nieautoryzowanego odtworzenia usuniętego UID.
- Zero przypadków, w których starsza odpowiedź podmienia nowszy lokalny stan.
- Identyczny wynik końcowy na wszystkich klientach po zakończeniu synchronizacji.
- Brak widocznego migania lokalnych operacji w testach E2E.
- Płynność przy typowych dokumentach i kontrolowana degradacja przy dużych.
- Brak nierozwiązanego błędu kompilacji lub testu regresyjnego.

## Etap 13. Wdrożenie produkcyjne na serwer

### Kolejność

1. Utworzyć pełny backup PostgreSQL i katalogów assetów.
2. Przetestować odtworzenie backupu na odrębnej instancji.
3. Wdrożyć nowy schemat SQL, pozostawiając stary kod operacyjny.
4. Wdrożyć nowe endpointy API v2.
5. Sprawdzić zgodność ze starszymi klientami i mechanizm wymuszonej aktualizacji.
6. Uruchomić nowy mechanizm w środowisku testowym.
7. Przetestować dwa prawdziwe urządzenia.
8. Włączyć nowy protokół tylko dla konta testowego.
9. Zweryfikować migrację oraz synchronizację podczas restartów.
10. Przełączyć pozostałe konta po spełnieniu kryteriów.
11. Zablokować stare endpointy zapisu snapshotów dla zmigrowanych kont.
12. Monitorować błędy, opóźnienia, nierozwiązane operacje i niespójności checkpointów.
13. Zachować możliwość powrotu do kompatybilnej wersji kodu bez cofania migracji SQL i bez odrzucania nowych operacji.

### Przykładowe polecenia wdrożeniowe

Dopiero po implementacji i po weryfikacji konkretnej migracji, na serwerze:

```
cd /srv/nanotateczki
git pull --ff-only origin main
scripts/apply-migrations.sh
docker compose up -d --build api caddy
docker compose ps
```

Przed tymi poleceniami obowiązkowy backup bazy i assetów. Konkretna procedura będzie dopasowana do faktycznej struktury instalacji — teraz nie trzeba wykonywać tych komend.

## Etap 14. Usunięcie nieaktualnego kodu i finalizacja

- Usunąć stare mechanizmy synchronizacji pełnych snapshotów po potwierdzeniu migracji.
- Usunąć nieużywane timery, debouncery, ścieżki `restoreDeleted` i obejścia konfliktów.
- Usunąć zbędne ponowne importowanie całych dokumentów po serwerowych ACK.
- Zlikwidować zdublowane implementacje backendu.
- Zachować adaptery potrzebne do importu starych danych.
- Nie usuwać nieznanych plików bez ustalenia ich zastosowania.
- Uporządkować `data.md` i `PROJECT_MAP.md`.
- Zaktualizować dokumentację wdrożeniową serwera i testów.
- Zweryfikować stan końcowy obu repozytoriów i wszystkie testy lokalne. Oznaczyć wymagane testy środowiskowe jako **niezweryfikowane**, dopóki nie zostaną rzeczywiście wykonane.
- Utworzyć oddzielne commity dla ukończonych etapów na właściwych gałęziach.

## Ostateczna kolejność wykonania i definicja „gotowe”

1. Zweryfikować 0–4, bez przebudowy sprawnych modułów; w etapie 2 domknąć limit 256, a w etapie 4 kolejność commita/kursora.
2. Domknąć pełną integrację 5–6 (w tym Quill, PDF/assety, wszystkie akcje edytora, host/guest Share).
3. Domknąć 7–10 i reguły planera, folderów, backupu oraz shutdownu na jednym protokole.
4. Dla potwierdzonych *pustych* danych uruchomić bezpieczny bootstrap v2; dla niepustych wykonać pełny etap 11. Nie ma automatycznej zgody na usunięcie danych niezweryfikowanych urządzeń.
5. Wykonać etap 12 w rzeczywistym środowisku oraz zapisać wyniki i wersje kodu. Przed G3 nie włączać canary na produkcji.
6. Etap 13: backup i odtworzenie poza produkcją → pojedynczy canary → monitoring → stopniowy rollout → wyłącznie nowe konta v2 po zakończeniu przełączenia.
7. Etap 14 wyłącznie po G6, gdy nie ma już aktywnych writerów i zalegających kolejek v1.

**Przekazanie etapu:** osobny commit, wskazanie hashy `NaNotateczki/dev` i `NaNotateczki-serwer/main`, zmienione pliki, lokalne testy PASS/FAIL/SKIP z powodem, status bramek i komendy na serwerze tylko gdy są rzeczywiście potrzebne. Nie uruchamiać GitHub Actions bez wyraźnego polecenia.

## Zależności między etapami

Migrację produkcyjną i finalne porządki wykonujemy dopiero po zakończeniu testów, nie równolegle z projektowaniem protokołu.

## Zasady obowiązujące podczas całej przebudowy

1. Nie dodawać kolejnych obejść do starych mechanizmów, jeśli problem usuwa nowy model operacji.
2. Każda naprawa ma własny test regresyjny.
3. Każdy ukończony etap ma własny commit i udokumentowany wynik weryfikacji.
4. Żaden snapshot ani stary klient nie może przywrócić usuniętego obiektu.
5. Backend ma jedno źródło kodu i zgodny kontrakt z aplikacją.
6. Nie przełączać na nowy system częściowo zmigrowanego konta.
7. Nie robić GitHub Actions bez wyraźnej prośby; podczas prac wykonywać dostępne testy lokalne.
8. Nie uznawać zielonego CI za dowód płynnej współpracy — wymagane są rzeczywiste testy E2E.

Najważniejsza decyzja techniczna: zachowujemy Flutter, Drift i PostgreSQL, ale zmieniamy jednostkę zapisu i synchronizacji z całego dokumentu na trwałą, identyfikowalną operację. Dzięki temu backup, synchronizacja konta i share przestaną konkurować o prawo do nadpisania tego samego stanu.