import 'package:flutter_test/flutter_test.dart';

import 'app_smoke_test.dart' as bootstrap;
import 'document_lifecycle_test.dart' as documents;
import 'pointer_contact_matrix_test.dart' as pointer;

/// Registers all native scenarios in a single Flutter test application.
/// Group scopes keep path-provider and text-storage test hooks isolated.
void main() {
  group('platform bootstrap', bootstrap.main);
  group('isolated document lifecycle', documents.main);
  group('pointer contact matrix', pointer.main);
}
