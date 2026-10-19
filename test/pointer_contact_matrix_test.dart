import 'package:flutter/material.dart';

import 'support/native_test_documents.dart';
import 'support/pointer_contact_matrix.dart';

void main() {
  useIsolatedNativeTestDocuments();
  registerPointerContactMatrix(surfaceSize: const Size(390, 844));
}
