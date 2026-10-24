import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';

void main() {
  late Directory fixture;
  late String helper;
  setUp(() async {
    fixture = await Directory('/tmp').createTemp('bsg-bridge-environment-');
    helper = '${fixture.path}/busystack-git-helper';
    final build = await Process.run('cc', [
      '-std=c11',
      '-O2',
      '-Wall',
      '-Wextra',
      '-Werror',
      'native/git_helper.c',
      '-o',
      helper,
    ]);
    expect(build.exitCode, 0, reason: '${build.stderr}');
  });
  tearDown(() => fixture.delete(recursive: true));

  Future<ProcessResult> child(String temporary, String mode) async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        'test/support/editor_bridge_environment_driver.dart',
        helper,
        mode,
      ],
      environment: {'TMPDIR': temporary, 'BUSYSTACK_GIT_HELPER_PATH': helper},
    );
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    int code;
    try {
      code = await process.exitCode.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      rethrow;
    }
    return ProcessResult(process.pid, code, await out, await err);
  }

  test(
    'editor and sequence callbacks work with a long Unicode TMPDIR',
    () async {
      final long = await Directory('${fixture.path}/${'路径-é-' * 20}').create();
      expect(utf8.encode(long.path).length, greaterThan(108));
      final result = await child(long.path, 'callbacks');
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        result.stdout,
        contains('private editor and sequence callbacks verified'),
      );
      expect(await long.list().toList(), isEmpty);
    },
  );

  test(
    'an unusable prompt directory returns a structured failure without deleting existing data',
    () async {
      final marker = File('${fixture.path}/not-a-directory');
      await marker.writeAsString('Preserve existing data.');
      final result = await child(marker.path, 'unavailable');
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        result.stdout,
        contains('structured private-channel failure verified'),
      );
      expect(await marker.readAsString(), 'Preserve existing data.');
    },
  );
}
