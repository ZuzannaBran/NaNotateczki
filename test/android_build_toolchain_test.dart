import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android Kotlin plugin meets Flutter minimum 2.3.20', () {
    final gradleSettings = File(
      'android/settings.gradle.kts',
    ).readAsStringSync();
    final match = RegExp(
      r'id\("org\.jetbrains\.kotlin\.android"\)\s+version\s+"(\d+)\.(\d+)\.(\d+)"',
    ).firstMatch(gradleSettings);

    expect(match, isNotNull, reason: 'Kotlin plugin version must be pinned.');
    final major = int.parse(match!.group(1)!);
    final minor = int.parse(match.group(2)!);
    final patch = int.parse(match.group(3)!);
    final supported =
        major > 2 || (major == 2 && (minor > 3 || (minor == 3 && patch >= 20)));

    expect(supported, isTrue, reason: 'Minimum supported version: 2.3.20.');
  });
  test('Android Kotlin uses typed JVM 17 compiler options', () {
    final buildScript = File('android/app/build.gradle.kts').readAsStringSync();

    expect(buildScript, isNot(contains('kotlinOptions {')));
    expect(buildScript, contains('compilerOptions {'));
    expect(buildScript, contains('jvmTarget.set(JvmTarget.JVM_17)'));
  });
  test('legacy CargoKit requires the verified Gradle 8 toolchain', () {
    final lock = File('pubspec.lock').readAsStringSync();
    final wrapper = File(
      'android/gradle/wrapper/gradle-wrapper.properties',
    ).readAsStringSync();
    final config = File('android/settings.gradle.kts').readAsStringSync();

    expect(lock, contains('irondash_engine_context:'));
    expect(wrapper, contains('gradle-8.14-all.zip'));
    expect(config, contains('id("com.android.application") version "8.11.1"'));
  });
}
