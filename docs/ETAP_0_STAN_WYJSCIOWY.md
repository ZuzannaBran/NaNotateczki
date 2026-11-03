# Etap 0 — stan wyjściowy (3 listopada 2026)

**Repozytoria:** `NaNotateczki/dev` i `NaNotateczki-serwer/main`.
Punkty odniesienia przed zmianami:
`59f1a356f2938c9838b6ca2c4aef0a1f4966a4c2` (aplikacja) oraz
`0ef32363bd254bccac8badeae82dc9a9855fcc75` (serwer).

## Obecne zachowanie

| Zdarzenie | Zapis lokalny | Synchronizacja / ryzyko |
| --- | --- | --- |
| Utworzenie notatnika lub boardu | `createNotebook` / `createBoard` nadają UID i zapisują stronę przez `saveNotebook`. | Callback zgłasza zmianę backupowi i live sync. |
| Dopisanie, usunięcie lub przesunięcie elementu | `saveNotebook` zapisuje stan SQLite, kasując i ponownie wstawiając rekordy potomne stron. | REST przesyła pełen notebook z `expectedRevision`; nie istnieje jeszcze dziennik indywidualnych operacji. |
| Usunięcie notatnika | `deleteNotebook` archiwizuje poprzedni stan (poza Web) i atomowo kasuje rekordy w SQLite. | Serwer zachowuje tombstone; `restoreDeleted` legacy nie może odtworzyć usuniętego UID. |
| Backup | Lokalny format v6 z checksumami; zdalny v2 przechodzi `pending/upload/finalize/verified`. | Backup pozostaje oddzielnym archiwum; obecny klient nadal próbuje odzyskiwać backup przy starcie konta. |
| Share | Gość ma roboczą bazę w pamięci i osobny outbox snapshotów. | Serwer odbiera całe JSON przez `PUT /v1/study-shares/{id}/document`, scala zawartość i sygnalizuje WebSocket. Nie jest to jeszcze sync przyrostowych operacji. |
| Kalendarz / Study Sessions | Wpisy mają własne ID i tombstones. | Osobny feed planera; usunięty wpis nie może być odtworzony przez spóźniony PUT. |

## Usunięte problemy bazowe

- Naprawiono niezdefiniowane `notifyChanges` w atomowym restore oraz
  faktyczne stosowanie parametru podczas atomowego importu. Dodano testy
  domyślnych powiadomień, wyciszenia i błędu transakcji.
- Kanoniczny backend to **`NaNotateczki-serwer/main`**. Katalog
  `NaNotateczki/server/` jest tymczasowym lustrem zgodności testów; jego
  implementacja i wspólna dokumentacja zostały uzgodnione z kanonicznym
  repo. `tool/check_server_mirror.py` umożliwia kontrolę i świadome
  odświeżenie lustra.
- Serwer główny chroni tombstones notatników, planera i udostępniania,
  udostępnia `GET /v1/time`, a nowa baza inicjalizuje rolę `nano_app`.
- Zachowano testy regresyjne `restoreDeleted`, skew zegarów planera,
  API czasu i sortowania backupów według `verified_at`.
- Zastosowano 17 dokładnych zmian formatowania Darta z wcześniejszego
  raportu formatera.

## Weryfikacja

**Odczyt istniejących wyników, nie nowy przebieg GitHub Actions:**
uruchomienie `41572215382` zgłosiło błędne `notifyChanges`,
formatowanie 17 plików i nieprzechodzący test `restoreDeleted`.
Z kolei wcześniejszy przebieg kanonicznego backendu
`41565946768` zakończył się pomyślnie.

**Nie zweryfikowano jeszcze lokalnie testów Flutter/Python/E2E.**
Środowisko wykonawcze tej sesji nie ma Fluttera, Darta, Dockera ani
lokalnych klonów prywatnych repozytoriów; brak też `asyncpg`.
Inspekcja kodu i poprzednie CI nie zastępują nowego przebiegu testów.

Po pobraniu aktualnego `dev` i `main` należy wykonać lokalnie:

```bash
dart format --output=none --set-exit-if-changed lib test integration_test test_driver
dart analyze
flutter test
python3 tool/check_server_mirror.py ../NaNotateczki-serwer
# W katalogu NaNotateczki-serwer, w środowisku z zależnościami:
python3 -m pytest api/tests
```

Dodatkowo wymagane pozostają testy HTTP i WebSocket z prawdziwą bazą
PostgreSQL i dwoma klientami. Bez nich nie uznajemy ochrony przed
miganiem i utratą niezależnych edycji za potwierdzoną.

## Ograniczenia przekazane do kolejnych etapów

1. Pełne snapshoty mogą nadpisać niezależne zmiany w niesprawdzonych
   przypadkach; należy przejść na dziennik operacji.
2. Share wysyła pełne dokumenty i ma ograniczoną trwałość outboxa gościa.
3. Restore backupu i live sync nadal wymagają separacji ról oraz checkpointów.
4. Dane kont i Local nie mają jeszcze osobnych baz (opis w `data.md`).
5. Przenoszenia zmian podczas gestu, offline, crashu i reconnect
   wymagają testów rzeczywistych urządzeń, nie tylko mocków.
