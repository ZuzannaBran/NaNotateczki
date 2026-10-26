class AppDataMigrationReport {
  const AppDataMigrationReport({
    required this.dataPath,
    this.migratedPaths = const <String>[],
    this.conflictingPaths = const <String>[],
  });

  final String dataPath;
  final List<String> migratedPaths;
  final List<String> conflictingPaths;

  bool get hasConflicts => conflictingPaths.isNotEmpty;
}
