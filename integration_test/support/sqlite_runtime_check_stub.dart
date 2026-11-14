const supportsNativeSqliteRuntime = false;

Future<void> verifyNativeSqliteRuntime() async {
  throw UnsupportedError('Native SQLite is unavailable on this platform.');
}
