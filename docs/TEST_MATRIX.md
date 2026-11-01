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
- Real pen hardware, OS shutdown, device permissions and native pickers still
  require manual/device-farm tests.
- CI tests are failure detectors; a green CI run is not proof that unknown bugs
  cannot occur.
- The desktop matrix also runs merged catalog/planner UI, typography and
  planner lifecycle regressions directly on Linux, Windows and macOS.

## Account and study timer typography (November 2026)

Automated regression: `test/library_account_slot_test.dart` checks that
account dialog titles and profile title use
`AppHeaderDivider.titleStyle` (18 px, weight 600), the same style as
`Study timer`. The account footer name instead matches document labels
(14 px, weight 400). Account status and mode details use the small 12 px
secondary style; `AppTheme.light` and `AppTheme.dark` both prefer
Georgia, followed by Gelasio, Noto Serif, DejaVu Serif, Liberation Serif,
Times New Roman and the generic serif. The shared order applies to normal
and primary text themes and default text-block previews. Structural tests
do not prove a particular font is installed or rendered on a given OS.

Repeatable manual acceptance on Linux, Windows, macOS and browser:

1. Open the sidebar with a signed-in account. The name must match a
   document label (14 px, normal weight), not the bold Study timer title.
   The backup status must match the timer subtitle (12 px).
2. Open account settings and the Sign in, Create account, Local mode and
   Change password dialogs. Titles must match the timer heading; labels
   stay above inputs at 14 px, including after typing. In the initial
   dialog there must be a single NaNotateczki title, with Welcome in
   the paragraph below, rather than two competing title blocks.
3. In light and dark themes, check the account profile title (18 px),
   mode and sync descriptions (12 px), and secondary section headings.
4. Repeat at a narrow sidebar, mobile drawer and 75–150% UI scale.
   Confirm the footer has no avatar, the account name starts 14 px from
   the left edge (like the timer header), and status text is aligned
   with the name. Long account names must elide instead of overlapping
   the 18 px settings icon. Local mode and signed-out states have
   their own status text.
5. Compare the same screen on Linux and web. If Georgia is unavailable,
   both timer and account must fall back to the same serif family.
6. On Linux and Android without Georgia, compare text in the library,
   calendar, account dialogs and a default editor text block. Check the
   sentence "Zażółć gęślą jaźń" in light/dark modes, online and offline.
   Verify a consistent serif appearance without missing Polish glyphs.
   Repeat on Windows/macOS/iOS with Georgia installed and verify it remains
   preferred. Do not mark device rendering as tested without running it.

The folder tree also has a regression in
`test/library_screen_responsive_layout_test.dart` and
`test/library_sidebar_drag_drop_test.dart`. Folder, notebook, board
and planner type icons must not appear in tree rows or drag feedback.
Expand/collapse chevrons and three-dot action menus must stay visible.

Manual checks: expand and collapse nested folders, open each document
kind, long-press and move a folder or document, and open its action menu.
Check readable indentation in both themes, on desktop and in the
mobile drawer. Do not count these checks as passed without execution.

## Persistent account session (November 2026)

Automated regression: `test/account_session_controller_test.dart` uses a
fake credential store. It covers token rotation and a second application
session without a login dialog, offline restarts without loss of refresh
credentials, and deletion of rejected credentials or on logout. It does not
validate real platform secret storage.

Manual acceptance on Linux, Windows, macOS, Android, iOS and HTTPS Web:

1. Complete the first-run onboarding, sign in and fully restart the app.
   The library must open without a login dialog and account status must
   show the same signed-in username.
2. Restart without Internet: local notebooks must remain accessible
   without a modal; after network restoration reauthenticate from
   account settings if needed.
3. Change password, quit and reopen: the old refresh credential must
   not restore access. Repeat after logging out or switching to local.
4. On Web, verify a browser restart with the same origin and profile.
   First sync still requires explicit safe policy selection; auto-login
   must not automatically select upload/download/merge.
5. Linux requires `libsecret-1-dev` to build, `libsecret-1-0` and
   an available GNOME Keyring/KWallet/Secret Service at runtime.
   Windows builds with this plugin require Visual Studio C++ ATL.
   Run `flutter pub get` after adding the dependency. A missing
   secure store must not prevent local notebook use.

