import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'client.dart';
import 'content_queries.dart';
import 'context.dart';
import 'index_mutations.dart';
import 'linux_paths.dart';
import 'models.dart';
import 'parsers.dart';
import 'reference_workflows.dart';
import 'repository_queries.dart';
import 'runner.dart';
import 'transactions.dart';

final class OrganizationWorkflows {
  OrganizationWorkflows(
    this.ctx,
    this.repositories,
    this.contents,
    this.references,
  ) : index = IndexMutations(ctx, contents),
      transactions = IndexTransactions(ctx);
  final GitContext ctx;
  final RepositoryQueries repositories;
  final ContentQueries contents;
  final ReferenceWorkflows references;
  final IndexMutations index;
  final IndexTransactions transactions;
  Future<Json> inspect(
    RepositoryId repo,
    GitInspection request, {
    GitCancellation? cancellation,
  }) async {
    if (request.limit < 1 || request.limit > 300 || request.offset < 0)
      throw const GitException(GitErrorCode.invalidRequest);
    switch (request.kind) {
      case GitInspectionKind.stashes:
        final rows = await stashes(
          repo,
          offset: request.offset,
          limit: request.limit + 1,
        );
        return {
          'entries': rows.take(request.limit).toList(),
          'hasMore': rows.length > request.limit,
        };
      case GitInspectionKind.worktrees:
        final rows = await worktrees(repo);
        return {
          'entries': rows.skip(request.offset).take(request.limit).toList(),
          'hasMore': rows.length > request.offset + request.limit,
        };
      case GitInspectionKind.submodules:
        final reviewedHead = await ctx.head(repo);
        final reviewedIndex = await ctx.indexToken(repo);
        final entries = (await contents.index(
          repo,
        )).where((e) => e.mode == '160000' && e.stage == 0).toList();
        final rows = <Json>[];
        for (final entry in entries.skip(request.offset).take(request.limit)) {
          cancellation?.check();
          final path = entry.path.utf8Path;
          RepositoryId? child;
          GitException? error;
          GitSnapshot? state;
          if (path != null &&
              await Directory(p.join(repo.root, path)).exists()) {
            try {
              child = await repositories.discover(
                p.join(repo.root, path),
                cancellation: cancellation,
              );
              if (child?.root != p.join(repo.root, path)) child = null;
              if (child != null)
                state = await repositories.status(
                  child,
                  cancellation: cancellation,
                );
            } on GitException catch (failure) {
              error = failure;
            }
          }
          final working = await contents.content(
            repo,
            entry.path,
            const ContentVersion.working(),
            cancellation: cancellation,
          );
          if (state != null && state.head != working.oid) {
            throw const GitException(GitErrorCode.staleReview);
          }
          rows.add({
            'path': entry.path.toJson(),
            'recorded': entry.oid.value,
            'repository': child?.toJson(),
            'checkedOut': working.oid?.value,
            'workingToken': working.token,
            'operation': state?.operation.toJson(),
            'initialized': child != null,
            'dirty': state == null ? null : state.changes.isNotEmpty,
            'error': error?.toJson(),
          });
        }
        if (await ctx.head(repo) != reviewedHead ||
            await ctx.indexToken(repo) != reviewedIndex) {
          throw const GitException(GitErrorCode.staleReview);
        }
        return {
          'head': reviewedHead?.value,
          'indexToken': reviewedIndex,
          'entries': rows,
          'hasMore': entries.length > request.offset + request.limit,
        };
      case GitInspectionKind.reflog:
        final ref = request.reference ?? 'HEAD';
        if (ref != 'HEAD' && !ref.startsWith('refs/heads/'))
          throw const GitException(GitErrorCode.invalidRequest);
        final result = await ctx.runRepository(repo, [
          'reflog',
          'show',
          '--date=iso-strict',
          '--format=%H%x00%gD%x00%gs%x00%gn%x00%ge%x00',
          '--max-count=${request.limit + 1}',
          '--skip=${request.offset}',
          ref,
        ], cancellation: cancellation);
        final values = nulRecords(result.stdout), rows = <Json>[];
        for (var i = 0; i + 4 < values.length; i += 5) {
          String value(int j) =>
              utf8.decode(values[i + j], allowMalformed: true);
          rows.add({
            'revision': value(0).trimLeft(),
            'selector': value(1),
            'action': value(2),
            'name': value(3),
            'email': value(4),
          });
        }
        return {
          'entries': rows.take(request.limit).toList(),
          'hasMore': rows.length > request.limit,
        };
      default:
        throw const GitException(GitErrorCode.invalidRequest);
    }
  }

