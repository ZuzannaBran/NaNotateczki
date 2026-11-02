# Wdrożenie poprawek backupu, konfliktów i linków share

## Co zostało potwierdzone

- Publiczny `/` zwracał HTTP 200, a
  `/share/d0aeb626-bec2-4246-8cdf-5de894aa9762` puste HTTP 404.
  Ta odpowiedź pochodziła z hostingu przed uruchomieniem Fluttera.
- Klient odrzucał poprawny backup, ponieważ liczył checksumę ponownie
  zakodowanego JSON zamiast oryginalnego payloadu. Różne zapisy liczb mogą
  oznaczać tę samą wartość, ale mają inne sumy SHA-256.
- Poprawiony klient sprawdza sumę całego pliku i oryginalnego payloadu.
  Zachowuje obsługę starszych producentów kompaktowego JSON.
- Niepusta biblioteka może przyjąć brakujące dokumenty. Inna wersja tego
  samego dokumentu dostaje nowy UID i nazwę `Nazwa (1)`, `(2)` itd.
  w tym samym folderze. Tekst, obrazy, kreski i strony mają nowe ID.
  Nie są nadpisywane istniejące dokumenty ani przywracane UID usunięte
  w autorytatywnej historii synchronizacji.
- Foldery są łączone, a zadania konfliktowego planera przypisywane do
  jego kopii. Preferencje mają własny mechanizm wersjonowania i konfliktów;
  nie nadpisujemy ich automatycznie starym snapshotem.

Nie wykonano zmian na produkcyjnym serwerze ani wdrożenia Cloudflare.
Poniższa procedura wymaga dostępu administracyjnego użytkownika.

## 1. Przygotuj pliki na komputerze z projektem

Z katalogu NaNotateczki:

```bash
flutter build web --release --no-web-resources-cdn \
  --dart-define=BACKEND_URL=https://api.nanotateczki.pl
python3 tool/package_cloudflare_web.py
test -s build/web/index.html
test -s build/web/main.dart.js
test -s build/web/sqlite3.wasm
test -s build/web/drift_worker.dart.js
test -s build/web/_redirects
test -s build/web/canvaskit/canvaskit.wasm
test -s build/web/vendor/pdfjs/4.6.82/pdf.min.mjs
test -s build/web/vendor/pdfjs/4.6.82/pdf.worker.min.mjs
test -s build/web/vendor/flutter-fonts/manifest.json
test -s build/web/nanotateczki-release.json
```

Publikowany katalog to **cała zawartość `build/web/`**, łącznie z
`_redirects`, `assets/`, `canvaskit/`, `vendor/`, plikami JS i WASM.
Nie publikuj źródeł `lib/` zamiast builda. Nie mieszaj pojedynczych plików
z dwóch buildów. Alternatywnie wgraj wygenerowany
`build/nanotateczki-cloudflare-<release_id>.zip`: ma `index.html` bezpośrednio
w katalogu głównym, bez nadrzędnego `web/` lub `build/`.
Skrypt nie tworzy paczki, jeżeli brakuje fontów, PDF.js lub wariantu CanvasKit,
albo tabela czcionek nie odpowiada wersji silnika w buildzie.
Aktualny `web/_redirects` jest kopiowany do builda:

```text
/share/* /index.html 200
```

To wewnętrzny rewrite, nie przekierowanie 301/302 do `/`.
Identyfikator sesji musi zostać w pasku adresu.

`web/flutter_bootstrap.js` wymusza lokalny CanvasKit i inicjuje lokalny
PDF.js wraz z workerem i mapami znaków przed startem Fluttera. Gelasio jest
lokalnym fontem UI; pełna tabela fontów zapasowych Fluttera jest w
`vendor/flutter-fonts/`, z oryginalnymi plikami i licencjami. Emoji i inne
alfabety nadal działają, a ich fonty są pobierane z tej samej domeny dopiero
przy potrzebie. Po aktualizacji Fluttera odtwórz tę tabelę poleceniem
`python3 tool/vendor_flutter_fonts.py`, a następnie przebuduj aplikację.
Adresy
uwzględniają `<base href>`, także przy wejściu bezpośrednio w `/share/UID`.
Nie nadpisuj `_flutter.buildConfig` ręcznie: generuje go Flutter.
SDK może nadal zawierać domyślne adresy CDN jako tekst w wygenerowanym JS.
Konfiguracja bootstrapa nadpisuje je lokalnymi adresami; o rzeczywistym
źródle zasobów rozstrzygają żądania w Network i test z zablokowanymi CDN-ami.
Hosting musi zwracać pliki `.mjs` jako JavaScript, a `.wasm` jako
`application/wasm`; odpowiedź HTML zamiast brakującego assetu jest błędem.

