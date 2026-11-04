# Etap 14 — porządki po migracji

Status 2026-11-04: **częściowo wykonany, pełne usunięcie v1 ZABLOKOWANE**.
Nie jest to potwierdzenie produkcyjnej migracji.

## Powód blokady

- docs/ETAP_11_MIGRATION.md: czyste instalacje są odizolowane Local/konto,
  ale historyczne stagingi nie są aktywowane i nie mają bezstratnego importu.
- docs/ETAP_12_TESTS.md: pełne E2E, gesty Share i testy platformowe
  wciąż wymagają rzeczywistego wykonania.
- Kanoniczny backend NaNotateczki-serwer/main i jego
  docs/STAGE13_PRODUCTION_ROLLOUT_PL.md: marker konta v2 nie migruje danych,
  aktywacja etapu 13 obsługuje tylko nowe PUSTE konto testowe.
- LiveWebSyncService i StudyShareGuestEditor nadal zapisują snapshoty
  i rewizje v1. SyncEngine v2 i ShareOperationProjection są opt-in.
  Legacy nie jest więc martwym kodem.

## Potwierdzenie usunięcia danych lokalnych (2026-11-04)

Użytkownik potwierdził, że usunął również lokalne dane testowe.
Dla pustych magazynów nie jest wymagany import historycznych SQLite,
WAL, UID ani kolejki v1 do v2. Nie jest to równoznaczne z przełączeniem
aplikacji: rejestracja nowych kont i produkcyjny edytor nadal używają v1.
Nie należy uruchamiać skryptów migracji historycznych danych na pustych
magazynach ani automatycznie włączać v2 bez obsługi wszystkich akcji.
Aktualny reset serwera nie gwarantuje usunięcia stanu pozostawionego na
innych, niezweryfikowanych urządzeniach.

## Dodatkowe zabezpieczenie przy wylogowaniu (2026-11-04)

Przed żądaniem odwołania sesji konto zatrzymuje i opróżnia lokalne writery
przez onBeforeAccountChange; błąd flush nie unieważnia sesji i nie usuwa
jej tokenu. Dwa testy regresyjne kontrolują kolejność i przypadek błędu.
Brak Flutter SDK w środowisku — testów nie ogłoszono jako zaliczonych.

## Dodatkowa decyzja: dane testowe można usunąć

Pełny reset PostgreSQL oraz serwerowego `data/` został potwierdzony
w logu użytkownika (2026-11-04). `scripts/reset-all-test-data.sh`
ponownie nałożył migracje 0001–0013 i uruchomił API, DB oraz Caddy.
Reset nie wyczyścił automatycznie danych lokalnych urządzeń.

Dla wyczyszczonych instalacji w `NaNotateczki/dev` wdrożono izolowany
bootstrap `local/`, `accounts/<hash>/` i prefiksy Web IndexedDB/localStorage.
Zmiana konta zatrzymuje legacy writery, fluszuje i odtwarza provider tree.
Guest Share ma własny klucz outbox per link. Regresje dodano, nieuruchomione.
To **nie kończy przełączenia operacji v2**: Quill, assety/PDF oraz pełna
projekcja notebooka nadal nie mają produkcyjnego writera v2.


Zamiast pełnego replay danych v1 przygotowano na kanonicznym backendzie
skrypt `scripts/stage14-reset-test-account-v2.sh`, kasujący atomowo dane
wyłącznie wskazanego konta testowego po potwierdzeniu UUID, loginu,
wyłączeniu API i wykonaniu backupu. Zachowuje login i hasło, usuwa
serwerowe kolejki i dodaje marker v2. Odmawia resetu konta już na v2.
Dodatkowo wszystkie stare mutacje ustawień, planera, Share i backupu
zostały zablokowane dla kont v2 i odzwierciedlone w lustrze `server/`.
Testy: `scripts/tests/test_stage14_reset_test_account.py` oraz
`api/tests/test_stage14_reset_legacy_write_fences.py`.

Nie wykonano skryptu na produkcji; brak identyfikatora konta i dostępu
do terminala serwera. Reset eliminuje koszt konwersji starych notatek,
ale **nie** zastępuje integracji SyncEngine v2 z Flutterem,
assetami, formatowaniem Quill i Share. Przed nią konto po resecie
może służyć do testów API v2, nie do normalnej pracy w aplikacji.
Instrukcja administratora: kanoniczny serwer
`docs/STAGE14_TEST_RESET_PL.md`.

## Dodatkowa blokada niezgodnego klienta (2026-11-04)

