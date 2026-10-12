# Linux: uruchomienie i ostrzeżenia GTK

## Schematy z VS Code Snap

W środowisku Ubuntu 26.04.1 / Wayland terminal uruchomiony z VS Code Snap
dziedziczył `GSETTINGS_SCHEMA_DIR` wskazujący
`/home/.../snap/code/268/.local/share/glib-2.0/schemas`.
Poprzedni log uruchomienia zawierał fatalny `GLib-GIO-ERROR`:
brak klucza `antialiasing` w `org.gnome.settings-daemon.plugins.xsettings`.
Schematy użyte przez systemową aplikację nie powinny pochodzić z innego
runtime'u edytora. [Dokumentacja GIO](https://docs.gtk.org/gio/overview.html)
opisuje wpływ `GSETTINGS_SCHEMA_DIR` na wyszukiwanie schematów.

`linux/runner/linux_environment.cc` naprawia to przed utworzeniem
`GtkApplication`, zanim GTK/GIO zbuforuje źródło schematów:

- zmienia tylko wartości zawierające ścieżkę `/snap/code/`;
- wybiera `/usr/share/glib-2.0/schemas` tylko przy istniejącym pliku
  `gschemas.compiled`;
- zachowuje środowisko domyślne i jawne katalogi niezwiązane z Code Snap;
- dotyczy procesu aplikacji i jego dzieci, nie konfiguracji systemowej.

`.vscode/settings.json` ustawia tę samą ścieżkę w nowych terminalach
Linuxa tylko dla tego projektu. Zwykłe uruchomienie:

```bash
flutter run -d linux
```

Zatrzymanie i ponowny start są wymagane po zmianie kodu C++;
hot reload/hot restart Darta nie wykonuje ponownie `main.cc`.

## `gdk_x11_window_get_xid` na Waylandzie

`GDK_IS_X11_WINDOW (window)` oznacza, że funkcja oczekująca okna X11
otrzymała inny typ okna. Lokalna sesja używa Waylanda; jest to zgodne
z problemem zgodności backendów okien. Nie wskazuje błędu SQLite ani
zapisów plików. Funkcja pobiera identyfikator zasobu X11:
[dokumentacja GDK](https://docs.gtk.org/gdk3-x11/method.X11Window.get_xid.html).

Własny runner sprawdza typ ekranu przed swoim wywołaniem API X11;
nie wywołuje `gdk_x11_window_get_xid`. W sprawdzonych źródłach Fluttera
i pluginów również nie znaleziono bezpośredniego wywołania tej funkcji.
Nie ustalono stosu wywołania z działającego procesu użytkownika, dlatego
nie przypisano ostrzeżenia konkretnej bibliotece systemowej/pluginowi.

Sam komunikat nie dowodzi utraty danych ani nie musi zamykać aplikacji;
GTK kontynuował działanie w dostarczonym logu. Nie należy jednak deklarować
go całkowicie nieszkodliwym bez sprawdzenia funkcji, która go wywołuje:
potencjalnie problem może dotyczyć fokusu, dialogu lub integracji systemowej.
Nie wyciszono błędów ani nie wymuszono X11 globalnie — taka zmiana wymaga
sprawdzenia dotyku i rysika.

Jeśli pojawiają się niedziałające dialogi/fokus lub zamknięcie aplikacji,
porównaj na tej samej sesji, o ile dostępny jest XWayland:

```bash
GDK_BACKEND=x11 flutter run -d linux
```

To test diagnostyczny, nie domyślne ustawienie projektu. Zmianę zachowania
trzeba powiązać ze stosem wywołania ostrzeżenia, nie tylko ukryciem logu.

## Wpis backupu i czasy klatek

`[backup] reason=idle ... changed=0 same=3` pochodzi z raportu poprawnie
zakończonego snapshotu. Trzy dokumenty były niezmienione; nie jest to
komunikat o błędzie backupu. `strokes=0` i `pts=0` opisują liczbę obiektów ink
w tym snapshotcie, a nie liczbę tekstów/obrazów. Same liczniki nie pozwalają
ocenić kompletności treści konkretnego dokumentu.

`snapshotMs=962` / `totalMs=977` to czas operacji, nie dowód blokowania
UI przez całą sekundę. `ftTotalMaxUs=190396` i 9/15 klatek powyżej 16 ms
wskazują za to na przycięcia w obserwowanym przedziale. Log debugowy nie
rozstrzyga ich przyczyny; ocenę wydajności należy powtórzyć w `--profile`.
Nie zmieniano mechanizmu zapisu ani backupu w tej poprawce środowiska.

## Testy

```bash
bash .github/scripts/test_linux_environment.sh
dart format lib test
dart analyze
flutter test --reporter expanded --timeout 2m
flutter build linux --debug
```

Sześć testów C++/GLib obejmuje obie lokalizacje schematów Code Snap,
zachowanie jawnego katalogu, innych Snapów i braku zmiennej oraz brak
systemowych skompilowanych schematów. Test ścieżki Code Snap odtworzył
problem przed implementacją korekty i przechodzi po niej. Testy nie
uruchamiają Fluttera, nie otwierają osobistej bazy i nie zmieniają GSettings.
W CI wykonuje je krok `Verify Linux startup environment` macierzy desktop.

Kontrola ręczna na natywnym Waylandzie: uruchom bez prefiksu, sprawdź
tworzenie/rename, ustawienia, systemowe otwieranie/zapisywanie pliku,
schowek oraz fokus klawiatury. Dla realnego dotyku/rysika sprawdź także
pan, przyciski i nacisk. Te scenariusze nie są zaliczonym testem
automatycznym i nie wymagają wyłączania ochrony zapisu przy zamknięciu.
