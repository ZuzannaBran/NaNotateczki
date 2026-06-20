import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/diagnostics/optimization_log.dart';
import '../../../core/error/app_error_log.dart';
import '../../../core/input/app_preferences_controller.dart';
import '../../notebook/domain/notebook_kind.dart';
import '../state/editor_controller.dart';
import '../state/input_mode.dart';
import '../state/page_background.dart';
import 'widgets/page_background_paint.dart';

class EditorSettingsScreen extends StatelessWidget {
  const EditorSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditorController>();
    final preferences = context.watch<AppPreferencesController>();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: DefaultTabController(
        length: 3,
        child: Column(
          children: [
            const Material(
              color: Colors.transparent,
              child: TabBar(
                tabs: [
                  Tab(text: 'System'),
                  Tab(text: 'Visual'),
                  Tab(text: 'Widgets'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  ListView(
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 16,
                    ),
                    children: [
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                        ),
                        title: const Text('Device mode'),
                        subtitle: Text(preferences.deviceInputMode.description),
                        trailing: SegmentedButton<DeviceInputMode>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(
                              value: DeviceInputMode.computer,
                              label: Text('Computer'),
                            ),
                            ButtonSegment(
                              value: DeviceInputMode.tablet,
                              label: Text('Tablet'),
                            ),
                          ],
                          selected: {preferences.deviceInputMode},
                          onSelectionChanged: (selection) {
                            preferences.setDeviceInputMode(selection.single);
                          },
                        ),
                      ),
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                        ),
                        title: const Text('Stylus and touch'),
                        subtitle: Text(controller.pointerInputMode.description),
                        trailing: SegmentedButton<PointerInputMode>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(
                              value: PointerInputMode.off,
                              label: Text('Off'),
                            ),
                            ButtonSegment(
                              value: PointerInputMode.on,
                              label: Text('On'),
                            ),
                          ],
                          selected: {controller.pointerInputMode},
                          onSelectionChanged: (selection) {
                            controller.setPointerInputMode(selection.single);
                          },
                        ),
                      ),
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                        ),
                        title: const Text('Stylus buttons'),
                        subtitle: const Text(
                          'Use stylus buttons to switch eraser.',
                        ),
                        trailing: SegmentedButton<bool>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(value: false, label: Text('Off')),
                            ButtonSegment(value: true, label: Text('On')),
                          ],
                          selected: {controller.stylusButtonsEnabled},
                          onSelectionChanged: (selection) {
                            controller.setStylusButtonsEnabled(
                              selection.single,
                            );
                          },
                        ),
                      ),
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                        ),
                        title: const Text('Scribble eraser'),
                        subtitle: const Text(
                          'Erase ink by scribbling over it with the pen.',
                        ),
                        trailing: SegmentedButton<bool>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(value: false, label: Text('Off')),
                            ButtonSegment(value: true, label: Text('On')),
                          ],
                          selected: {controller.scratchEraseEnabled},
                          onSelectionChanged: (selection) {
                            controller.setScratchEraseEnabled(selection.single);
                          },
                        ),
                      ),
                      AnimatedBuilder(
                        animation: AppErrorLog.instance,
                        builder: (context, _) {
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            title: const Text('Errors'),
                            subtitle: Text(
                              AppErrorLog.instance.isEmpty
                                  ? 'No errors recorded.'
                                  : '${AppErrorLog.instance.length} recorded.',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _showErrorsDialog(context),
                          );
                        },
                      ),
                      AnimatedBuilder(
                        animation: OptimizationLog.instance,
                        builder: (context, _) {
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            title: const Text('Optimization'),
                            subtitle: Text(
                              OptimizationLog.instance.isEmpty
                                  ? 'No suspicious events recorded.'
                                  : '${OptimizationLog.instance.length} recorded.',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _showOptimizationDialog(context),
                          );
                        },
                      ),
                    ],
                  ),
                  ListView(
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 16,
                    ),
                    children: [
                      _BackgroundSection(
                        title: 'Notebook default',
                        settings: controller.defaultBackgroundSettingsForKind(
                          NotebookKind.notebook,
                        ),
                        onChanged: (settings) =>
                            controller.setDefaultBackgroundSettings(
                              NotebookKind.notebook,
                              settings,
                            ),
                      ),
                      const SizedBox(height: 20),
                      _BackgroundSection(
                        title: 'Board default',
                        settings: controller.defaultBackgroundSettingsForKind(
                          NotebookKind.board,
                        ),
                        onChanged: (settings) =>
                            controller.setDefaultBackgroundSettings(
                              NotebookKind.board,
                              settings,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showErrorsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      return AnimatedBuilder(
        animation: AppErrorLog.instance,
        builder: (context, _) {
          final logText = AppErrorLog.instance.toClipboardText();
          return AlertDialog(
            title: const Text('Errors'),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      AppErrorLog.instance.isEmpty
                          ? 'No errors recorded.'
                          : '${AppErrorLog.instance.length} errors recorded.',
                    ),
                    const SizedBox(height: 12),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('Preview'),
                      children: [
                        Container(
                          width: double.infinity,
                          constraints: const BoxConstraints(maxHeight: 280),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Theme.of(context).dividerColor,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: SingleChildScrollView(
                            child: SelectableText(
                              logText,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: AppErrorLog.instance.isEmpty
                    ? null
                    : AppErrorLog.instance.clear,
                child: const Text('Clear'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
              FilledButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: logText));
                  if (!context.mounted) {
                    return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Errors copied.')),
                  );
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy'),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<void> _showOptimizationDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      return AnimatedBuilder(
        animation: OptimizationLog.instance,
        builder: (context, _) {
          final logText = OptimizationLog.instance.toClipboardText();
          return AlertDialog(
            title: const Text('Optimization'),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      OptimizationLog.instance.isEmpty
                          ? 'No suspicious optimization events recorded.'
                          : '${OptimizationLog.instance.length} suspicious events recorded.',
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Filtered entries only. Terminal output still keeps all raw diagnostic logs.',
                    ),
                    const SizedBox(height: 12),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('Preview'),
                      children: [
                        Container(
                          width: double.infinity,
                          constraints: const BoxConstraints(maxHeight: 280),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Theme.of(context).dividerColor,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: SingleChildScrollView(
                            child: SelectableText(
                              logText,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: OptimizationLog.instance.isEmpty
                    ? null
                    : OptimizationLog.instance.clear,
                child: const Text('Clear'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
              FilledButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: logText));
                  if (!context.mounted) {
                    return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Optimization log copied.')),
                  );
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy'),
              ),
            ],
          );
        },
      );
    },
  );
}

class _BackgroundSection extends StatelessWidget {
  const _BackgroundSection({
    required this.title,
    required this.settings,
    required this.onChanged,
  });

  final String title;
  final PageBackgroundSettings settings;
  final ValueChanged<PageBackgroundSettings> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        SegmentedButton<PageBackgroundStyle>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: PageBackgroundStyle.blank,
              icon: Icon(Icons.crop_square),
              label: Text('Plain'),
            ),
            ButtonSegment(
              value: PageBackgroundStyle.grid,
              icon: Icon(Icons.grid_4x4),
              label: Text('Grid'),
            ),
            ButtonSegment(
              value: PageBackgroundStyle.lines,
              icon: Icon(Icons.density_medium),
              label: Text('Lines'),
            ),
          ],
          selected: {settings.style},
          onSelectionChanged: (selection) {
            onChanged(settings.copyWith(style: selection.single));
          },
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const SizedBox(width: 56, child: Text('Density')),
            Expanded(
              child: Slider(
                value: settings.spacing,
                min: PageBackgroundSettings.minSpacing,
                max: PageBackgroundSettings.maxSpacing,
                divisions: 12,
                onChanged: (value) {
                  onChanged(settings.copyWith(spacing: value));
                },
              ),
            ),
          ],
        ),
        PageBackgroundPreview(settings: settings),
      ],
    );
  }
}