These checks are not marked as passed without execution.

## Image and imported PDF transform gestures (October 2026)

Synthetic pointer regression: `test/image_pdf_transform_regression_test.dart`
sends real Flutter touch contacts through the selected object and notebook
viewport. It verifies that one finger always moves the object, two fingers
transform neither the object nor the frozen canvas, and the HUD does not
start a competing multitouch transform. The suite also covers off-page
handles, undo/redo, corner scaling, side cropping, the always-active move
handle, selection only in Move, taps across the full selected frame,
deselection outside the frame or after changing tools, and the long-press
Copy menu without OCR actions.
PDF pages in the editor are rasterized image blocks; this is not a native
PDF-render throughput benchmark.

Manual checks on touch-capable Linux/Windows laptops, Android and iPadOS:

1. Insert a photo and select it in Move. Move it with one finger with finger
   writing both enabled and disabled. The result must be identical.
2. Place two fingers on the selected object or with the second outside its
   frame. Confirm that neither the object nor the canvas moves or scales.
3. Import a multipage PDF and repeat on a page represented as an image;
   drag the object partly outside notebook bounds and resize from handles.
4. Repeat on a board and notebook at 50%, 100%, 125% and 200% zoom,
   in portrait and landscape orientations. Verify consistent dimensions.
5. Cancel a gesture (e.g. OS interruption), undo and redo the resize,
   save/reopen, and verify that the prior geometry is restored.
6. Hold both fingers and perform 30–50 movements on a large imported PDF
   page. The frame, pixels and canvas must remain fixed without an error
   flood. Deselect the object or switch documents mid-touch; no
   setState-after-dispose.
7. Without an active image selected, verify two-finger canvas pan/zoom
   still works normally.
8. Tap the center and near every inner edge of the selected frame. Selection
   must remain until tapping outside the full frame or switching from Move.

These manual checks require physical touch hardware and are not recorded
as passed until they are actually executed.

## Shape placement and temporary Move (October 2026)

Automated regression source: `test/shape_edit_test.dart` covers shape
handles, geometric resizing, moving, hit testing, undo/redo and restoring the
previous tool on both notebook and board. It must be executed before claiming
a passing platform result.

Manual checks on Linux, Windows, macOS, Android, iOS/iPadOS and web:

1. Choose each shape from the toolbar and draw it. The editor should switch
   to Move, select the new shape and show two endpoint handles for lines and
   thin arrows, three vertex handles for triangles, four corner handles for
   rectangles/squares, four axis handles for ellipses/circles and three
   controls for block arrows.
2. Drag inside a closed shape or along a line to move the entire object.
   Drag each handle to modify its geometry; squares and circles must keep
   equal width and height. Use stylus, mouse and touch where supported.
3. Draw Pen/Highlighter ink and hold to snap a straight line, rectangle or
   ellipse. Releasing must select the recognized shape in Move. Tapping
   outside it must restore Pen/Highlighter, or the original toolbar shape.
4. Undo/redo shape moves and edits, then save/reopen: geometry, colors and
   tool type must persist. Repeat at 50%, 100% and 200% zoom.
5. While dragging a handle, confirm the document viewport does not pan or
   scroll. Outside the selected shape, ordinary navigation must work.
6. Verify ordinary pen strokes, lasso, eraser and text/image transforms are
   unaffected. Repeat in light/dark modes, notebook and board.

These checks are a manual test plan, not a claim of tests already run.

## Android finger-ink acceptance (October 2026)

Automated regression: `test/android_finger_ink_test.dart` injects Android-like
touch contact ellipses (major radius 34 logical px) at a phone viewport,
for both notebook and board. It verifies that Off draws with a single finger,
On ignores fingers but accepts a stylus, two stationary contacts create no
dots, finger writing resumes after multi-touch, and an incoming stylus
supersedes a resting finger. This is synthetic pointer
testing, not a claim of verification on a physical phone.

Manual checks on a physical Android phone (repeat on iPhone/iPad and
Windows/Linux touchscreens when hardware is available):

