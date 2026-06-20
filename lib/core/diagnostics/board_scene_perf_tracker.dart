import 'package:flutter/foundation.dart';

class BoardScenePerfTracker {
  BoardScenePerfTracker._();

  static final BoardScenePerfTracker instance = BoardScenePerfTracker._();

  final List<_BoardSceneSample> _samples = <_BoardSceneSample>[];
  int _nextSequence = 1;

  int captureCursor() => _nextSequence;

  void recordBuild(int elapsedUs) {
    _record('sceneBuild', elapsedUs);
  }

  void recordPaint(String layer, int elapsedUs) {
    _record(layer, elapsedUs);
  }

  BoardScenePerfSummary summarySince(int cursor) {
    final matching = _samples.where((sample) => sample.sequence >= cursor);
    final sceneBuild = _BoardSceneAggregate();
    final scenePaint = _BoardSceneAggregate();
    final backgroundPaint = _BoardSceneAggregate();
    final inactiveOverlayPaint = _BoardSceneAggregate();
    final canvasHostPaint = _BoardSceneAggregate();
    final activeOverlayPaint = _BoardSceneAggregate();

    for (final sample in matching) {
      switch (sample.label) {
        case 'sceneBuild':
          sceneBuild.add(sample.elapsedUs);
        case 'scenePaint':
          scenePaint.add(sample.elapsedUs);
        case 'backgroundPaint':
          backgroundPaint.add(sample.elapsedUs);
        case 'inactiveOverlayPaint':
          inactiveOverlayPaint.add(sample.elapsedUs);
        case 'canvasHostPaint':
          canvasHostPaint.add(sample.elapsedUs);
        case 'activeOverlayPaint':
          activeOverlayPaint.add(sample.elapsedUs);
      }
    }

    return BoardScenePerfSummary(
      sceneBuildAvgUs: sceneBuild.avgUs,
      sceneBuildMaxUs: sceneBuild.maxUs,
      scenePaintAvgUs: scenePaint.avgUs,
      scenePaintMaxUs: scenePaint.maxUs,
      backgroundPaintAvgUs: backgroundPaint.avgUs,
      backgroundPaintMaxUs: backgroundPaint.maxUs,
      inactiveOverlayPaintAvgUs: inactiveOverlayPaint.avgUs,
      inactiveOverlayPaintMaxUs: inactiveOverlayPaint.maxUs,
      canvasHostPaintAvgUs: canvasHostPaint.avgUs,
      canvasHostPaintMaxUs: canvasHostPaint.maxUs,
      activeOverlayPaintAvgUs: activeOverlayPaint.avgUs,
      activeOverlayPaintMaxUs: activeOverlayPaint.maxUs,
    );
  }

  void _record(String label, int elapsedUs) {
    if (!kDebugMode) {
      return;
    }
    _samples.add(
      _BoardSceneSample(
        sequence: _nextSequence++,
        label: label,
        elapsedUs: elapsedUs,
      ),
    );
    if (_samples.length > 1200) {
      _samples.removeRange(0, _samples.length - 1200);
    }
  }
}

class BoardScenePerfSummary {
  const BoardScenePerfSummary({
    required this.sceneBuildAvgUs,
    required this.sceneBuildMaxUs,
    required this.scenePaintAvgUs,
    required this.scenePaintMaxUs,
    required this.backgroundPaintAvgUs,
    required this.backgroundPaintMaxUs,
    required this.inactiveOverlayPaintAvgUs,
    required this.inactiveOverlayPaintMaxUs,
    required this.canvasHostPaintAvgUs,
    required this.canvasHostPaintMaxUs,
    required this.activeOverlayPaintAvgUs,
    required this.activeOverlayPaintMaxUs,
  });

  final int sceneBuildAvgUs;
  final int sceneBuildMaxUs;
  final int scenePaintAvgUs;
  final int scenePaintMaxUs;
  final int backgroundPaintAvgUs;
  final int backgroundPaintMaxUs;
  final int inactiveOverlayPaintAvgUs;
  final int inactiveOverlayPaintMaxUs;
  final int canvasHostPaintAvgUs;
  final int canvasHostPaintMaxUs;
  final int activeOverlayPaintAvgUs;
  final int activeOverlayPaintMaxUs;

  String toLogString() {
    return 'sceneBuildUsAvg=$sceneBuildAvgUs '
        'sceneBuildUsMax=$sceneBuildMaxUs '
        'scenePaintUsAvg=$scenePaintAvgUs '
        'scenePaintUsMax=$scenePaintMaxUs '
        'bgPaintUsAvg=$backgroundPaintAvgUs '
        'bgPaintUsMax=$backgroundPaintMaxUs '
        'inactiveOverlayPaintUsAvg=$inactiveOverlayPaintAvgUs '
        'inactiveOverlayPaintUsMax=$inactiveOverlayPaintMaxUs '
        'canvasHostPaintUsAvg=$canvasHostPaintAvgUs '
        'canvasHostPaintUsMax=$canvasHostPaintMaxUs '
        'activeOverlayPaintUsAvg=$activeOverlayPaintAvgUs '
        'activeOverlayPaintUsMax=$activeOverlayPaintMaxUs';
  }
}

class _BoardSceneSample {
  const _BoardSceneSample({
    required this.sequence,
    required this.label,
    required this.elapsedUs,
  });

  final int sequence;
  final String label;
  final int elapsedUs;
}

class _BoardSceneAggregate {
  int _samples = 0;
  int _totalUs = 0;
  int _maxUs = 0;

  void add(int elapsedUs) {
    _samples++;
    _totalUs += elapsedUs;
    if (elapsedUs > _maxUs) {
      _maxUs = elapsedUs;
    }
  }

  int get avgUs => _samples == 0 ? 0 : _totalUs ~/ _samples;

  int get maxUs => _maxUs;
}
