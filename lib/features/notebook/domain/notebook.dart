import 'note_page.dart';

class Notebook {
  Notebook({
    required this.uid,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.pages,
  });

  final String uid;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<NotePage> pages;

  Notebook copyWith({
    String? uid,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<NotePage>? pages,
  }) {
    return Notebook(
      uid: uid ?? this.uid,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      pages: pages ?? this.pages,
    );
  }
}
