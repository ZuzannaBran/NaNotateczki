import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/empty_state.dart';
import '../../editor/presentation/editor_screen.dart';
import '../../editor/state/editor_controller.dart';

class NotebookScreen extends StatelessWidget {
  const NotebookScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditorController>();

    if (controller.pages.isEmpty) {
      return const EmptyState(
        title: 'Empty notebook',
        message: 'Add a page to start writing.',
      );
    }

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Container(
            color: AppColors.toolbar,
            child: const TabBar(
              tabs: [
                Tab(text: 'Pages'),
                Tab(text: 'Outline'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _PagesView(controller: controller),
                const _OutlineView(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PagesView extends StatelessWidget {
  const _PagesView({required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Text('Pages', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              TextButton.icon(
                onPressed: controller.addPage,
                icon: const Icon(Icons.add),
                label: const Text('New page'),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 0.7,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
            ),
            itemCount: controller.pages.length,
            itemBuilder: (context, index) {
              final page = controller.pages[index];
              return InkWell(
                onTap: () {
                  controller.setCurrentPage(index);
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ChangeNotifierProvider.value(
                        value: controller,
                        child: EditorScreen(),
                      ),
                    ),
                  );
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.paper,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: const [
                      BoxShadow(
                        color: AppColors.shadow,
                        blurRadius: 10,
                        offset: Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Expanded(
                        child: Center(
                          child: Icon(
                            page.isBookmarked
                                ? Icons.bookmark
                                : Icons.description_outlined,
                            size: 40,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(page.title),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _OutlineView extends StatelessWidget {
  const _OutlineView();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      title: 'Outline coming soon',
      message: 'Outline view will list headings and bookmarks.',
    );
  }
}
