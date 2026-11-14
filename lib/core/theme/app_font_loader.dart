import 'package:flutter/services.dart';

/// Loads icon glyphs before the first frame, including Web and Share entry.
Future<void> loadAppIconFonts() async {
  final loader = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await loader.load();
}
