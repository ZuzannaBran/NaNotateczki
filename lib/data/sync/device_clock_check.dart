import 'api_client.dart';

/// Difference between the device's UTC clock and the API clock.
class DeviceClockDifference {
  const DeviceClockDifference({
    required this.offset,
    required this.roundTrip,
  });

  /// Positive means the server is ahead of the device.
  final Duration offset;
  final Duration roundTrip;

  static const tolerance = Duration(minutes: 1);

  bool get isSignificant =>
      offset.inMilliseconds.abs() >
      tolerance.inMilliseconds + roundTrip.inMilliseconds ~/ 2;
}

/// Measures clock drift without relying on the device's time zone.
class DeviceClockCheck {
  DeviceClockCheck({
    required this.apiClient,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ApiClient apiClient;
  final DateTime Function() _clock;

  /// Returns null when network delay or a clock jump makes the result unsafe.
  Future<DeviceClockDifference?> measure() async {
    final startedAt = _clock().toUtc();
    final stopwatch = Stopwatch()..start();
    final response = await apiClient.get('/v1/time', authenticated: false);
    stopwatch.stop();
    final finishedAt = _clock().toUtc();

    if (stopwatch.elapsed > const Duration(seconds: 10) ||
        (finishedAt.difference(startedAt) - stopwatch.elapsed)
                .inMilliseconds
                .abs() >
            2000) {
      return null;
    }

    final decoded = response.decodeJson();
    if (decoded is! Map<String, dynamic> ||
        decoded['serverTimeMs'] is! int) {
      throw const FormatException('Invalid API clock response.');
    }
    final serverTime = DateTime.fromMillisecondsSinceEpoch(
      decoded['serverTimeMs'] as int,
      isUtc: true,
    );
    final midpoint = startedAt.add(
      Duration(microseconds: stopwatch.elapsedMicroseconds ~/ 2),
    );
    return DeviceClockDifference(
      offset: serverTime.difference(midpoint),
      roundTrip: stopwatch.elapsed,
    );
  }
}
