# Etap 9 — backup i odtwarzanie

## Wdrożone zabezpieczenia

- Normalne logowanie i otwarcie zapamiętanego konta uruchamia live sync,
  nie importuje za każdym razem najnowszego archiwalnego backupu.
- Klient wykrywa uszkodzenie/quarantine bazy oraz utratę wcześniej
  zainicjalizowanej bazy (trwały marker per konto). Pierwsze uruchomienie
  i celowo pusta biblioteka nie oznaczają utraty danych.
- Backup czeka na opróżnienie lokalnych zapisów. Odczyt dokumentów i
  checkpointów odbywa się w jednej transakcji SQLite. Przy zmianie
  planera/ustawień podczas capture snapshot nie zostaje wysłany.
- Niepotwierdzony outbox operacji blokuje tworzenie snapshotu z
  zatwierdzonym checkpointem; kolejka pozostaje trwała i oczekuje na ACK.
- Envelope v2 zawiera `accountId`, `schemaVersion` SQLite,
  `operationCheckpoint`, checksum SHA-256 obejmującą serializowany
  payload wraz z osadzonymi bajtami obrazów oraz SHA-256 całego pliku.
  Backend odrzuca cudze konto lub wadliwy checkpoint. Starsze v2 są
  czytelne ze względu na bezpieczeństwo istniejących kopii.
- Serwerowy verified backup jest niezmienny; recovery waliduje
  rozmiar, SHA-256 całego pliku i oryginalnego payloadu.
  Obecne tombstones oraz lokalne usunięcia mają pierwszeństwo.
- Zachowano 15/30/60/120/300/900/1800 sekund; 30 sekund domyślnie.

## Niezakończone zależności

- Etapy 5–6: infrastruktura v2 istnieje, ale produkcyjny edytor i Share
  nadal korzystają także z protokołu snapshotowego v1. Przełączenie
  przed migracją etapu 11 naruszyłoby ochronę przed dwoma writerami.
- Etapy 7–8: namespace i rewizje planera są gotowe opt-in, ale aktywna
  separacja baz, import Local, foldery/zadania i produkcyjny planner v2
  zależą od bezstratnej migracji identyfikatorów i danych w etapie 11.
- Właściwe odtworzenie snapshotu operacyjnego v2 i późniejszych
  operacji (bez historii snapshotowej v1) wymaga pełnego cutover z etapu 11.
  Dziś recovery awaryjne jest wykonywane przed istniejącym live sync.
- Snapshot serwerowy nadal przechowuje pełne bajty obrazów. Dzielenie
  assetów na content-addressed obiekty i ponowne używanie ich między
  kolejnymi snapshotami to przyszła zmiana formatu/protokołu serwera.
- Pełny mechanizm kopii awaryjnych `(1)` tylko dla nieodtwarzalnych
  szkiców zależy od przełączenia edytora na dziennik operacji.
- Zewnętrzne pliki planera i preferencji nie mają jednej transakcji
  SQLite; klient wykrywa zmianę podczas capture i odmawia backupu,
  ale pełną atomowość zapewni dopiero przeniesienie ich do jednego magazynu.

## Scenariusze do weryfikacji

Testy regresyjne źródłowe (nieuruchomione w bieżącym środowisku bez SDK):
`test/remote_backup_service_test.dart` oraz
`api/tests/test_backup_validation.py`.

Po migracji etapu 11 i w etapie 12 wykonać lokalnie i na odrębnym
środowisku FastAPI/PostgreSQL:

1. 1000 równoległych dopisków/usunięć podczas upływu timera backupu.
2. Zerwanie HTTP i restart w chwili zapisu pending/content/finalize.
3. Offline outbox z edycjami i usunięciami: backup odroczony, po ACK
   snapshot verified, kolejka bez utraty i podwójnej aplikacji.
4. Nowa instalacja vs brak pliku SQLite/utracony IndexedDB po wcześniejszym
   logowaniu; uszkodzona baza z quarantine; celowo pusta biblioteka.
5. Starszy backup po nowszym tombstone i checkpoint, odtworzenie snapshotu
   i replay wszystkich późniejszych operacji.
6. Zmiana konta podczas capture/upload oraz bardzo duży asset.
7. 15/30/60 sekund idle, aktywny rysik, zmiana danych podczas uploadu.

Nie uruchamiać GitHub Actions bez wyraźnej prośby użytkownika.
Nie włączać protokołu v2 bez migracji etapów 11–13.