Po buildzie wykonaj (Node 22+ i Chrome):

```bash
node .github/scripts/test_web_local_assets.mjs
```

Test uruchamia lokalny serwer i izolowany profil Chrome, blokuje gstatic,
Google Fonts i jsDelivr, sprawdza pierwszą klatkę Fluttera, render PDF przez
rzeczywisty worker, lokalną mapę znaków oraz fonty emoji, japońskie, arabskie
i matematyczne dla `/`, `/share/UID` i `/app/share/UID`.
Nie łączy się z kontem ani nie zmienia danych produkcyjnych.

## 2. Zaktualizuj backend na HP

Poniższe komendy zakładają katalog wdrożenia `/srv/nanotateczki` z
`compose.yaml`, `.env`, `api/`, `migrations/`, `scripts/` i `data/`.
Jeżeli serwer używa innej lokalizacji, zmień tylko tę ścieżkę.
Nie zmieniaj haseł, `JWT_SECRET`, tokenu tunelu ani nazwy projektu Compose.

### Dostarczenie kodu

Przykład uruchamiany na komputerze z repozytorium; zastąp `USER@SERWER`
rzeczywistym dostępem SSH. Najpierw obejrzyj plan kopiowania:

```bash
rsync -av --dry-run \
  --exclude='.env*' --exclude='data/' --exclude='web-dist/' \
  --exclude='backups/' --exclude='.venv/' --exclude='__pycache__/' \
  --exclude='.pytest_cache/' \
  server/ USER@SERWER:/srv/nanotateczki/
```

Po sprawdzeniu uruchom tę samą komendę bez `--dry-run`.
Nie dodawaj `--delete`. Sama aktualizacja `api/` nie dostarcza migracji
ani konfiguracji proxy.

### Backup i migracje

Na serwerze:

```bash
cd /srv/nanotateczki
test -f compose.yaml
test -f .env
docker compose up -d db
docker compose stop api
```

Przed migracją wykonaj kopię na rzeczywistym osobnym nośniku. Przykładową
ścieżkę `/mnt/backup/nanotateczki` zastąp lokalizacją tego nośnika:

```bash
scripts/backup-server.sh /mnt/backup/nanotateczki
```

Skrypt sprawdza manifest SHA-256. Zachowaj podaną przez niego ścieżkę kopii.
Jeżeli kopia nie powstanie poprawnie, nie przechodź do migracji.

Nowa wersja wymaga wszystkich migracji `0001`–`0007`:

- `0004_study_shares.sql` — wspólne sesje;
- `0005_study_share_edit_clock.sql` — zegar scalania;
- `0006_change_events_document_revision.sql` — historia bazowych rewizji;
- `0007_account_settings.sql` — ustawienia konta.

```bash
scripts/apply-migrations.sh
docker compose exec -T db psql -U nano_data -d nanotateczki \
  -c 'SELECT name FROM schema_migrations ORDER BY name;'
docker compose build api
docker compose up -d api caddy
```

Nie edytuj już zastosowanych migracji ani tabeli ich checksum.
Jeśli skrypt zgłosi `Applied migration was modified`, zatrzymaj aktualizację
i przywróć oryginalny plik migracji z wcześniej wdrożonej wersji.

Jeżeli tunel jest zarządzany przez repozytoryjny `compose.public.yaml`,
zachowaj istniejące wartości `CLOUDFLARED_IMAGE` i `TUNNEL_TOKEN`:

```bash
docker compose -f compose.yaml -f compose.public.yaml up -d cloudflared
```

Nie uruchamiaj lokalnego wariantu `compose.local.yaml` jako publicznego
wdrożenia. Nie używaj `docker compose down -v` ani nie usuwaj wolumenu bazy.

