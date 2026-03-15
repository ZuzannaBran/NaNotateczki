# Stylus Notes - Flutter App

Stylus-first note app inspired by iPad workflows. Focused on fast drawing,
organization, and export, with local persistence and optional folder sync.

## Scope (current)
- Drawing with stylus or finger on a page.
- Color palette and stroke width.
- Eraser tool.
- Undo / redo.
- Pages inside a notebook.
- Notebook library with search.
- PNG/PDF export.
- Text blocks and image blocks (with OCR on mobile).
- Shapes recognition (line, ellipse, rectangle) with snapping.
- Local backup export/import (JSON).
- Folder-based sync (no API keys; user-provided folder).

## Structure (feature-first)
- lib/app: app scope, DI, routing.
- lib/core: theme, shared widgets.
- lib/data: Isar storage, sync services.
- lib/features:
	- library: notebooks list, search, sync actions.
	- notebook: domain models, repository, notebook screen.
	- editor: drawing canvas, tools, page overlay, controller.

## Run
- flutter pub get
- flutter run

## Notes
- OCR works on Android/iOS only (ML Kit). On desktop/web, it shows a
	"not supported" message.
- Folder sync writes a shared JSON to a user-selected directory and merges
	by updated time.
