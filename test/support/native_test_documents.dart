import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:program/core/storage/text_storage.dart';
import 'package:program/features/editor/state/ink_color_presets.dart';

class _IsolatedDocumentsProvider extends PathProviderPlatform {
  _IsolatedDocumentsProvider(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void useIsolatedNativeTestDocuments() {
  late Directory directory;
  late PathProviderPlatform originalProvider;

  setUpAll(() async {
    originalProvider = PathProviderPlatform.instance;
    directory = await Directory.systemTemp.createTemp('native-test-documents-');
    PathProviderPlatform.instance = _IsolatedDocumentsProvider(directory.path);
  });

  tearDownAll(() async {
    await waitForPendingTextStorageOperations();
    PathProviderPlatform.instance = originalProvider;
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });
}

/// Keeps widget tests deterministic without performing disk I/O in FakeAsync.
void useInMemoryTestTextStorage() {
  final values = <String, String>{};
  setUp(() {
    SharedRecentColors.resetPendingForTests();
    values.clear();
    textStorageReadOverride = (key) async => values[key];
    textStorageWriteOverride = (key, value) async {
      values[key] = value;
    };
  });
  tearDown(() {
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
  });
}
