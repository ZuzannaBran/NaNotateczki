import 'package:flutter/scheduler.dart';

class FrameTimingTracker {
  FrameTimingTracker._();

  static final FrameTimingTracker instance = FrameTimingTracker._();

  static const int _maxSamples = 240;

  final List<_FrameTimingSample> _samples = <_FrameTimingSample>[];

  bool _initialized = false;
  int _nextSequence = 1;

  void initialize() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    SchedulerBinding.instance.addTimingsCallback(_recordTimings);
  }

  int captureCursor() => _nextSequence;

  FrameTimingSummary summarySince(int cursor) {
    final matching = _samples.where((sample) => sample.sequence >= cursor);
    var frames = 0;
    var buildTotalUs = 0;
    var rasterTotalUs = 0;
    var totalTotalUs = 0;
    var buildMaxUs = 0;
    var rasterMaxUs = 0;
    var totalMaxUs = 0;
    var over16ms = 0;
    var over33ms = 0;

    for (final sample in matching) {
      frames++;
      buildTotalUs += sample.buildUs;
      rasterTotalUs += sample.rasterUs;
      totalTotalUs += sample.totalUs;
      if (sample.buildUs > buildMaxUs) {
        buildMaxUs = sample.buildUs;
      }
      if (sample.rasterUs > rasterMaxUs) {
        rasterMaxUs = sample.rasterUs;
      }
      if (sample.totalUs > totalMaxUs) {
        totalMaxUs = sample.totalUs;
      }
      if (sample.totalUs > 16667) {
        over16ms++;
      }
      if (sample.totalUs > 33333) {
        over33ms++;
      }
    }

    return FrameTimingSummary(
      frames: frames,
      buildAvgUs: frames == 0 ? 0 : buildTotalUs ~/ frames,
      buildMaxUs: buildMaxUs,
      rasterAvgUs: frames == 0 ? 0 : rasterTotalUs ~/ frames,
      rasterMaxUs: rasterMaxUs,
      totalAvgUs: frames == 0 ? 0 : totalTotalUs ~/ frames,
      totalMaxUs: totalMaxUs,
      over16ms: over16ms,
      over33ms: over33ms,
    );
  }

  void _recordTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      _samples.add(
        _FrameTimingSample(
          sequence: _nextSequence++,
          buildUs: timing.buildDuration.inMicroseconds,
          rasterUs: timing.rasterDuration.inMicroseconds,
          totalUs: timing.totalSpan.inMicroseconds,
        ),
      );
    }
    if (_samples.length > _maxSamples) {
      _samples.removeRange(0, _samples.length - _maxSamples);
    }
  }
}

class FrameTimingSummary {
  const FrameTimingSummary({
    required this.frames,
    required this.buildAvgUs,
    required this.buildMaxUs,
    required this.rasterAvgUs,
    required this.rasterMaxUs,
    required this.totalAvgUs,
    required this.totalMaxUs,
    required this.over16ms,
    required this.over33ms,
  });

  final int frames;
  final int buildAvgUs;
  final int buildMaxUs;
  final int rasterAvgUs;
  final int rasterMaxUs;
  final int totalAvgUs;
  final int totalMaxUs;
  final int over16ms;
  final int over33ms;

  String toLogString() {
    return 'ftFrames=$frames ftBuildAvgUs=$buildAvgUs '
        'ftBuildMaxUs=$buildMaxUs ftRasterAvgUs=$rasterAvgUs '
        'ftRasterMaxUs=$rasterMaxUs ftTotalAvgUs=$totalAvgUs '
        'ftTotalMaxUs=$totalMaxUs ftOver16=$over16ms ftOver33=$over33ms';
  }
}

class _FrameTimingSample {
  const _FrameTimingSample({
    required this.sequence,
    required this.buildUs,
    required this.rasterUs,
    required this.totalUs,
  });

  final int sequence;
  final int buildUs;
  final int rasterUs;
  final int totalUs;
}