Kanoniczne API wystawia uwierzytelnione `GET /v1/auth/protocol`.
`AppScope` odpytuje je przed recovery, `LiveWebSyncService.start`
i uruchomieniem schedulerów backupu v1. Wywołania synchronizacji
ustawień sprzed rozruchu również oczekują na pozytywną weryfikację. Odpowiedź `v2` zatrzymuje
rozruch starszego synchronizatora i pozostawia lokalne dane/outbox.
Jedynie HTTP 404 ze starszego backendu pozwala użyć kontraktu v1;
inne błędy blokują bootstrap bez utraty lokalnych danych. Serwerowe
transakcyjne bariery v1/v2 pozostają konieczne również po sondzie.
Regresje: `test/api_client_test.dart`,
`api/tests/test_account_protocol_fence.py` (kanoniczny serwer i lustro).
Brak Flutter SDK w tym środowisku — nie ogłoszono PASS aplikacji.
To zabezpieczenie **nie uruchamia** edycji v2 i nie zamyka etapów 11–13.

## Wykonane bezpieczne porządki

1. Naprawiono błędny delimiter SQL w kanonicznym
   scripts/stage13-status.sh i istniejącym lustrze aplikacji
   server/scripts/stage13-status.sh.
2. W kanonicznym backendzie dodano odczytowy
   scripts/stage14-retirement-audit.sh i test
   scripts/tests/test_stage14_retirement_audit.py.
   Sprawdzane są konta i dokumenty v1, aktywne Share legacy,
   podwójne UID oraz niepoprawne checkpointy.
3. Zachowano działające timery/debounce, kompatybilność historycznych
   backupów i istniejące testy. Nie usuwano nieznanych plików.
4. Uzupełniono dokumentację zależności i warunków końca migracji.

## Kontrola po wdrożeniu kanonicznego serwera

Tylko po zastosowaniu migracji 0013, na hostingu z poprawnym Compose:

    cd /srv/nanotateczki
    bash scripts/stage14-retirement-audit.sh

Skrypt korzysta z PostgreSQL REPEATABLE READ READ ONLY i nie zmienia danych.
Kod 75 to blokada: legacy lub niespójność. Błąd SQL, brak migracji lub
błędna odpowiedź także blokują. Kod 0 oznacza jedynie brak wykrytych
**serwerowych** przeszkód, a NIE zgodę na usunięcie v1.
Nowe konta nadal startują w v1; lokalne outboxy urządzeń są niewidoczne
w audycie serwera.

Test bez Dockera w checkoutcie serwera:

    python3 -m unittest discover -s scripts/tests -p 'test_stage14_retirement_audit.py'

Nie trzeba wykonywać teraz żadnych komend na produkcyjnym serwerze.

## Wynik lokalnej weryfikacji (2026-11-04)

Uruchomiono `python -m unittest discover -s scripts/tests -p
'test_stage14*.py' -q` na lokalnej kopii **dokładnie tych samych**
skryptów i testów (potwierdzono zgodność Git blob SHA z GitHub).
Wynik: **13/13 PASS**. `bash -n` skryptów także zaliczone.
Były to testy z atrapą Dockera/odpowiedzi bazy, nie wykonano
destrukcyjnego SQL na PostgreSQL i nie uruchomiono scenariuszy
API/Flutter E2E. Testy routerów API pozostają do uruchomienia
na kompletnym checkoutcie backendu z zależnościami. Nie wykonywano
ręcznie GitHub Actions.

## Kroki pozostałe do pełnego zamknięcia

1. Zamknąć etap 11: aktywacja namespaces Local/Account/Web, bezstratny
   cutover istniejących UID, assetów, CRDT, tombstones, checkpointów,
   offline outboxu i idempotentnego importu.
2. Zaliczyć etap 12: realny Flutter + PostgreSQL + WebSocket, dwa urządzenia,
   host/guest, E2E gestów bez migania, awarie, backup/restore, platformy.
3. Wykonać etap 13: zweryfikowany backup i odtworzenie, canary,
   migracja kolejnych kont, odcięcie starych klientów i onboarding
   wyłącznie v2. Monitorować kolejki także na urządzeniach.
4. Dopiero po sprawdzeniu braku writerów v1: usunąć snapshotowe ścieżki
   LiveWebSyncService, StudyShareGuestEditor, backendowy v1 sync i v1
   Share PUT. Zachować adaptery importu starszych danych.
5. Usunąć stare debounce, timery, importy snapshotów po ACK i obejścia
   konfliktów wyłącznie jeśli wszystkie ich call sites są już martwe.
   Nie usuwać retry/timeoutów ani zgodności restoreDeleted na ślepo.
6. Przełączyć testy backendu aplikacji na kanoniczny serwer, dopiero
   potem usunąć lustro server/; zachować wszystkie migracje SQL.
7. Na pełnym checkoutcie uruchomić dart format, dart analyze, flutter test,
   pytest, unittest i rzeczywiste E2E. Odnotować wyniki i commity.

W tym środowisku brak działającego Flutter SDK, Dockera i klona repo.
Dodanie regresji nie oznacza zaliczenia testów. GitHub Actions nie
zostały ręcznie uruchomione.
