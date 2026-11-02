# Backup, konto, synchronizacja i wspólne sesje — plan wdrożenia

Stan: 2026-11-02. Gałąź aplikacji: `dev`, serwera: `main`.
`CZAT.md`, `data.md` i `PROJECT_MAP.md` obowiązują przy kolejnych zmianach.

## Niezmienne wymagania

- Na każdym urządzeniu to samo konto = ten sam zatwierdzony stan notatników,
  folderów, zadań, kalendarza, sesji nauki i ustawień.
- Synchronizacja zmian na żywo nie jest tym samym co backup historii.
- Usunięcie ma trwały tombstone; starszy backup ani offline bootstrap nie
  może wskrzeszać usuniętych danych.
- Niepotwierdzone edycje offline są zachowywane. Kopię `(1)` tworzymy tylko
  dla rzeczywistego konfliktu edycji, a nie zwykłego usunięcia.
- Konflikt usunięcie–edycja: klient potwierdza tombstone przed ponowieniem
  rzeczywiście oczekującej edycji. Serwer akceptuje ją przez jawne
  `restoreDeleted` i CAS nowej rewizji, zachowując oryginalny UID. Kolejność
  przyjęcia przez serwer jest decydująca; zegar urządzenia ani backup
  nie mogą samodzielnie wskrzeszać dokumentu. Jeżeli nie ma edycji,
  usunięcie obowiązuje wszędzie. Późniejszy DELETE wymaga nowej rewizji.
- Współdzielona sesja jest osobnym mechanizmem: goście edytują *oryginał*
  u hosta pod jego UID i folderem, bez tworzenia kopii `(1)` przy scalaniu
  niezależnych obiektów. Po zakończeniu brak dostępu gości.
- W shared session każda lokalnie zapisana operacja (kreska, tekst,
  gumka, przesunięcie) musi wywoływać natychmiastowe wysłanie rewizji,
  bez cyklicznego 2-sekundowego odpytywania. WebSocket powiadamia pozostałych.
- Host i każdy gość utrzymują niezależny viewport, zoom, scroll,
  aktywną stronę, fokus i zaznaczenie. Odbiór nowych danych nie może
  odmontowywać lokalnego edytora ani zmieniać widoku innego uczestnika.
- Stare błędy nie pojawiają się ponownie przy otwarciu ustawień.
  Nowy incydent pokazać raz; historię zachować w logach diagnostycznych.
- Logowanie na urządzeniu jest zapamiętywane; jawny `Log out` usuwa token
  i wraca do wyboru trybu. Zmiana hasła i administracyjne unieważnienie sesji
  pozostają celowymi wyjątkami.
- Bezczynność oznacza brak kliknięć, interakcji rysikiem, przewijania i
  pisania (również klawiaturą ekranową). Hover i zdarzenia z ukrytej karty
  nie są aktywnością. Backup po powrocie z tła nie zeruje licznika.
- Backup automatyczny: 15 s / 30 s / 1 / 2 / 5 / 15 / 30 minut,
  domyślnie 30 s.
  Preferencje docelowo są jedną wersjonowaną polityką serwerową per konto.

## Etapy i status

1. **Schemat serwera — kod dodany, CI niepotwierdzony.**
   Migracja `0009_account_settings_library_state.sql` dopuszcza
   `libraryState` bez edycji zastosowanej migracji `0007`; dodano test.
   Przed wdrożeniem wykonać pełny backup i `scripts/apply-migrations.sh`.
2. **Usunięcia notatników — poprawki i testy dopisane, CI niepotwierdzone.**
   Bootstrap usuwa potwierdzone tombstones bez kopii; niezapisany draft
   zachowuje jako `(1)`, także przy odpowiedzi HTTP 409. Sprawdzić
   rzeczywiste równoległe operacje i historię zmian na serwerze.
3. **Trwała sesja i UI — poprawki i testy dopisane, CI niepotwierdzone.**
   Dodano `Log out` i powrót do wyboru trybu po ponownym uruchomieniu;
   usunięto ikonę `Back up now`. Serwer domyślnie wydaje rotowane
   refresh tokeny na 3650 dni (stare wygasłe tokeny wymagają logowania).
   Po starcie offline klient ponawia zapamiętaną sesję po wznowieniu lub
   okresowo na widocznym ekranie; równoległe próby mają single-flight.
   Nadal dopilnować bezpiecznego odnawiania po utracie odpowiedzi i w wielu kartach.
4. **Wykrywanie aktywności — poprawki i testy dopisane, CI niepotwierdzone.**
   Zmiana danych z sync nie zeruje bezczynności. Ukryta karta nie liczy
   interakcji. Wpisy w Quill liczą także klawiaturę ekranową.
   Wake API ignoruje hover i ruch kursora bez wciśniętego przycisku.
   Do przetestowania inne pola tekstowe i rzeczywiste zawieszenie aplikacji.
5. **Odtwarzanie backupu — poprawki i testy dopisane, CI niepotwierdzone.**
   Weryfikowana utrata SQLite pozwala ponownie odtworzyć już pobrany backup.
   Błąd pobrania nie blokuje live sync ani nie uruchamia backupu niekompletnego
   stanu. Backend sortuje kopie po czasie weryfikacji.
   Dodano fallback i test: niepoprawna najnowsza kopia ustępuje starszej
   prawidłowej. Pozostaje test atomowego odtwarzania uszkodzonego payloadu.
6. **Synchronizacja folderów, okładek, zadań — CZĘŚCIOWO.**
   Klient obsługuje `libraryState` i CAS z automatycznym scalaniem
   znanych folderów, okładek i zadań, potwierdzonymi usunięciami oraz
   kopiami `(1)` dla konfliktujących zadań. Zabezpiecza zmiany lokalne
   podczas żądania REST. Dodać testy end-to-end z PostgreSQL,
   dwoma urządzeniami i rename/move podfolderów oraz dopracować
   usunięcia i metadane plików przy niepełnych snapshotach.
