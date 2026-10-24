import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'byte_text.dart';
import 'models.dart';
import 'runner.dart';
import 'linux_paths.dart';
import 'native_helper.dart';

enum GitPromptKind { message, credential }

final class GitPrompt {
  const GitPrompt({
    required this.repository,
    required this.operationId,
    required this.kind,
    required this.title,
    this.initialText = '',
  });
  final RepositoryId repository;
  final String operationId, title, initialText;
  final GitPromptKind kind;
}

typedef GitPromptHandler =
    Future<Uint8List?> Function(GitPrompt prompt, GitCancellation cancellation);

final class GitEditorBridge {
  GitEditorBridge._(
    this.repository,
    this.directory,
    this.server,
    this.helper,
    this.handler,
    this.cancellation,
    this.captureSequence,
    this.preparedTodo,
  );
  final RepositoryId repository;
  final Directory directory;
  final ServerSocket server;
  final String helper;
  final GitPromptHandler? handler;
  final GitCancellation cancellation;
  final bool captureSequence;
  final String? preparedTodo;
  final String token = _randomHex(32), operationId = _randomHex(16);
  final _sockets = <Socket>{};
  StreamSubscription<Socket>? _listener;
  Uint8List? capturedTodo;
  bool _closed = false;
  bool promptCancelled = false;
  GitException? failure;
  final _credentialSecrets = <String>{};
  String redact(String value) {
    var result = value;
    for (final secret in _credentialSecrets) {
      result = result.replaceAll(secret, '[redacted]');
    }
    return sanitizeGitDiagnostic(result);
  }

  GitException redactFailure(GitException failure) => GitException(
    failure.code,
    command: failure.command,
    diagnostic: redact(failure.diagnostic),
    exitCode: failure.exitCode,
  );
  static Future<GitEditorBridge> open(
    RepositoryId repository, {
    GitPromptHandler? handler,
    GitCancellation? cancellation,
    bool captureSequence = false,
    String? preparedTodo,
    String? helperPath,
  }) async {
    final helper = installedGitHelper(preferred: helperPath);
    if (helper == null)
      throw const GitException(
        GitErrorCode.unavailable,
        diagnostic: 'The installed Git editor/askpass helper is missing.',
      );
    final directory = await Directory.systemTemp.createTemp('bsg-prompt-');
    LinuxPaths.chmod(directory.path, 0x1c0);
    final socket = await ServerSocket.bind(
      InternetAddress('${directory.path}/s', type: InternetAddressType.unix),
      0,
    );
    LinuxPaths.chmod('${directory.path}/s', 0x180);
    final promptCancellation = GitCancellation();
    if (cancellation != null)
      unawaited(
        cancellation.whenCancelled.then((_) => promptCancellation.cancel()),
      );
    final bridge = GitEditorBridge._(
      repository,
      directory,
      socket,
      helper,
      handler,
      promptCancellation,
      captureSequence,
      preparedTodo,
    );
    bridge._listener = socket.listen((peer) {
      bridge._sockets.add(peer);
      unawaited(bridge._serve(peer));
    });
    return bridge;
  }

