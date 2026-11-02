# Flutter fallback fonts

These unmodified WOFF2 files mirror the font table in Flutter 3.47.6's
engine (`692136cb6582dbfc5af3fb33c2515a069f2f66d0`). All 724 Noto subsets,
including emoji and multilingual scripts, and the engine's default Roboto
font are retained. Gelasio remains the application's UI font.

`manifest.json` records the engine revision, the SHA-256 of its fallback
font table, and each font's SHA-256. Paths match the engine's original
`https://fonts.gstatic.com/s/` paths, served instead from this directory
using `fontFallbackBaseUrl`. Fonts are fetched only when needed, not all
at application startup.

Regenerate from the installed Flutter SDK when updating Flutter:

```bash
python3 tool/vendor_flutter_fonts.py
```

The original fonts remain under their original licenses: SIL OFL 1.1 for
Noto and Noto Color Emoji, Apache 2.0 for this version of Roboto. Full
license notices are included alongside the checksum manifest. Font files
retain the original metadata; they have not been renamed or modified.
