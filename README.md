# NaNotateczki

NaNotateczki to aplikacja do cyfrowych notatek tworzona z myślą o pracy
rysikiem, ale wygodna także na desktopie z myszką, klawiaturą i touchpadem.
Możesz prowadzić klasyczne zeszyty z wieloma stronami, szkicować na swobodnej
tablicy, wklejać obrazy i tekst, porządkować materiały w folderach, a gotowe
notatki eksportować do PDF albo PNG.

Projekt jest aplikacją Flutterową z lokalnym zapisem danych w Drift/SQLite. Nie
w trybie Local konta ani backendu: notatki są przechowywane lokalnie,
a kopie zapasowe pozostają na urządzeniu. Po zalogowaniu synchronizacja
konta używa wyłącznie V2. Instrukcja uruchomienia jest w
[dokumencie pakietu 11](docs/ETAP_14_FINALIZACJA.md).

## Licencja

Własny kod NaNotateczki udostępniany jest na warunkach
**[PolyForm Noncommercial License 1.0.0](LICENSE.md)**.
Używanie, modyfikowanie i redystrybucja są dozwolone wyłącznie
w ramach użytku niekomercyjnego określonego w licencji.
Użycie komercyjne wymaga osobnej zgody właściciela praw.

Licencja nie obejmuje na nowych zasadach bibliotek i innych materiałów
osób trzecich: obowiązują dla nich ich własne warunki.
Informacja copyright znajduje się w [NOTICE](NOTICE),
a szczegóły w [przeglądzie licencji zależności](docs/LICENSING.md).
Projekt udostępnia kod źródłowy, ale nie jest licencjonowany jako
open source w rozumieniu OSI.

## Co potrafi aplikacja?

### Biblioteka notatek

- Tworzenie dwóch typów materiałów:
  - **Notebook** - klasyczny, wielostronicowy zeszyt.
  - **Board** - jedna swobodna tablica/canvas do luźnego układania treści.
- Foldery do porządkowania notatek i tablic.
- Zmiana nazw folderów oraz elementów biblioteki.
- Usuwanie pojedynczych notatek/tablic i całych folderów z zawartością.
- Wyszukiwanie po tytule, nazwach stron, blokach tekstowych i zachowanym
  tekście OCR ze starszych dokumentów.
- Widok szeroki z panelami: foldery, lista notatek, obszar roboczy.
- Widok wąski z paskiem folderów i otwieraniem notatek na osobnym ekranie.
- Zwijanie i ręczna zmiana szerokości paneli w układzie desktopowym.

### Edytor zeszytu

- Wielostronicowe notatki o proporcjach kartki A4.
- Dodawanie i usuwanie stron.
- Przewijanie dokumentu z automatyczną synchronizacją aktywnej strony.
- Zoom i przesuwanie widoku myszką, touchpadem oraz gestami dotykowymi.
- Mini-mapa dokumentu z podglądem stron, treści i aktualnego obszaru widoku.
- Oznaczanie notatek jako ulubione/ważne przez zakładkę w pasku aplikacji.
- Renderowanie tylko widocznego zakresu stron, żeby duże notatniki działały
  sprawniej.

### Tablica Board

- Jedna przestrzeń robocza do swobodnego szkicowania i układania elementów.
- Zoom, przesuwanie widoku, dopasowanie do zawartości i reset widoku.
- Te same narzędzia rysowania, tekstu, obrazów, eksportu i schowka co w
  edytorze zeszytu.
- Eksport widocznej/zawartej treści tablicy do PDF lub PNG.

### Rysowanie i narzędzia

- Pióro i zakreślacz.
- Gumka punktowa oraz gumka usuwająca całe kreski.
- Kształty: linia, strzałka, prostokąt, kwadrat, trójkąt, elipsa, koło i
  strzałka blokowa.
- Automatyczne wygładzanie szybkich kresek dla pióra i zakreślacza.
- Rozpoznawanie prostych kształtów po przytrzymaniu rysunku.
- Regulacja grubości kreski.
- Kolor aktywny, szybkie kolory, ostatnio używane kolory i własny wybór RGB.
- Obsługa rysika, myszy, dotyku i touchpada.
- Ochrona przed przypadkowym rysowaniem dłonią przy pracy rysikiem.

### Tekst

- Dodawanie bloków tekstowych w dowolnym miejscu strony lub tablicy.
- Edycja tekstu w rich text przez `flutter_quill`.
- Formatowanie: pogrubienie, kursywa, podkreślenie i przekreślenie.
- Wybór fontu, rozmiaru i koloru tekstu.
- Przesuwanie i zmiana szerokości bloków tekstowych.
- Zapamiętywanie ostatnich ustawień tekstu.
- Grupowanie wpisywania w jedną akcję undo, zamiast cofania pojedynczych
  znaków.

### Obrazy i pliki

- Dodawanie obrazów z galerii lub pliku.
- Wklejanie obrazów i tekstu ze schowka.
- Import plików PNG, JPG/JPEG, PDF oraz TXT.
- Import PDF jako obrazy stron:
  - na Linuksie przez `pdftoppm` z pakietu `poppler-utils`,
  - na pozostałych platformach przez `pdfx`.
- W Move: przesuwanie uchwytem lub jednym palcem niezależnie od ustawienia
  pisania palcem, skalowanie rogami i kadrowanie krawędziami.
- Gesty dwoma palcami nie transformują obiektów. Gdy obiekt jest zaznaczony,
  canvas pozostaje zamrożony.
- Zaznaczenie pozostaje aktywne po tapnięciu w dowolnym miejscu ramki;
  kończy je dopiero tapnięcie obok albo zmiana narzędzia.
