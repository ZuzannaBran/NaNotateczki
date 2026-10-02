# AGENTS.md

Stały kontrakt dla agentów AI w tym repozytorium. Czytaj go na początku każdej
sesji. Domyślny język komunikacji: polski.

## 1. Najpierw mapa

Przed czytaniem `lib/` otwórz [PROJECT_MAP.md](PROJECT_MAP.md): całość przy
pierwszym zadaniu w sesji, później tylko właściwe sekcje. Następnie:

1. Wybierz plik i zakres linii z mapy.
2. Czytaj tylko potrzebny zakres; nie otwieraj dużych plików w całości.
3. Gdy lokalizacja nie jest jasna, użyj najpierw `rg` po słowie kluczowym.
4. Przed edycją sprawdź `git status` i zachowaj zmiany użytkownika.

Nie używaj eksploracji agentem, dopóki szybkie wyszukiwanie nie da hipotezy.
Oszczędność kontekstu jest wymaganiem, nie sugestią.

## 2. Jak prowadzić PROJECT_MAP.md

Mapa jest krótkim indeksem, nie katalogiem każdej prywatnej funkcji. Dla
każdego pliku w `lib/` ma zawierać:

- jednozdaniową odpowiedzialność,
- publiczne punkty wejścia i ważne prywatne granice z numerami linii,
- tylko istotne pułapki i zależności między plikami.

Po zmianie kodu aktualizuj wyłącznie dotknięte wpisy: numery wskazanych granic,
publiczne symbole, odpowiedzialność i ostrzeżenia. Nowy plik w `lib/` zawsze
wymaga wpisu; ważny nowy test dopisz do skróconej listy testów. Nie rozbudowuj
mapy o oczywiste helpery ani opis każdej metody.

## 3. Pre-flight przed edycją

- Schemat `notes_database.dart`: uruchom `dart run build_runner build`; przy
  zmianie schematu świadomie podbij `schemaVersion` i dodaj migrację danych.
- Mutacja strony, która ma być cofalna: dodaj `EditorAction` i użyj
  `_applyAction`/`_applyInkAction`; nie mutuj `pages` bezpośrednio.
- Zmiana `DrawingTool`: zachowaj symetrię `_toolFromIndex`/`_toolToIndex` i
  zgodność starych danych.
- Kod platformowy: OCR działa tylko na Android/iOS, a PDF na Linuxie używa
  `pdftoppm`.

## 4. Kod i weryfikacja

Szczegóły stylu są w [AI_INSTRUCTIONS.md](AI_INSTRUCTIONS.md). Minimum:

- `dart format`, linie do 80 znaków, standardowe nazewnictwo Darta,
- klamry przy sterowaniu; UpperCamelCase dla typów, lowerCamelCase dla reszty,
  `_` dla prywatnych; bez `library`, prefiksów `k` i SCREAMING_CAPS,
- importy `dart:` → `package:` → względne, posortowane w sekcjach,
- `///` zamiast `/** */`; komentarze tylko wyjaśniające „dlaczego”,
- nowe teksty UI po angielsku,
- Provider + ChangeNotifier; bez nowego state managera.

Po zmianie uruchom testy proporcjonalne do ryzyka oraz:

```bash
dart format lib test
dart analyze
flutter test
```

Pomocniczo: `flutter pub get`, `flutter run`, a po zmianie workera
`dart compile js -O4 -o web/drift_worker.dart.js web/drift_worker.dart`.
Na Linuxie użytkownik instaluje `zenity` i `poppler-utils`; agent nie używa
`apt`.

## 5. Twarde zakazy

- Nie czytaj całego `notes_database.g.dart`; weryfikuj go przez `rg`.
- Nie edytuj `notes_database.g.dart` ręcznie.
- Nie łącz `DrawingCanvas` z `DocumentDrawingCanvas` ani `PageOverlay` z
  `DocumentPageOverlay` bez zgody użytkownika — używają innych układów
  współrzędnych.
- Nie dodawaj komentarzy typu „added for issue” ani komentarzy opisujących
  oczywiste „co”.
- Nie commituj bez wyraźnej prośby użytkownika.

## 6. Komunikacja

Odpowiadaj krótko po polsku. Linkuj jako
`[lib/foo.dart:42](lib/foo.dart#L42)`. Pytaj tylko wtedy, gdy odpowiedź zmienia
kierunek pracy; drobiazgi rozwiązuj samodzielnie.
