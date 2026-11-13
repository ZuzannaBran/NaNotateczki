# Etap 11 — bezpieczna migracja dotychczasowych danych

Status: oddzielne magazyny Local/Account i protokół v2 są w kodzie.
Konto historyczne można przekonwertować na środowisku testowym po
opróżnieniu kolejek v1 wszystkich urządzeń. Produkcyjny rollout nie
jest częścią tej procedury testowej. Nie uruchamiać obu writerów na
tym samym UID.

## Zweryfikowany proces przygotowawczy na Linux / native

Skrypt tool/stage11_migrate.py działa **offline**. Zamknąć wszystkie
instancje NaNotateczki przed jego uruchomieniem. Narzędzie NIE ingeruje w
serwer i NIE zmienia aktywnej ścieżki SQLite aplikacji.

- Weryfikuje account_profile.json (boundUserId): dane przypisane do
  konta mogą trafić wyłącznie do accounts/<sha256(userId)[:40]>, a
  nieprzypisane wyłącznie do local/. Import Local → konto jest osobnym
  procesem po wyraźnej decyzji użytkownika.
- Sprawdza SQLite quick_check, foreign_key_check, user_version 1–8
  i liczby notatników, stron, elementów, outboxu i tombstones.
- Kopiuje istniejące SQLite, WAL/SHM/journal, ustawienia i dane planera,
  account_profile.json, storage_layout.json, identyfikator urządzenia,
  stan synchronizacji, kursor ustawień i preimport (tylko dla właściwego
  konta), assety, backupy lokalne, archiwa usunięć i incydenty. Oryginalne
  bajty SQLite i sidecarów są dodatkowo zachowane w legacy_sqlite/.
  Wszystkie pliki źródłowe mają SHA-256 sprawdzany po kopiowaniu.
- Aktualizuje ścieżki obrazów w **kopii** SQLite; odmawia migrowania
  osieroconego assetu bez inline bytes lub ścieżki poza images/.
- Kontroluje niezmienność źródła, porównuje liczbę rekordów po zmianie
  ścieżek, publikuje kompletny katalog przez rename. Przy błędzie
  usuwa wyłącznie własny katalog tymczasowy, źródło pozostaje nietknięte.
- Ponowne uruchomienie weryfikuje manifest, pełną listę plików docelowych
  i ich SHA-256 **oraz aktualnego źródła**; zmiana legacy po stagingu
  blokuje ponowne użycie nieaktualnej kopii. Weryfikacja obejmuje także
  account_profile.json i nowo utworzone pliki źródłowe.
  Nie nadpisuje istniejącego, niezweryfikowanego katalogu docelowego.
- Kopia jest oznaczona **staged-not-activated**: nie wolno jej uznać za
  zakończoną migrację protokołu, ani skasować starej biblioteki.

Przykład na komputerze z zamkniętą aplikacją, nie na serwerze:

    python3 tool/stage11_migrate.py \
      --data "$HOME/.local/share/com.example.program/data"

Można dodatkowo wymagać dokładnego przypisanego konta przez
--account-id UUID. Nie stosować tej opcji do nieskojarzonych danych Local.

Regresje: python3 -m unittest discover -s tool -p 'test_stage11_migrate.py'.
Dwadzieścia scenariuszy dodano; testy wymagają wykonania na checkoutcie: poprawne kopiowanie,
izolacja właściciela, brak assetu, restart, odmowa obcego katalogu,
zmodyfikowane dane oraz symlink w assetach lub celu. Nowe testy:
stale źródło, pliki `.previous`, ścieżka z `..`, zewnętrzny obraz,
prawidłowy staging konta, metadane konta, zmodyfikowany profil,
nowy plik źródłowy i nieoczekiwany plik w stagingu. Nie uruchomiono Flutter/Dart,
PostgreSQL ani GitHub Actions. Testy używają uproszczonych schematów
SQLite; historyczne zrzuty rzeczywistych instalacji wciąż są konieczne.

## Granice weryfikacji przed produkcją

- Przejść procedurę na kopii rzeczywistej bazy i na dwóch instalacjach
  z historią. Osobno zweryfikować stare schematy, brak miejsca, restart
  procesu i restore PostgreSQL oraz magazynu assetów.
- Nie przełączać konta, jeżeli jakiekolwiek urządzenie lub gość ma
  niezapisane dane albo nie można potwierdzić jego stanu.
- Nie modyfikować katalogu stagingu w miejscu i nie usuwać danych v1.

## Serwer

Staging plików nie wymaga żadnych poleceń na serwerze. Test konwersji
serwerowej opisano niżej. Uruchomienie produkcyjne należy do osobnej
procedury etapu 13 i wymaga wcześniej zweryfikowanej kopii PostgreSQL
oraz assetów.

## Zasady zgodności po korekcie

