import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'models.dart';
import 'runner.dart';
import 'linux_paths.dart';

final class GitContext {
  GitContext(this.runner, this.authorized);
  final GitRunner runner;
  final bool Function(RepositoryId) authorized;
  final metadataPaths = <String, String>{};
  final diagnosticRedactors = <String, String Function(String)>{};
  String? _runtimeVersion;
  Future<String> runtimeVersion(RepositoryId repo) async =>
      _runtimeVersion ??= oneLine(
        (await runRepository(repo, ['--version'])).text,
      ).replaceFirst('git version ', '');
  Future<GitRunResult> run(
    String cwd,
    List<String> args, {
    bool passive = true,
    List<int>? input,
    GitCancellation? cancellation,
    Duration? deadline,
    Map<String, String> environment = const {},
    void Function(String)? progress,
    bool allowFailure = false,
    Map<int, List<int>> byteArguments = const {},
    int? maximumBytes,
  }) async {
    if (runner case final ProcessGitRunner process) await process.verify();
    final prefix = <String>[
      '--no-pager',
      '--literal-pathspecs',
      '-c',
      'color.ui=false',
      '-c',
      'core.quotepath=false',
      '-c',
      'i18n.logOutputEncoding=UTF-8',
      '-c',
      'diff.external=',
      '-c',
      'maintenance.auto=false',
      '-c',
      'gc.auto=0',
      '-c',
      'submodule.recurse=false',
      if (passive) ...[
        '-c',
        'core.fsmonitor=false',
        '-c',
        'core.hooksPath=/dev/null',
        for (final event in const [
          'applypatch-msg',
          'pre-applypatch',
          'post-applypatch',
          'pre-commit',
          'pre-merge-commit',
          'prepare-commit-msg',
          'commit-msg',
          'post-commit',
          'pre-rebase',
          'post-checkout',
          'post-merge',
          'pre-push',
          'pre-receive',
          'update',
          'proc-receive',
          'post-receive',
          'post-update',
          'reference-transaction',
          'push-to-checkout',
          'pre-auto-gc',
          'post-rewrite',
          'sendemail-validate',
          'fsmonitor-watchman',
          'post-index-change',
        ]) ...['-c', 'hook.$event.enabled=false'],
      ],
    ];
    final result = await runner.run(
      [...prefix, ...args],
      cwd: cwd,
      input: input,
      cancellation: cancellation,
      deadline:
          deadline ??
          (passive ? const Duration(seconds: 45) : const Duration(minutes: 30)),
      environment: {
        'GIT_OPTIONAL_LOCKS': passive ? '0' : '1',
        'GIT_NO_LAZY_FETCH': passive ? '1' : '0',
        // The empty transport allowlist also constrains internal promisor
        // subprocesses during restricted browsing.
        if (passive) 'GIT_ALLOW_PROTOCOL': '',
        if (!passive) ...{
          'GIT_EDITOR': '/bin/false',
          'GIT_SEQUENCE_EDITOR': '/bin/false',
        },
        ...environment,
      },
      onProgress: progress,
      maximumBytes: maximumBytes,
      redactDiagnostic:
          diagnosticRedactors[environment['BUSYSTACK_GIT_OPERATION']],
      byteArguments: {
        for (final entry in byteArguments.entries)
          entry.key + prefix.length: entry.value,
      },
    );
    if (!allowFailure && !result.success) {
      throw classifyGitFailure(
        result.diagnostic,
        exitCode: result.exitCode,
        command: args.first,
      );
    }
    return result;
  }

  /// Bind command execution to the reviewed worktree's metadata. Discovery and
  /// validateIdentity deliberately use unbound run() calls to check the live
  /// association; a gitfile changed after that check cannot retarget a command.
  Future<GitRunResult> runRepository(
    RepositoryId repo,
    List<String> args, {
    bool passive = true,
    List<int>? input,
    GitCancellation? cancellation,
    Duration? deadline,
    Map<String, String> environment = const {},
    void Function(String)? progress,
    bool allowFailure = false,
    Map<int, List<int>> byteArguments = const {},
    int? maximumBytes,
  }) => run(
    repo.root,
    args,
    passive: passive,
    input: input,
    cancellation: cancellation,
    deadline: deadline,
    environment: {
      'GIT_DIR': repo.gitDir,
      'GIT_COMMON_DIR': repo.commonDir,
      if (!repo.bare) 'GIT_WORK_TREE': repo.root,
      ...environment,
    },
    progress: progress,
    allowFailure: allowFailure,
    byteArguments: byteArguments,
    maximumBytes: maximumBytes,
  );
  void requireAuthorization(RepositoryId repo) {
    if (!authorized(repo)) throw const GitException(GitErrorCode.trustRequired);
  }

