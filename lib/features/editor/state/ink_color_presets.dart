import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/storage/text_storage.dart';
import '../../../core/theme/app_colors.dart';

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
    InkColorPreset.blue => AppColors.blueColorSet,
    InkColorPreset.pink => AppColors.pinkColorSet,
    InkColorPreset.green => AppColors.greenColorSet,
  };
}

/// Shared recent colors for the canvas, text picker and folder covers.
/// Migrates the previous editor history without changing saved notebook data.
class SharedRecentColors {
  static const _storageKey = 'shared_recent_colors.json';
  static Future<void> _pending = Future<void>.value();

  static List<Color> merge(Iterable<Color> newest, Iterable<Color> older) {
    final colors = <Color>[];
    final seen = <int>{};
    for (final color in <Color>[...newest, ...older]) {
      if (seen.add(color.toARGB32())) {
        colors.add(color);
        if (colors.length == 12) {
          break;
        }
      }
    }
    return colors;
  }

  static Future<List<Color>> load() async {
    await _pending;
    return _read();
  }

  static Future<List<Color>> _read() async {
    try {
      final saved = await readStoredText(_storageKey);
      if (saved != null) {
        final decoded = jsonDecode(saved);
        if (decoded is List) {
          return merge(decoded.whereType<int>().map(Color.new), const []);
        }
        return [];
      }

      final legacy = await readStoredText('editor_prefs.json');
      if (legacy == null) {
        return [];
      }
      final decoded = jsonDecode(legacy);
      if (decoded is! Map || decoded['recentColors'] is! List) {
        return [];
      }
      final colors = <Color>[];
      for (final value in decoded['recentColors'] as List) {
        if (value is! String) {
          continue;
        }
        final hex = value.replaceAll('#', '').trim();
        if (hex.length != 6) {
          continue;
        }
        final parsed = int.tryParse(hex, radix: 16);
        if (parsed != null) {
          colors.add(Color(0xFF000000 | parsed));
        }
      }
      return merge(colors, const []);
    } catch (error) {
      debugPrint('SharedRecentColors.load failed: $error');
      return [];
    }
  }

  static Future<void> record(Color color) {
    final next = _pending.then((_) async {
      final colors = merge([color], await _read());
      await writeStoredText(
        _storageKey,
        jsonEncode(colors.map((item) => item.toARGB32()).toList()),
      );
    });
    _pending = next.catchError((Object error) {
      debugPrint('SharedRecentColors.record failed: $error');
    });
    return _pending;
  }
}
