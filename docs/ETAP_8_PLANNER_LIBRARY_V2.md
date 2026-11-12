# Pakiet 5 — scenariusze akceptacyjne v2

1. Urządzenie A w trybie offline tworzy planer z Study Sessions, wydarzeniami
   cyklicznymi oraz zadaniami; B tworzy osobne zadania i foldery. Po połączeniu
   sprawdź zgodne UID, daty, stan zakończenia i historię, także po restarcie.
2. A przenosi `School/Physics` do `Archive`, B zmienia kolor okładki i
   edytuje notatkę w tym poddrzewie. Oba klienty mają ten sam graf folderów,
   bez cykli i bez duplikowania dokumentu.
3. A usuwa zadanie/folder, B edytuje jego starszą wersję offline. Żaden
   zatwierdzony tombstone nie może zostać wskrzeszony.
4. W trakcie importu Local → konto v2 przerwij po zapisie pierwszego planera.
   Ponów po restarcie: nie może przybyć UID, po ACK i CAS import ma domknąć
   checkpoint. Sprawdź Local i obce konto: źródła mają pozostać nietknięte.
5. Ustaw na A motyw, kolor akcentu, rozmiar UI i preferencje backupu; na B
   zastosuj zdalny stan, edytuj niezależną kategorię, sprawdź CAS 409 i
   odtworzenie po restarcie. Nigdy nie wysyłaj `libraryState` przez
   `/v2/account-settings`.
6. Przełącz konta Local → A → B → A przy aktywnych operacjach HTTP:
   spóźnione żądanie nie może zapisać zmian do aktywnego namespace B.

Testy automat.: `test/library_v2_operation_service_test.dart`,
`test/library_v2_operation_integration_test.dart`,
`test/local_account_import_service_test.dart`,
`test/account_settings_sync_service_test.dart`,
`test/planner_revision_sync_service_test.dart` i backend
`test_account_settings.py`. Scenariusz dwóch fizycznych urządzeń wymaga
osobnego testu ręcznego przed produkcyjnym włączeniem v2.