1. Open a notebook and a board, set **Pointer input / Off** (finger allowed),
   select Pen, and draw several strokes with one finger, including slow
   strokes and starting in the middle of the canvas. Confirm strokes persist.
2. Set **On** (stylus only): a finger must navigate rather than create ink;
   a supported pen must still draw.
3. Return to **Off**: rest two fingers without moving them. They must not
   create dots. Lift them and draw with a single finger immediately.
4. With a stylus touching the canvas, rest part of the hand on the screen;
   it must not generate strokes, interrupt existing stylus ink or select
   unrelated objects.
5. Repeat with orientation and split-screen changes, and check that
   the toolbar remains interactive in either mode. Record device model,
   Android version and whether pointer input was Off or On.

## Shared pen, palm and pointer routing matrix (October 2026)

The production notebook and board canvas are exercised by the same six
synthetic widget scenarios in `test/pointer_contact_matrix_test.dart` and
`integration_test/pointer_contact_matrix_test.dart` (shared driver:
`test/support/pointer_contact_matrix.dart`). The scenarios validate:

- Finger drawing with multiple contact radii, including Android-like large
  touch ellipses, versus touch blocking in the stylus-only input mode.
- Stylus continuity with a palm near and far from the writing tip, including
  moving the palm, and no phantom ink or wide coordinate jumps.
- Palm-first, two-fingers-first, stylus-first and finger-after-multi-touch
  ordering. Two fingers alone must pan/zoom the canvas without ink; when
  a stylus arrives, it must regain drawing control without a phantom stroke.
- A canceled finger or stylus stroke must not be saved; a later valid stroke
  must still work. A stationary touch never becomes a saved dot.

`test/cross_platform/pointer_dispatch_contract_test.dart` checks synthesized
touch/stylus identities, contact size and cancel dispatch in Chrome and the
native Dart suite. This is a **framework contract** check, not browser/OS
hardware classification.

An independent `stylus-input` CI job checks pen-related formatting and
regressions without being blocked by unrelated planner changes.
GitHub Actions runs the native widget matrix on Ubuntu and Windows/macOS,
device-level Flutter integration on Linux/Windows/macOS desktops, the Android
emulator and iPhone/iPad simulators. Chrome runs the browser-compatible
contract test. These inject Flutter pointer events; they validate real
production canvas behavior and persistence boundaries, **but do not inject
physical capacitive contacts or native palm rejection decisions**. A green
result must not be described as a hardware palm-rejection certification.

Manual/device-farm acceptance on each supported pen-capable platform:

1. Select Pen, allow finger ink, draw a deliberate finger stroke, including
   contacts with different contact areas; verify the actual saved stroke.
2. Hold a stylus on the canvas. Rest and move the palm at approximately
   30, 100 and 300 logical pixels from the tip; alternate both sides.
   Confirm zero extra dots and no pointer/cursor jump.
3. Repeat in reverse order (palm before stylus), add a second touch,
   then release the pen before the palm. Drawing must resume normally.
4. Repeat with the stylus-only mode: touch must not create ink, while
   stylus pressure and drawing remain functional.
5. Force a gesture cancellation where the native input stack supports it;
   confirm no partial canceled stroke persists after save/reopen.
6. Log platform, OS version, device and digitizer model, active input mode,
   pointer kind and cancel transitions; compare with the saved stroke count.

Limit: when finger drawing is intentionally enabled and the OS reports a
moving palm *only* as an ordinary touch with no contemporaneous stylus,
there may be insufficient information to distinguish it from a deliberate
finger stroke. A universal zero-false-positive promise is not realistic.

## Manual check: symmetric notebook and board grid (October 2026)

1. Create a folder with alternating notebooks and boards, including at
   least seven items and a long document name.
2. At a wide window size, check that five columns are horizontally centered
   and that the next row starts under the first column.
3. Confirm all thumbnails have the same width and aligned top and left
   edges within their grid columns. Notebook previews must remain portrait;
   board previews must remain square. The shorter boards leave empty space
   beneath their preview, not a stretched or distorted image.
4. Verify three-dot menus and truncated titles remain inside the thumbnail
   width and start at the same position for both document types.
