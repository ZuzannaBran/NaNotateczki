import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/study_share_web_assets.dart';

void main() {
  test('direct invitation route resolves sqlite wasm from origin root', () {
    final url = sharedGuestWasmUri(Uri.parse(
      'https://app.nanotateczki.pl/share/abcd-1234?source=invitation',
    ));
    expect(url.toString(), 'https://app.nanotateczki.pl/sqlite3.wasm');
  });

  test('root editor and guest editor resolve the same wasm file', () {
    final root = sharedGuestWasmUri(
      Uri.parse('https://app.nanotateczki.pl/'),
    );
    final guest = sharedGuestWasmUri(
      Uri.parse('https://app.nanotateczki.pl/share/session-1'),
    );
    expect(guest, root);
  });
}
