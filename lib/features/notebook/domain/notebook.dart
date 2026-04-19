import 'note_page.dart';
import 'notebook_kind.dart';

class Notebook {
  Notebook({
    required this.uid,
    required this.title,
    required this.kind,
    required this.folder,
    required this.createdAt,
    required this.updatedAt,
    required this.pages,
  });

  final String uid;
  final String title;
  final NotebookKind kind;
  final String folder;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<NotePage> pages;

  Notebook copyWith({
    String? uid,
    String? title,
    NotebookKind? kind,
    String? folder,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<NotePage>? pages,
  }) {
    return Notebook(
      uid: uid ?? this.uid,
      title: title ?? this.title,
      kind: kind ?? this.kind,
      folder: folder ?? this.folder,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      pages: pages ?? this.pages,
    );
  }
}