Sprawdź:

```bash
docker compose ps
docker compose logs --tail=100 api caddy
curl --fail --silent --show-error https://api.nanotateczki.pl/health
curl --fail --silent --show-error https://api.nanotateczki.pl/ready
```

`/ready` ma zwrócić HTTP 200 z działającą bazą. Anonimowe
`GET /v1/account-settings` ma zwracać 401, nie 404 ani 500. Nie trzeba
włączać publicznej rejestracji ani tworzyć ponownie istniejącego konta.

## 3. Opublikuj frontend i włącz routing linków

Publiczne nagłówki nie identyfikują jednoznacznie produktu hostingu.
Wybierz wariant faktycznie obsługujący domenę `app.nanotateczki.pl`.
Nie zmieniaj domeny API na domenę frontendu.

### Cloudflare Pages

1. Otwórz istniejący projekt w Cloudflare → Workers & Pages.
2. Opublikuj nową produkcyjną wersję z całym `build/web/`, wraz z `_redirects`.
   W integracji Git ustaw katalog wynikowy na `build/web`.
3. Domena niestandardowa projektu ma wskazywać `app.nanotateczki.pl`.
4. Upewnij się, że Functions lub nadrzędny Worker nie przechwytują
   `/share/*` i nie zwracają własnego 404 przed obsługą plików statycznych.
5. Nie dodawaj własnego `404.html` wyłączającego domyślny routing SPA.

Pages obsługuje regułę `_redirects` ze statusem 200:
https://developers.cloudflare.com/pages/configuration/redirects/

### Cloudflare Workers z plikami statycznymi

1. Opublikuj cały `build/web`, z `_redirects`, w istniejącym Workerze domeny.
2. Dla wdrożenia przez Wrangler połącz poniższe pole z istniejącą
   konfiguracją `wrangler.jsonc`; zachowaj jej `name`, powiązania i trasy:

```json
{
  "assets": {
    "directory": "./build/web",
    "not_found_handling": "single-page-application"
  }
}
```

Ścieżka jest względem pliku konfiguracyjnego, więc powyższy przykład zakłada
`wrangler.jsonc` w katalogu głównym aplikacji. Następnie użyj istniejącego
procesu wdrożenia lub `npx wrangler deploy --config wrangler.jsonc`.
Jeśli własny Worker działa przed assets, musi przekazać te żądania do
assets zamiast samodzielnie zwracać 404. Nie zastępuj istniejących bindings.

Dokumentacja:
https://developers.cloudflare.com/workers/static-assets/routing/single-page-application/
https://developers.cloudflare.com/workers/static-assets/redirects/

### Frontend przez Caddy na HP

Repozytoryjny `Caddyfile` już zawiera poprawny fallback:

```caddy
@app host {$APP_DOMAIN}
handle @app {
    root * /srv/app
    try_files {path} /index.html
    file_server
}
```

W `compose.yaml` `./web-dist` jest montowane jako `/srv/app`, a przy
`BASE_DOMAIN=nanotateczki.pl` kontener dostaje
`APP_DOMAIN=app.nanotateczki.pl` oraz `API_DOMAIN=api.nanotateczki.pl`.
Skopiuj całą paczkę do `web-dist/`, z zachowaniem jej struktury, i sprawdź:

```bash
cd /srv/nanotateczki
test -s web-dist/index.html
test -s web-dist/main.dart.js
docker compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile
curl --include --silent --show-error \
  -H 'Host: app.nanotateczki.pl' \
  http://127.0.0.1:8080/share/routing-check
```

Lokalna odpowiedź ma być HTTP 200 z HTML, mimo że `routing-check` nie jest
prawdziwą sesją. Cloudflare Tunnel dla obu domen ma prowadzić do
`http://caddy:8080` przy uruchomieniu w sieci Compose, bez zmiany nagłówka
Host. Sam rekord DNS nie przełącza istniejącego Worker Route na ten tunel.

## Raporty i diagnostyka

Nowe API zawiera:
- `POST /v1/reports/feedback` – anonimowe zgłoszenie użytkownika
  (z limitem żądań);
- `PUT /v1/reports/diagnostics` – zastąpienie snapshotu Errors,
  Data integrity i Optimization, wyłącznie po zalogowaniu.

