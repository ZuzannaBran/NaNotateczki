# NaNotateczki — platform testing and regression matrix

Status: expanded release-oriented automated cross-platform suite. This document is a coverage
inventory, not a claim of complete coverage or passing builds. Never describe
a platform as tested until its actual Actions job succeeds.

## Execution policy

- Every push or pull request against `dev`: format, analyze, native unit/widget
  tests (excluding the PNG/PDF renderer) and coverage on Ubuntu; a separate
  render job runs real PNG/PDF export tests with a two-minute per-test limit;
  Chrome-compatible tests and web release build;
  actual desktop app smoke tests and release builds on Linux, Windows and macOS;
  Android debug APK build; unsigned iOS simulator build.
- On pushes to `dev`: Android emulator and iOS simulator run both
  launch-and-bootstrap and isolated document lifecycle integration tests. PRs skip the expensive simulators.
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
- Production regression fixtures: SQLite and portable backup roundtrip of
  styled Quill Delta, binary images, crop fields, bookmarks, multi-page ink;
  page-scoped changes, independent concurrent saves and a backup restore
  into a fresh isolated SQLite database.
- Cloud merge: equal timestamps, older/newer conflicts, independent notebooks,
  duplicate IDs.
- Background settings invalid-value normalization.

### Platform
- Each native desktop device starts real app storage/plugins and reaches
  `LibraryScreen`.
- Same startup integration test runs in Chrome and on Android/iOS simulators
  on pushes to `dev`.
- Production export renderer tests check actual in-memory PNG/PDF output,
  dimensions, content differences and legacy eraser handling. They run in
  `tester.runAsync` to keep engine image encoding outside widget FakeAsync.
  Additional cases cover twelve PNG pages and board PNG/PDF rendering;
  physical file-save dialogs, very large images and pixel-perfect output
  remain separate acceptance scenarios.
- Production SQLite and backup roundtrip tests mock `PathProviderPlatform`
  and use a fresh temporary documents directory for each case.
- Release builds validate compilation of every desktop/web platform.
- Isolated platform integration tests use an explicit opt-in Dart define,
  create/rename/reload/delete a CI document and never run against a personal
  notebook directory without that flag.
- Windows runner uses modern CMake. The root `windows/CMakeLists.txt` sets
  `CMAKE_POLICY_VERSION_MINIMUM=3.5` for CMake 4 child processes invoked by
  legacy `pdfx/pdfium`. A runner test must confirm that this workaround builds
  the application; an upstream pdfx update is the long-term fix.

## Still required before declaring release-level cross-platform coverage

