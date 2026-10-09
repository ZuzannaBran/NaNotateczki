# CZAT.md

Instrukcje dla czatu programującego bezpośrednio w repozytorium GitHub.
Domyślny język komunikacji: polski. Nie zgaduj: gdy czegoś nie wiesz,
sprawdź repozytorium, a pytaj tylko wtedy, gdy odpowiedź zmienia kierunek
pracy.

## 1. Najpierw mapa

Przed czytaniem `lib/` otwórz cały `PROJECT_MAP.md` przy pierwszym zadaniu w
sesji, a później tylko właściwe sekcje. Następnie:

1. Wybierz z mapy plik i potrzebny zakres linii.
2. Czytaj tylko ten zakres; duże pliki przeszukuj najpierw przez `rg`.
3. Przed edycją uruchom `git status --short --branch` i zachowaj cudze zmiany.

Nie używaj szerokiej eksploracji repozytorium, jeśli szybkie wyszukiwanie daje
wystarczającą hipotezę.

## 2. Aktualizacja mapy

Po zmianie kodu aktualizuj tylko dotknięte wpisy w `PROJECT_MAP.md`: numery
ważnych granic, publiczne symbole, odpowiedzialność i istotne ostrzeżenia.
Każdy nowy plik w `lib/` wymaga wpisu, a ważny nowy test dopisania do
skróconej listy testów. Nie opisuj oczywistych helperów ani każdej metody.

## 3. Zasady zmian

- Zmiana schematu `notes_database.dart` wymaga świadomego podbicia
  `schemaVersion`, migracji danych i uruchomienia
  `dart run build_runner build`.
- Nie czytaj całego ani nie edytuj ręcznie `notes_database.g.dart`; sprawdzaj
  go przez `rg`.
- Cofalna mutacja strony musi używać `EditorAction` oraz
  `_applyAction`/`_applyInkAction`, nie bezpośredniej mutacji `pages`.
- Przy zmianie `DrawingTool` zachowaj symetrię `_toolFromIndex` i
  `_toolToIndex` oraz zgodność zapisanych danych.
- Nie łącz `DrawingCanvas` z `DocumentDrawingCanvas` ani `PageOverlay` z
  `DocumentPageOverlay` bez wyraźnej zgody użytkownika — mają różne
  układy współrzędnych.
- OCR działa tylko na Androidzie i iOS. Import PDF na Linuxie używa
  `pdftoppm`.
- Używaj Provider + ChangeNotifier; nie dodawaj innego systemu zarządzania
  stanem.

## 4. Styl i weryfikacja

- Stosuj standardowy styl Darta, linie do 80 znaków i posortowane importy:
  `dart:` → `package:` → względne.
- Używaj klamer w instrukcjach sterujących, `UpperCamelCase` dla typów,
  `lowerCamelCase` dla pozostałych nazw i `_` dla elementów prywatnych.
- Nie używaj `library`, prefiksów `k`, nazw `SCREAMING_CAPS` ani komentarzy
  opisujących oczywiste działanie. Dokumentację zapisuj jako `///`.
- Nowe teksty interfejsu zapisuj po angielsku.
- Po zmianie uruchom testy odpowiednie do ryzyka, a następnie, jeśli
  środowisko udostępnia Fluttera i Darta:

```bash
dart format lib test
dart analyze
flutter test
```

Jeśli narzędzia lub zależności są niedostępne, nie pomijaj tego po cichu.
Opisz ograniczenie w odpowiedzi i komunikacie commita nie oznaczaj testów
jako zaliczone.

## 5. Commit i push na `dev_ui`

Każdy ukończony zestaw zmian wykonany przez czat musi trafić w osobnym
commicie na gałąź `dev_ui`.

1. Przed pracą upewnij się, że działasz na `dev_ui`, i zsynchronizuj ją przez
   `git pull --ff-only origin dev_ui`, o ile połączenie z GitHubem jest
   dostępne.
2. Po edycji przejrzyj `git diff` i wynik weryfikacji.
3. Dodaj do commita wyłącznie własne pliki, wskazując je jawnie w `git add`.
   Nie używaj `git add .` i nie dołączaj cudzych zmian.
4. Nazwij commit według schematu:

```text
chat: <krótki opis zmiany>
```

5. Wykonaj `git push origin dev_ui` i sprawdź, czy operacja się powiodła.

Nie używaj `--force`, nie przepisuj historii i nie usuwaj cudzych zmian. Jeśli
brakuje uprawnień, połączenia albo synchronizacja wymagałaby merge'a lub
rebase'a, zatrzymaj się i dokładnie opisz użytkownikowi przeszkodę. W
końcowej odpowiedzi podaj zakres zmian, wykonane testy, hash commita i wynik
pushowania.
