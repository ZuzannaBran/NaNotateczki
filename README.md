# Effective Dart: Style - najwazniejsze zasady

Zrodlo: https://dart.dev/effective-dart/style

Ten skrot jest po to, zebym zawsze trzymal sie jasnych, powtarzalnych zasad przy tworzeniu aplikacji w Dart.

## 1) Nazewnictwo (Identifiers)
- Typy (klasy, enumy, typedefy, type param): UpperCamelCase.
- Extensiony: UpperCamelCase.
- Pakiety, katalogi, pliki: lowercase_with_underscores.
- Prefiksy importow: lowercase_with_underscores.
- Pozostale identyfikatory (zmienne, funkcje, parametry): lowerCamelCase.
- Stale: preferuj lowerCamelCase (SCREAMING_CAPS tylko gdy musisz dla zgodnosci).
- Skroty >2 litery kapitalizuj jak slowa (Http, Uri). Dwuliterowe skrzoty zostaja wielkimi literami (ID, UI).
- Nieuzywane parametry w callbackach: uzywaj _ jako wildcard.
- Nie uzywaj wiodacego _ dla identyfikatorow, ktore nie sa prywatne.
- Nie uzywaj prefix letters (np. kDefaultTimeout).
- Nie nazywaj bibliotek (library my_library;).

## 2) Kolejnosc dyrektyw (Ordering)
- Najpierw importy dart:, potem package:, potem importy wzgledne.
- Eksporty po wszystkich importach, w osobnej sekcji.
- Sekcje sortuj alfabetycznie.
- Sekcje rozdzielaj pusta linia.

## 3) Formatowanie (Formatting)
- Zawsze uzywaj `dart format`.
- Gdy formatowanie wychodzi slabo, uprosc kod (dziel wyrazenia, skroc nazwy, wynies do zmiennych lokalnych).
- Preferuj linie do 80 znakow.
- Uzywaj klamer przy wszystkich instrukcjach sterujacych przeplywem (if/for/while/else),
  wyjatek: pojedynczy if bez else w jednej linii moze byc bez klamer.

## 4) Dokumentacja (Doc comments)
- Uzywaj `///` do dokumentowania typow i memberow (zamiast `/** ... */`).
- Dokumentuj publiczne API; prywatne tylko gdy ulatwia zrozumienie.
- Zacznij od jednoliniowego podsumowania z kropka, potem pusta linia i detale.
- Unikaj nadmiarowosci (nie powtarzaj tego, co wynika z sygnatury).
- Dla funkcji z efektem ubocznym startuj od czasownika w 3. osobie ("Starts", "Connects").
- Dla wartosci: rzeczownik; dla bool: "Whether ...".
- Nie dokumentuj jednoczesnie gettera i settera tego samego pola.
- Uzywaj nawiasow kwadratowych do referencji (np. [Duration.inDays]).

## 5) Komentarze (Comments)
- Komentarze formatuj jak zdania: wielka litera, kropka na koncu.
- Nie uzywaj komentarzy blokowych do dokumentacji (/* ... */).
- Doc commenty umieszczaj przed adnotacjami (metadata).
- Markdown stosuj oszczednie, HTML unikaj.

## 6) Minimalny checklista przed commitem
- Nazwy zgodne z regulem (UpperCamelCase/lowerCamelCase/lowercase_with_underscores).
- Importy i eksporty w poprawnej kolejnosci.
- `dart format` uruchomiony.
- Brak dlugich linii i "dziwnych" zlaman.
- Brak wiodacych podkreslen tam, gdzie nie oznaczaja prywatnosci.
