import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
