# NaNotateczki — platform testing and regression matrix

Status: initial automated cross-platform suite. This document is a coverage
inventory, not a claim of complete coverage or passing builds. Never describe
a platform as tested until its actual Actions job succeeds.

## Execution policy

- Every push or pull request against `dev`: format, analyze, native unit/widget
  tests and coverage on Ubuntu; Chrome-compatible tests and web release build;
  actual desktop app smoke tests and release builds on Linux, Windows and macOS;
  Android debug APK build; unsigned iOS simulator build.
- On pushes to `dev`: Android emulator and iOS simulator run the
  launch-and-bootstrap integration tests too. PRs skip the expensive simulators.
- The `schedule` and `workflow_dispatch` triggers are inactive until the
  workflow also exists on default branch `main` (GitHub Actions requirement).
  No file is committed to `main` by this change.
- Browser smoke test installs a Chrome/ChromeDriver matched pair and uses
  `flutter drive`; browser-compatible
  Dart tests run under Chrome, **not** in the native Dart VM.
- Real pen hardware, OS shutdown, device permissions, native pickers and
  camera/OCR workflows still require manual/device-farm tests.
- CI tests are failure detectors; a green CI run is not proof that unknown bugs
  cannot occur.

## Platform coverage

| Platform | Logic/widget | Native app | Build | Input/peripherals |
|---|---|---|---|---|
| Linux | VM suite | Xvfb integration | Release | Real stylus manual |
| Windows | VM suite on Ubuntu; Windows smoke | Windows integration | Release | Windows Ink manual |
| macOS | VM suite on Ubuntu; macOS smoke | macOS integration | Release | Trackpad manual |
| Web / Chrome | Browser-compatible suite | ChromeDriver integration | Release | Clipboard and Safari/Firefox/Edge manual |
| Android | VM suite on Ubuntu | Emulator integration nightly | Debug APK | S Pen, pressure, OCR manual |
| iOS / iPadOS | VM suite on Ubuntu | iPhone simulator nightly | Simulator | Apple Pencil, OCR and iPad UI manual |

A build only checks compilation. Unit/widget tests use test bindings and do
not validate native platform plugins. An emulator/simulator has different input,
timing, filesystem and GPU behavior from physical hardware.

## Current automatic regression checks

### Ink and erasers
- Point/brush/scratch/area modes; fragment IDs; legacy eraser flattening;
  persistent storage, undo and restore (existing tests).
- Seeded, repeatable stress sequences with ID uniqueness and never-resurrected
  IDs after dozens of consecutive erase gestures.
- Consecutive erasures of neighboring strokes; no resurrection when the second
  erasure crosses the earlier erasure region; repeat-erasure idempotence.
- Spatial index rebuilt for a changed stroke collection.
- Erase → lasso move → save → reopen; undo/redo multiple erasures.

### Geometry, editors and viewport
- Board scene bounds frozen during transforms (existing tests).
- Object transform cancel/restart, world coordinate moves, reversed gestures.
- Top edge and move grabber have non-overlapping hit zones for small, medium and
  large objects; simulated stylus and touch gestures; cancel does not commit.
- Controller viewport is frozen while an object transforms.
- Text edit/resize/formatter behavior and responsive page constraints
  (existing tests).

### Persistence
- SQLite integrity, corrupted rows, strict JSON import, version migration,
  interrupted backup, content hashes, partial manifests, asset loss, dirty-page
  snapshots, recovery (existing tests).
- Exit flush coordinator drains all dirty editors, skips clean/unregistered
  editors and propagates failures.
- Exit-contact waiter handles two simultaneous contacts.
- Library lifecycle: no notification after dispose while data is still loading.
- Cloud merge: equal timestamps, older/newer conflicts, independent notebooks,
  duplicate IDs.
- Background settings invalid-value normalization.

### Platform
- Each native desktop device starts real app storage/plugins and reaches
  `LibraryScreen`.
- Same startup integration test runs in Chrome and on Android/iOS simulators
  on pushes to `dev`.
- Release builds validate compilation of every desktop/web platform.
- Windows runner uses modern CMake. The root `windows/CMakeLists.txt` sets
  `CMAKE_POLICY_VERSION_MINIMUM=3.5` for CMake 4 child processes invoked by
  legacy `pdfx/pdfium`. A runner test must confirm that this workaround builds
  the application; an upstream pdfx update is the long-term fix.

