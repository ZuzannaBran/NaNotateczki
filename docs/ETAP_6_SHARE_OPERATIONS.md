# Etap 6 — Share oparte na operacjach (implementacja przygotowawcza)

## Granica bezpieczeństwa

**Nie przełączać produkcyjnego Share na v2 na istniejących UID.**
`SyncEngine` i API `/v2/operations` istnieją, ale serwer celowo odmawia
zapisu operacyjnego do dokumentu obecnego w `synced_notebooks` (HTTP 409).
Migracja musi jednoznacznie przenieść dokument i zablokować starego writera
snapshotowego (etap 11, z kontrolowanym włączeniem w etapie 13).
Nie uruchamiać jednocześnie `LiveWebSyncService` i `SyncEngine` dla jednego UID.

## Przygotowane elementy

1. `ShareOperationProjection`: czysty reducer per dokument/strona/obiekt,
   kopiowanie tylko zmienianej gałęzi (bez pełnej serializacji JSON),
   trwałe tombstones i wersjonowanie osobnych właściwości operacji
   `document.*`, `page.*`, `stroke.create`, `object.*`.
   Nie przesyła pełnego JSON notebooka i nie dotyka stanu widoku.
2. `PendingShareProjection`: warstwa nakładana na zatwierdzone operacje,
   nie usuwa niepotwierdzonych zmian, gdy nadejdzie nowszy remote lub
   tombstone. Odrzucone rebase pozostaje widoczne w `unresolved`.
   Ten obiekt jest stanem prezentacji, nie zastępuje trwałego outboxu.
3. `OperationTextSequence` (Dart) i `text_sequence.py` (FastAPI):
   deterministyczna sekwencja atomów dla obiektów oznaczonych `objectType: text`, z trwałymi ID,
   kotwicami, porządkiem
   Lamport + actor i trwałymi znacznikami usunięcia. `text.insert` oraz
   `text.delete` są walidowane i odtwarzane na serwerze; zwykłe `object.set`
   nie może nadpisać istniejącego tekstu CRDT.
4. `ShareTextEditAdapter` mapuje zatwierdzony plain-text edit na
   `text.insert/delete` atom po atomie, dzieląc wsady po 256 atomów.
   Nie pozwala zgubić formatowania Quill: nieobsługiwane delty odrzuca.
   Adapter nie jest jeszcze podpięty do lokalnych callbacków edytora.
5. `openSharedGuestOperationDatabase(shareId)` tworzy osobny, trwały
   SQLite WASM/IndexedDB dla pary `shareId` + `guestActorId`. Nie wykorzystuje bazy
   konta, natomiast stary edytor v1 nadal korzysta z pamięciowej SQLite
   i osobnego outboxu v1.
6. `EditorController.applyConfirmedShareObjectPatch` pozwala zaaplikować
   jeden utrwalony obiekt albo usunięcie **bez odmontowania kontrolera**,
   bez resetu zoomu, pan i aktualnej strony. Odmawia, jeśli lokalne zapisy
   lub aktywna edycja wykluczają bezpieczne nałożenie zmiany.
7. `SyncEngine` z etapu 5 zapewnia trwałe ACK, retry, REST catch-up,
   WebSocket hints i izolację `shareId` na transportach v2. Backend
   weryfikuje zakres dokumentu i uprawnienia gościa; odwołanie dostępu
   obowiązuje także przy zatwierdzaniu batcha.

## Nadal nieaktywne / zależności

- Produkcyjny `StudyShareGuestEditor` oraz host nadal przesyłają snapshoty
  przez v1. Nowy projector **nie jest jeszcze połączony** z istniejącym
  `EditorController`, `NotebookRepository` ani `SyncEngine`.
  Nie deklarować braku migania w produkcji.
- Do włączenia potrzebna jest atomowa adaptacja akcji Fluttera na operacje:
  zakończenie rysowania → `stroke.create`, gumka → `object.delete`
  i nowe odcinki, ruch/resize → aktualizacja właściwości,
  Undo/Redo → nowa operacja. `OperationStore` musi utrwalić projekcję,
  outbox i checkpoint w tej samej transakcji, po czym UI aktualizuje tylko
  dotknięty obiekt. Bez tego nowe helpery pozostają opt-in.
- Edytor Quill używa `TextBlock.deltaJson`: before/after plain text musi
  zostać przekonwertowany na atomy tekstu, a formatowanie potrzebuje osobnych
  operacji/CRDT atrybutów. **Nie przesyłać całego `deltaJson` przez
  `object.set` jako zamiennika tekstowego CRDT.** Istniejący tekst wymaga
  jawnej migracji na atomy; serwer zgłasza błąd zamiast go utracić.
- Obrazy/PDF i `asset.attach` nadal wymagają zweryfikowanego kanału assetów
  (etap 9), nie włączać tych operacji bez danych.
- Nietrwałe fragmenty aktywnego stroke'a oraz ich usuwanie po disconnect
  nie są jeszcze podłączone do WebSocket i osobnej warstwy podglądu.
  Nie utrwalać preview w dzienniku operacji.
- Osobne profile aktorów i separacja Local/kont/gościa z etapu 7,
  migracja UID/checkpointów z etapu 11 i finalne E2E z etapu 12
  poprzedzają włączenie produkcyjne.

## Testy i kontrola

Dodane: `operation_text_sequence_test.dart`,
`share_text_edit_adapter_test.dart`,
`share_operation_projection_test.dart`,
`share_operation_guest_database_test.dart` (Chrome/WASM),
`share_editor_object_patch_test.dart`;
serwer: `api/tests/test_text_sequence.py`.

Scenariusz ręczny **do wykonania po migracji**, niezaliczony obecnie:
otworzyć ten sam dokument na hoście i gościu, rysować i usuwać jednocześnie,
zmienić kolor podczas przesuwania, edytować tekst z dwóch urządzeń,
rozłączyć/reconnect Wi-Fi, zamknąć i wznowić kartę gościa, zakończyć share
podczas inflight requestu. Potwierdzić brak duplikatów i migania, identyczny
stan końcowy, niezmieniony viewport oraz brak przywrócenia tombstone.

Zakaz uruchamiania GitHub Actions bez wyraźnej prośby użytkownika nadal
obowiązuje. W środowisku bez Fluttera/Darta oraz zależności backendu nie
wolno raportować nowych testów jako wykonanych.

## Kolejna część etapu 6 — zakończone gesty ink

- `ShareInkEditAdapter` planuje przyrostowe `stroke.create`,
  `object.delete`, `object.transform`, `object.set` i
  `object.reorder` na poziomie UID, bez wysyłania notebooka.
  Walidacja payloadu nie pozwala wysłać uszkodzonej kreski ani
  niemożliwego do obsłużenia narzędzia.
- Zmiana koloru i punktów jest rozdzielona na niezależne właściwości.
  Odległe obiekty nie są dotykane; usunięcie pozostaje tombstonem.
- Naprawiono składnię adaptera tekstu i usunięto kosztowne kopiowanie
  całego CRDT przy zmianie atomu. Testy obejmują Unicode, granicę 256
  atomów, zachowanie poprzedniej projekcji, ink oraz z-order.

**Nadal nie jest to produkcyjne przełączenie v2.**
Adapter jest celowo opt-in: pełna integracja transakcyjna
`EditorController` + `OperationStore`, inicjalizacja projektu z migracji,
transport assetów i testy prawdziwego hosta i gościa są konieczne.
Serwer blokuje współistnienie dwóch writerów (v1/v2) dla tego samego UID.
