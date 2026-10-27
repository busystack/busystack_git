import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';

void main() {
  for (final scenario in [
    'queries',
    'mutations',
    'prompts',
    'lifecycle',
    'cancellation',
  ]) {
    test(
      'background engine preserves $scenario through the real adapter',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'bsg-background-host-',
        );
        final home = await Directory('${root.path}/home').create();
        final runtime = await Directory('${root.path}/runtime').create();
        await Process.run('/bin/chmod', ['0700', runtime.path]);
        final child = await Process.start(
          Platform.resolvedExecutable,
          [
            '--packages=${File('.dart_tool/package_config.json').absolute.path}',
            'test/support/background_client_driver.dart',
            scenario,
          ],
          includeParentEnvironment: false,
          environment: {
            'PATH': '/usr/bin:/bin',
            'HOME': home.path,
            'XDG_CONFIG_HOME': home.path,
            'XDG_RUNTIME_DIR': runtime.path,
            'TMPDIR': root.path,
            'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_CONFIG_GLOBAL': '/dev/null',
            'BUSYSTACK_GIT_EXECUTABLE':
                Platform.environment['BUSYSTACK_TEST_GIT'] ?? '/usr/bin/git',
            'BUSYSTACK_GIT_HELPER_PATH':
                Platform.environment['BUSYSTACK_GIT_HELPER_PATH'] ?? '',
          },
        );
        final output = child.stdout.transform(utf8.decoder).join();
        final errors = child.stderr.transform(utf8.decoder).join();
        try {
          final code = await child.exitCode.timeout(
            const Duration(seconds: 60),
          );
          expect(code, 0, reason: '${await output}\n${await errors}');
          expect(await output, contains('PASS $scenario'));
        } finally {
          child.kill(ProcessSignal.sigterm);
          await child.exitCode;
          await root.delete(recursive: true);
        }
      },
    );
  }
}
