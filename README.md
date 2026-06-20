# NaNotateczki

NaNotateczki to aplikacja do cyfrowych notatek tworzona z myślą o pracy
rysikiem, ale wygodna także na desktopie z myszką, klawiaturą i touchpadem.
Możesz prowadzić klasyczne zeszyty z wieloma stronami, szkicować na swobodnej
tablicy, wklejać obrazy i tekst, porządkować materiały w folderach, a gotowe
notatki eksportować do PDF albo PNG.

Projekt jest aplikacją Flutterową z lokalnym zapisem danych w Drift/SQLite. Nie
wymaga konta ani zewnętrznego backendu: notatki są przechowywane lokalnie,
backup działa jako pliki JSON, a synchronizacja folderowa zapisuje jeden plik
w wybranym katalogu.

## Co potrafi aplikacja?

### Biblioteka notatek

- Tworzenie dwóch typów materiałów:
  - **Notebook** - klasyczny, wielostronicowy zeszyt.
  - **Board** - jedna swobodna tablica/canvas do luźnego układania treści.
- Foldery do porządkowania notatek i tablic.
- Zmiana nazw folderów oraz elementów biblioteki.
- Usuwanie pojedynczych notatek/tablic i całych folderów z zawartością.
- Wyszukiwanie po tytule, nazwach stron, blokach tekstowych i wyniku OCR.
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
- Kolorowe zakładki indeksujące na stronach, z edycją koloru i pozycji.
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

### Obrazy, pliki i OCR

- Dodawanie obrazów z galerii lub pliku.
- Wklejanie obrazów i tekstu ze schowka.
- Import plików PNG, JPG/JPEG, PDF oraz TXT.
- Import PDF jako obrazy stron:
  - na Linuksie przez `pdftoppm` z pakietu `poppler-utils`,
  - na pozostałych platformach przez `pdfx`.
- Przesuwanie, skalowanie, kadrowanie i obracanie obrazów.
- Kopiowanie obrazów do schowka.
- OCR obrazów na Androidzie i iOS przez ML Kit.
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

- Undo/redo dla operacji na tekstach, obrazach, kreskach, zakładkach i lasso.
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
- Synchronizacja folderowa bez API keys i bez konta.
- Plik synchronizacji `notatek_cloud.json` w wybranym katalogu.
- Scalanie danych metodą "nowsza aktualizacja wygrywa" na podstawie
  `updatedAt`.

## Stack techniczny

- Flutter 3.x i Dart `^3.11.1`.
- Material 3.
- Provider + ChangeNotifier do stanu aplikacji.
- Drift + SQLite jako lokalna baza danych.
- `flutter_quill` do edycji tekstu rich text.
- `pdf`, `pdfx`, `file_picker`, `image_picker`, `super_clipboard`.
- `google_mlkit_text_recognition` dla OCR na Androidzie i iOS.

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

- OCR działa tylko na Androidzie i iOS. Na desktopie aplikacja zwraca komunikat
  o braku wsparcia zamiast przerywać pracę błędem.
- Import PDF na Linuksie wymaga `pdftoppm`.
- Synchronizacja folderowa nie jest usługą chmurową sama w sobie. Aplikacja
  zapisuje plik JSON w katalogu, który może być synchronizowany np. przez
  Dropbox, Syncthing, iCloud Drive, OneDrive albo inny system plików.
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