## Still required before declaring release-level cross-platform coverage

**P0 data integrity and power loss**
- Platform-specific filesystem fault injection: full disk, permissions,
  interrupted fsync, locked database, process killed between write/rename.
- Race tests: concurrent editor saves, undo/save, ink activity while backup
  worker interrupts, an exit attempt while backups are queued, backup error
  followed by retry; restore after forced shutdown.
- Persist/reload precise text deltas, image crop, multiple pages and bookmarks
  with binary file assets across both SQLite variants (native and web).
- Upgrade testing from historical production database and backup fixtures.
- No tests must write to a person's production notebook directory.

**P0 input and rendering**
- Multi-touch/palm rejection against actual graphics tablet and touch screen.
- Device stylus buttons, inverted stylus, double-tap, pressure, tilt and
  contact cancellation; Linux GTK pointer data, Windows Ink, Apple Pencil.
- Rendered image/pixel comparisons for active vs committed pen/highlighter,
  scaling, pressure and eraser, and visual goldens at each target pixel ratio.
  Goldens need separately approved reference images per renderer/platform.
- Benchmark thresholds for input-to-paint latency and frame duration under
  100, 1000 and 10,000 strokes; performance hardware baselines.

**P1 editor behavior**
- Full-board screen gesture tests with origin changes while resizing objects
  through zoom and scrolling, not only a standalone scene resolver.
- Selection / move / resize for all image/text/PDF block types under multiple
  zoom levels, including very small frames and overlapping touch targets.
- Clipboard copy/cut/paste of text, images and selection; pasted images remain
  behind ink and text; keyboard shortcuts do not fire inside EditableText.
- Multiple pages: lasso across page boundary, insertion and deletion, zoom,
  overview navigation, undo/redo and persistent reorder.
- Property-based tests generating thousands of valid interaction sequences
  and checking serialization invariants, uniqueness of IDs and history rules.

**P1 import/export/cloud**
- Actual PDF/PNG output: valid magic bytes, page order, dimensions, ink/images,
  text layout, no blank export and no remnants of legacy erase masks.
- Linux `pdftoppm` and alternative platform PDF renderers.
- Image pickers, native OS file permission dialogs, clipboard MIME formats.
- OCR enabled Android/iOS only; explicit unsupported behavior on desktop/web.
- Cloud path rejection, malformed remote file, conflicts with renamed/deleted
  notebook, inaccessible cloud folder, and partial sync writes.

**P2 platform and accessibility**
- Web persistence after browser refresh, denied IndexedDB access, storage quota
  exceeded, two tabs editing simultaneously, Safari/Firefox/Edge behavior.
- Desktop minimize/reopen/close, OS logout/shutdown, HiDPI multi-monitor.
- Accessibility, scaling, IME, keyboard navigation, screen-reader semantic
  labels, RTL and different locales.
- Mobile rotation, split-screen/multitasking, memory pressure and background/
  resume. iPad layouts must be verified separately from iPhone simulator.
- Upgrade CI to device farms for hardware, browsers and screen dimensions.

## Commands

```bash
flutter pub get
dart format --output=none --set-exit-if-changed lib test integration_test test_driver
dart analyze
flutter test test --coverage
flutter test --platform chrome test/cross_platform
flutter test integration_test/app_smoke_test.dart -d linux
flutter build web --release
```

GitHub Actions: `.github/workflows/cross_platform_tests.yml`. A local Linux
integration run needs an active X display; headless CI uses `xvfb-run -a`.
The browser end-to-end test needs ChromeDriver on port 4444. Mobile native
integration tests must run with an emulator, simulator or real device connected.

## Evidence requirements

For each release, record: tested commit SHA, workflow run URLs, each job's
pass/fail result, exact Flutter/Dart/Xcode/Android versions, coverage report,
hardware test results and unresolved regressions. Do not equate 100% line
coverage with exhaustive functional coverage.

The test suite was authored via a GitHub connector, without a local Dart/Flutter
runtime. Actual GitHub Actions results, not this plan, are the evidence for
compilation and runtime validation. Initial CI uncovered a disposal race in
LibraryController, legacy pdfx/pdfium Windows CMake incompatibility and a
too-strict test assumption about spatial-index broadphase candidates. All
three are tracked via committed changes; subsequent Actions must confirm them.
