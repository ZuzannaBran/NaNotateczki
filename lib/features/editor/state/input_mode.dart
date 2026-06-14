enum PointerInputMode { off, on }

extension PointerInputModeX on PointerInputMode {
  String get label {
    return switch (this) {
      PointerInputMode.off => 'Off',
      PointerInputMode.on => 'On',
    };
  }

  String get description {
    return switch (this) {
      PointerInputMode.off =>
        'Keep the current behavior and allow finger drawing.',
      PointerInputMode.on =>
        'Use system pointer types and disable finger drawing.',
    };
  }

  bool get allowsFingerDrawing {
    return this == PointerInputMode.off;
  }
}

PointerInputMode pointerInputModeFromIndex(Object? value) {
  if (value is! int || value <= 0) {
    return PointerInputMode.off;
  }
  return PointerInputMode.on;
}