5. Reduce the window until the grid shows two columns, then one. Check
   spacing, centering, action menus, and opening both kinds of documents.
6. Repeat in light and dark mode. Inspect all four corners of the folder,
   notebook and board previews. Their rounded shape and continuous soft
   shadow should match in both modes, without clipped diagonal corners.
   Verify hover/press still follows the preview's rounded shape.

Automated coverage: `test/library_catalog_test.dart` exercises grid widths,
alignment, preview aspect ratios, title/menu bounds, and responsive columns.
Automated shape checks also verify the shared 24 px radius and outer
shadow for folder, notebook, and board previews in both themes.
A visual check is still needed on a running Flutter UI.

## Calendar events and folder task planner (October 2026)

The regression tests for these features are
`test/study_planner_controller_test.dart`,
`test/study_planner_widget_test.dart`,
`test/library_planner_test.dart`, and the sidebar creation-menu tests.
Their execution has not been verified in this change.

Manual checks on desktop and mobile, in both light and dark themes:

1. Create an Event in the calendar; set its name, description, color,
   date, hour and duration. Move, edit and delete it. Confirm Upcoming
   offers Edit event, never starts a timer, and the event survives restart.
2. Create a Planner within a folder. Rename it, move it to another folder
   and reopen it; the task list and catalog preview must follow the item.
3. Add a task, type its name, tick/untick the checkbox. Set a date without
   an hour, optionally add/change/remove the hour, remove the entire
   deadline, then delete the task. The deadline cell only appears if set.
4. Future deadline = medium blue, overdue unfinished = light blue,
   completed = dark blue, no deadline = dark blue. Check legible contrast
   and full-length separators inside the 12 px rounded board.
5. Restart the app and verify that tasks persist. Restore a local backup
   and confirm that the planner and its tasks are recovered.

## Planner editor isolation (October 2026)

Regression: `test/planner_editor_isolation_test.dart` checks that planner
items cannot instantiate the drawing editor or use notebook/board
background preference keys. This test has not been run in this environment.

Manual check: create a planner in a folder and open it; verify that
the task checklist appears instead of the drawing toolbar. Open an
existing notebook and board after closing the planner, and confirm their
drawing and page-background settings are unchanged.

## Platform coverage

| Platform | Logic/widget | Native app | Build | Input/peripherals |
|---|---|---|---|---|
| Linux | VM suite | Xvfb integration | Release | Real stylus manual |
| Windows | Full suite on Ubuntu; merged UI/planner on Windows | Windows integration | Release | Windows Ink manual |
| macOS | Full suite on Ubuntu; merged UI/planner on macOS | macOS integration | Release | Trackpad manual |
| Web / Chrome | Browser-compatible suite | ChromeDriver integration | Release | Clipboard and Safari/Firefox/Edge manual |
| Android | VM suite on Ubuntu | Emulator integration nightly | Debug APK | S Pen and pressure manual |
| iOS / iPadOS | VM suite on Ubuntu | iPhone simulator nightly | Simulator | Apple Pencil and iPad UI manual |

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
- Sidebar popup seam: test folder, notebook, board and plus menus at normal
  and resized sidebar widths in both themes. The seam bridge must mask
  the resize divider; only the outer menu edges should cast a shadow.
  Desktop manual check: opening/closing each menu has no dark strip where
  it joins the sidebar, including during animation.
- Color picker regression: display-mode RGB/HEX, Recent swatches and slider
  edits, preserving stored values when unchanged in light and dark modes.
  Each brightness is tested in an isolated widget test with explicit
  ThemeMode and a matching Theme.of(context).brightness assertion.
  Text/ink hit tests use a single QuillEditor finder even when multiple
  render layers contain text widgets.
  Manual: on Linux/Chrome switch themes with the same ink/text, open the pen
  and text pickers, compare Recent/HEX/slider preview to visible ink/text,
  save slider and HEX edits in dark mode, then switch back to light mode.
- Merged UI: empty-library appearance settings, live theme changes across
  catalog and planner routes, dark notebook/board previews without changing
  stored ink/text, dark actions and compact timer, original sidebar menu
  geometry before/after resizing in both themes, and live touch sensitivity
  in catalog, calendar, sidebar timer and session form.