Pliki dostępne na HP:
- `/srv/nanotateczki/data/feedback/reports.json` – zgłoszenia
  z licznikiem identycznych problemów;
- `/srv/nanotateczki/data/diagnostics/<account-id>/<device-id>.json` –
  ostatnie logi urządzenia. Ten sam plik jest nadpisywany po zmianie.

Nie udostępniaj tego katalogu przez Caddy ani Cloudflare. Może zawierać
ścieżki plików i stack trace. `scripts/backup-server.sh` archiwizuje
teraz całe `data/`, a nie tylko `data/backups/`. Nie jest potrzebna
nowa migracja PostgreSQL. Backend powinien zostać zaktualizowany przed
opublikowaniem frontendu z zakładką Contact the creator.

## 4. Potwierdź wynik po wdrożeniu

Najpierw otwórz `https://app.nanotateczki.pl/nanotateczki-release.json`.
Pole `release_id` musi być identyczne z lokalnym `build/web/nanotateczki-release.json`
i nazwą wgranego ZIP-a. Odpowiedź 404, HTML zamiast JSON lub inny identyfikator
oznaczają, że domena nadal nie serwuje tej paczki. Sprawdź aktywną wersję,
przypisanie domeny do właściwego Workera/Pages i cache hostingu.
Samo poprawne wgranie plików do innego projektu nie aktualizuje tej domeny.

```bash
curl --include --silent --show-error \
  -H 'Sec-Fetch-Mode: navigate' \
  https://app.nanotateczki.pl/share/d0aeb626-bec2-4246-8cdf-5de894aa9762
curl --include --silent --show-error https://app.nanotateczki.pl/sqlite3.wasm
curl --include --silent --show-error https://app.nanotateczki.pl/flutter_bootstrap.js
```

- Link share: HTTP 200 i HTML aplikacji, z identyfikatorem pozostającym w URL.
- WASM: HTTP 200 i `Content-Type: application/wasm`, nie HTML fallbacku.
- Bootstrap: HTTP 200 i JavaScript.
- Następnie otwórz stronę z twardym odświeżeniem lub w nowym profilu
  przeglądarki. Nie czyść IndexedDB ani localStorage profilu z lokalnymi
  notatkami; odświeżenie plików aplikacji nie wymaga usuwania danych.
- Jeśli domena nadal zwraca stary build, sprawdź, do którego wdrożenia
  faktycznie prowadzi domena, oraz cache HTML/JS w Cloudflare.

HTTP 200 strony share nie dowodzi ważności biletu lub sesji. Po uruchomieniu
Flutter ma pokazać formularz hasła; wygasła/unieważniona sesja może wtedy
zwrócić 410 z API. Do testu użyj nowego linku utworzonego po wdrożeniu.

## 5. Kontrola danych na dwóch urządzeniach

1. Na źródłowym urządzeniu zapisz notatkę i wybierz `Back up now`.
   Poczekaj na potwierdzenie weryfikacji.
2. Na nowym profilu drugiego urządzenia zaloguj to samo konto. Sprawdź
   dokument, obrazy, tekst, foldery, preferencje i brak komunikatu o checksumie.
3. W osobnym testowym profilu przygotuj inną lokalną wersję dokumentu.
   Po odzyskaniu obie wersje muszą zostać zachowane, konflikt z sufiksem
   `(1)` w tym samym folderze. Zajęte `(1)` daje następny wolny numer.
4. Sprawdź, że kopia jest dostępna także na kolejnym urządzeniu po sync,
   a nie tylko w lokalnej SQLite pierwszego klienta.
5. Usuń dokument przez konto i potwierdź, że starszy backup go nie wskrzesza.
6. Utwórz świeży link share. Otwórz go bez konta w innym profilu, wpisz
   hasło, edytuj i sprawdź oryginał właściciela. Powtórz po odświeżeniu
   bezpośredniego URL oraz po zakończeniu sesji.

Testy z rzeczywistym PostgreSQL uruchamiaj na osobnej instancji lokalnej
według `server/TESTING.md`. Nie uruchamiaj `smoke-local-api.py` na
produkcyjnej bazie jako zamiennika tych kontroli.
