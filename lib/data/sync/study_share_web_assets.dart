/// Resolves the sqlite3 module from the Flutter Web app root, not from the
/// nested `/share/<id>` route used when joining an invitation directly.
Uri sharedGuestWasmUri(Uri pageUri) {
  return pageUri.resolve('/sqlite3.wasm');
}
