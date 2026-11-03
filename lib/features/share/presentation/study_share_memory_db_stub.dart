import '../../../data/drift/notes_database.dart';

Future<NotesDatabase> openSharedGuestDatabase() async {
  throw UnsupportedError('Shared guest editing requires Flutter Web.');
}

Future<NotesDatabase> openSharedGuestOperationDatabase(String shareId) async {
  throw UnsupportedError('Shared guest operations require Flutter Web.');
}
