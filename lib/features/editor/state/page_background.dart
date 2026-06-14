import '../../notebook/domain/notebook_kind.dart';

enum PageBackgroundStyle { blank, grid, lines }

extension PageBackgroundStyleX on PageBackgroundStyle {
  String get label {
    return switch (this) {
      PageBackgroundStyle.blank => 'Plain',
      PageBackgroundStyle.grid => 'Grid',
      PageBackgroundStyle.lines => 'Lines',
    };
  }
}

class PageBackgroundSettings {
  const PageBackgroundSettings({
    this.style = PageBackgroundStyle.blank,
    this.spacing = defaultSpacing,
  });

  static const double minSpacing = 16.0;
  static const double maxSpacing = 64.0;
  static const double defaultSpacing = 32.0;

  final PageBackgroundStyle style;
  final double spacing;

  PageBackgroundSettings copyWith({
    PageBackgroundStyle? style,
    double? spacing,
  }) {
    return PageBackgroundSettings(
      style: style ?? this.style,
      spacing: spacing ?? this.spacing,
    );
  }

  Map<String, dynamic> toJson() {
    return {'style': style.index, 'spacing': spacing};
  }

  static PageBackgroundSettings fromJson(Object? value) {
    if (value is! Map) {
      return const PageBackgroundSettings();
    }
    final styleIndex = value['style'];
    final spacingValue = value['spacing'];
    final style =
        styleIndex is int &&
            styleIndex >= 0 &&
            styleIndex < PageBackgroundStyle.values.length
        ? PageBackgroundStyle.values[styleIndex]
        : PageBackgroundStyle.blank;
    final spacing = spacingValue is num
        ? spacingValue.toDouble()
        : defaultSpacing;
    return PageBackgroundSettings(
      style: style,
      spacing: spacing.clamp(minSpacing, maxSpacing).toDouble(),
    );
  }
}

String backgroundPrefsKeyForKind(NotebookKind kind) {
  return switch (kind) {
    NotebookKind.notebook => 'notebook',
    NotebookKind.board => 'board',
  };
}
