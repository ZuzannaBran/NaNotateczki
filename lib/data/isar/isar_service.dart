import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';

import 'entities/notebook_entity.dart';

class IsarService {
  IsarService(this.isar);

  final Isar isar;

  static Future<IsarService> open() async {
    final dir = await getApplicationDocumentsDirectory();
    final isar = await Isar.open(
      [NotebookEntitySchema],
      directory: dir.path,
    );
    return IsarService(isar);
  }

  Future<void> close() => isar.close();
}
