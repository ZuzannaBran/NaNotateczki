import 'app_data_migration_report.dart';

Future<String> getAppDataPath() async => '';

Future<AppDataMigrationReport> prepareAppDataDirectory({
  String? supportPath,
  String? legacyDocumentsPath,
}) async {
  return const AppDataMigrationReport(dataPath: '');
}
