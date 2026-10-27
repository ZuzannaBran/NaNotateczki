import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:program/core/input/app_scroll_behavior.dart';
import 'package:program/core/theme/app_theme.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/drift/notes_database_connection.dart';
import 'package:program/features/editor/presentation/editor_screen.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

/// Entry point for the website's embedded, real Flutter editor.
///
/// Build with:
/// flutter build web --release --target tool/website_widget_demo.dart \\
///   --base-href /NaNotateczki-web/demo/
///
/// This entry point is deliberately separate from AppScope. It does not
/// initialize the account, cloud sync, remote backup, or the user's library.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WebsiteWidgetDemo());
}

const websiteDemoDatabaseName = 'nanotateczki-website-widget-demo-v1';
const websiteDemoNotebookId = '5ce1f397-8dbb-4746-ae14-0b9f1592b8d7';
const websiteDemoPageId = 'cfd16c5d-9f3d-4af8-8cd0-1edacb8e7349';

/// A blank notebook in a dedicated origin-local demo database.
Notebook createWebsiteDemoNotebook(DateTime now) {
  return Notebook(
    uid: websiteDemoNotebookId,
    title: 'Pismo i tło strony',
    kind: NotebookKind.notebook,
    folder: '',
    createdAt: now,
    updatedAt: now,
    pages: [
      NotePage(
        id: websiteDemoPageId,
        title: 'Strona 1',
        textBlocks: [],
        imageBlocks: [],
        inkStrokes: [],
        isBookmarked: false,
      ),
    ],
  );
}

class _DemoSession {
  _DemoSession({required this.database, required this.controller});

  final NotesDatabase database;
  final EditorController controller;

  Future<void> close() async {
    try {
      await controller.flushPendingSaves();
    } finally {
      controller.dispose();
      await database.close();
    }
  }
}

Future<_DemoSession> _openSession() async {
  // Uses the real application's SQLite/Drift engine, but a distinct IndexedDB
  // database name. Website visitors never connect to the account backend.
  final opened = await NotesDatabase.open(
    connectionOpener: (_) =>
        openNotesDatabaseConnection(websiteDemoDatabaseName),
  );
  final database = opened.database;
  try {
    final repository = NotebookRepository(database);
    final notebooks = await repository.fetchNotebooks();
    Notebook? demo;
    for (final candidate in notebooks) {
      if (candidate.uid == websiteDemoNotebookId) {
        demo = candidate;
        break;
      }
    }

    if (demo == null) {
      demo = createWebsiteDemoNotebook(DateTime.now());
      final saved = await repository.saveNotebook(demo);
      if (!saved) {
        throw StateError('Could not initialize the widget demo notebook.');
      }
    }

    return _DemoSession(
      database: database,
      controller: EditorController(repository: repository, notebook: demo),
    );
  } catch (_) {
    await database.close();
    rethrow;
  }
}

class WebsiteWidgetDemo extends StatefulWidget {
  const WebsiteWidgetDemo({super.key});

  @override
  State<WebsiteWidgetDemo> createState() => _WebsiteWidgetDemoState();
}

class _WebsiteWidgetDemoState extends State<WebsiteWidgetDemo> {
  late final Future<_DemoSession> _future = _openSession();
  _DemoSession? _session;

  @override
  void dispose() {
    final session = _session;
    if (session != null) {
      unawaited(session.close());
    } else {
      unawaited(
        _future.then((value) => value.close()).catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final darkMode = Uri.base.queryParameters['theme'] == 'dark';
    return MaterialApp(
      title: 'NaNotateczki — widget edytora',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const AppScrollBehavior(),
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: darkMode ? ThemeMode.dark : ThemeMode.light,
      home: FutureBuilder<_DemoSession>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Nie udało się uruchomić demonstracji Flutter. '
                    'Odśwież stronę lub sprawdź obsługę pamięci przeglądarki.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final session = snapshot.data!;
          _session = session;
          // This is the original editor and the original EditorToolbar.
          // It uses the actual pointer, ink, eraser, shapes, background,
          // selection and undo/redo implementations from NaNotateczki.
          return ChangeNotifierProvider<EditorController>.value(
            value: session.controller,
            child: const EditorScreen(title: 'Pismo i tło strony'),
          );
        },
      ),
    );
  }
}
