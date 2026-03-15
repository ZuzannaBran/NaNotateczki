import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/empty_state.dart';
import '../../notebook/data/notebook_repository.dart';
import '../../notebook/domain/notebook.dart';
import '../../notebook/presentation/notebook_screen.dart';
import '../../editor/state/editor_controller.dart';
import 'library_controller.dart';
import 'widgets/notebook_card.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<LibraryController>().initialize();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LibraryController>();
    final notebook = controller.selectedNotebook();

    return Scaffold(
      appBar: AppBar(
        title: SizedBox(
          width: 360,
          child: TextField(
            decoration: InputDecoration(
              hintText: 'Search notebooks',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: controller.searchQuery.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => controller.setSearchQuery(''),
                    ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: controller.setSearchQuery,
          ),
        ),
        actions: [
          PopupMenuButton<_LibraryMenuAction>(
            onSelected: (action) => _handleMenu(action, controller),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _LibraryMenuAction.setCloudFolder,
                child: Text('Set cloud folder'),
              ),
              PopupMenuItem(
                value: _LibraryMenuAction.syncNow,
                child: Text('Sync now'),
              ),
              PopupMenuItem(
                value: _LibraryMenuAction.exportBackup,
                child: Text('Export backup'),
              ),
              PopupMenuItem(
                value: _LibraryMenuAction.importBackup,
                child: Text('Import backup'),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New notebook',
            onPressed: controller.createNotebook,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 980;
          if (isWide) {
            return Row(
              children: [
                SizedBox(
                  width: 300,
                  child: _NotebookListPane(
                    controller: controller,
                    onOpen: (item) => controller.selectNotebook(item.uid),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _NotebookWorkspace(notebook: notebook)),
              ],
            );
          }

          return _NotebookListPane(
            controller: controller,
            onOpen: (item) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => _NotebookRoute(notebook: item),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _handleMenu(
    _LibraryMenuAction action,
    LibraryController controller,
  ) async {
    if (action == _LibraryMenuAction.exportBackup) {
      final path = await controller.exportBackup();
      _showMessage('Backup saved to $path');
      return;
    }
    if (action == _LibraryMenuAction.setCloudFolder) {
      final path = await _promptCloudPath(controller.cloudPath ?? '');
      if (path == null || path.isEmpty) {
        return;
      }
      await controller.setCloudPath(path);
      _showMessage('Cloud folder set to $path');
      return;
    }
    if (action == _LibraryMenuAction.syncNow) {
      try {
        await controller.syncNow();
        final result = controller.lastSyncResult;
        if (result == null) {
          _showMessage('Synced.');
          return;
        }
        _showMessage(
          'Synced ${result.totalNotebooks} notebooks '
          '(up ${result.uploaded}, down ${result.downloaded}).',
        );
      } catch (error) {
        _showMessage('Sync failed: $error');
      }
      return;
    }
    if (action == _LibraryMenuAction.importBackup) {
      final path = await _promptImportPath();
      if (path == null || path.isEmpty) {
        return;
      }
      try {
        await controller.importBackup(path);
        _showMessage('Backup imported.');
      } catch (error) {
        _showMessage('Import failed: $error');
      }
    }
  }

  Future<String?> _promptImportPath() async {
    final textController = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Import backup'),
          content: TextField(
            controller: textController,
            decoration: const InputDecoration(hintText: '/path/to/backup.json'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(textController.text),
              child: const Text('Import'),
            ),
          ],
        );
      },
    );
  }

  Future<String?> _promptCloudPath(String current) async {
    final textController = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Cloud folder'),
          content: TextField(
            controller: textController,
            decoration: const InputDecoration(
              hintText: '/path/to/cloud/folder',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(textController.text),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

enum _LibraryMenuAction { setCloudFolder, syncNow, exportBackup, importBackup }

class _NotebookListPane extends StatelessWidget {
  const _NotebookListPane({required this.controller, required this.onOpen});

  final LibraryController controller;
  final ValueChanged<Notebook> onOpen;

  @override
  Widget build(BuildContext context) {
    if (controller.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (controller.notebooks.isEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'No notebooks yet',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                'Create your first notebook to get started.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: controller.createNotebook,
                icon: const Icon(Icons.add),
                label: const Text('Create notebook'),
              ),
            ],
          ),
        ),
      );
    }

    if (controller.visibleNotebooks.isEmpty) {
      return const EmptyState(
        title: 'No results',
        message: 'Try a different search query.',
      );
    }

    return ListView.separated(
      itemCount: controller.visibleNotebooks.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final notebook = controller.visibleNotebooks[index];
        return NotebookCard(
          notebook: notebook,
          selected: notebook.uid == controller.selectedNotebookId,
          onTap: () => onOpen(notebook),
          onDelete: () => controller.deleteNotebook(notebook.uid),
        );
      },
    );
  }
}

class _NotebookWorkspace extends StatelessWidget {
  const _NotebookWorkspace({required this.notebook});

  final Notebook? notebook;

  @override
  Widget build(BuildContext context) {
    if (notebook == null) {
      return const EmptyState(
        title: 'Pick a notebook',
        message: 'Select a notebook from the list or create a new one.',
      );
    }

    final repository = context.read<NotebookRepository>();
    return ChangeNotifierProvider(
      key: ValueKey(notebook!.uid),
      create: (_) =>
          EditorController(repository: repository, notebook: notebook!),
      child: const NotebookScreen(),
    );
  }
}

class _NotebookRoute extends StatelessWidget {
  const _NotebookRoute({required this.notebook});

  final Notebook notebook;

  @override
  Widget build(BuildContext context) {
    final repository = context.read<NotebookRepository>();
    return ChangeNotifierProvider(
      create: (_) =>
          EditorController(repository: repository, notebook: notebook),
      child: const NotebookScreen(),
    );
  }
}
