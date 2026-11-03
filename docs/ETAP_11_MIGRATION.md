# Etap 11 — bezpieczna migracja dotychczasowych danych

Status: **przygotowanie danych natywnych wdrożone; produkcyjne przełączenie
NIE jest wykonane**. Nie uruchamiać obu protokołów zapisujących do jednego UID.

## Zweryfikowany proces przygotowawczy na Linux / native

Skrypt tool/stage11_migrate.py działa **offline**. Zamknąć wszystkie
instancje NaNotateczki przed jego uruchomieniem. Narzędzie NIE ingeruje w
serwer i NIE zmienia aktywnej ścieżki SQLite aplikacji.

- Weryfikuje account_profile.json (boundUserId): dane przypisane do
  konta mogą trafić wyłącznie do accounts/<sha256(userId)[:40]>, a
  nieprzypisane wyłącznie do local/. Import Local → konto jest osobnym
  procesem po wyraźnej decyzji użytkownika.
- Sprawdza SQLite quick_check, foreign_key_check, user_version 1–5
  i liczby notatników, stron, elementów, outboxu i tombstones.
- Kopiuje istniejące SQLite, WAL/SHM/journal, ustawienia i dane planera,
  identyfikator urządzenia, checkpoint sync (tylko dla właściwego konta),
  assety, backupy lokalne, archiwa usunięć i incydenty. Wszystkie bajty
  wejściowe są sumowane SHA-256 i weryfikowane po kopiowaniu.
- Aktualizuje ścieżki obrazów w **kopii** SQLite; odmawia migrowania
  osieroconego assetu bez inline bytes lub ścieżki poza images/.
- Kontroluje niezmienność źródła, porównuje liczbę rekordów po zmianie
  ścieżek, publikuje kompletny katalog przez rename. Przy błędzie
  usuwa wyłącznie własny katalog tymczasowy, źródło pozostaje nietknięte.
- Ponowne uruchomienie weryfikuje manifest i wszystkie SHA-256.
  Nie nadpisuje istniejącego, niezweryfikowanego katalogu docelowego.
- Kopia jest oznaczona **staged-not-activated**: nie wolno jej uznać za
  zakończoną migrację protokołu, ani skasować starej biblioteki.

Przykład na komputerze z zamkniętą aplikacją, nie na serwerze:

    python3 tool/stage11_migrate.py \
      --data "$HOME/.local/share/com.example.program/data"

Można dodatkowo wymagać dokładnego przypisanego konta przez
--account-id UUID. Nie stosować tej opcji do nieskojarzonych danych Local.

Regresje: python3 -m unittest discover -s tool -p 'test_stage11_migrate.py'.
Osiem scenariuszy uruchomiono lokalnie z CPython 3: poprawne kopiowanie,
izolacja właściciela, brak assetu, restart, odmowa obcego katalogu,
zmodyfikowane dane oraz symlink w assetach lub celu. Nie uruchomiono Flutter/Dart,
PostgreSQL ani GitHub Actions. Testy używają uproszczonych schematów
SQLite; historyczne zrzuty rzeczywistych instalacji wciąż są konieczne.

## Otwarte blokady (nie wolno ich ukrywać)

1. **Aktywacja namespace (etap 7/11):** AppScope wciąż otwiera
   notes.sqlite, a inne pliki mają globalne klucze; wymagane jest
   atomowe przełączanie kontrolerów/providerów, Web IndexedDB, ustawień
   i tokenów bez mieszania kont. Dopiero potem można odblokować login B.
2. **Przejście Local → account:** jawna decyzja i idempotentne UID mapping
   dokumentów, stron, planera i folderów (wraz z assetami), bez
   nadpisywania preferencji konta.
3. **Zamiana v1 → v2:** każdy serwerowy dokument i SQLite potrzebują
   snapshotu początkowego v2, punktu startowego dziennika i potwierdzenia
   checkpointu. Wymagane przeniesienie tombstones, outbox i poprawnych
   CRDT tekstu. Nie wolno po prostu skopiować JSON v1 do document_states.
4. **Serwer:** transakcyjne zamknięcie zapisów v1 per UID, migracja,
   trwały marker trybu, bezpieczny retry i blokada starych klientów.
   Dotychczasowy serwer chroni przed dwoma writerami, ale nie oferuje
   jeszcze ukończonego endpointu cutover.
5. **Rekordy historyczne:** testy na SQLite v1–v5, brak WAL,
   obecny WAL, uszkodzone strony, brak miejsca, wymuszony restart,
   prawdziwe dokumenty z PDF i Quill.
6. **Etapy 5/6/8/9/10:** włączenie produkcyjnego SyncEngine i Share,
   folderów/zadań i planera v2, odtwarzanie snapshot+replay, poprawne
   wyjście z zachowaniem outboxu wymagają migracji i testów E2E.
7. **Etapy 12–13:** test środowiska PostgreSQL/WebSocket, dwóch urządzeń,
   backup produkcyjnej bazy przed migracjami, wdrożenie canary.
   Dopiero po nim usuwać legacy (etap 14).

## Serwer

Na tym etapie **nie wykonywać poleceń na serwerze**: nowej migracji SQL ani
przełączenia API nie wdrożono. Polecenia z etapu 13 są warunkowe i wymagają
najpierw zweryfikowanego pełnego backupu PostgreSQL i assetów.

Dotychczasowa aplikacja nadal używa legacy storage i sync; ten etap
zmniejsza ryzyko przygotowania kopii, ale nie zamyka migracji v2.
