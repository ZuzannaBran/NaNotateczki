import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _IsolatedDocumentsProvider extends PathProviderPlatform {
  _IsolatedDocumentsProvider(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
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
    await Future<void>.delayed(const Duration(milliseconds: 100));
    PathProviderPlatform.instance = originalProvider;
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });
}
