import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

import 'byte_text.dart';
import 'models.dart';
import 'native_helper.dart';

final class GitCancellation {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void check() {
    if (isCancelled) throw const GitException(GitErrorCode.cancelled);
  }
}

final class GitRunResult {
  const GitRunResult(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final Uint8List stdout, stderr;
  String get text => decodeGitUtf8(stdout);
  String get diagnostic =>
      sanitizeGitDiagnostic(decodeGitUtf8(stderr, allowMalformed: true));
  bool get success => exitCode == 0;
  GitException get failure =>
      classifyGitFailure(diagnostic, exitCode: exitCode);
}

abstract interface class GitRunner {
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
  });
}

/// Only this class starts Git. The environment overrides are engine-internal;
/// adapters cannot submit command lines or environment through the public API.
final class ProcessGitRunner implements GitRunner {
  ProcessGitRunner({
    String? executable,
    this.helperPath,
    this.maximumOutputBytes = 32 * 1024 * 1024,
  }) : executable = executable ?? _defaultExecutable();
  final String executable;
  final String? helperPath;
  final int maximumOutputBytes;
  Future<String>? _version;
  static String _defaultExecutable() {
    final snap = Platform.environment['SNAP'];
    final directory = p.dirname(Platform.resolvedExecutable);
    final candidates = [
      if (Platform.environment['BUSYSTACK_GIT_EXECUTABLE'] case final path?)
        path,
      if (snap != null) '$snap/libexec/git-runtime/bin/git',
      p.join(directory, 'libexec/git-runtime/bin/git'),
      p.join(directory, 'git-runtime/bin/git'),
      p.normalize(
        p.join(directory, '../../lib/busyfiles/libexec/git-runtime/bin/git'),
      ),
    ];
    for (final path in candidates) {
      if (p.isAbsolute(path) && File(path).existsSync()) return path;
    }
    return '/usr/bin/git';
  }

