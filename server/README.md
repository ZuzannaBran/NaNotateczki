# NaNotateczki server

Lekki backend dla PostgreSQL 17 i jednego procesu FastAPI. Udostępnia konta,
wersjonowaną synchronizację dokumentów, trwały dziennik zmian, WebSocket jako
sygnał oraz weryfikowane snapshoty urządzeń. PostgreSQL i Uvicorn nie mają
portów hosta; jedyny port hosta to Caddy na `127.0.0.1:8080`.

## Uruchomienie

1. Skopiuj `.env.example` do `.env` i ustaw trzy różne losowe sekrety.
2. Wpisz przetestowany digest obrazu cloudflared do `CLOUDFLARED_IMAGE`.
3. Utwórz `data`, ustaw właściciela `10001:10001` i prawa `700`.
4. Uruchom `docker compose up -d db`, zastosuj migracje przez
   `scripts/apply-migrations.sh`, potem uruchom `api` i `caddy`. Skrypt
   zapisuje nazwę oraz SHA-256 każdej migracji i odmawia uruchomienia po
   zmianie wcześniej zastosowanego pliku.
5. Rejestrację włącz tylko na czas zakładania konta, następnie ustaw
   `ALLOW_REGISTRATION=false` i odtwórz kontener API.

Nie uruchamiaj `docker compose down -v`. Przed każdą migracją wykonaj
`pg_dump -Fc` oraz kopię `data/` na inny fizyczny nośnik i sprawdź testowe
odtworzenie.

## Backup całego serwera

`scripts/backup-server.sh /mnt/osobny-dysk/nanotateczki` tworzy spójny
`pg_dump -Fc`, archiwum zweryfikowanych snapshotów urządzeń, metadane
wdrożenia i manifest SHA-256. Cel musi być ścieżką absolutną poza katalogiem
projektu. Skrypt nie usuwa starszych kopii.

Zalecany wariant szyfruje wynik przez `age`:

```bash
export BACKUP_AGE_RECIPIENT='age1...public-recipient...'
server/scripts/backup-server.sh /mnt/osobny-dysk/nanotateczki
```

Klucz prywatny trzymaj poza serwerem. Bez `BACKUP_AGE_RECIPIENT` użyj
szyfrowanego nośnika. Co najmniej raz przed wdrożeniem odtwórz kopię na
oddzielnej instancji PostgreSQL i sprawdź `sha256sum --check SHA256SUMS`.

## Testy

```bash
cd server/api
python -m pytest -q
```

Testy z prawdziwym PostgreSQL (izolacja dwóch kont, CAS/idempotencja i restart
procesu podczas synchronizacji) są obowiązkowe przed publicznym wdrożeniem.
Obecne testy jednostkowe nie zastępują tego etapu.
