# Etap 3 — finalizacja integracji edytora v2

Stan na 2026-11-05. Aktywna produkcja pozostaje na v1. Każdy przyrost
jest realizowany na `NaNotateczki/dev`. Żaden punkt nie może być
uznany za zaliczony na podstawie samego dodania testu.

## A. Integralność istniejącego zapisu v2 — pierwszeństwo

- [x] Jeden transakcyjny commit projekcji Drift, actorSeq i outboxu.
- [x] Opt-in `EditorController` bez równoległego `saveNotebook`.
- [x] Trwała blokada v1 dla UID mającego historię operacji v2.
- [x] Korekty remote UI, stron, ink, z-order, podstawowego tekstu Quill.
- [x] Ink `object.move`; obraz `object.move` tylko z referencją assetu.
- [x] LWW właściwości na podstawie trwałej historii operacji.
- [ ] Zweryfikować pełną spójność replay CRDT, formatowania i kolejności
  operacji, także po restarcie i przy równoczesnych edycjach.
- [ ] Zablokować każdą operację powodującą osierocone referencje
  do obrazu, PDF lub osadzonego assetu Quill.
- [ ] Uruchomić `dart analyze` i wąskie testy v2. Nie używać Actions
  do czasu zakończenia etapu 3 (chyba że użytkownik zezwoli).

Warunek zamknięcia A: rollback nie gubi danych ani aktora; ACK nie
odmalowuje; konflikt nie nadpisuje trwającego gestu; restart odtwarza
ten sam stan i trwały outbox.

## B. Kompletny łańcuch plików i Quill

1. Zdefiniować kanoniczne powiązanie `assetId` ↔ SHA-256 ↔
   bajty/pliki na urządzeniu dla Linux, Android, iOS i Web.
2. Ukończony, sprawdzony upload przed `asset.attach`; pobranie
   zweryfikowanych bajtów przed zdalnym renderem.
3. `object.create` obrazu/PDF, `asset.attach`, `object.set`,
   `asset.detach` i `object.delete` muszą mieć jednoznaczny,
   atomowy porządek na serwerze i w lokalnej projekcji.
4. Quill: upload, attach, insert, delete i detach embedów bez
   osieroconych assetów i bez kasowania nadal używanych plików.
5. Testy podmiany/usuń/przenieś, zerwania sieci, ponowienia ACK,
   błędnego SHA-256 oraz ponownego otwarcia notatnika.

Warunek zamknięcia B: bez utraty treści, bez niezweryfikowanych
referencji, bez duplikatów i bez nieodwracalnego kasowania pliku.

## C. Undo/Redo i rozstrzyganie konfliktów

1. Jedna operacja odwrotna na gest (`revertsOperationId`).
2. Ponowne utworzenie po tombstone ma nowy UID; starego UID nie wolno
   wskrzesić. Usuwanie i redo nie mogą omijać walidacji.
3. Odtwarzanie strony, zmiany Quill oraz usuwania bloku w Undo/Redo.
4. Jednoczesne zmiany pola, text atoms, `object.move`, usunięcia
   strony i offline queue — deterministyczny rebase.
5. Testy obu kolejności dostarczenia i dwóch klientów, również przy
   utracie połączenia przed ACK.

Warunek zamknięcia C: ten sam stan na obu urządzeniach i po restarcie,
bez konfliktowych kopii w zwykłym przebiegu.

## D. Integracja produkcyjna i wyłączenie v1

1. Domknąć wszystkie produkcyjne `EditorAction`, strony i zapis
   preferencji/metadanych na operacyjny v2 lub świadomie odseparować.
2. Podłączyć `SyncEngine` i dispatcher do aktywnego edytora, bez
   remountu, przesunięcia zoomu/pan ani dodatkowego snapshot save.
3. Podłączyć backup i jego harmonogram do rzeczywistych commitów
   operacji, respektując tombstones.
4. Sprawdzić staging, lokalną migrację v1→v2, serwerowy protokół i
   jednoznaczną blokadę wersji dla konta.
5. Testy jednostkowe, integracyjne, E2E dwóch klientów, restartów,
   offline i wszystkich platform. GitHub Actions tylko po
   zakończeniu etapu albo za wyraźną zgodą użytkownika.
6. Dopiero po zaliczeniu testów aktywować v2 i usunąć przestarzałe
   produkcyjne writery v1.

Warunek zamknięcia D: aplikacja działa na v2 w produkcji; nie istnieje
równoległy snapshot writer. Każde usunięcie i nowy obiekt są
propagowane na wszystkie urządzenia.

## Zasady pracy

- Żadnej fałszywej deklaracji o zaliczeniu testów bez ich wykonania.
- Każda naprawa błędu wymaga testu regresyjnego.
- Nie tworzyć kopii (1) w rutynowych konfliktach; wyłącznie krytyczna
  sytuacja grożąca utratą danych.
- Kod fail-closed i opt-in nie oznacza gotowego produkcyjnego cutover.
- Nie uruchamiać GitHub Actions bez wyraźnego upoważnienia użytkownika.