  Future<String> verify() => _version ??= _verify();
  Future<String> _verify() async {
    if (!executable.startsWith('/') || !await File(executable).exists()) {
      throw const GitException(
        GitErrorCode.unavailable,
        diagnostic:
            'Git 2.56 or newer is required. Repair the application’s bundled Git runtime.',
      );
    }
    final result = await run(
      ['--version'],
      cwd: Directory.systemTemp.path,
      deadline: const Duration(seconds: 5),
    );
    final version = RegExp(
      r'git version (\d+)\.(\d+)\.(\d+)',
    ).firstMatch(result.text);
    if (!result.success ||
        version == null ||
        int.parse(version[1]!) < 2 ||
        (int.parse(version[1]!) == 2 && int.parse(version[2]!) < 56)) {
      throw const GitException(
        GitErrorCode.unsupportedVersion,
        diagnostic:
            'Git 2.56 or newer is required. Repair the bundled runtime or explicitly select a supported trusted executable.',
      );
    }
    return '${version[1]}.${version[2]}.${version[3]}';
  }

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
  }) async {
    cancellation?.check();
    final snap = Platform.environment['SNAP'];
    final launcher = Platform.isLinux
        ? installedGitHelper(preferred: helperPath)
        : null;
    if (Platform.isLinux && launcher == null)
      throw const GitException(
        GitErrorCode.unavailable,
        diagnostic:
            'The installed native Git process supervisor is missing. Repair the application package.',
      );
    final inherited = Map<String, String>.fromEntries(
      Platform.environment.entries.where(
        (e) =>
            !e.key.startsWith('GIT_') &&
            !const {
              'GIT_CONFIG',
              'GIT_DIR',
              'GIT_WORK_TREE',
              'GIT_COMMON_DIR',
              'GIT_INDEX_FILE',
            }.contains(e.key),
      ),
    );
    Process process;
    var command = executable;
    var commandArguments = arguments;
    if (byteArguments.isNotEmpty) {
      for (final entry in byteArguments.entries) {
        if (entry.key < 0 ||
            entry.key >= arguments.length ||
            entry.value.contains(0))
          throw const GitException(GitErrorCode.invalidRequest);
      }
      final helper = installedGitHelper(preferred: helperPath);
      if (helper == null)
        throw const GitException(
          GitErrorCode.unavailable,
          diagnostic:
              'The installed native Git helper is required for byte-sensitive filenames.',
        );
      command = helper;
      commandArguments = [
        '--git-argv',
        executable,
        for (var i = 0; i < arguments.length; i++)
          (byteArguments[i] ?? utf8.encode(arguments[i]))
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(),
      ];
    }
    try {
      process = await Process.start(
        Platform.isLinux ? launcher! : command,
        [
          if (Platform.isLinux) ...['--supervise', command],
          ...commandArguments,
        ],
        workingDirectory: cwd,
        includeParentEnvironment: false,
        runInShell: false,
        environment: {
          ...inherited,
          if (snap != null) ...{'GIT_SSH': '$snap/usr/bin/ssh'},
          if (executable.endsWith('/git-runtime/bin/git')) ...{
            'GIT_EXEC_PATH': p.normalize(
              p.join(p.dirname(executable), '../libexec/git-core'),
            ),
          },
          'GIT_TERMINAL_PROMPT': '0',
          'GIT_PAGER': 'cat',
          'PAGER': 'cat',
          'LC_ALL': 'C.UTF-8',
          'GIT_LITERAL_PATHSPECS': '1',
          ...environment,
          // Only the selected runner may name the executable used by the
          // operation-local reference guard. Never trust an inherited value.
          'BUSYSTACK_GIT_RUNTIME': executable,
        },
      );
    } on ProcessException {
      throw const GitException(GitErrorCode.unavailable);
    }
    final stdout = BytesBuilder(copy: false),
        stderr = BytesBuilder(copy: false);
    final limit = maximumBytes ?? maximumOutputBytes;
    var count = 0;
    final progressLine = <int>[];
    var progressLineOmitted = false;
    void flushProgress() {
      if (progressLineOmitted) {
        onProgress?.call('Git progress line exceeded the display limit.');
      } else if (progressLine.isNotEmpty) {
        final raw = decodeGitUtf8(progressLine, allowMalformed: true);
        onProgress?.call(
          sanitizeGitDiagnostic(redactDiagnostic?.call(raw) ?? raw),
        );
      }
      progressLine.clear();
      progressLineOmitted = false;
    }

    final overflow = Completer<void>();
    Future<void> collect(
      Stream<List<int>> source,
      BytesBuilder destination,
      bool progress,
    ) async {
      await for (final chunk in source) {
        final remaining = limit - count;
        if (remaining <= 0 || chunk.length > remaining) {
          if (!overflow.isCompleted) overflow.complete();
          if (remaining > 0) destination.add(chunk.sublist(0, remaining));
          count = limit;
          continue;
        }
        destination.add(chunk);
        count += chunk.length;
        if (progress) {
          for (final byte in chunk) {
            if (byte == 10 || byte == 13) {
              flushProgress();
            } else if (progressLine.length < 16384) {
              progressLine.add(byte);
            } else {
              progressLineOmitted = true;
            }
          }
        } else {
          onStdout?.call(chunk);
        }
      }
    }

    final out = collect(process.stdout, stdout, false);
    final err = collect(process.stderr, stderr, true);
    final write = () async {
      try {
        if (input != null) process.stdin.add(input);
        await process.stdin.close();
      } on IOException {
        // Git may reject the request before consuming stdin. Its exit is authoritative.
      }
    }();
    final finished = () async {
      final code = await process.exitCode;
      await Future.wait([out, err, write]);
      flushProgress();
      return code;
    }();
    Timer? timer;
    final expired = Completer<void>();
    if (deadline != null) timer = Timer(deadline, () => expired.complete());
    try {
      final code = await Future.any<int>([
        finished,
        overflow.future.then<int>(
          (_) => throw const GitException(GitErrorCode.outputLimit),
        ),
        if (cancellation != null)
          cancellation.whenCancelled.then<int>(
            (_) => throw const GitException(GitErrorCode.cancelled),
          ),
        if (deadline != null)
          expired.future.then<int>(
            (_) => throw const GitException(GitErrorCode.deadline),
          ),
      ]);
      final captured = stderr.takeBytes();
      return GitRunResult(
        code,
        stdout.takeBytes(),
        redactDiagnostic == null
            ? captured
            : Uint8List.fromList(
                utf8.encode(
                  redactDiagnostic(
                    decodeGitUtf8(captured, allowMalformed: true),
                  ),
                ),
              ),
      );
    } on Object {
      _signal(process, ProcessSignal.sigterm);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      _signal(process, ProcessSignal.sigkill);
      // A helper inheriting pipes must not keep the caller waiting indefinitely.
      try {
        await finished.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        /* Group has received SIGKILL; reconciliation follows. */
      }
      rethrow;
    } finally {
      timer?.cancel();
    }
  }

  void _signal(Process process, ProcessSignal signal) {
    if (Platform.isLinux) {
      final kill = DynamicLibrary.process()
          .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
            'kill',
          );
      kill(-process.pid, signal.signalNumber);
    }
    process.kill(signal);
  }
}