  Future<String> indexToken(
    RepositoryId repo, {
    GitCancellation? cancellation,
  }) async {
    // Equal commit IDs do not identify the destination branch. In particular,
    // symbolic-ref or branch -m can retarget a reviewed commit without touching
    // the index. Bind its opaque review token to the resolved HEAD target too.
    Future<String> headTarget() async {
      final result = await runRepository(
        repo,
        ['symbolic-ref', '--quiet', 'HEAD'],
        cancellation: cancellation,
        allowFailure: true,
      );
      if (result.success) return 'symbolic:${fingerprint(result.stdout)}';
      if (result.exitCode == 1) return 'detached';
      throw classifyGitFailure(result.diagnostic, exitCode: result.exitCode);
    }

    final binding = await headTarget();
    final path = utf8.encode(await gitMetadataPath(this, repo, 'index'));
    if (!LinuxPaths.stat(path).exists) {
      if (await headTarget() != binding) {
        throw const GitException(GitErrorCode.staleReview);
      }
      return fingerprint(utf8.encode('$binding:absent'));
    }
    final fd = LinuxPaths.secureOpen(path, readOnly: true);
    try {
      final before = LinuxPaths.descriptorStat(fd);
      if (before.mode & 0xf000 != 0x8000)
        throw const GitException(GitErrorCode.unsafePath);
      final digest = await sha256
          .bind(
            File('/proc/self/fd/$fd').openRead().map((chunk) {
              cancellation?.check();
              return chunk;
            }),
          )
          .first;
      if (before.stamp != LinuxPaths.descriptorStat(fd).stamp ||
          before.identity != LinuxPaths.stat(path).identity ||
          await headTarget() != binding) {
        throw const GitException(GitErrorCode.staleReview);
      }
      return fingerprint([...utf8.encode(binding), 0, ...digest.bytes]);
    } finally {
      LinuxPaths.close(fd);
    }
  }

  Future<String?> headReference(
    RepositoryId repo, {
    GitCancellation? cancellation,
  }) async {
    final result = await runRepository(
      repo,
      ['symbolic-ref', '--quiet', 'HEAD'],
      allowFailure: true,
      cancellation: cancellation,
    );
    if (result.success) return oneLine(result.text);
    if (result.exitCode == 1) return null;
    throw result.failure;
  }

  Future<GitOid?> head(
    RepositoryId repo, {
    GitCancellation? cancellation,
  }) async {
    final result = await runRepository(
      repo,
      ['rev-parse', '--verify', '--quiet', 'HEAD^{commit}'],
      allowFailure: true,
      cancellation: cancellation,
    );
    if (!result.success) return null;
    return GitOid(oneLine(result.text));
  }

  Future<void> validateIdentity(RepositoryId repo) async {
    if (repo.filesystemToken.isNotEmpty &&
        repo.filesystemToken !=
            repositoryFilesystemToken(repo.root, repo.gitDir, repo.commonDir)) {
      throw const GitException(GitErrorCode.staleReview);
    }
    for (final directory in [repo.root, repo.gitDir, repo.commonDir]) {
      if (!await Directory(directory).exists() ||
          await Directory(directory).resolveSymbolicLinks() != directory) {
        throw const GitException(GitErrorCode.staleReview);
      }
    }
    final dir = await run(repo.root, ['rev-parse', '--absolute-git-dir']);
    final common = await run(repo.root, [
      'rev-parse',
      '--path-format=absolute',
      '--git-common-dir',
    ]);
    if (oneLine(dir.text) != repo.gitDir ||
        oneLine(common.text) != repo.commonDir) {
      throw const GitException(GitErrorCode.staleReview);
    }
  }

  Future<void> validatePreconditions(
    RepositoryId repo,
    GitOid? head,
    String index, {
    GitCancellation? cancellation,
  }) async {
    await validateIdentity(repo);
    if (await this.head(repo, cancellation: cancellation) != head ||
        await indexToken(repo, cancellation: cancellation) != index) {
      throw const GitException(GitErrorCode.staleReview);
    }
  }