  Map<String, String> get environment => {
    'BUSYSTACK_GIT_PROMPT_SOCKET': '${directory.path}/s',
    'BUSYSTACK_GIT_PROMPT_TOKEN': token,
    'BUSYSTACK_GIT_OPERATION': operationId,
    'GIT_EDITOR': '${_quote(helper)} editor',
    'GIT_SEQUENCE_EDITOR': '${_quote(helper)} sequence',
    'GIT_ASKPASS': helper,
    'SSH_ASKPASS': helper,
    'SSH_ASKPASS_REQUIRE': 'prefer',
  };
  Future<void> _serve(Socket socket) async {
    final bytes = BytesBuilder();
    Future<void> reply(int code, [List<int> answer = const []]) async {
      final header = Uint8List(5);
      header[0] = code;
      ByteData.sublistView(header).setUint32(1, answer.length, Endian.big);
      socket.add(header);
      socket.add(answer);
      await socket.flush();
      await socket.close();
    }

    try {
      await for (final chunk in socket.timeout(const Duration(minutes: 10))) {
        bytes.add(chunk);
        if (bytes.length > 262245)
          throw const GitException(GitErrorCode.outputLimit);
        if (bytes.length < 105) continue;
        final data = bytes.toBytes(),
            length = ByteData.sublistView(data).getUint32(101, Endian.big);
        if (length > 262144 ||
            data.length > 105 + length ||
            ascii.decode(data.sublist(0, 4)) != 'BSG1' ||
            !_constantEquals(data.sublist(4, 68), ascii.encode(token)) ||
            !_constantEquals(data.sublist(68, 100), ascii.encode(operationId)))
          throw const GitException(GitErrorCode.invalidRequest);
        if (data.length < 105 + length) continue;
        final kind = data[100], value = decodeGitUtf8(data.sublist(105));
        if (_closed || cancellation.isCancelled) {
          await reply(1);
          return;
        }
        if (kind == 1 || kind == 2) {
          final file = await _editorFile(value, sequence: kind == 2);
          final initial = await file.readAsBytes();
          if (kind == 2) {
            if (captureSequence) {
              capturedTodo = initial;
              await reply(1);
              return;
            }
            if (preparedTodo == null) {
              await reply(1);
              return;
            }
            LinuxPaths.replaceExisting(
              utf8.encode(file.path),
              Uint8List.fromList(utf8.encode(preparedTodo!)),
            );
            await reply(0);
            return;
          }
          final answer = await _prompt(
            GitPrompt(
              repository: repository,
              operationId: operationId,
              kind: GitPromptKind.message,
              title: 'Git commit message',
              initialText: decodeGitUtf8(initial),
            ),
          );
          if (answer == null) {
            promptCancelled = true;
            await reply(1);
            return;
          }
          LinuxPaths.replaceExisting(utf8.encode(file.path), answer);
          await reply(0);
          return;
        }
        if (kind != 3) throw const GitException(GitErrorCode.invalidRequest);
        final answer = await _prompt(
          GitPrompt(
            repository: repository,
            operationId: operationId,
            kind: GitPromptKind.credential,
            title: sanitizeGitDiagnostic(value),
          ),
        );
        if (answer == null || answer.length > 65536) {
          promptCancelled = answer == null;
          await reply(1);
          return;
        }
        if (answer.isNotEmpty)
          _credentialSecrets.add(decodeGitUtf8(answer, allowMalformed: true));
        await reply(0, answer);
        answer.fillRange(0, answer.length, 0);
        return;
      }
    } on Object catch (error) {
      if (!_closed) {
        failure ??= error is GitException
            ? error
            : GitException(
                GitErrorCode.commandFailed,
                diagnostic: 'Git prompt bridge failed (${error.runtimeType}).',
              );
        try {
          await reply(1);
        } on IOException {
          socket.destroy();
        }
      }
    } finally {
      _sockets.remove(socket);
      socket.destroy();
    }
  }

  Future<Uint8List?> _prompt(GitPrompt prompt) async {
    if (handler == null || cancellation.isCancelled) return null;
    return Future.any<Uint8List?>([
      handler!(prompt, cancellation),
      cancellation.whenCancelled.then((_) => null),
    ]).timeout(const Duration(minutes: 10), onTimeout: () => null);
  }

  Future<File> _editorFile(String value, {required bool sequence}) async {
    final allowed = sequence
        ? {'git-rebase-todo'}
        : {'COMMIT_EDITMSG', 'MERGE_MSG', 'SQUASH_MSG'};
    if (!p.isAbsolute(value) || !allowed.contains(p.basename(value)))
      throw const GitException(GitErrorCode.unsafePath);
    final canonical = await File(value).resolveSymbolicLinks();
    if (canonical != p.normalize(value) ||
        !p.isWithin(repository.gitDir, canonical) ||
        await FileSystemEntity.type(value, followLinks: false) !=
            FileSystemEntityType.file ||
        await File(value).length() > 4 * 1024 * 1024) {
      throw const GitException(GitErrorCode.unsafePath);
    }
    return File(canonical);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    cancellation.cancel();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    await _listener?.cancel();
    await server.close();
    _credentialSecrets.clear();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

String _randomHex(int size) => List.generate(
  size,
  (_) => Random.secure().nextInt(256),
).map((e) => e.toRadixString(16).padLeft(2, '0')).join();
String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";
bool _constantEquals(List<int> a, List<int> b) {
  var difference = a.length ^ b.length;
  for (var i = 0; i < a.length && i < b.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}
