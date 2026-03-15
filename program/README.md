# Notatek

Stylus-first notes app built with Flutter. Includes drawing tools, shapes,
text and image blocks, export, and local persistence with optional folder sync.

## Features
- Pen, pencil, highlighter, eraser.
- Lasso select and move strokes.
- Shapes recognition with snapping.
- Text blocks and image blocks.
- OCR on images (Android/iOS only).
- Undo/redo per-object actions.
- Notebook library with search.
- PNG/PDF export.
- Local backup export/import (JSON).
- Folder-based sync (no API keys required).

## Project Layout
- lib/app: app scope, DI, routing.
- lib/core: theme, shared widgets.
- lib/data: Isar storage, sync services.
- lib/features: library, notebook, editor.

## Run
1) flutter pub get
2) flutter run

## Notes
- OCR uses ML Kit on Android/iOS only. Desktop/web returns a "not supported"
	message.
- Folder sync writes a single JSON file to a user-selected directory and
	resolves conflicts by latest update timestamp.