  Future<List<Json>> stashes(
    RepositoryId repo, {
    int offset = 0,
    int? limit,
  }) async {
    final result = await ctx.runRepository(repo, [
      'stash',
      'list',
      '--format=%H%x00%gd%x00%gs%x00%at%x00',
      '--skip=$offset',
      if (limit != null) '--max-count=$limit',
    ]);
    final records = nulRecords(result.stdout), rows = <Json>[];
    for (var i = 0; i + 3 < records.length; i += 4) {
      String value(int j) => utf8.decode(records[i + j], allowMalformed: true);
      rows.add({
        'identity': GitOid(value(0).trimLeft()).value,
        'selector': value(1),
        'message': value(2),
        'time': int.parse(value(3)),
      });
    }
    return rows;
  }

  Future<List<Json>> worktrees(RepositoryId repo) async {
    final result = await ctx.runRepository(repo, [
      'worktree',
      'list',
      '--porcelain',
      '-z',
    ]);
    final rows = <Json>[];
    Json row = {};
    for (final record in nulRecords(result.stdout)) {
      if (record.isEmpty) {
        if (row.isNotEmpty) rows.add(row);
        row = {};
        continue;
      }
      final space = record.indexOf(32),
          key = ascii.decode(space < 0 ? record : record.sublist(0, space));
      final value = space < 0 ? '' : utf8.decode(record.sublist(space + 1));
      row[switch (key) {
        'worktree' => 'path',
        'HEAD' => 'head',
        _ => key,
      }] = value.isEmpty
          ? true
          : value;
    }
    if (row.isNotEmpty) rows.add(row);
    for (final entry in rows) {
      entry['current'] = entry['path'] == repo.root;
      entry['dirty'] = null;
      entry['inUse'] = false;
      final path = entry['path'] as String;
      if (entry.containsKey('bare') || !await Directory(path).exists())
        continue;
      try {
        final child = await repositories.discover(path);
        if (child == null ||
            child.root != path ||
            child.commonDir != repo.commonDir)
          throw const GitException(GitErrorCode.staleReview);
        entry['repository'] = child.toJson();
        final fd = LinuxPaths.secureOpen(
          utf8.encode('${child.gitDir}/busystack-open.lock'),
          create: true,
        );
        try {
          entry['inUse'] = !LinuxPaths.tryLock(fd);
        } finally {
          LinuxPaths.close(fd);
        }
        final state = await repositories.status(child);
        entry['dirty'] = state.changes.isNotEmpty;
        entry['head'] = state.head?.value;
        if (state.branch == null) {
          entry.remove('branch');
        } else {
          entry['branch'] = 'refs/heads/${state.branch}';
        }
        entry['reviewToken'] = fingerprint(
          utf8.encode(
            '${child.key}\u0000${state.token}\u0000${entry['branch']}\u0000${entry['locked']}\u0000${entry['prunable']}',
          ),
        );
      } on GitException catch (error) {
        entry['error'] = error.toJson();
      }
    }
    return rows;
  }