- Planner controls retain global Georgia typography in both themes;
  asynchronous planner load completed after disposal neither notifies,
  starts a timer nor writes recovered history.

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
- Linux native startup environment: six C++/GLib regressions for inherited
  Code Snap schemas, preserving explicit/default/other-Snap values and
  retaining the environment when host compiled schemas are unavailable.
  These tests do not replace real Wayland/XWayland input/plugin checks;
  see [Linux startup diagnostics](LINUX_STARTUP.md).
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
- No OCR UI or runtime dependency on any platform; legacy recognized text is
  retained only for lossless loading and search of existing documents.
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

- Android Release failed in `:app:minifyReleaseWithR8` because the former OCR
  dependency referenced optional language recognizers missing from the graph.
  OCR was later removed on every platform, together with that dependency and
  its R8 exceptions; shrinking remains active.
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

## Node 24 artifact upload (9 October 2026)

- CI coverage artifacts use `actions/upload-artifact@v6`, which runs on
  Node.js 24 and replaces the deprecated Node 20 action. The upload step
  remains a GitHub Actions runtime check; no local Flutter runtime was used.

## Kotlin 2.3.20 Gradle DSL regression (9 October 2026)

- Kotlin 2.3.20 rejects legacy `android.kotlinOptions.jvmTarget`.
  `android/app/build.gradle.kts` now applies typed `kotlin.compilerOptions`
  with `JvmTarget.JVM_17`. The `android_build_toolchain_test.dart` regression
  verifies both the required Kotlin version and the compiler options DSL.
  Android Debug, Release and emulator CI builds remain the acceptance tests.

- Added `critical_editor_regressions_test.dart` to the isolated native
  documents fixture after CI showed `MissingPluginException` in its tests.
  The existing erase/lasso/save/undo regression scenarios remain unchanged.

## Gradle 9 / AGP 9 compatibility staging (9 October 2026)

- Upgrade Gradle 8.14 to 9.1.0 and Android Gradle Plugin 8.11.1 to 9.0.1,
  matching the minimums announced by Flutter 3.47.6 and AGP 9.0.
- Explicitly enable Flutter's temporary backwards-compatible behavior:
  `android.newDsl=false` and `android.builtInKotlin=false`. Native
  third-party plugins still using the legacy Kotlin Gradle Plugin require
  this until they migrate. These flags are transitional, not permanent.
- Android Debug, Release (including R8), emulator smoke test, and
  document lifecycle must pass before adopting AGP 9 as the stable baseline.
  If the migration fails, restore the last green toolchain in a revert commit.

## Gradle 9 / AGP 9 compatibility rollback (9 October 2026)

- CI run 37924767077 demonstrates that Gradle 9.1.0 / AGP 9.0.1 fails
  on Android Debug and Release at
  `irondash_engine_context-0.5.5/cargokit/gradle/plugin.gradle:60`:
  `Could not find method exec()` when CargoKit invokes removed
  `Project.exec` in Gradle 9. Kotlin built-in compatibility flags cannot
  address this different Gradle API failure.
- Toolchain reverted to the previously passing Gradle 8.14 / AGP 8.11.1.
  Keep Kotlin 2.3.20 and typed JVM 17 compiler options. The Android Gradle
  deprecation notices remain tracked until upstream provides compatible
  stable CargoKit / irondash dependencies; do not suppress or fake them.
- Regression test `android_build_toolchain_test.dart` now guards the
  compatibility hold. Revisit only after an updated dependency and verify
  Android Debug, Release, R8 and emulator end-to-end on the new toolchain.

## Adaptive layouts and system insets (18 October 2026)

Widget regressions: `test/adaptive_platform_layout_test.dart`,
`test/library_screen_responsive_layout_test.dart`,
`test/editor_screen_responsive_layout_test.dart` and
`test/study_planner_widget_test.dart`.

Manual release checks required on actual devices (widget tests do not replace
platform or accessibility testing):

1. Android 13–16 phone: portrait and landscape; status and gesture bars,
   3-button navigation, camera cutout, keyboard open, font/display scaling,
   dark mode and system back gesture.
