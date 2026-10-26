import 'package:path_provider/path_provider.dart';

import 'app_data_directory_io.dart';
import 'app_data_migration_report.dart';

Future<String> getAppDataPath() async {
  final support = await getApplicationSupportDirectory();
  return '${support.path}/data';
}

Future<AppDataMigrationReport> prepareAppDataDirectory({
  String? supportPath,
  String? legacyDocumentsPath,
}) async {
  final resolvedSupportPath =
      supportPath ?? (await getApplicationSupportDirectory()).path;
  final resolvedLegacyDocumentsPath =
      legacyDocumentsPath ?? (await getApplicationDocumentsDirectory()).path;
  return migrateNativeAppData(
    supportPath: resolvedSupportPath,
    legacyDocumentsPath: resolvedLegacyDocumentsPath,
  );
}
