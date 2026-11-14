import 'package:flutter_test/flutter_test.dart';

import 'support/app_icon_check.dart';

void main() {
  testWidgets(
    'bundled Material icons retain their glyphs in both themes',
    verifyAppIcons,
  );
}
