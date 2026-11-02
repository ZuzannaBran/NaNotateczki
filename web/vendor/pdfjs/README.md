# Bundled PDF.js

`4.6.82/` contains unmodified files from Mozilla's `pdfjs-dist` npm package,
matching the version required by pdfx 2.9.2. The module, module worker and
all 168 packed character maps are served from the application's origin.
The package and CMap licenses are included. `SHA256SUMS.json` records the
SHA-256 of each upstream file and is checked by Flutter tests.

Source: https://registry.npmjs.org/pdfjs-dist/-/pdfjs-dist-4.6.82.tgz

Archive SHA-256:
`f3dae8939624974de670f28a99babc7df1909fb1e8cf9e3c7606fe57b4d5289d`

Included upstream paths: `build/pdf.min.mjs`, `build/pdf.worker.min.mjs`,
`cmaps/*`, `LICENSE`. Build files are placed directly in `4.6.82/`.
Do not edit vendored files. When updating pdfx/PDF.js, update the module,
worker, maps, licenses and checksum manifest together, then verify PDF
rendering with `.github/scripts/test_web_local_assets.mjs`.
