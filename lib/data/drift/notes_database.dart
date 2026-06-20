import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../core/error/app_error_log.dart';
import 'notes_database_connection.dart';

part 'notes_database.g.dart';

class NotebookRows extends Table {
  TextColumn get uid => text()();
  TextColumn get title => text()();
  IntColumn get kindIndex => integer()();
  TextColumn get folder => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {uid};
}

class PageRows extends Table {
  TextColumn get uid => text()();
  TextColumn get notebookUid => text().references(NotebookRows, #uid)();
  IntColumn get pageIndex => integer()();
  TextColumn get title => text()();
  BoolColumn get isBookmarked => boolean()();
  IntColumn get legacyIndexTabColorValue => integer().nullable()();
  RealColumn get legacyIndexTabPosition => real().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {uid};
}

class IndexTabRows extends Table {
  TextColumn get uid => text()();
  TextColumn get pageUid => text().references(PageRows, #uid)();
  IntColumn get colorValue => integer()();
  RealColumn get position => real()();

  @override
  Set<Column<Object>> get primaryKey => {uid};
}

class TextBlockRows extends Table {
  TextColumn get uid => text()();
  TextColumn get pageUid => text().references(PageRows, #uid)();
  TextColumn get plainText => text().named('text')();
  TextColumn get deltaJson => text().nullable()();
  RealColumn get fontSize => real()();
  IntColumn get colorValue => integer()();
  RealColumn get width => real()();
  RealColumn get rotation => real()();
  RealColumn get dx => real()();
  RealColumn get dy => real()();
  IntColumn get sortIndex => integer()();

  @override
  Set<Column<Object>> get primaryKey => {uid};
}

class ImageBlockRows extends Table {
  TextColumn get uid => text()();
  TextColumn get pageUid => text().references(PageRows, #uid)();
  TextColumn get path => text()();
  TextColumn get ocrText => text()();
  BlobColumn get bytes => blob().nullable()();
  TextColumn get imageExt => text().nullable()();
  TextColumn get imageMime => text().nullable()();
  RealColumn get width => real()();
  RealColumn get height => real()();
  RealColumn get rotation => real()();
  RealColumn get dx => real()();
  RealColumn get dy => real()();
  RealColumn get cropLeft => real()();
  RealColumn get cropTop => real()();
  RealColumn get cropRight => real()();
  RealColumn get cropBottom => real()();
  IntColumn get sortIndex => integer()();

  @override
  Set<Column<Object>> get primaryKey => {uid};
}

class InkStrokeRows extends Table {
  TextColumn get uid => text()();
  TextColumn get pageUid => text().references(PageRows, #uid)();
  IntColumn get colorValue => integer()();
  RealColumn get width => real()();
  IntColumn get toolIndex => integer()();
  TextColumn get pointsJson => text()();
  IntColumn get sortIndex => integer()();

  @override
  Set<Column<Object>> get primaryKey => {uid};
}

class DatabaseOpenResult {
  DatabaseOpenResult({
    required this.database,
    required this.wasReset,
    required this.freshFile,
    this.resetReason,
  });

  final NotesDatabase database;
  final bool wasReset;
  final bool freshFile;
  final String? resetReason;
}

enum DatabaseOpenStage { connection, validation }

class DatabaseOpenException implements Exception {
  const DatabaseOpenException({
    required this.stage,
    required this.attempts,
    required this.cause,
  });

  final DatabaseOpenStage stage;
  final int attempts;
  final Object cause;

  String get stageLabel => switch (stage) {
    DatabaseOpenStage.connection => 'creating the SQLite connection',
    DatabaseOpenStage.validation =>
      'validating or migrating the SQLite database',
  };

  @override
  String toString() {
    return 'DatabaseOpenException(stage=${stage.name}, attempts=$attempts, '
        'cause=$cause)';
  }
}

@DriftDatabase(
  tables: [
    NotebookRows,
    PageRows,
    IndexTabRows,
    TextBlockRows,
    ImageBlockRows,
    InkStrokeRows,
  ],
)
class NotesDatabase extends _$NotesDatabase {
  NotesDatabase(super.executor);

  static const _databaseFileName = 'notes.sqlite';
  static const _openAttemptCount = 3;
  static const _openRetryDelay = Duration(milliseconds: 250);

  static Future<DatabaseOpenResult> open({
    @visibleForTesting
    Future<NotesDatabaseConnection> Function(String name)? connectionOpener,
    @visibleForTesting Future<void> Function(Duration duration)? retryDelay,
    @visibleForTesting
    void Function(Object error, StackTrace stackTrace, String source)?
    errorRecorder,
  }) async {
    final openConnection = connectionOpener ?? openNotesDatabaseConnection;
    final waitBeforeRetry = retryDelay ?? Future<void>.delayed;
    final recordError =
        errorRecorder ??
        (Object error, StackTrace stackTrace, String source) {
          AppErrorLog.instance.record(error, stackTrace, source: source);
        };
    Object? lastError;
    StackTrace? lastStackTrace;
    DatabaseOpenStage? lastStage;

    for (var attempt = 1; attempt <= _openAttemptCount; attempt++) {
      NotesDatabase? database;
      var stage = DatabaseOpenStage.connection;
      try {
        final connection = await openConnection(_databaseFileName);
        stage = DatabaseOpenStage.validation;
        database = NotesDatabase(connection.executor);
        await database.customSelect('select 1').getSingle();
        return DatabaseOpenResult(
          database: database,
          wasReset: false,
          freshFile: connection.freshFile,
        );
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        lastStage = stage;
        debugPrint(
          'NotesDatabase.open stage=${stage.name} '
          'attempt=$attempt/$_openAttemptCount failed: $error',
        );
        recordError(
          error,
          stackTrace,
          'NotesDatabase.open(stage=${stage.name},attempt=$attempt)',
        );
        if (database != null) {
          try {
            await database.close();
          } catch (closeError, closeStackTrace) {
            recordError(
              closeError,
              closeStackTrace,
              'NotesDatabase.open(close_failed)',
            );
          }
        }
        if (attempt < _openAttemptCount) {
          await waitBeforeRetry(_openRetryDelay);
        }
      }
    }

    Error.throwWithStackTrace(
      DatabaseOpenException(
        stage: lastStage!,
        attempts: _openAttemptCount,
        cause: lastError!,
      ),
      lastStackTrace!,
    );
  }

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
