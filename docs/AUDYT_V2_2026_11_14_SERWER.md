# Audyt ukończenia v2 — 14 listopada 2026

Trwały punkt wznowienia: [issue #2](https://github.com/ZuzannaBran/NaNotateczki/issues/2).
Ten raport zastępuje wcześniejsze oceny stanu bieżącego z 9 i 13 listopada.
Historia w starszych dokumentach nie jest listą aktualnych blokad.

## Wynik

Przebudowa nie jest jeszcze w pełni zakończona. API działa już wyłącznie
na v2, natomiast publiczny klient wymaga aktualizacji, a długoterminowa
kompaktacja historii i pełna akceptacja fizycznych urządzeń pozostają otwarte.
Nie ma potrzeby ponownego resetowania danych ani budowania drugiego silnika.

## Potwierdzone wdrożenie serwera

- Działający runtime ma włączony zapis v2, migracje do 0017 włącznie,
  zero tras /v1 i brak czterech tabel snapshotowego protokołu v1.
- Odczytowy audyt nie znalazł kont/dokumentów legacy, aktywnych Share v1,
  podwójnych protokołów ani błędnych checkpointów aktorów.
- Baza początkowo była pusta. Użytkowniczka później założyła konto i dodała
  dane testowe: odczyt wykazał 1 konto, 11 operacji, 2 projekcje i 2 aktorów.
  Nie wykonywano resetu ani migracji danych; nowe dane pozostają nienaruszone.
- Kod wdrożonego API został opublikowany na kanonicznym main:
  [8440fc4e](https://github.com/ZuzannaBran/NaNotateczki-serwer/commit/8440fc4e03b7e67987fb35e8a73cb111f29a1f8a).
  Porównanie drzewa Git potwierdza identyczność z wdrożonym źródłem.
- Publiczny endpoint /ready odpowiada poprawnie. To potwierdza backend,
  a nie poprawność wersji aplikacji WWW.
- Rejestracja jest włączona; preflight CORS dla originu publicznej aplikacji zwraca
  poprawne 200 i Access-Control-Allow-Origin. Zgłoszenie „Failed to fetch”
  ma potwierdzoną dodatkową przyczynę: localhost otrzymuje odmowę CORS.
  Poprawkę HTTP i WebSocketów śledzi issue #7. Wdrożono ją: publiczny
  preflight localhost zwraca 200, niepoprawny formularz logowania 422
  z prawidłowym Access-Control-Allow-Origin. Dane konta są zachowane.

## Kod klienta

Odzyskano niezapisane w GitHubie zmiany poprzedniej sesji i połączono je
z aktualnym dev, zachowując najnowszą poprawkę natywnego SQLite oraz
warunkowego importu testu Web (6c55b7c9). Oryginalne drzewo robocze zachowano.

- Auth, raporty i zegar używają /v2. Usunięto importery snapshotowego v1.
- Rebase usunięcia strony odtwarza projekcję według zatwierdzonych receiptów,
  potem lokalnych operacji. Nie zmienia operationId, actorSeq ani outboxu.
- Usunięcie ostatniej strony tworzy identyczny, deterministyczny pusty UID
  w Pythonie i SQLite. Wspólny korpus obejmuje także usunięcie wszystkich stron.
- Konto i Share używają wspólnej polityki usunięć i jawnego odzyskiwania.
- Planner jest podłączony przez CAS/revisions; foldery i zadania przez operacje
  v2; ustawienia przez wersjonowany serwis konta. Nie są wyłączone jak w audycie
  z 9 listopada.
- Import Local jest jawny i idempotentny; namespace jest odseparowany.
- Backup format 3, replay, wznowienie recovery i wspólne zamykanie są obecne.

## Niezamknięte wymagania

1. [Issue #5](https://github.com/ZuzannaBran/NaNotateczki/issues/5): publiczny
   main.dart.js nadal zawiera wywołania /v1/auth/login, register, refresh,
   logout i change-password. Trzeba opublikować cały zgodny pakiet klienta
   oraz potwierdzić logowanie, edycję, Share i backup. CI przygotowuje artefakt
   nanotateczki-cloudflare-upload; samo uruchomienie CI go nie wdraża.
   Lokalnie powstał też kompletny release Web 0708e497e6452e81 (31,5 MiB ZIP),
   lecz nie obejmuje późniejszych równoległych zmian typografii. Do publikacji
   docelowej użyć artefaktu nowego CI. Brak połączenia do Cloudflare w tej sesji.
2. [Issue #4](https://github.com/ZuzannaBran/NaNotateczki/issues/4): limity
   50 tys. wpisów historii projekcji i 100 tys. operacji backupu nie mają
   działającej kompaktacji/checkpointów bazowych. Jawne zatrzymanie chroni
   dane, ale nie spełnia wymagań nieprzerwanej długoterminowej pracy.
3. Pełna akceptacja dwóch fizycznych urządzeń: gesty hosta/gościa, Quill,
   PDF/obrazy, offline/reconnect/restart, revoke i viewport. Automatyczne
   procesy/symulatory są dowodem częściowym, nie zastępują tych prób.
4. Pełna akceptacja złożonych łańcuchów ruchów A→B→C oraz równoczesnego
   usunięcia A/B, także z mediami i różnymi pozycjami ACK. Rebase jest
   zaimplementowany; dotychczasowe regresje nie są dowodem wszystkich
   wariantów dwóch rzeczywistych procesów.
5. [Issue #3](https://github.com/ZuzannaBran/NaNotateczki/issues/3): nowy
   przebieg CI ma potwierdzić poprawkę kompilacji testu Web. Poprzedni
   przebieg 43526945751 miał 16/17 PASS; Web był jedynym błędem.

## Weryfikacja tej sesji

- Backend przed CORS: 378 PASS, 18 SKIP bez bazy; skrypty: 46 PASS.
  Po zmianie Origin: 394 PASS, 18 SKIP; 60 regresji CORS/auth/Share PASS.
- Odizolowany PostgreSQL: 17 PASS; osobny test 1000+1000 operacji pominięty
  w tym krótkim przebiegu. Sprawdzono kolejność commitów konkurujących
  transakcji, frontier ponad 256 zależności, atomowe ACK oraz migrację 0017
  odmawiającą usunięcia historycznych danych i jej rollback.
- Regresje Flutter synchronizacji, reducerów, startupu, bibliotek i ACK:
  190 PASS. Po dołączeniu najnowszych zmian dev: 115 regresji PASS.
  Dodatkowo funkcje konta/backup/import/planner/Share/namespace/
  shutdown: 70 PASS.
- Dart analyze: No issues found. Kontrola lustra backendu: zgodne.
- Kompilacja testu cyklu życia dla Web po wydzieleniu importów natywnych:
  PASS. Pierwszą ciężką kompilację z równoległym audytem WASM przerwano,
  aby ograniczyć obciążenie serwera; nie jest liczona jako zaliczona.
- Lokalny test pakowania nie był zaliczony w tej sesji: brak cmake.
  Poprzednia macierz dev zaliczyła pakowanie i wszystkie platformy natywne.
- Pierwszy dodatkowy zestaw testów miał 58 PASS i dwa błędy uruchomienia:
  omyłkowo wskazany nieistniejący plik planera oraz brak cmake. Poprawiony
  zestaw funkcjonalny ma 70 PASS. Nie zaliczamy pierwszego przebiegu jako PASS.

## Kontynuacja

Najpierw sprawdzić najnowszy komentarz issue #2 i przebieg CI przypisany
konkretnemu commitowi. Potem opublikować zgodnego klienta (#5), domknąć
checkpointy/kompaktację (#4) i wykonać pozostałą akceptację. Nie wracać do
projektowania lokalnego SQLite, nie usuwać operacji dla odblokowania kursora,
nie resetować instalacji z powodu niezgodności wersji klienta i API.
