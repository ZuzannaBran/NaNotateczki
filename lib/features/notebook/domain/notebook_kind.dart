enum NotebookKind {
  notebook,
  board,
}

extension NotebookKindValue on NotebookKind {
  int get indexValue => index;

  static NotebookKind fromIndex(int value) {
    if (value < 0 || value >= NotebookKind.values.length) {
      return NotebookKind.notebook;
    }
    return NotebookKind.values[value];
  }
}
