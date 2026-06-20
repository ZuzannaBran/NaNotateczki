# AGENTS.md

Trwałe instrukcje dla Claude'a (oraz innych agentów AI) pracujących w tym
repozytorium. **Czytaj ten plik na początku każdej sesji.** Plik jest
universalnym kontraktem — stosuje się do wszystkich modeli Claude i, przez
analogię, do Codeksa/innych agentów (zob. [.codex/](../.codex/) i
[.agents/](../.agents/)).

---

## 1. ZASADA ZERO: zacznij od PROJECT_MAP.md

**Zanim cokolwiek przeczytasz w `lib/`, zacznij od
[PROJECT_MAP.md](PROJECT_MAP.md).**

Mapa zawiera dla każdego pliku w `lib/`:
- jednozdaniowy opis odpowiedzialności pliku,
- listę klas/funkcji z numerami linii,
- ostrzeżenia o nieoczywistych zachowaniach (Drift schema, OCR, undo/redo,
  symetria `_toolFromIndex/_toolToIndex` itd.).

Procedura przy każdym zadaniu:

1. Przeczytaj **PROJECT_MAP.md** od deski do deski jeżeli jest to pierwsze
   pytanie w nowej sesji. Jeżeli mapę widziałeś w tej samej sesji, wystarczy
   że wrócisz do interesujących sekcji.
2. Zidentyfikuj plik i przedział linii istotny dla zadania.
3. Czytaj **wyłącznie** ten zakres przez `Read(file_path, offset, limit)`.
   Nie wczytuj całych ~1800-liniowych plików w ciemno.
4. Jeśli nie wiesz gdzie szukać → szybki `grep`/`Bash` po słowie kluczowym
   (nie `Agent`, nie `Explore`, dopóki nie masz hipotezy).
5. Dopiero potem edytuj.

**Kara za zignorowanie mapy:** zżerasz tokeny użytkownika (cały kontekst
projektu to ~10k linii kodu, większość niepotrzebna w jednym zadaniu).
Użytkownik wprost prosił o oszczędność tokenów — traktuj to jako twardy wymóg.

## 2. Aktualizacja mapy

Jeżeli edycja kodu zmienia numerację linii w danym pliku (dodanie/usunięcie
funkcji, przesunięcie klasy, większy refaktor), **w tym samym commicie**
zaktualizuj odpowiednią sekcję w [PROJECT_MAP.md](PROJECT_MAP.md):

- Zmieniły się tylko liczby linii → zaktualizuj numery.
- Dodałeś/usunąłeś klasę lub publiczną funkcję → dodaj/usuń wpis.
- Zmieniła się odpowiedzialność pliku → zaktualizuj opis nagłówka pliku
  i jeśli trzeba sekcję „Kluczowe konwencje".

Drobne zmiany w ciele funkcji bez przesuwania linii — nie ruszaj mapy.

Jeżeli tworzysz nowy plik w `lib/`, dopisz dla niego sekcję w PROJECT_MAP.md
**zanim** zakończysz zadanie. Pliki bez wpisu w mapie nie są „skończone".

## 3. Pre-flight checklist (przed napisaniem `Edit`/`Write`)

- [ ] Otworzyłem PROJECT_MAP.md i wiem, w którym pliku/zakresie pracuję.
- [ ] Wiem czy zmiana wymaga regen Drifta
      (dotyka `lib/data/drift/notes_database.dart`?).
      Jeżeli tak → po zmianie uruchom `dart run build_runner build` i
      świadomie podbij `schemaVersion`, jeśli trzeba zachować istniejące dane.
- [ ] Wiem czy zmiana powinna być undoowalna (mutuje stan strony w edytorze?).
      Jeżeli tak → dodaj `EditorAction` i wywołuj `_applyAction`, NIE mutuj
      stron bezpośrednio.
- [ ] Wiem czy zmiana dotyka `_toolFromIndex`/`_toolToIndex` w
      `notebook_repository.dart` — jeżeli tak, modyfikuj **obie** funkcje
      symetrycznie i pamiętaj o starych danych.
- [ ] Wiem czy zmiana dotyka platform-specific kodu (OCR — tylko Android/iOS;
      PDF na Linuksie — `pdftoppm`).

## 4. Konwencje kodu

Pełen skrót w [AI_INSTRUCTIONS.md](AI_INSTRUCTIONS.md). Streszczenie:

- `dart format` przed commitem.
- Linie ≤80 znaków, klamry zawsze przy `if/for/while/else` (wyjątek: jednolinijkowy `if`).
- UpperCamelCase dla typów, lowerCamelCase dla wszystkiego innego, `_` dla prywatnych.
- Bez `library …;`, bez prefiksów `k`, bez SCREAMING_CAPS.
- Importy: `dart:` → `package:` → względne, sekcje oddzielone pustą linią,
  sortowane alfabetycznie wewnątrz sekcji.
- `///` do dokumentacji, **NIE** `/** */`. Komentuj publiczne API tylko gdy
  dodaje wartość (nie powtarzaj sygnatury).
- Wszystkie nowe stringi UI po angielsku (aktualny UI miesza ang/pl — nie
  pogarszaj, nowe ekrany po angielsku, zgodnie z `EmptyState`/`LibraryScreen`).

## 5. Workflow uruchamiania

```bash
flutter pub get
flutter run                                              # default device
flutter test                                             # smoke test
dart analyze                                             # lint
dart format lib test                                     # formatowanie
dart run build_runner build                              # po edycji schematu Drifta
```

Linux dependencies (instaluj user → nie próbuj `apt` z agenta):
- `zenity` — file picker,
- `poppler-utils` — `pdftoppm` dla PDF.

## 6. Czego NIE robić

- **Nie czytaj automatycznie** `notes_database.g.dart` (ponad 6000 linii kodu
  generowanego przez `drift_dev`). Jeśli musisz coś tam zweryfikować → użyj
  `grep`.
- **Nie konsoliduj** `DrawingCanvas` z `DocumentDrawingCanvas` (ani
  `PageOverlay` z `DocumentPageOverlay`) bez wyraźnej zgody użytkownika —
  to świadome dublowanie ze względu na różne układy współrzędnych
  (board: world = page, notebook: world = document).
- **Nie wprowadzaj** Riverpod/Bloc/innego state managera. Stack to
  Provider + ChangeNotifier — trzymaj się tego.
- **Nie dodawaj** komentarzy w stylu „// added for issue #XYZ" ani opisów
  „what" zamiast „why". Reguła główna: domyślnie zero komentarzy.
- **Nie commituj** bez wyraźnej prośby użytkownika.
- **Nie modyfikuj** `lib/data/drift/notes_database.g.dart` ręcznie.

## 7. Jak komunikować się z użytkownikiem

- Język domyślny: **polski** (użytkownik pisze po polsku).
- Krótkie odpowiedzi, bez podsumowań „co właśnie zrobiłem" na końcu.
- Pliki i linie linkuj jako `[lib/foo.dart:42](lib/foo.dart#L42)` żeby IDE
  umiało przeskoczyć.
- Pytania zadawaj tylko gdy odpowiedź zmienia kierunek pracy — drobiazgi
  rozwiązuj samodzielnie.
