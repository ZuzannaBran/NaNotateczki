# Licencja projektu i komponenty zewnętrzne

## Własny kod NaNotateczki

Kod źródłowy, dokumentacja i oryginalne materiały projektu, do których
licencjodawca posiada odpowiednie prawa, są oferowane na warunkach
[PolyForm Noncommercial License 1.0.0](../LICENSE.md).
Informacja o właścicielu praw znajduje się w [NOTICE](../NOTICE).

Licencja zezwala na używanie, modyfikowanie i dalsze udostępnianie
oprogramowania **wyłącznie w granicach dozwolonego użytku
niekomercyjnego**. Tekst licencji wyraźnie dopuszcza pewne formy użytku
przez instytucje edukacyjne, badawcze, publiczne oraz organizacje
charytatywne, niezależnie od źródeł ich finansowania.

Użytkowanie komercyjne wymaga odrębnej zgody/licencji udzielonej przez
właściciela praw do danego fragmentu. PolyForm Noncommercial jest
licencją source-available, **nie** licencją open source OSI.

Licencja projektu nie zmienia warunków korzystania z cudzych
bibliotek, narzędzi, fontów, kodu wzorcowego ani materiałów graficznych.
W zakresie materiałów, do których właściciel projektu nie posiada
praw, obowiązują licencje ich odpowiednich autorów.

## Sprawdzone główne zależności

Poniższe ustalenia dotyczą wskazanych pakietów używanych w projekcie
(`pubspec.yaml` / `pubspec.lock`) i dostępnych informacji ich autorów.
Są to odrębne licencje, których wymagane noty należy zachowywać.

| Komponent | Licencja / warunki | Źródło |
| --- | --- | --- |
| Flutter framework | BSD 3-Clause | https://docs.flutter.dev/resources/faq |
| flutter_quill 11.5.1 | MIT | https://pub.dev/packages/flutter_quill/license |
| drift | MIT | https://pub.dev/packages/drift/license |
| pdfx 2.9.2 | MIT (wrapper) | https://pub.dev/packages/pdfx/versions/2.9.2/license |
| super_clipboard | MIT | https://pub.dev/packages/super_clipboard/license |
| file_picker | MIT | https://pub.dev/packages/file_picker/license |
| flutter_box_transform 0.4.7 | Apache 2.0 | https://pub.dev/packages/flutter_box_transform |
| pdf | Apache 2.0 | https://pub.dev/packages/pdf |
| sqlite3 / sqlite3_flutter_libs | MIT (pakiety) | https://pub.dev/packages/sqlite3/license |
| google_mlkit_text_recognition | MIT (wrapper) | https://pub.dev/packages/google_mlkit_text_recognition/license |
| PDFium (komponent natywny) | Licencja BSD i dodatkowe noty komponentów | https://github.com/chromium/pdfium/blob/main/LICENSE |

**Dodatkowe warunki:**

- Natywne komponenty Google ML Kit podlegają również
  [warunkom Google ML Kit](https://developers.google.com/ml-kit/terms).
  Licencja wrappera Flutter nie zastępuje warunków SDK.
- W systemie Linux import PDF korzysta z osobno zainstalowanego
  `pdftoppm` (`poppler-utils`). Projekt nie dołącza tego programu;
  jego dystrybucję należy ocenić według odrębnych warunków Popplera.
- Licencje wyżej wymienionych pakietów nie są automatycznie przenoszone
  na sam kod NaNotateczki i na odwrót.

## Przed publikacją binariów

To **częściowy przegląd**, a nie kompletna inwentaryzacja licencji
wszystkich zależności pośrednich (Dart, CocoaPods, Gradle, Rust/Cargo,
Flutter Engine, PDFium) i zasobów. Przed dystrybucją należy:

1. Wygenerować zestawienie licencji dla dokładnych wersji z
   `pubspec.lock` oraz natywnych zależności dla każdej platformy.
2. Udostępnić wymagane teksty licencji i informacje copyright
   wraz z aplikacją. Flutter oferuje do tego m.in.
   `showLicensePage` / `LicenseRegistry`.
3. Sprawdzić pochodzenie obrazów i ikon w katalogach platformowych
   oraz warunki dystrybucji SDK, PDFium i ewentualnie Popplera.
4. Potwierdzić prawa do wszystkich wkładów w oryginalny kod projektu,
   jeśli zostały dostarczone przez zewnętrznych współautorów.

Żaden z powyższych punktów nie oznacza, że cudze komponenty
automatycznie przechodzą na licencję PolyForm Noncommercial.
