# WIP: wspólna edycja sesji Web

Stan roboczy zapisany w GitHub na prośbę użytkownika, do kontynuacji w
następnym czacie. **Nie jest to ukończone ani zweryfikowane wdrożenie.**

## Cel

Właściciel tworzy link do konkretnego boardu/notatnika. Goście bez konta,
po podaniu hasła, korzystają z rzeczywistego edytora Flutter i mogą
edytować dokument do zakończenia/wygaśnięcia sesji. Wszelkie zatwierdzone
zmiany są zapisywane w oryginalnym UID/folderze właściciela. Nie ma
dostępu do innych dokumentów autora.

Współbieżne zmiany niezależnych obiektów powinny się łączyć. Przy
kolizji na jednym obiekcie pierwszeństwo ma wcześniejszy mikrosekundowy
czas **przyjęcia przez serwer**; przy identycznym czasie wygrywa większa
zmiana. Nie używać zegarów przeglądarek.

## Przygotowane zmiany (WIP)

- Serwer: endpointy `GET /v1/study-shares/active`,
  `GET /v1/study-shares/{id}/document` i
  `PUT /v1/study-shares/{id}/document`, uwierzytelnienie biletem gościa,
  aktualizacja oryginalnego `synced_notebooks`, sygnały WebSocket.
- Reguły scalania dla gościa i właściciela; `edit_clock` utrwalony
  w nowej migracji `0005_study_share_edit_clock.sql`.
- Flutter: osobny edytor gościa (BoardScreen / NotebookScreen)
  z izolowaną bazą in-memory, odzyskiwanie sesji właściciela,
  powiadamianie o aktualizacjach WebSocket, retry i status zapisu.
- Skrócone debounce: edytor aktywnej sesji 100 ms, kolejka sync właściciela
  90 ms, zgłoszenie zapisu gościa 35 ms. Nie jest to gwarancja latencji.
- Przy zakończeniu sesji odebranie uprawnień nie powinno zależeć
  od powodzenia ostatniego zapisu.
- Dodano/rozszerzono testy kontraktowe klienta i FastAPI.

## Krytyczne zadania na kolejny czat

1. **Uruchomić formatowanie, analizę i testy lokalne** – te pliki nie
   zostały przetestowane ani skompilowane. Naprawić wszystkie problemy
   kompilacji i runtime, w tym ładowanie SQLite WASM in-memory.
2. Zweryfikować `StudyShareGuestEditor`: prawidłowe zapisy tekstu,
   kreski/obrazki, zmiany właściciela, szybkie odświeżanie, brak resetu
   lokalnych niezapisanych operacji i retry. Zabezpieczyć utratę danych
   przy zamknięciu karty i rzeczywistych kolizjach.
3. Zweryfikować połączenie `LiveWebSyncService` z `sync.py`:
   trójstronne scalenie danych właściciela i gości bez duplikatów
   konfliktowych; szczególnie ponawiane żądania/idempotencja,
   jednoczesna edycja i usunięcie.
4. Sprawdzić algorytm kolejności: wcześniejsza zmiana (na serwerze)
   wygrywa, większa tylko przy identycznej mikrosekundzie. Ustalić
   odporne rozstrzyganie remisów wielokrotnych i poprawne liczenie
   wielkości zmiany. Dodać testy regresyjne.
5. Sprawdzić ścisłą blokadę edycji po wygaśnięciu/zakończeniu sesji,
   w tym wyścig PUT vs DELETE oraz opóźnione żądania.
6. Dokończyć odzyskiwanie aktywnej sesji właściciela po reloadzie,
   przy otwartym edytorze, na wielu kartach i po wylogowaniu.
7. Wyczyścić historyczne chwilowe PNG po wygaśnięciu. Rozważyć
   wyłączenie starych endpointów PNG, gdy goście już ich nie używają.
8. Wykonać testy rzeczywistego PostgreSQL, WebSocket, Flutter Web
   w dwóch przeglądarkach i pomiary latencji w rzeczywistej sieci.
9. Zsynchronizować zgodność backendu `NaNotateczki/server` i osobnego
   `NaNotateczki-serwer`; wdrożyć migracje 0004/0005 przed nowym API.
10. Potwierdzić, że dotychczasowe backupy, lokalne notatniki i
    synchronizacja kont pozostają zgodne po przebudowie.

## Uwagi o wdrożeniu

To **checkpoint WIP**, nie release. Nie uruchamiano testów GitHub Actions
zgodnie z instrukcjami projektu. Nie przeprowadzono rzeczywistego E2E,
nie wdrożono API ani Flutter Web na serwerze HP. Aktualnie działający
backend może nadal zwracać 404, dopóki nie zostanie zaktualizowany.

Następny czat powinien zacząć od `CZAT.md`, `PROJECT_MAP.md` i
`data.md`, a następnie użyć tej listy.
