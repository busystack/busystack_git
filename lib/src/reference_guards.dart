import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'context.dart';
import 'linux_paths.dart';
import 'models.dart';
import 'native_helper.dart';

/// Git calls these operation-local guards while its own ref locks are held.
/// They neither replace user hooks nor maintain a reference database.
final class ReferenceGuards {
  const ReferenceGuards(this.ctx, {this.helperPath});
  final GitContext ctx;
  final String? helperPath;
  static String _random() => List.generate(
    32,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  static String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

  Future<List<String>> _arguments(
    RepositoryId repository,
    String mode,
    List<String> values,
  ) async {
    final enabled = await ctx.runRepository(
      repository,
      ['config', '--type=bool', '--get', 'hook.reference-transaction.enabled'],
      passive: false,
      allowFailure: true,
    );
    if (enabled.success && oneLine(enabled.text) == 'false') {
      throw const GitException(
        GitErrorCode.invalidRequest,
        diagnostic:
            'This operation needs its reference-transaction safety guard. Enable hook.reference-transaction.enabled, then review again.',
      );
    }
    if (!enabled.success && enabled.exitCode != 1) throw enabled.failure;
    final helper = installedGitHelper(preferred: helperPath);
    if (helper == null) {
      throw const GitException(
        GitErrorCode.unavailable,
        diagnostic: 'Repair the installed native Git safety helper.',
      );
    }
    final hook = 'busystack-review-${_random()}';
    return [
      '-c', 'hook.reference-transaction.enabled=true',
      '-c', 'hook.$hook.event=reference-transaction',
      '-c', 'hook.$hook.enabled=true',
      '-c', 'hook.$hook.parallel=true',
      // exec makes the owning Git process the helper's direct parent. Nested
      // Git commands in user hooks can then be distinguished without ptrace.
      '-c',
      'hook.$hook.command=exec ${_quote(helper)} $mode ${values.map(_quote).join(' ')}',
    ];
  }

  Future<List<String>> deletion(RepositoryId repo, String ref, GitOid tip) =>
      _arguments(repo, '--reference-guard', [ref, tip.value]);

  Future<HeadReferenceGuard> commit(
    RepositoryId repo,
    String? target,
    GitOid? tip,
  ) async {
    final arguments = await _arguments(repo, '--head-guard', [
      target ?? '-',
      tip?.value ?? '-',
    ]);
    final temporary = await Directory.systemTemp.createTemp(
      'busystack-git-safety-',
    );
    final directory = Directory(await temporary.resolveSymbolicLinks());
    LinuxPaths.chmod(directory.path, 0x1c0);
    final path = '${directory.path}/commit';
    int? fd;
    try {
      fd = LinuxPaths.secureOpen(
        utf8.encode(path),
        create: true,
        exclusive: true,
      );
      final token = _random();
      LinuxPaths.writeAndFlush(fd, utf8.encode('$token\npending\n'));
      return HeadReferenceGuard._(
        directory,
        path,
        fd,
        token,
        target,
        LinuxPaths.descriptorStat(fd).identity,
        LinuxPaths.stat(utf8.encode(directory.path)).identity,
        arguments,
      );
    } on Object {
      if (fd != null) LinuxPaths.close(fd);
      await directory.delete(recursive: true);
      rethrow;
    }
  }
}

/// A single authenticated, inode-bound local outcome record. It is written by
/// Git's committed callback, inspected after process reconciliation, then removed.
/// It is never a source of truth for subsequent Git operations.
final class HeadReferenceGuard {
  HeadReferenceGuard._(
    this.directory,
    this.path,
    this.fd,
    this.token,
    this.target,
    this.identity,
    this.directoryIdentity,
    this.arguments,
  );
  final Directory directory;
  final String path, token, identity, directoryIdentity;
  final String? target;
  final int fd;
  final List<String> arguments;
  Map<String, String> get environment => {
    'BUSYSTACK_GIT_RECEIPT_PATH': path,
    'BUSYSTACK_GIT_RECEIPT_TOKEN': token,
    'BUSYSTACK_GIT_RECEIPT_ID': identity,
  };

  Future<GitOid?> receipt() async {
    final metadata = LinuxPaths.descriptorStat(fd);
    if (metadata.identity != identity ||
        metadata.size > 256 ||
        metadata.mode & 0xf000 != 0x8000 ||
        LinuxPaths.stat(utf8.encode(path)).identity != identity) {
      throw const GitException(
        GitErrorCode.unsafePath,
        diagnostic:
            'The private commit outcome record changed. Inspect Git state before another commit.',
      );
    }
    final bytes = await File('/proc/self/fd/$fd').readAsBytes();
    final body = ascii.decode(bytes, allowInvalid: true).split('\n');
    if (body.length != 3 ||
        body[0] != token ||
        body[2].isNotEmpty ||
        body[1] != 'pending' &&
            !RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$').hasMatch(body[1])) {
      throw const GitException(
        GitErrorCode.unsafePath,
        diagnostic:
            'The private commit outcome record is invalid. Inspect Git state before another commit.',
      );
    }
    return body[1] == 'pending' ? null : GitOid(body[1]);
  }

  Future<void> close() async {
    LinuxPaths.close(fd);
    if (LinuxPaths.stat(utf8.encode(directory.path)).identity !=
        directoryIdentity) {
      throw const GitException(
        GitErrorCode.unsafePath,
        diagnostic:
            'The private Git safety directory changed; it was retained for inspection.',
      );
    }
    await directory.delete(recursive: true);
  }
}

final class CommitObservation {
  const CommitObservation(this.target, this.created, this.failure);
  final String? target;
  final GitOid? created;
  final GitException? failure;
}
