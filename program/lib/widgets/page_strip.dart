import 'package:flutter/material.dart';

import '../state/note_editor_controller.dart';

class PageStrip extends StatelessWidget {
  const PageStrip({required this.controller, super.key});

  final NoteEditorController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        return SizedBox(
          height: 64,
          child: Row(
            children: [
              Expanded(
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemBuilder: (context, index) {
                    final page = controller.pages[index];
                    return ChoiceChip(
                      label: Text(page.title),
                      selected: controller.currentPageIndex == index,
                      onSelected: (_) => controller.setCurrentPage(index),
                    );
                  },
                  separatorBuilder: (context, index) =>
                      const SizedBox(width: 8),
                  itemCount: controller.pages.length,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: controller.addPage,
                tooltip: 'Add page',
              ),
            ],
          ),
        );
      },
    );
  }
}