7. **Konflikty ustawień i jedna polityka backupu — NIEUKOŃCZONE.**
   Potrzebne trójstronne uzgadnianie niezależnych ustawień, idempotencja
   po 409 oraz jedna wersjonowana polityka backend + lokalny cache.
   Klient odnawia obecnie wygasły access JWT przed ponownym sync ustawień.
8. **Harmonogram, tło i retencja — CZĘŚCIOWO.**
   Dodano 15 s oraz nowy domyślny interwał 30 s (API i UI). Przy normalnym
   zamknięciu zalogowanej aplikacji natywny exit guard blokuje wyjście do
   zakończenia zweryfikowanego backupu i pokazuje spinner + Retry.
   Przy `detached` i Web `hidden` podejmowana jest próba awaryjna.
   Zabicie procesu i zamknięcie karty nie gwarantują wykonania HTTP;
   zaległe dane muszą być ponawiane po uruchomieniu. Nadal potrzebne są:
   natywny worker, atomowa retencja snapshotów, kontrola miejsca,
   czyszczenie niedokończonych uploadów i testy restore.
9. **Współdzielone sesje — poprawki płynności i viewportu, CI w trakcie.**
   Naprawiono wyścig rejestracji zdarzenia `ended` przed autoryzacją
   WebSocket i dodano test. Pozostają rzeczywiste testy host + dwóch gości
   na dwóch przeglądarkach, przerywanie sieci, równoczesne operacje na
   tym samym obiekcie, wznowienie, przedłużenie, wygaśnięcie i odwołanie.
   Niezależnych obiektów nie wolno scalać przez kopie konfliktowe.
   Dodano natychmiastowy drain po lokalnym zapisie i w trakcie lotu innych
   requestów. Gość i host aktualizują strony w istniejącym kontrolerze
   zamiast resetować viewport. Pozostają pomiary latencji na dwóch
   przeglądarkach i weryfikacja zmian podczas aktywnego gestu.
10. **Testy końcowe i wdrożenie — NIEUKOŃCZONE.**
    Python API + prawdziwy PostgreSQL, Flutter na Linux/Web/Android/iOS,
    minimum 2 urządzenia, restart i usunięcie lokalnej bazy, awaria serwera
    między wysyłką a finalize, zmiana hasła, wylogowanie i powrót.

## Reżim prac

Po każdej zamkniętej poprawce: nowy test regresyjny, commit i push;
push na `dev` / `main` wywołuje właściwy workflow GitHub Actions.
Nie czekać na jego zakończenie przed następną niezależną poprawką.
Aktualny app workflow używa `cancel-in-progress: true`: nowszy push może
anulować poprzedni test; liczy się kompletna kontrola ostatniego commita.
Co kilka etapów pobierać statusy i naprawiać błędy. Nie oznaczać testów
jako zaliczonych bez wyniku `success`.

## Scenariusze obowiązkowe przed ukończeniem

- A tworzy/edytuje/usuwa notatnik i folder, B widzi to bez restartu.
- A usuwa, B jest offline i nie zmienia dokumentu: brak kopii `(1)`.
- A usuwa, B offline edytuje: usunięty oryginał + jedna zachowana kopia.
- A usuwa zadanie lub wydarzenie, B nie przywraca go ze starego backupu.
- Oba urządzenia zmieniają ten sam folder/zadanie/preferencję jednocześnie.
- Świeża instalacja i utrata samej SQLite bez utraty markerów backupu.
- Najnowsza kopia jest uszkodzona, starsza poprawna: restore jest możliwy.
- Login zapamiętany po kilku miesiącach, brak sieci, wylogowanie offline,
  restart po wylogowaniu, zmiana hasła na drugim urządzeniu.
- Klawiatura sprzętowa, ekranowa, dotyk/rysik, kliknięcia, hover, ukryta
  karta i powrót; backup nie blokuje interfejsu i nie gubi zmian w trakcie.
- Gość A + gość B + host edytują równocześnie jeden dokument; stan u hosta
  jest scalony i gość traci dostęp natychmiast po `End session`.

## Dodatkowe scenariusze edge-case

- A usuwa, B nie edytuje: oba urządzenia usuwają; stary backup nie przywraca.
- A usuwa, B ma niezapisany draft: po wysłaniu i potwierdzeniu tombstone
  serwer przyjmuje świadomy retry; ten sam UID i folder wracają wszystkim.
- B edytuje i zapis zostaje przyjęty przed A DELETE: późniejszy DELETE po
  odczytaniu nowej rewizji usuwa dokument, bez automatycznego odtworzenia.
- A i B równocześnie usuwają/edytują: CAS 409 + maksymalnie jedna próba
  rekonsyliacji; przy kolejnych konfliktach operacja pozostaje w outboxie,
  z czytelnym statusem zamiast utraty danych.
- Host i dwóch gości: niezależna strona, zoom, przewinięcie i zaznaczenie,
  podczas gdy każda zakończona edycja jest natychmiast transmitowana.
- Zamknięcie online z aktywnym kontem: overlay do zweryfikowanego uploadu;
  brak Internetu: pozostaje w aplikacji i przycisk Retry.
- Utrata procesu lub Web przed `finalize`: brak gwarancji uploadu;
  po ponownym starcie kolejka wywołuje retry, nie usuwa sprawnej kopii.
- Ten sam błąd synchronizacji zgłoszony wiele razy: jednorazowy komunikat,
  rearm po poprawnym zakończeniu operacji i nowym błędzie.
