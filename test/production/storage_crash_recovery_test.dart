import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:program/core/storage/text_storage.dart';

class _DocumentsPathProvider extends PathProviderPlatform {
  _DocumentsPathProvider(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documents;
  late PathProviderPlatform originalProvider;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('atomic-text-test-');
    originalProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _DocumentsPathProvider(documents.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalProvider;
    await documents.delete(recursive: true);
  });

  test('interrupted replacement restores last committed text', () async {
    await writeStoredText('app_prefs.json', 'committed');
    final file = File('${documents.path}/app_prefs.json');
    await file.rename('${file.path}.previous');
    await File('${file.path}.tmp').writeAsString('truncated');

    expect(await readStoredText('app_prefs.json'), 'committed');
    expect(await file.readAsString(), 'committed');
    expect(await File('${file.path}.tmp').exists(), isFalse);
    expect(await File('${file.path}.previous').exists(), isFalse);
  });

  test('uncommitted temporary data never replaces a valid file', () async {
    await writeStoredText('app_prefs.json', 'stable');
    final file = File('${documents.path}/app_prefs.json');
    await File('${file.path}.tmp').writeAsString('new but uncommitted');

    expect(await readStoredText('app_prefs.json'), 'stable');
    expect(await File('${file.path}.tmp').exists(), isFalse);
  });

  test('committed new file wins over a leftover previous copy', () async {
    await writeStoredText('app_prefs.json', 'new');
    final file = File('${documents.path}/app_prefs.json');
    await File('${file.path}.previous').writeAsString('old');
    await File('${file.path}.tmp').writeAsString('incomplete');

    expect(await readStoredText('app_prefs.json'), 'new');
    expect(await File('${file.path}.previous').exists(), isFalse);
    expect(await File('${file.path}.tmp').exists(), isFalse);
  });

  test('concurrent writes to one key commit in invocation order', () async {
    final writes = List<Future<void>>.generate(
      30,
      (index) => writeStoredText('app_prefs.json', 'value-$index'),
    );
    await Future.wait(writes);

    expect(await readStoredText('app_prefs.json'), 'value-29');
    expect(
      await File('${documents.path}/app_prefs.json.tmp').exists(),
      isFalse,
    );
  });

  test(
    'failed filesystem write does not destroy last good settings',
    () async {
      await writeStoredText('app_prefs.json', 'last good');
      final blocker = File('${documents.path}/not-a-directory');
      await blocker.writeAsString('occupied');
      PathProviderPlatform.instance = _DocumentsPathProvider(blocker.path);
  
      await expectLater(
        writeStoredText('app_prefs.json', 'must not commit'),
        throwsA(isA<FileSystemException>()),
      );
  
      PathProviderPlatform.instance = _DocumentsPathProvider(documents.path);
      expect(await readStoredText('app_prefs.json'), 'last good');
      await writeStoredText('app_prefs.json', 'retry succeeded');
      expect(await readStoredText('app_prefs.json'), 'retry succeeded');
    },
  );
}