- Kopiowanie obrazów do schowka z menu po przytrzymaniu.
- Brak OCR na wszystkich platformach; zapisane wcześniej wyniki pozostają
  czytelne i przeszukiwalne.
- Przechowywanie bajtów obrazów w danych notatki, żeby aplikacja potrafiła
  odtworzyć obraz nawet po utracie pliku cache.

### Zaznaczanie, schowek i skróty

- Zaznaczanie lasso dla kresek, tekstu i obrazów.
- Przesuwanie całego zaznaczenia jako jednej operacji.
- Kopiowanie, wycinanie, wklejanie i usuwanie aktywnego elementu.
- Wewnętrzny schowek elementów aplikacji oraz integracja ze schowkiem systemu.
- Skróty klawiszowe `Ctrl/Cmd+C`, `Ctrl/Cmd+V`, `Ctrl/Cmd+X` i `Delete`
  poza aktywną edycją tekstu.

### Cofanie, zapis i bezpieczeństwo danych

- Undo/redo dla operacji na tekstach, obrazach, kreskach i lasso.
- Automatyczny zapis notatki po zmianach.
- Lokalna baza Drift/SQLite.
- Rotowany lokalny backup JSON: najnowszy snapshot oraz dwie poprzednie kopie.
- Eksport i import backupu biblioteki jako JSON.
- Odporne otwieranie bazy z wykrywaniem problemów schematu.
- Banner informujący o resecie bazy i próba automatycznego odtwórzenia z
  backupu, gdy to możliwe.

### Eksport i synchronizacja

- Eksport notebooków i tablic do PDF.
- Eksport do PNG:
  - tablica lub pojedyncza strona jako plik,
  - wielostronicowy notebook jako folder z plikami `page_XX.png`.
- Dialog wyboru miejsca zapisu przez `file_picker`.
- Zalogowane urządzenia synchronizują notatki i Share przez dziennik
  operacji V2. Tryb Local działa niezależnie od konta.

## Stack techniczny

- Flutter 3.x i Dart `^3.11.1`.
- Material 3.
- Provider + ChangeNotifier do stanu aplikacji.
- Drift + SQLite jako lokalna baza danych.
- `flutter_quill` do edycji tekstu rich text.
- `pdf`, `pdfx`, `file_picker`, `image_picker`, `super_clipboard`.

## Struktura projektu

```text
NaNotateczki/
├── lib/
│   ├── main.dart              # start aplikacji
│   ├── app/                   # root widget, Provider i bootstrap
│   ├── core/                  # motyw, metryki i wspólne widgety
│   ├── data/                  # Drift/SQLite, backup, eksport, synchronizacja
│   └── features/
│       ├── library/           # biblioteka, foldery, search, sync
│       ├── notebook/          # modele domenowe i repository
│       ├── editor/            # edytor zeszytów
│       └── board/             # edytor tablicy
├── test/widget_test.dart      # smoke test aplikacji
├── PROJECT_MAP.md             # mapa plików dla agentów i developerów
└── pubspec.yaml               # zależności Flutter/Dart
```

Najważniejszym dokumentem dla osób wchodzących w kod jest `PROJECT_MAP.md`.
Opisuje odpowiedzialność plików w `lib/`, klasy, funkcje i miejsca, na które
trzeba uważać przy zmianach.

## Uruchomienie

Wymagania:

- Flutter z obsługą Dart SDK zgodnego z `^3.11.1`.
- Na Linuksie dla file pickera: `zenity`.
- Na Linuksie dla importu PDF: `poppler-utils`, bo aplikacja używa `pdftoppm`.

Komendy:

```bash
flutter pub get
flutter run
```

Na Linuksie możesz używać zwykłego `flutter run -d linux`, również z VS Code
Snap. Runner przed inicjalizacją GTK zastępuje ścieżkę schematów odziedziczoną
z Code Snap systemową `/usr/share/glib-2.0/schemas`, jeśli istnieje jej
`gschemas.compiled`. Jawne ścieżki niezwiązane z Code Snap pozostają bez zmian.
Nowe terminale VS Code w tym projekcie również dostają systemową ścieżkę.
Po zmianie runnera zatrzymaj aplikację i uruchom ją ponownie: hot reload
nie przeładowuje natywnego kodu startowego.
Diagnostyka ostrzeżeń Wayland i testy: [Linux startup](docs/LINUX_STARTUP.md).

Przydatne komendy developerskie:

```bash
dart format lib test
dart analyze
flutter test
```

Po zmianach w schemacie Drifta trzeba dodatkowo uruchomić:

```bash
dart run build_runner build
```

## Ważne ograniczenia

- OCR jest wyłączony na wszystkich platformach.
- Import PDF na Linuksie wymaga `pdftoppm`.
- Projekt świadomie używa Provider + ChangeNotifier. Nie ma tu Bloc ani
  Riverpoda.

## Dla osób rozwijających projekt

- Przed zmianami w `lib/` przeczytaj `PROJECT_MAP.md`.
- Nie edytuj ręcznie wygenerowanego `notes_database.g.dart`.
- Zmiany schematu Drifta wymagają regeneracji plików i świadomej migracji
  `schemaVersion`, jeśli trzeba zachować istniejące dane.
- Mutacje w edytorze, które użytkownik powinien móc cofnąć, powinny przechodzić
  przez akcje undo/redo w `EditorAction`.
- `DrawingCanvas` i `DocumentDrawingCanvas` są podobne, ale obsługują inne
  układy współrzędnych. Ich rozdzielenie jest celowe.

## Status

Projekt jest lokalną aplikacją notatkową w aktywnym rozwoju. Aktualny smoke
test sprawdza, czy `NotesApp` startuje i pokazuje ekran ładowania podczas
otwierania bazy.
