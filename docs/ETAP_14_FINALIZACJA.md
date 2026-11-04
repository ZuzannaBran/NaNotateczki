# Etap 14 — porządki po migracji

Status 2026-11-04: **częściowo wykonany, pełne usunięcie v1 ZABLOKOWANE**.
Nie jest to potwierdzenie produkcyjnej migracji.

## Powód blokady

- docs/ETAP_11_MIGRATION.md: dane są staged-not-activated;
  AppScope i Web nadal korzystają z legacy storage.
- docs/ETAP_12_TESTS.md: pełne E2E, gesty Share i testy platformowe
  wciąż wymagają rzeczywistego wykonania.
- Kanoniczny backend NaNotateczki-serwer/main i jego
  docs/STAGE13_PRODUCTION_ROLLOUT_PL.md: marker konta v2 nie migruje danych,
  aktywacja etapu 13 obsługuje tylko nowe PUSTE konto testowe.
- LiveWebSyncService i StudyShareGuestEditor nadal zapisują snapshoty
  i rewizje v1. SyncEngine v2 i ShareOperationProjection są opt-in.
  Legacy nie jest więc martwym kodem.

## Dodatkowa decyzja: dane testowe można usunąć

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