  Future<GitRunResult?> execute(
    RepositoryId repo,
    GitMutation request, {
    GitCancellation? cancellation,
    void Function(String)? progress,
    Map<String, String> operationEnvironment = const {},
  }) async {
    Future<GitRunResult> run(List<String> args, {List<int>? input}) =>
        ctx.runRepository(
          repo,
          args,
          passive: false,
          input: input,
          cancellation: cancellation,
          progress: progress,
          environment: operationEnvironment,
          allowFailure: true,
        );
    switch (request) {
      case StashMutation():
        if (request.keepIndex && request.stagedOnly ||
            request.stagedOnly && request.includeUntracked) {
          throw const GitException(GitErrorCode.invalidRequest);
        }
        if (request.action == StashAction.create) {
          if (request.message.contains('\u0000'))
            throw const GitException(GitErrorCode.invalidRequest);
          final input = BytesBuilder();
          for (final path in request.paths) {
            await ctx.workingPath(repo, path);
            input.add(ascii.encode(':(literal)'));
            input.add(path.bytes);
            input.addByte(0);
          }
          // Stash's documented implementation uses magic :/ pathspecs in its
          // own checkout/clean subprocesses. Permit that internal syntax while
          // explicitly marking every caller-supplied byte path as literal.
          return run([
            '--no-literal-pathspecs',
            'stash',
            'push',
            '--message',
            request.message,
            if (request.keepIndex) '--keep-index',
            if (request.stagedOnly) '--staged',
            if (request.includeUntracked) '--include-untracked',
            if (request.paths.isNotEmpty) ...[
              '--pathspec-from-file=-',
              '--pathspec-file-nul',
            ],
          ], input: request.paths.isEmpty ? null : input.takeBytes());
        }
        final oid = request.identity;
        if (oid == null ||
            !(await stashes(repo)).any((e) => e['identity'] == oid.value))
          throw const GitException(GitErrorCode.staleReview);
        if (request.action == StashAction.drop)
          return _dropStash(repo, oid, run);
        if (request.action == StashAction.branch) {
          final name = request.branchName;
          if (name == null)
            throw const GitException(GitErrorCode.invalidRequest);
          await references.branchName(repo, name);
          // An object ID deliberately retains the original stash. Deletion is
          // an explicit separate action after successful branch creation.
          return run(['stash', 'branch', name, oid.value]);
        }
        final result = await run([
          'stash',
          'apply',
          if (request.restoreIndex) '--index',
          oid.value,
        ]);
        if (!result.success || request.action != StashAction.pop) return result;
        final after = await repositories.status(
          repo,
          policy: GitReadPolicy.authorized,
        );
        if (after.changes.any((e) => e.conflicted)) return result;
        return _dropStash(repo, oid, run);
      case WorktreeMutation():
        if (!p.isAbsolute(request.path) ||
            p.normalize(request.path) != request.path)
          throw const GitException(GitErrorCode.unsafePath);
        if (request.action == WorktreeAction.create) {
          await _newDestination(request.path);
          if (request.branch != null)
            await references.branchName(repo, request.branch!);
          return run([
            'worktree',
            'add',
            '--no-guess-remote',
            if (request.branch != null) ...[
              '-b',
              request.branch!,
            ] else
              '--detach',
            '--',
            request.path,
            request.start?.value ?? request.expectedHead?.value ?? 'HEAD',
          ]);
        }
        final selected = (await worktrees(
          repo,
        )).where((e) => e['path'] == request.path).firstOrNull;
        if (selected == null || selected['current'] == true)
          throw const GitException(
            GitErrorCode.invalidRequest,
            diagnostic:
                'The current worktree cannot be moved or removed while this workspace uses it.',
          );
        if (selected['inUse'] == true &&
            {
              WorktreeAction.move,
              WorktreeAction.remove,
            }.contains(request.action)) {
          throw const GitException(
            GitErrorCode.locked,
            diagnostic:
                'Another BusyStack Git workspace has this worktree open. Close it before moving or removing the worktree.',
          );
        }
        if (request.expectedTargetToken == null ||
            selected['reviewToken'] != request.expectedTargetToken) {
          throw const GitException(
            GitErrorCode.staleReview,
            diagnostic:
                'This worktree changed after review. Refresh its identity and contents before changing it.',
          );
        }
        if (request.action == WorktreeAction.move) {
          if (request.destination == null)
            throw const GitException(GitErrorCode.invalidRequest);
          await _newDestination(request.destination!);
          return _unusedWorktree(
            repo,
            request.path,
            () => run([
              'worktree',
              'move',
              '--',
              request.path,
              request.destination!,
            ]),
          );
        }
        if (request.action == WorktreeAction.remove) {
          if (selected.containsKey('locked'))
            throw const GitException(
              GitErrorCode.locked,
              diagnostic: 'Unlock this worktree explicitly before removing it.',
            );
          return _unusedWorktree(
            repo,
            request.path,
            () => run([
              'worktree',
              'remove',
              if (request.forceReviewed) '--force',
              '--',
              request.path,
            ]),
          );
        }
        return run([
          'worktree',
          request.action == WorktreeAction.lock ? 'lock' : 'unlock',
          '--',
          request.path,
        ]);
      case SubmoduleMutation():
        if (request.paths.isEmpty)
          throw const GitException(GitErrorCode.invalidRequest);
        final gitlinks = (await contents.index(
          repo,
        )).where((e) => e.mode == '160000').map((e) => e.path).toSet();
        for (final path in request.paths) {
          if (!gitlinks.contains(path))
            throw const GitException(GitErrorCode.staleReview);
          await ctx.workingPath(repo, path);
          final expected = request.contentTokens[path.key];
          if (expected == null ||
              expected !=
                  (await contents.content(
                    repo,
                    path,
                    const ContentVersion.working(),
                    cancellation: cancellation,
                  )).token) {
            throw const GitException(
              GitErrorCode.staleReview,
              diagnostic:
                  'The selected submodule checkout changed after review. Refresh before updating or staging it.',
            );
          }
        }
        if (request.action == SubmoduleAction.stagePointer) {
          return index.execute(
            repo,
            StagePaths(
              request.paths,
              expectedHead: request.expectedHead,
              expectedIndex: request.expectedIndex,
              contentTokens: request.contentTokens,
            ),
            cancellation: cancellation,
            progress: progress,
            operationEnvironment: operationEnvironment,
          );
        }
        final arguments = <String>[
          'submodule',
          switch (request.action) {
            SubmoduleAction.initialize => 'init',
            SubmoduleAction.synchronize => 'sync',
            _ => 'update',
          },
          if (request.recursive && request.action != SubmoduleAction.initialize)
            '--recursive',
          if ({
            SubmoduleAction.updateRecorded,
            SubmoduleAction.updateRemote,
          }.contains(request.action)) ...[
            '--init',
            '--checkout',
            if (request.action == SubmoduleAction.updateRemote) '--remote',
          ],
          '--',
          ...request.paths.map((e) => e.utf8Path ?? ''),
        ];
        return ctx.runRepository(
          repo,
          arguments,
          passive: false,
          cancellation: cancellation,
          progress: progress,
          environment: operationEnvironment,
          allowFailure: true,
          byteArguments: {
            for (var i = 0; i < request.paths.length; i++)
              if (request.paths[i].utf8Path == null)
                arguments.length - request.paths.length + i:
                    request.paths[i].bytes,
          },
        );
      case RestorePaths():
        if (request.paths.isEmpty)
          throw const GitException(GitErrorCode.invalidRequest);
        for (final path in request.paths) {
          if (request.target != RestoreTarget.staged &&
              !request.contentTokens.containsKey(path.key)) {
            throw const GitException(
              GitErrorCode.staleReview,
              diagnostic:
                  'Review the current working content before replacing or deleting this path.',
            );
          }
          if (request.contentTokens[path.key] case final token?) {
            if ((await contents.content(
                  repo,
                  path,
                  const ContentVersion.working(),
                )).token !=
                token)
              throw const GitException(GitErrorCode.staleReview);
          }
        }
        if (request.discardUntracked) {
          final tracked = (await contents.index(
            repo,
          )).map((e) => e.path).toSet();
          for (final path in request.paths) {
            if (tracked.contains(path))
              throw const GitException(GitErrorCode.staleReview);
            LinuxPaths.replaceWorking(
              await ctx.workingPath(repo, path),
              null,
              '100644',
            );
          }
          return null;
        }
        final paths = BytesBuilder();
        for (final path in request.paths) {
          await ctx.workingPath(repo, path);
          paths.add(path.bytes);
          paths.addByte(0);
        }
        GitRunResult? result;
        Future<void> restore(Map<String, String> env) async {
          result = await ctx.runRepository(
            repo,
            [
              'restore',
              '--no-recurse-submodules',
              if (request.target != RestoreTarget.staged) '--worktree',
              if (request.target != RestoreTarget.workingTree) '--staged',
              if (request.revision != null)
                '--source=${request.revision!.value}',
              '--pathspec-from-file=-',
              '--pathspec-file-nul',
            ],
            input: paths.takeBytes(),
            passive: false,
            cancellation: cancellation,
            environment: {...operationEnvironment, ...env},
            allowFailure: true,
          );
          if (!result!.success) throw result!.failure;
        }
        if (request.target == RestoreTarget.workingTree) {
          await restore(const {});
        } else {
          await transactions.update(
            repo,
            request.expectedHead,
            request.expectedIndex,
            restore,
            cancellation: cancellation,
          );
        }
        return result;
      case RestoreFileRevision():
        final before = await contents.content(
          repo,
          request.target,
          const ContentVersion.working(),
        );
        if (before.token != request.expectedWorking)
          throw const GitException(GitErrorCode.staleReview);
        final historical = await contents.content(
          repo,
          request.source,
          ContentVersion(ContentKind.commit, revision: request.revision),
        );
        if ({
          ContentAvailability.unavailable,
          ContentAvailability.tooLarge,
          ContentAvailability.gitlink,
        }.contains(historical.availability)) {
          throw const GitException(GitErrorCode.unsupportedContent);
        }
        Uint8List? bytes = historical.availability == ContentAvailability.absent
            ? null
            : historical.bytes;
        if (bytes != null && historical.mode != '120000') {
          final name = request.target.utf8Path;
          bytes = (await ctx.runRepository(
            repo,
            [
              'cat-file',
              '--filters',
              '--path=${name ?? ''}',
              historical.oid!.value,
            ],
            byteArguments: {
              if (name == null)
                2: [...ascii.encode('--path='), ...request.target.bytes],
            },
            passive: false,
            cancellation: cancellation,
            environment: operationEnvironment,
          )).stdout;
        }
        if ((await contents.content(
              repo,
              request.target,
              const ContentVersion.working(),
            )).token !=
            before.token) {
          throw const GitException(GitErrorCode.staleReview);
        }
        LinuxPaths.replaceWorking(
          await ctx.workingPath(repo, request.target),
          bytes,
          historical.mode == '000000' ? '100644' : historical.mode,
        );
        return null;
      case ResetBranch():
        return run([
          'reset',
          '--${request.mode.name}',
          '--no-recurse-submodules',
          request.revision.value,
        ]);
      default:
        throw const GitException(GitErrorCode.invalidRequest);
    }
  }