Wcześniejszy katalog stagingu ze starszym manifestem może zostać
odrzucony po rozszerzeniu listy zabezpieczanych plików lub kontroli
liczników. **Nie usuwać go automatycznie**. Należy zachować kopię i
po ręcznej weryfikacji przenieść nieaktualny katalog w bezpieczne
miejsce poza przestrzenią aktywnych danych, a następnie powtórzyć
staging przy wyłączonej aplikacji. Samo przygotowanie kopii nie
włącza żadnego writer'a v2 i nie wymaga komend na serwerze.

## Uzupełnienie po etapie 12

SQLite v6 rozszerza trwałe lokalne tombstones o `task`. Narzędzie
`stage11_migrate.py` rozpoznaje `user_version=6`, kopiuje i zachowuje
źródłowe bajty oraz działa nadal wyłącznie w trybie `staged-not-activated`.
Test regresyjny sprawdza staging bazy v6 bez zmiany źródła.

## Pakiet 8 — kontrola aktywacji konta v2

Klient najpierw potwierdza protokół konta, a przed uruchomieniem
writera wywołuje `GET /v2/activation/readiness`. Serwer kontroluje
trwały marker v2 i allowlistę kont. Jeżeli istnieją dane v1,
wymagany jest dodatkowo administracyjny receipt konwersji. Brak endpointu
albo przerwanie HTTP pozostawia edytor zablokowany.

Na urządzeniu nawet obecność `document.set` nie oznacza wykonanej
migracji: każdy istniejący notebook musi mieć `document.create`
w dzienniku v2. Niewysłany outbox v1 blokuje aktywację nawet wtedy,
gdy lokalny notebook został już usunięty. Aktywacja pustego konta
testowego odrzuca błąd
sprawdzenia procesu API, nieznane tabele i zweryfikowane assety.

**Konta historyczne:** migracja SQL 0015 dodaje administracyjny receipt.
`python -m app.legacy_cutover UUID` na testowym backendzie wykonuje
dry-run. Proces ma używać konta DB uprawnionego do zapisu markera i
receipt oraz tego samego prywatnego magazynu assetów co API. Zatrzymać
stare klienty po potwierdzeniu wysłania ich dokumentów, folderów,
ustawień, planera i zmian gości. Zamknąć aktywne Share. Na zweryfikowanej
kopii danych uruchomić apply z `--expect-v1-cursor` z dry-runu oraz
`--all-v1-devices-flushed`. Wymagana jest jawna allowlista zapisu v2.
Nie ustawiaj `all` na produkcji w celu obejścia tej bramki.

Serwer zachowuje wiersze v1 i atomowo publikuje operacje, receipt i
marker v2. Ponowne uruchomienie odczytuje istniejący receipt. Dokumenty,
strony, elementy i zadania zachowują identyfikatory. Foldery bez UID
dostają deterministyczne identyfikatory. Formatowany tekst jest
przenoszony do atomów Quill. Inline PNG/JPEG/WebP/PDF i inline
osadzenia Quill z danymi są weryfikowane przez SHA-256. Brak bytes,
nieobsługiwany embed lub brak zgodności danych blokuje konwersję.
Ustawienia konta i planer pozostają w ich istniejących rejestrach CAS.

Klient porównuje lokalne dokumenty z zachowaną rewizją v1.
W tej samej transakcji archiwizuje tabele SQLite, zapisuje oczekujące
edycje i usunięcia oraz opróżnia wyłącznie projekcję. Po odtworzeniu
checkpointu v2 stosuje bezkolizyjne zmiany jako operacje. Zapis statusu
każdej konwersji jest atomowy razem z jej kopertami i outboxem.
Ponowienie po restarcie nie tworzy kolejnych kopert dla zakończonej
pozycji.

Nowa lokalna notatka zachowuje UID, jeśli ten UID nie istnieje i nie
ma tombstone. Lokalna edycja może być scalona z niezależnym polem
serwera. Przy kolizji lub nowszej wersji zdalnej nie wykonuje się
nieodwracalnego usunięcia ani nie wskrzesza dokumentu. Użytkownik
może skopiować dane odzyskiwania i jawnie odtworzyć zachowaną treść
jako nową notatkę. Foldery i zadania są scalane względem ostatniej
potwierdzonej wartości v1 po odtworzeniu notatek. Zapis zgodnych zmian
i oznaczenie wyniku są atomowe. Nowsze pola serwera i tombstones
pozostają nietknięte. Kolizje, brak wiarygodnego punktu odniesienia
i nieobsługiwane formaty zostają w archiwum do przejrzenia.
Nadal należy zsynchronizować wszystkie znane klienty
przed produkcyjną aktywacją, szczególnie outboxy gości Share.

Świeży, pusty identyfikator testowy nadal obsługuje
`scripts/stage13-activate-empty-canary.sh`. Nie wykonano cutover
żadnego rzeczywistego konta.
