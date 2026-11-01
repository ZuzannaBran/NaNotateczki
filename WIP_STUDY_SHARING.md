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

## Stan po kontynuacji 2026-11-01

**Kod zabezpieczeń zapisano commitami** na `NaNotateczki/dev` oraz
`NaNotateczki-serwer/main`; kopie backendu w obu repozytoriach są zgodne.
Nie oznacza to pomyślnego zakończenia ani wdrożenia mechanizmu.

Przeprowadzone poprawki:

- W feedzie zmian właściciela utrwalany jest zatwierdzony, scalony snapshot,
  a nie nieaktualny payload przeglądarki.
- Gość i właściciel muszą podawać `baseNotebook` zgodny z odpowiednią
  historyczną rewizją serwera; dodano indeks historii (migracja 0006).
- Serwer blokuje tworzenie dwóch aktywnych sesji tego samego UID,
  serializuje tworzenie z operacjami konta i unieważnia sesję przy skasowaniu
  udostępnionego oryginału.
- Przy ręcznym kończeniu sesji Flutter najpierw odcina gości, dopiero potem
  próbuje opróżnić zaległe zapisy właściciela.
- Klient gościa rozpoznaje terminalne kody zamknięcia WebSocket oraz
  ponownie odczytuje dokument po inicjalizacji edytora.
- Dodano regresje do `test/study_share_http_test.dart`,
  `test/study_share_guest_socket_test.dart` i
  `server/api/tests/test_study_shares_flow.py`. **Nie uruchomiono ich**.

**Wciąż obowiązkowe przed uznaniem pracy za ukończoną:**

1. Trwała kolejka gościa dla odłączenia, odświeżenia i zamknięcia karty;
   brak dowodu ochrony każdej niezapisanej operacji przy kolizjach.
2. Weryfikacja działania całego edytora (tekst, rysowanie, gumka, obrazy,
   obiekty) i widoku właściciela bez nadmiarowych kopii konfliktowych.
3. Kontrola czyszczenia plików PNG po wygaśnięciu i wielokrotnych remisów.
4. Lokalne `flutter test`, `dart analyze`, `pytest`, prawdziwy
   PostgreSQL i dwie przeglądarki, wraz z pomiarem latencji.
5. Po wykonaniu kopii bezpieczeństwa: migracje 0004–0006 na serwerze HP,
   wdrożenie nowego API i Flutter Web, ponowny test E2E.

Plik WIP należy **usunąć dopiero po wykonaniu i potwierdzeniu** powyższych
punktów. GitHub Actions nie uruchamiano.

Dalsza poprawka: `hasRejectedSharedEdits` i testy `shared_edit_conflicts_test.dart`
wykrywają, gdy serwer nie przyjął edycji konkretnego obiektu. Klient zachowuje
ją lokalnie w otwartej karcie i pokazuje ostrzeżenie zamiast cichego
nadpisania; bez trwałego outboxu wciąż nie ma odzyskiwania po zamknięciu.

## Doprecyzowanie i poprawka współpracy (2026-11-01)

- Blokada dotyczy **liczby aktywnych linków/sesji jednego dokumentu**, a
  nie liczby gości. Jedna sesja wpuszcza wielu edytujących uczestników.
- Poprawiono mylący opis przy tworzeniu linku (goście mogą edytować).
- Przed zastosowaniem zdarzeń z serwera klient właściciela opróżnia edytor
  i wysyła oczekujące zmiany przez serwerowy merge, ograniczając zbędne
  kopie konfliktowe podczas równoczesnej edycji.
- Dodano regresję synchronizacji właściciel–gość i tekstu dialogu.
- Nadal brak trwałego outboxu gości, przeglądarkowego E2E i pomiarów.
  Zmiany nie są wdrożeniem produkcyjnym, testy Flutter nieuruchomione.

## Audyt kolejnych skrajnych przypadków

- Dodano snapshot niepotwierdzonych edycji gościa, izolowany per link.
  Ponowne wejście przez hasło odtwarza zapis i ponawia żądanie serwerowe.
  Rekord nie zawiera biletu sesji ani hasła.
- Przed wysłaniem gościa opróżniane są zapisy edytora, w tym bieżącego tekstu.
- Snapshot jest usuwany dopiero po odpowiedzi serwera potwierdzającej brak
  odrzuconych edycji; przy HTTP 409, 410 lub problemie sieciowym pozostaje.
- Przy braku miejsca w localStorage edytor zgłasza niepowodzenie odzyskiwania,
  ale nadal podejmuje próbę wysłania zmian do serwera.
- Weryfikacja kodu nie zastępuje testów przeglądarkowych. Zapis w toku w chwili
  zabicia procesu, bardzo duże dokumenty i brak dostępnej przestrzeni
  magazynu przeglądarki nadal są otwartymi ryzykami.

- Usunięto wyścig pomiędzy HTTP odświeżeniem a timerem wysyłania gościa:
  po zakończeniu odświeżenia oczekująca zmiana ponawia PUT.
- Zamknięcie niezmienionego edytora nie tworzy fałszywego rekordu outboxu.

- URI SQLite WASM w edytorze gościa rozwiązywane jest od korzenia originu,
  niezależnie od ścieżki /share/UUID i parametrów zaproszenia.
