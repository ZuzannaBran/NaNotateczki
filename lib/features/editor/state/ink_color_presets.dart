import 'package:flutter/material.dart';

/// Matching pen, highlighter and light-accent colors for quick swatches.
enum InkColorPreset {
  blue,
  pink,
  green;

  String get label => switch (this) {
    InkColorPreset.blue => 'Blue',
    InkColorPreset.pink => 'Pink',
    InkColorPreset.green => 'Green',
  };

  List<Color> get colors => switch (this) {
    InkColorPreset.blue => const [
      Color(0xFF2A3851),
      Color(0xFFA1B2CE),
      Color(0xFFD0D8E7),
    ],
    InkColorPreset.pink => const [
      Color(0xFF583240),
      Color(0xFFCCA4B2),
      Color(0xFFE9D8DE),
    ],
    InkColorPreset.green => const [
      Color(0xFF2C443A),
      Color(0xFF9BBFB0),
      Color(0xFFD0E1DA),
    ],
  };
}
