import 'dart:io';
import 'package:busystack_git/busystack_git.dart';

/// Test-only environment isolation. Production honors the user's effective
/// configuration; semantic fixtures must never inherit it.
final class IsolatedGitRunner implements GitRunner {
  IsolatedGitRunner(this.home, {String? executable, this.globalConfig})
    : process = ProcessGitRunner(
        executable: executable ?? Platform.environment['BUSYSTACK_TEST_GIT'],
      );
  final String home;
  final String? globalConfig;
  final ProcessGitRunner process;
  @override
  Future<GitRunResult> run(
    List<String> arguments, {
    required String cwd,
    List<int>? input,
    GitCancellation? cancellation,
    Duration? deadline,
    void Function(List<int>)? onStdout,
    void Function(String)? onProgress,
    String Function(String)? redactDiagnostic,
    Map<String, String> environment = const {},
    Map<int, List<int>> byteArguments = const {},
    int? maximumBytes,
  }) => process.run(
    arguments,
    cwd: cwd,
    input: input,
    cancellation: cancellation,
    deadline: deadline,
    onStdout: onStdout,
    onProgress: onProgress,
    redactDiagnostic: redactDiagnostic,
    byteArguments: byteArguments,
    maximumBytes: maximumBytes,
    environment: {
      'HOME': home,
      'XDG_CONFIG_HOME': home,
      'XDG_RUNTIME_DIR': '$home/runtime',
      'GIT_CONFIG_NOSYSTEM': '1',
      'GIT_CONFIG_GLOBAL': globalConfig ?? '/dev/null',
      'GIT_AUTHOR_NAME': 'Fixture',
      'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
      'GIT_COMMITTER_NAME': 'Fixture',
      'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
      'SSH_AUTH_SOCK': '$home/no-agent',
      ...environment,
    },
  );
  static Future<void> prepare(String home) async {
    await Directory('$home/runtime').create(recursive: true);
    final result = await Process.run('/bin/chmod', ['0700', '$home/runtime']);
    if (result.exitCode != 0)
      throw StateError('Cannot protect fixture runtime.');
  }
}
