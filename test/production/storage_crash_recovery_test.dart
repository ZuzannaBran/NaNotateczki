import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:program/core/storage/app_data_directory.dart';
import 'package:program/core/storage/text_storage.dart';

class _DocumentsPathProvider extends PathProviderPlatform {
  _DocumentsPathProvider(this.path, {String? supportPath})
    : supportPath = supportPath ?? path;

  final String path;
  final String supportPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}

class _DelayedFirstSupportPathProvider extends _DocumentsPathProvider {
  _DelayedFirstSupportPathProvider(super.path);

  final firstRequestStarted = Completer<void>();
  final releaseFirstRequest = Completer<void>();
  var supportRequestCount = 0;

  @override
  Future<String?> getApplicationSupportPath() async {
    supportRequestCount += 1;
    if (supportRequestCount == 1) {
      firstRequestStarted.complete();
      await releaseFirstRequest.future;
    }
    return supportPath;
  }
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
    final file = File('${await getAppDataPath()}/app_prefs.json');
    await file.rename('${file.path}.previous');
    await File('${file.path}.tmp').writeAsString('truncated');

    expect(await readStoredText('app_prefs.json'), 'committed');
    expect(await file.readAsString(), 'committed');
    expect(await File('${file.path}.tmp').exists(), isFalse);
    expect(await File('${file.path}.previous').exists(), isFalse);
  });

  test('uncommitted temporary data never replaces a valid file', () async {
    await writeStoredText('app_prefs.json', 'stable');
    final file = File('${await getAppDataPath()}/app_prefs.json');
    await File('${file.path}.tmp').writeAsString('new but uncommitted');

    expect(await readStoredText('app_prefs.json'), 'stable');
    expect(await File('${file.path}.tmp').exists(), isFalse);
  });

  test('committed new file wins over a leftover previous copy', () async {
    await writeStoredText('app_prefs.json', 'new');
    final file = File('${await getAppDataPath()}/app_prefs.json');
    await File('${file.path}.previous').writeAsString('old');
    await File('${file.path}.tmp').writeAsString('incomplete');

    expect(await readStoredText('app_prefs.json'), 'new');
    expect(await File('${file.path}.previous').exists(), isFalse);
    expect(await File('${file.path}.tmp').exists(), isFalse);
  });

  test('concurrent writes to one key commit in invocation order', () async {
    final delayedProvider = _DelayedFirstSupportPathProvider(documents.path);
    PathProviderPlatform.instance = delayedProvider;
    final firstWrite = writeStoredText('app_prefs.json', 'first');
    await delayedProvider.firstRequestStarted.future;
    final secondWrite = writeStoredText('app_prefs.json', 'second');
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(delayedProvider.supportRequestCount, 1);
    delayedProvider.releaseFirstRequest.complete();
    await Future.wait([firstWrite, secondWrite]);
    expect(await readStoredText('app_prefs.json'), 'second');

    final writes = List<Future<void>>.generate(
      30,
      (index) => writeStoredText('app_prefs.json', 'value-$index'),
    );
    await Future.wait(writes);

    expect(await readStoredText('app_prefs.json'), 'value-29');
    expect(
      await File('${await getAppDataPath()}/app_prefs.json.tmp').exists(),
      isFalse,
    );
  });

  test('failed filesystem write does not destroy last good settings', () async {
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
  });
}