2. iPhone with notch/Dynamic Island and home indicator: portrait/landscape,
   keyboard open, VoiceOver, enlarged Dynamic Type and modal/drawer navigation.
3. Android tablets and iPad/iPadOS: 600–960 dp portrait, 960+ dp landscape,
   split screen, Stage Manager/window resize, stylus, physical keyboard and
   touch input. Verify sidebar/drawer transitions while a document is open.
4. Foldable and dual-screen devices: folded/narrow, expanded, rotating and
   changing app-window width; verify hinge/cutout insets and unobstructed
   controls on both sides. Hinge spanning behavior needs real-device testing.
5. Windows, Linux, macOS and web: resize between 320, 600, 959, 960 and
   1440 logical pixels; verify no lost editor state, accessible menus and
   existing desktop sidebar. Also test 125–200% OS display/text scaling.
6. Across all platforms: open a notebook and board, draw/erase with touch
   and stylus, scroll the toolbars, zoom the page, add/delete a page, create
   folders and study sessions, rotate or resize, then save/reopen and verify
   persisted content. Confirm timer, settings, dialogs and export are usable.

Layouts depend on available logical viewport width, not the operating system:
compact navigation below 960 dp and desktop sidebar at 960 dp or above.
System UI insets use Flutter `SafeArea`/`MediaQuery`; do not disable Android
edge-to-edge, and do not assume iOS devices share the same status bar height.

## Calendar and timer UI: manual check (October 2026)

1. Pull the latest `dev` branch and fully restart the Flutter app.
   Open Calendar, then use a day cell's + to add a study session.
2. Click Name, type several characters, click Description, and enter multiline
   text. Both headings must remain above their fields with unchanged position,
   size and font. Repeat with New event and editing an existing entry.
3. In New event, tick and untick the square All day checkbox. Duration and
   time controls should react to its value. Save and reopen to verify it.
4. With no upcoming sessions, the sidebar timer must have 16 px below the
   Start session and Smart buttons before the lower separator. After adding
   an upcoming session, the list must end without extra bottom padding.
5. Inspect the task canvas, folder/document cards, dialog corners, calendar
   days and notebook/board toolbars in both themes. Rectangular surfaces
   must use 12 px rounding; color swatches and circular handles stay round.
6. Check small-screen calendar/event dialog and desktop resizing for
   clipped controls, title shifting or overflowing action rows.

## Text edit/preview: device matrix (October 2026)

Automated Flutter widget tests in `test/page_overlay_text_gestures_test.dart`
compare font metrics and text bounds during repeated mode switches in light
and dark themes and verify font size values 8–192. They cannot verify system
font substitution, keyboard IME behavior or physical display scaling.

Manual checks on Linux, Windows, macOS, Chrome, Android and iOS/iPadOS:

1. Add short and wrapped multiline text in a notebook and on a board.
   Observe glyph position, line breaks and size before editing.
2. Double click/tap to edit, type, leave editing and repeat. The text must
   not jump, resize or reflow at zoom 50%, 100% and 200%, in both themes.
3. Choose 8, 9, 10, 11, 96, 128 and 192; resize by a corner handle and
   verify that the toolbar still shows the current value.
4. Repeat with physical and on-screen keyboards, OS text scaling and
   legacy mixed-color formatting. Save/reopen the notebook and board.

### Text wrap consistency on Linux and other platforms (21 October 2026)

The widget regression now compares caret positions for nine character offsets
in the same long, wrapped paragraph. The comparison is repeated across
readonly preview, active editing and restored readonly preview, twice in both
light and dark modes. Uniformly styled text uses read-only EditableText in
preview and the same Flutter renderer for editing. Mixed rich-text documents
retain Quill in preview, including per-run colors.

Manual scenario (Linux first; repeat on Windows/macOS, Chrome, Android/iOS):

1. Paste the paragraph beginning "The creativity is required from the author."
   into a roughly 600 logical-pixel wide text box in a notebook and board.
2. Before/during/after editing, compare the line break at "The product has to
   be published" and the positions of the first and last characters.
