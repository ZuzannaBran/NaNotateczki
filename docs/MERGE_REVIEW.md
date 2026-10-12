# Przegląd integracji dev / dev_ui / dev_planer

Przegląd z 2026-10-12. Punktem wyjścia jest merge `0a9c40f` na `dev`.
Poprawki pozostają niecommitowane; historia gałęzi nie została przepisana.

## Zakres i sposób porównania

Przejrzano sekwencje commitów od wspólnego punktu `baa88eb`:
`dev_ui` do `2fc7999` (183 wpisy), `dev_planer` do `7ed5f48` (75 wpisów)
oraz przedmerge'owy `dev` do `a6a6936` (40 wpisów). Te liczby obejmują
wspólne commity, poprawki dokumentacji i formatowanie, nie tyle niezależnych
funkcji. Nie uruchamiano każdej historycznej wersji aplikacji osobno.

Porównano końcowy kod źródłowych gałęzi z merge oraz patche serii zmian
UI. Dodatkowe porównanie tokenów Darta pomijało komentarze, whitespace
i końcowe przecinki. Potwierdziło ono m.in., że rysowanie, nakładka tekstu,
motyw, eksport i pomocnik overview z `dev_ui` nie utraciły implementacji
przez formatowanie. Rzeczywiste różnice w edytorach to przede wszystkim
kompaktowy timer z planera; kolor picker został udostępniony katalogowi.
Kod planera i katalogu w punkcie wyjścia odpowiadał końcowemu `dev_planer`:
brakowało adaptacji tych nowych funkcji do ustawień wypracowanych na `dev_ui`.

## Warstwy pracy i zachowany efekt

| Warstwa | Kluczowe commity | Efekt końcowy / decyzja |
|---|---|---|
| Pasek folderów i menu | `28bef0d`, `b7f7227`, `a23b1f4`, `24f5438`, `ee62d6f` | Kotwiczenie do prawej krawędzi panelu, prosty lewy bok, promień 12 px tylko po prawej, nachodzenie na uchwyt bez szczeliny, etykiety 14 px, tekstowe menu dodawania, subtelny cień elevation 4 / alpha 0x44. Zachowane; dodatkowe Edit cover pochodzi z katalogu. |
| Kapsułki i pełny canvas | `68b2f1f`, `8d3c1a5`, `969ebb7`, `56657d1`, `20f89cc`, `a686887`, `855214d`, `89641ac` | Wspólne zwijanie toolbarów, adaptacyjne centrowanie, pełna wysokość i pan pod toolbar, pozycja/centrowanie strony. Bez odtwarzania starszych wersji układu. |
| Strzałki panelów | `fc6c428`, `527f5a3`, `fc6607f` | Centrowanie, 24 px szerokości, obrys i cień; stan toolbaru zachowany po przełączeniu dokumentów. |
| Tryb nocny | `f9c5ca4`, `fda6bff`, `c4c3fed`, `3887a02`, `a6cb197`, `261eeb0` | Persistowane ustawienie, ciemny canvas, odwrócenie jasności HSL wszystkich kolorów, read-only kopia rich text, adaptacja eksportu bez modyfikacji dokumentów. Rozszerzono na katalog, miniatury i planer. |
| Dotyk i overview | `7c8f8c7`, `894e203`, `da6a8d7`, `d7a90ec` | Żywy mnożnik nawigacji, bez wpływu na ink, przewijanie minimapy i kliknięcia na strony. Rozszerzono na nowe scrolle katalogu/planera. |
| Świadomy revert | `16bb77c` | Pionowe toolbary i wybór położenia toolbaru zostały cofnięte na dev_ui; nie przywrócono ich przypadkiem z wcześniejszych commitów. |
| Timery i kalendarz | `9d65da6`, `5c7449b`, `42ae6d5`, `1c734ae` | Trwały timer, Pomodoro / 50–10 / 90–20, Today/Week/Month, edycja i drag/drop. Zachowane. |
| Wygląd i oceny planera | `dae239a`, `a8b7ac4` | Subtelne beżowe akcje, jednorazowe pięć gwiazdek, brak ponagleń po pominięciu oceny. Jasna paleta zachowana; dodano nocną paletę i dziedziczenie typografii. |
| Katalog i okładki | `889ed7a`, `7ed5f48` | Start na kafelkach folderów, miniatury notebook/board, nazwa i menu nad kafelkiem, nagłówek nad treścią, pełny wspólny picker HEX/RGB. Zachowane; dodano nocne renderowanie. |
| dev: dane i platformy | Historia do `a6a6936` | Backup/persistence/eksport oraz istniejąca macierz platform pozostają. Nie zmieniano schematu SQLite, modeli ink ani historii undo. |

## Uzupełnienia integracji