  Future<GitRunResult> _unusedWorktree(
    RepositoryId repo,
    String path,
    Future<GitRunResult> Function() action,
  ) async {
    final child = await repositories.discover(path);
    if (child == null ||
        child.root != path ||
        child.commonDir != repo.commonDir)
      throw const GitException(GitErrorCode.staleReview);
    final fd = LinuxPaths.secureOpen(
      utf8.encode('${child.gitDir}/busystack-open.lock'),
      create: true,
    );
    try {
      if (!LinuxPaths.tryLock(fd))
        throw const GitException(GitErrorCode.locked);
      return await action();
    } finally {
      LinuxPaths.close(fd);
    }
  }

  Future<GitRunResult> _dropStash(
    RepositoryId repo,
    GitOid identity,
    Future<GitRunResult> Function(List<String>, {List<int>? input}) run,
  ) async {
    final matches = (await stashes(
      repo,
    )).where((e) => e['identity'] == identity.value).toList();
    if (matches.length != 1)
      throw const GitException(
        GitErrorCode.staleReview,
        diagnostic:
            'The stash was removed or its identity is ambiguous after another client changed the stash list. Refresh the list before dropping an entry.',
      );
    final entry = matches.single;
    final selector = entry['selector'] as String;
    final checked = await ctx.runRepository(repo, [
      'rev-parse',
      '--verify',
      selector,
    ]);
    if (oneLine(checked.text) != identity.value)
      throw const GitException(GitErrorCode.staleReview);
    return run(['stash', 'drop', selector]);
  }

  Future<void> _newDestination(String destination) async {
    if (!p.isAbsolute(destination) ||
        p.normalize(destination) != destination ||
        await FileSystemEntity.type(destination, followLinks: false) !=
            FileSystemEntityType.notFound ||
        await Directory(p.dirname(destination)).resolveSymbolicLinks() !=
            p.dirname(destination))
      throw const GitException(GitErrorCode.unsafePath);
  }
}