3. Repeat with keyboard input, resize handles, 50/100/200% zoom, light/dark
   mode, device text scaling and save/reopen. No word should change lines
   solely from entering or leaving editing.
4. Check a legacy multi-color rich-text block: its independent colored
   segments must still appear outside editing.

## Server backup and two-browser synchronization

Automated local tests cover the app-data migration, HTTPS-only API
configuration, authentication headers, complete backup v2, checksum handling,
Argon2/JWT primitives, paginated reconciliation, concurrent backup dirtiness,
image-path relocation, server-backup invariants and deployment boundaries.
Before enabling a real account, run an isolated PostgreSQL instance and verify
manually:

1. Create accounts A and B. Confirm that B receives 404/403 for every
   notebook, device, snapshot and download identifier belonging to A.
2. Open the same account in two separate Chrome profiles. Select an explicit
   initial policy, edit A and confirm B updates without reload. Repeat after
   disabling Wi-Fi, sleeping the tab, restarting API and letting JWT expire.
3. Edit the same document on both devices while offline. Confirm a `409`
   creates a visible conflict copy and neither version disappears.
4. Delete an uploaded document and a never-uploaded document. Confirm only the
   uploaded one creates a tombstone and neither is resurrected after reconnect.
5. Upload a snapshot containing rich text, ink, images, folders/tasks and study
   sessions. Download it on an empty test profile, verify both SHA-256 layers,
   restore it and compare counts/content.
6. Interrupt upload before finalize, corrupt one byte, exceed 64 MiB and reuse
   an idempotency key with another payload. All attempts must fail without
   replacing the newest `verified` backup.
7. Run `server/scripts/backup-server.sh` against a separate encrypted test
   volume, verify its manifest, restore `postgres.dump` plus device snapshots
   into an isolated stack and compare account/notebook/snapshot counts.

These PostgreSQL/Cloudflare/two-browser scenarios are not marked as passed by
the unit suite and require a configured test server.

### Wspólna edycja – scenariusze ręczne do wykonania na wdrożeniu

- Host otwiera board i udostępnia link; dwóch gości równocześnie rysuje na
  różnych częściach, host edytuje tekst. Zweryfikować ten sam UID i folder
  oraz brak dokumentów „Conflict”.
- Jeden gość zmienia tekst, drugi zmienia ten sam blok w tej samej sekundzie:
  wcześniejszy czas przyjęcia na serwerze wygrywa; przegrana wersja pozostaje
  widoczna i odzyskiwalna, nie znika po reloadzie.
- Odłączyć sieć podczas pisania i odświeżyć stronę gościa: po ponownym
  podaniu hasła jego zapisane lokalnie zmiany powinny zostać ponowione.
- Zamknąć kartę bezpośrednio w trakcie nowej kreski i otworzyć ponownie;
  odnotować, że operacja niewysłana jeszcze do lokalnego magazynu może
  wymagać ponownego wykonania.
- Uruchomić równoczesne PUT/DELETE i wygaszenie sesji; żadna edycja
  zatwierdzona po unieważnieniu nie może wejść do dokumentu.
- Wypełnić limit localStorage, ponowić edycję i zweryfikować ostrzeżenie.
- Sprawdzić tekst Quill, gumki, obrazy z bajtami, wiele stron, cofanie,
  przedłużanie sesji, dwa równoczesne zalogowane okna hosta, restart API.
- Zmierzyć czas od wykonania kreski do jej wyświetlenia na drugim kliencie,
  także na wolnym łączu i po utracie WebSocket.

- Gość rysuje w chwili trwającego GET odświeżającego po WebSocket,
  tak aby 35-ms timer zapisu wywołał się przed odpowiedzią GET.
  Po zakończeniu GET musi zostać zaplanowane ponowienie PUT;
  sprawdzić status Saved, oryginalny UID i brak pętli.
- Wyjście ze wspólnego edytora bez jakichkolwiek zmian nie może wytworzyć
  sztucznej oczekującej edycji w localStorage.

- Bezpośrednie wejście na /share/UUID z nowej karty i po odświeżeniu:
  SQLite WASM musi być pobrany z /sqlite3.wasm (Content-Type application/wasm),
  bez prób pobierania z /share/sqlite3.wasm.
