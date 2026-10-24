import 'dart:io';
import 'dart:convert';
import 'context.dart';
import 'models.dart';
import 'runner.dart';
import 'linux_paths.dart';

/// Advisory locks live in repository metadata, accessible to both installed
/// applications even when their private XDG/sandbox directories differ. flock
/// releases on process death; persistent lock files are deliberately not deleted.
final class RepositoryLocks {
  Future<T> withLocks<T>(
    RepositoryId repo,
    Future<T> Function() body, {
    Iterable<RepositoryId> related = const [],
    GitCancellation? cancellation,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final held = <int>[];
    final watch = Stopwatch()..start();
    try {
      // A child repository operation also locks its discovered superproject.
      // Acquire every common directory before private worktree directories, in
      // one deterministic order, so parent/child and sibling worktrees agree.
      final repositories = [repo, ...related];
      final common = repositories.map((r) => r.commonDir).toSet();
      final private = repositories
          .map((r) => r.gitDir)
          .where((directory) => !common.contains(directory))
          .toSet();
      final directories = [
        ...(common.toList()..sort()),
        ...(private.toList()..sort()),
      ];
      for (final directory in directories) {
        final fd = LinuxPaths.secureOpen(
          utf8.encode('$directory/busystack-mutation.lock'),
          create: true,
        );
        held.add(fd);
        while (!LinuxPaths.tryLock(fd)) {
          cancellation?.check();
          if (watch.elapsed >= timeout)
            throw const GitException(GitErrorCode.locked);
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }
      cancellation?.check();
      return await body();
    } finally {
      for (final fd in held.reversed) {
        LinuxPaths.close(fd);
      }
    }
  }
}

final class IndexTransactions {
  const IndexTransactions(this.ctx);
  final GitContext ctx;
  Future<void> update(
    RepositoryId repo,
    GitOid? head,
    String indexToken,
    Future<void> Function(Map<String, String> environment) update, {
    GitCancellation? cancellation,
    bool allowHeadChange = false,
  }) async {
    final indexPath = await gitMetadataPath(ctx, repo, 'index');
    final lock = File('$indexPath.lock');
    final fd = LinuxPaths.secureOpen(
      utf8.encode(lock.path),
      create: true,
      exclusive: true,
    );
    Directory? temporary;
    var installed = false;
    File? alternate;
    int? originalMode;
    Future<void> install({GitCancellation? token}) async {
      if ((!allowHeadChange &&
              await ctx.head(repo, cancellation: token) != head) ||
          await ctx.indexToken(repo, cancellation: token) != indexToken)
        throw const GitException(GitErrorCode.staleReview);
      LinuxPaths.writeAndFlush(fd, await alternate!.readAsBytes());
      LinuxPaths.setDescriptorMode(
        fd,
        originalMode ?? (await alternate!.stat()).mode,
      );
      LinuxPaths.finishIndexLock(utf8.encode(indexPath), fd, install: true);
      installed = true;
    }

    try {
      // The actual Git lock is held throughout validation and replacement.
      await ctx.validatePreconditions(
        repo,
        head,
        indexToken,
        cancellation: cancellation,
      );
      cancellation?.check();
      temporary = await Directory(repo.gitDir).createTemp('busystack-index-');
      alternate = File('${temporary.path}/index');
      final environment = {'GIT_INDEX_FILE': alternate.path};
      final original = File(indexPath);
      if (await original.exists()) {
        originalMode = (await original.stat()).mode;
        await original.copy(alternate.path);
        // Split-index links are relative to GIT_DIR, which remains unchanged.
      } else {
        await ctx.runRepository(
          repo,
          ['read-tree', '--empty'],
          passive: false,
          environment: environment,
        );
      }
      await update(environment);
      // A commit may already have moved a ref (including from a hook). Complete
      // its index reconciliation even when cancellation arrived at this point.
      if (!allowHeadChange) cancellation?.check();
      await install(token: allowHeadChange ? null : cancellation);
    } on Object catch (error, stack) {
      if (allowHeadChange &&
          alternate != null &&
          await alternate.exists() &&
          !await File('${alternate.path}.lock').exists()) {
        try {
          await install();
        } on GitException catch (failure) {
          throw GitException(
            failure.code,
            diagnostic:
                'Commit outcome requires reconciliation: ${failure.code.name}; original failure: ${error is GitException ? error.code.name : error.runtimeType}.',
          );
        }
      }
      Error.throwWithStackTrace(error, stack);
    } finally {
      try {
        if (!installed)
          LinuxPaths.finishIndexLock(
            utf8.encode(indexPath),
            fd,
            install: false,
          );
      } finally {
        LinuxPaths.close(fd);
        if (temporary != null) await temporary.delete(recursive: true);
      }
    }
  }
}