String sanitizeGitDiagnostic(String value) {
  final safe = value
      .replaceAllMapped(
        RegExp(r'([A-Za-z][A-Za-z0-9+.-]*://)[^\s/@]+(?::[^\s/@]*)?@'),
        (m) => '${m[1]}[redacted]@',
      )
      .replaceAllMapped(
        RegExp(r'([A-Za-z][A-Za-z0-9+.-]*://[^\s?#]+)[?#][^\s]*'),
        (m) => '${m[1]}?[redacted]',
      )
      .replaceAll(
        RegExp(
          r'([?&](?:token|access_token|password|key)=)[^\s&]+',
          caseSensitive: false,
        ),
        '[redacted]',
      )
      .replaceAll(
        RegExp(r'authorization:[^\r\n]+', caseSensitive: false),
        'Authorization: [redacted]',
      )
      .replaceAll(RegExp(r'\x1b\[[0-9;]*[A-Za-z]'), '')
      .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '');
  return safe.length <= 16384
      ? safe
      : '${safe.substring(0, 8000)}\n[diagnostic output truncated]\n${safe.substring(safe.length - 8000)}';
}

GitException classifyGitFailure(
  String diagnostic, {
  int? exitCode,
  String command = '',
}) {
  final text = diagnostic.toLowerCase();
  final code = switch (text) {
    _ when text.contains('busystack reviewed reference changed') =>
      GitErrorCode.staleReview,
    _ when text.contains('dubious ownership') => GitErrorCode.ownership,
    _
        when text.contains('author identity unknown') ||
            text.contains('unable to auto-detect email') ||
            text.contains('empty ident name') =>
      GitErrorCode.authorIdentity,
    _ when text.contains('index.lock') || text.contains('cannot lock ref') =>
      GitErrorCode.locked,
    _ when text.contains('host key verification failed') =>
      GitErrorCode.unknownHost,
    _
        when text.contains('authentication failed') ||
            text.contains('could not read username') ||
            text.contains('permission denied (publickey') =>
      GitErrorCode.authentication,
    _ when text.contains('gpg failed') || text.contains('failed to sign') =>
      GitErrorCode.signing,
    _ when text.contains('hook declined') => GitErrorCode.hook,
    _
        when text.contains('non-fast-forward') ||
            text.contains('stale info') ||
            text.contains('[rejected]') =>
      GitErrorCode.rejected,
    _
        when text.contains('would be overwritten') ||
            text.contains('unstaged changes') =>
      GitErrorCode.dirty,
    _
        when text.contains('transport') && text.contains('not allowed') ||
            text.contains('could not fetch') && text.contains('promisor') =>
      GitErrorCode.missingContent,
    _
        when text.contains('could not resolve host') ||
            text.contains('connection') =>
      GitErrorCode.transport,
    _ => GitErrorCode.commandFailed,
  };
  return GitException(
    code,
    command: command,
    diagnostic: diagnostic,
    exitCode: exitCode,
  );
}