  /// No symlink ancestor may escape the captured root. Final symlinks are Git
  /// entries and are handled as links, never followed as files.
  Future<Uint8List> workingPath(RepositoryId repo, RepoPath path) async {
    await validateIdentity(repo);
    final root = utf8.encode('${repo.root}/');
    final bytes = Uint8List.fromList([...root, ...path.bytes]);
    var start = root.length;
    for (var i = start; i < bytes.length; i++) {
      if (bytes[i] != 47) continue;
      final stat = LinuxPaths.stat(Uint8List.sublistView(bytes, 0, i));
      if (stat.exists && stat.mode & 0xf000 != 0x4000) {
        throw const GitException(GitErrorCode.unsafePath);
      }
      start = i + 1;
    }
    return bytes;
  }

  Future<void> passiveStatusPolicy(
    RepositoryId repo, {
    bool allowExecutableFilters = false,
  }) async {
    final config = await runRepository(repo, [
      'config',
      '--null',
      '--list',
      '--includes',
    ]);
    // Status may invoke clean/process filters while checking working content.
    // Require an explicit host trust grant before allowing that behavior.
    for (final row in config.text.split('\u0000')) {
      final newline = row.indexOf('\n');
      if (newline < 0) continue;
      final key = row.substring(0, newline).toLowerCase();
      if (RegExp(r'^filter\..+\.(clean|process)$').hasMatch(key) &&
          row.substring(newline + 1).isNotEmpty) {
        if (!allowExecutableFilters)
          throw const GitException(
            GitErrorCode.trustRequired,
            diagnostic:
                'This repository configures executable clean/process filters. Passive browsing does not run them. Authorize a focused Git inspection to compute working-tree status.',
          );
        requireAuthorization(repo);
      }
    }
  }
}

String oneLine(String value) =>
    value.endsWith('\n') ? value.substring(0, value.length - 1) : value;

Future<String> gitMetadataPath(
  GitContext ctx,
  RepositoryId repo,
  String name,
) async {
  final key = '${repo.key}:$name';
  if (ctx.metadataPaths[key] case final path?) return path;
  final result = oneLine(
    (await ctx.runRepository(repo, [
      'rev-parse',
      '--path-format=absolute',
      '--git-path',
      name,
    ])).text,
  );
  if (ctx.metadataPaths.length > 1024) ctx.metadataPaths.clear();
  ctx.metadataPaths[key] = result;
  return result;
}

String repositoryFilesystemToken(String root, String gitDir, String common) => [
  root,
  gitDir,
  common,
].map((path) => LinuxPaths.stat(utf8.encode(path)).identity).join('|');

/// Directory watchers catch Git's atomic replacements. A periodic reconciliation
/// also covers reference backends and descendants without a recursive file scan.
Stream<void> watchRepository(RepositoryId repo) {
  late StreamController<void> controller;
  final subscriptions = <StreamSubscription<FileSystemEvent>>[];
  Timer? debounce, timer;
  int? lease;
  bool cancelled = false;
  void invalidate() {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 180), () {
      if (!controller.isClosed) controller.add(null);
    });
  }

  controller = StreamController<void>(
    onListen: () {
      try {
        if (LinuxPaths.canWrite(repo.gitDir) &&
            LinuxPaths.canWrite(repo.commonDir)) {
          final fd = LinuxPaths.secureOpen(
            utf8.encode('${repo.gitDir}/busystack-open.lock'),
            create: true,
          );
          if (!LinuxPaths.trySharedLock(fd)) {
            LinuxPaths.close(fd);
            throw const GitException(GitErrorCode.locked);
          }
          if (cancelled) {
            LinuxPaths.close(fd);
          } else {
            lease = fd;
          }
        }
      } on GitException catch (error) {
        controller.addError(error);
      } on FileSystemException catch (error) {
        controller.addError(
          GitException(
            GitErrorCode.unsafePath,
            diagnostic:
                'Cannot acquire a worktree usage lease (errno ${error.osError?.errorCode ?? 0}).',
          ),
        );
      }
      for (final path in {
        repo.root,
        repo.gitDir,
        repo.commonDir,
        p.join(repo.commonDir, 'refs'),
      }) {
        if (Directory(path).existsSync()) {
          subscriptions.add(
            Directory(path).watch().listen(
              (_) => invalidate(),
              onError: (Object error, StackTrace stack) =>
                  controller.addError(error, stack),
            ),
          );
        }
      }
      timer = Timer.periodic(const Duration(seconds: 5), (_) => invalidate());
    },
    onCancel: () async {
      cancelled = true;
      if (lease != null) {
        LinuxPaths.close(lease!);
        lease = null;
      }
      debounce?.cancel();
      timer?.cancel();
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    },
  );
  return controller.stream;
}