**P0 data integrity and power loss**
- Automated atomic-write interruption coverage: the test harness simulates
  `.previous`/`.tmp` crash windows, failed filesystem writes, backup worker
  cancellation and recovery/retry. These are controlled filesystem faults,
  **not** proof against physical power loss or hardware write-cache failure.
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
flutter test test --coverage # Full local suite (export tests may be slower)
flutter test --platform chrome test/cross_platform
flutter test integration_test/app_smoke_test.dart -d linux
flutter build web --release
```

GitHub Actions: `.github/workflows/cross_platform_tests.yml`. A local Linux
integration run needs an active X display; headless CI uses `xvfb-run -a`.
The browser end-to-end test needs ChromeDriver on port 4444, with the
matching Chrome for Testing binary passed through `--chrome-binary`. Mobile native
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

CI discovery in run 37835178104: Windows/macOS/Linux and Android APK build passed.
The iOS build failed at link time with `Pods_Runner not found`, browser
bootstrap failed because ChromeDriver 155 launched Chrome 154 and Android
emulator could not start Dart Development Service. These results describe
that specific commit, not any later remediation. The CI now disables SwiftPM
**only for iOS jobs**, runs `pod install` explicitly and checks that the
generated workspace contains `Pods.xcodeproj`. An actual successful iOS build
is still required before calling this issue fixed. Emulator DDS remains a
platform/tooling issue to investigate.

## Extended verification after the second CI audit

**Confirmed harness correction:** The production restore test previously kept
two independent Drift database instances open simultaneously in one isolate.
Its source backup worker and database now close before the target database
opens. This removes the test-created overlap; it does not certify that runtime
code is immune to concurrent connection or filesystem problems. Production
connection ownership must still be reviewed separately.

**Coverage gate:** An earlier completed native suite (GitHub Actions run
`37835178104`, artifact `flutter-coverage`) recorded 6436 hit lines out
of 15454 instrumented lines (41.65%). Because the test selection has changed,
the initial required threshold is conservatively set to **35%**. CI fails when
`coverage/lcov.info` is missing, empty or falls below that floor. A successful
new baseline should be used to ratchet the threshold upward; coverage alone
cannot establish correctness.

**WASM versus JS:** A successful `flutter build web --release` does not mean
`flutter build web --wasm` works. The separate `wasm-audit` CI job attempts
the WASM build without blocking the verified JavaScript target and records a
warning plus compiler diagnostics on failure. Dependencies `pdfx` and
`image` were implicated in the prior dry-run warning; they must be evaluated
against an actual compiler dependency trace before dependency changes.
Even a successful WASM build needs a dedicated WasmGC browser runtime test.

**Platform build coverage:** Windows/macOS/Linux Release builds should execute
even if an earlier desktop integration assertion failed; both Debug and Release
Android APKs are compiled. On pushes to `dev`, iOS integration now targets
both available iPhone and iPad simulators. Android integration waits for an
`adb`-visible, boot-completed emulator before testing.

**Low-priority runner diagnostics:** macOS may log
`Failed to foreground app; open returned 1` despite a passing application
test. Android emulator initial `adb` errors can be transient when the boot
eventually succeeds. Treat recurrence as a runner issue until confirmed by
actual user-facing foreground or device behavior. Keep logs for regression
comparison; do not hide unsuccessful integration tests.

**Unverified production acceptance scenarios:** These remain mandatory
manual/device-farm checks, not automatic green CI claims:

- Pen pressure/tilt, palm rejection, side-button, eraser and multi-touch on
  Windows Ink, Linux tablet, Android S Pen and physical iPad Apple Pencil.
- Forced process termination, full disk, interrupted backup/rename, recovery
  from the last valid snapshot, and multiple documents saved concurrently.
- Large real-world notebooks: memory growth, export completion, output
  legibility/page order and document re-import on target OS versions.
- Browser persistence and input in Firefox, Safari and Edge, including storage
  restrictions, refresh and simultaneous tabs.
- Signed iOS/Android release distribution, real-device background/resume and
  OS-driven shutdown behavior.

A release decision requires successful platform jobs *and* recorded results
for the manual cases relevant to the intended distribution targets.

## Run 37845857438 — Android-only failures and remediation

The 8 October 2026 workflow run on `7e5748ac` completed 10 of 12 jobs
successfully: native tests (+133), export (+6), Chrome, WASM compilation,
Linux/Windows/macOS, iOS build and both iPhone/iPad simulators.
Native line coverage was 42.47% (6567/15463), above the 35% gate.
Both Android failures require a fresh verification run:

- Android Release failed in `:app:minifyReleaseWithR8` because
  `google_mlkit_text_recognition` references four optional language
  recognizer libraries missing from the dependency graph. The application
  actually constructs only `TextRecognitionScript.latin`. The Release
  ProGuard file now allows missing symbols only in the unused
  `com.google.mlkit.vision.text.{chinese,devanagari,japanese,korean}`
  packages; shrinking stays active and no unused OCR assets are added.
- The Android emulator failed before running Flutter tests when the
  emulator action executed an incomplete `for` block in separate
  `/bin/sh` commands. Its `script` input now invokes a single
  `.github/scripts/android_emulator_tests.sh` Bash process, which waits
  for a boot-completed device before running both integration tests.

Neither remediation is considered validated until the new workflow runs.
The Android Release artifact currently uses debug signing in
`android/app/build.gradle.kts`; a real distribution requires separate
production signing and installation testing. Although WASM **compiled**
successfully, browser execution of the WASM variant is not yet tested.
The Gradle, AGP and Kotlin compatibility deprecations are future upgrade
items, not the cause of either failure in this run.

## Dependency and CI tooling warnings (non-blocking as observed)

- SwiftPM is enabled by default in Flutter 3.47.6, but currently pinned
  dependencies including `super_native_extensions` lack complete SwiftPM
  support. iOS CI temporarily uses CocoaPods only; macOS keeps its previously
  successful configuration. Revisit migration before removing CocoaPods.
- On Windows, `super_native_extensions 0.8.24` emitted a PowerShell
  `resolve_symlinks.ps1` `Get-Item` warning while the desktop build passed.
  Consider `super_clipboard`/`super_native_extensions` 0.9.x only as a
  separately tested dependency migration, not an unverified hotfix.
- GitHub checkout moved to `actions/checkout@v5` to use Node 24 and avoid
  the deprecated Node 20 runtime warning on hosted runners.
- Render and persistence corrections are test-harness changes, not proof of
  production bugs. Recheck their actual results in the next workflow run.

## Release signing and crash-safety follow-up (9 October 2026)

- Android local publishable Release builds now read private
  `android/key.properties`: `storeFile`, `storePassword`, `keyAlias`,
  `keyPassword`. `storeFile` is relative to the `android/` directory or
  absolute; the keystore and properties are gitignored. Invalid or incomplete
  credentials fail early. Non-CI Release builds without signing credentials
  are rejected. The only debug-signed Release exceptions are CI jobs or an
  explicit developer opt-in `NANOTATECZKI_ALLOW_DEBUG_RELEASE_SIGNING=true`;
  neither is suitable for distribution. The default application id is still
  `com.example.program` and must be selected before publishing, with a
  deliberate plan for compatibility with existing installs.
- iOS Xcode Profile now inherits `Pods-Runner.profile.xcconfig` through
  `ios/Flutter/Profile.xcconfig` instead of incorrectly using Release pods
  configuration. App Store signing still needs a developer team,
  certificates and provisioning profiles; CI simulator builds do not supply
  real distribution signing.
- New tests `storage_crash_recovery_test.dart` and
  `backup_crash_recovery_test.dart` cover recovery from staged atomic file
  replacements, stale temporary files, filesystem errors and backup retry.
  Such test-injected failures do not simulate abrupt machine power removal,
  directory durability (`fsync`) or disk hardware faults. Hardware recovery
  tests remain release acceptance criteria.

## CI warning and DDS diagnostic follow-up (9 October 2026)

- Selected native Dart test suites use suite-scoped mocked documents paths
  to isolate `path_provider` logging and preferences. Editor layering checks
  valid inline image persistence and flushes before closing SQLite.
- Android integration tests retry only once when the Flutter runner reports
  `Failed to start Dart Development Service`. A shell regression verifies
  that unrelated test assertion failures are never retried or accepted and
  persistent DDS startup failures still fail CI. The underlying Flutter tool
  issue remains external.
- Android Gradle Plugin 9 migration requires built-in Kotlin compatibility
  and a cross-platform check of native plugins. Version changes are deferred
  until the diagnostic suite is confirmed by actual GitHub Actions results.