1. Katalog, puste stany, ikony okładek i miniatury respektują motyw.
   Ink i tekst miniatur korzystają z tej samej transformacji co edytor;
   powrót do jasnego motywu wymusza repaint. Obrazy nie są odwracane.
2. Akcje, segmenty, chips, dialogi i kompaktowy timer planera otrzymały
   ciemną paletę. Style kontrolek nie kasują już globalnej czcionki Georgia.
3. Globalne Settings są dostępne również bez dokumentu i z planera.
   Ustawienia rysika/tła pozostają dostępne tam, gdzie istnieje kontroler
   dokumentu; nie tworzono fikcyjnego dokumentu do przełączenia motywu.
4. Czułość dotyku obejmuje katalog, kalendarz, historię, formularz sesji
   oraz przewijany timer w sidebarze i reaguje bez restartu.
5. Wczytywanie planera kończące się po dispose jest ignorowane, zarówno
   dla odczytu poprawnego, jak i błędu. Nie powiadamia usuniętego kontrolera,
   nie zakłada nowego timera i nie zapisuje wtedy odzyskanej historii.

## Dowody regresji i lokalna weryfikacja

- Nowy zestaw UI uruchomiony na kopii kodu `0a9c40f` wykazał cztery
  nieprzechodzące przypadki: ustawienia pustego katalogu, nocny katalog,
  nocne kontrolki/kompaktowy timer i czułość nowych list. Geometria menu
  przechodziła już w tym punkcie: nie cofano jej do starszej wersji.
- Osobno potwierdzono czerwone testy typografii w obu motywach,
  przewijania timera/formularza oraz obu ścieżek load-after-dispose.
  Po poprawkach te testy przechodzą.
- `dart format lib test`, `dart analyze`: zaliczone, bez uwag analizy.
- `flutter test --reporter expanded --timeout 2m`: 201 testów zaliczonych.
- `flutter build linux --debug`: zaliczone. To kompilacja, nie test
  działania natywnych pluginów na wszystkich platformach.
- Przegląd renderów widgetowych: menu folderu/dokumentu/dodawania
  w obu motywach i przy resize, katalog/miniatury oraz planer/dialog sesji.
  Użyto lokalnego Noto Serif jako zamiennika Georgia i fontu MaterialIcons.
  Obrazy kontrolne nie są zatwierdzonymi goldenami ani dowodem identycznego
  rasteryzowania na Windowsie/macOS.

Testy używają SQLite w pamięci i tymczasowego katalogu dokumentów;
nie uruchamiano aplikacji z tymi testami na prywatnej bazie notatek.

## GitHub Actions: faktyczny stan

Odczytano logi [run 38217041689 dla 0a9c40f](https://github.com/ZuzannaBran/NaNotateczki/actions/runs/38217041689).
Analiza/regresje Ubuntu, PNG/PDF, Chrome/web, Android compilation
i iOS compilation były zielone. Bootstrap Linux/Windows/macOS oraz
Android, iPhone i iPad były czerwone z tym samym wyjątkiem
`StudyPlannerController was used after being disposed` w `load()`.
Poprawka wyścigu ma lokalny test odtwarzający dokładnie tę ścieżkę.

Macierz desktop otrzymała osobny krok testów integracji UI/typografii
i cyklu życia planera wykonywany na każdym z trzech systemów. Workflow
planera obejmuje również nowe testy katalogu/integracji.
Nowe lokalne zmiany nie zostały opublikowane, więc nie mają jeszcze
wyniku Actions. Zielonego stanu po poprawce na pozostałych systemach
nie potwierdzono; wymaga kolejnego uruchomienia po commit/push.

## Powtarzalna kontrola ręczna na docelowych systemach

1. Na pustej bibliotece przełącz Settings → Visual → Dark, wróć do
   katalogu, otwórz planer i przełącz z powrotem Light bez restartu.
2. Otwórz menu folderu, notebooka, boarda i `+` przed/po resize panelu,
   także po przewinięciu listy. Sprawdź brak szczeliny, prawostronne
   zaokrąglenia, subtelny cień, Rename/Delete i Edit cover.
3. Otwórz podglądy istniejących kolorowych notatek/boardów w obu motywach;
   sprawdź barwy także po wejściu do edytora i eksporcie. Przełącz motyw
   ponownie i sprawdź, że zapisany dokument nie zmienił kolorów.
4. Utwórz sesję, edytuj czas/datę/technikę, uruchom/pauzuj timer, zwiń
   sidebar, oceń lub pomiń ocenę. Obejrzyj historię w obu motywach
   i sprawdź odtworzenie timera po restarcie.
5. Sprawdź krótkie/wąskie okno, skalowanie systemowe i realny dotyk/rysik
   na docelowym urządzeniu; zmień czułość w Settings bez restartu.

Te scenariusze natywne/hardware nie są oznaczone jako wykonane.
