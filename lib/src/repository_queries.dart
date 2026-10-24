import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'context.dart';
import 'models.dart';
import 'parsers.dart';
import 'runner.dart';
import 'linux_paths.dart';

final class RepositoryQueries {
  const RepositoryQueries(this.ctx);
  final GitContext ctx;
  Future<RepositoryId?> discover(
    String localPath, {
    GitCancellation? cancellation,
  }) async {
    var directory = Directory(localPath);
    if (await FileSystemEntity.type(localPath) == FileSystemEntityType.file)
      directory = File(localPath).parent;
    if (!await directory.exists())
      throw const GitException(GitErrorCode.unsafePath);
    final cwd = await directory.resolveSymbolicLinks();
    final gitDir = await ctx.run(
      cwd,
      ['rev-parse', '--absolute-git-dir'],
      cancellation: cancellation,
      allowFailure: true,
    );
    if (!gitDir.success) {
      if (gitDir.diagnostic.contains('not a git repository')) return null;
      throw gitDir.failure;
    }
    final bare =
        oneLine(
          (await ctx.run(cwd, ['rev-parse', '--is-bare-repository'])).text,
        ) ==
        'true';
    final root = bare
        ? oneLine(gitDir.text)
        : oneLine((await ctx.run(cwd, ['rev-parse', '--show-toplevel'])).text);
    final canonicalRoot = await Directory(root).resolveSymbolicLinks();
    final privateDir = await Directory(
      oneLine(gitDir.text),
    ).resolveSymbolicLinks();
    final common = await Directory(
      oneLine(
        (await ctx.run(cwd, [
          'rev-parse',
          '--path-format=absolute',
          '--git-common-dir',
        ])).text,
      ),
    ).resolveSymbolicLinks();
    final refFormat = oneLine(
      (await ctx.run(cwd, [
        'rev-parse',
        '--show-ref-format',
      ], allowFailure: true)).text,
    );
    return RepositoryId(
      root: canonicalRoot,
      gitDir: privateDir,
      commonDir: common,
      filesystemToken: repositoryFilesystemToken(
        canonicalRoot,
        privateDir,
        common,
      ),
      referenceFormat: const {'files', 'reftable'}.contains(refFormat)
          ? refFormat
          : 'unknown',
      objectFormat: oneLine(
        (await ctx.run(cwd, ['rev-parse', '--show-object-format'])).text,
      ),
      bare: bare,
      shallow:
          oneLine(
            (await ctx.run(cwd, ['rev-parse', '--is-shallow-repository'])).text,
          ) ==
          'true',
    );
  }

  Future<GitSnapshot> status(
    RepositoryId repo, {
    GitCancellation? cancellation,
    GitReadPolicy policy = GitReadPolicy.restricted,
  }) async {
    await ctx.validateIdentity(repo);
    await ctx.passiveStatusPolicy(
      repo,
      allowExecutableFilters: policy == GitReadPolicy.authorized,
    );
    final index = await ctx.indexToken(repo, cancellation: cancellation);
    final result = repo.bare
        ? null
        : await ctx.runRepository(repo, [
            'status',
            '--porcelain=v2',
            '-z',
            '--branch',
            '--untracked-files=all',
            '--ignore-submodules=none',
          ], cancellation: cancellation);
    final parsed = await _backgroundStatus(
      repo,
      index,
      result?.stdout ?? const [],
      bareHead: repo.bare ? await ctx.head(repo) : null,
    );
    cancellation?.check();
    if (await ctx.indexToken(repo, cancellation: cancellation) != index)
      throw const GitException(GitErrorCode.staleReview);
    final operation = await operationState(
      repo,
      head: parsed.head,
      unmerged: parsed.unmerged,
    );
    cancellation?.check();
    final writable =
        LinuxPaths.canWrite(repo.gitDir) && LinuxPaths.canWrite(repo.commonDir);
    return GitSnapshot(
      repository: repo,
      token: parsed.token,
      indexToken: index,
      head: parsed.head,
      branch: parsed.branch,
      upstream: parsed.upstream,
      ahead: parsed.ahead,
      behind: parsed.behind,
      changes: parsed.changes,
      operation: operation,
      observedAt: DateTime.now().toUtc(),
      capabilities: GitCapabilities(
        writeMetadata: writable,
        replaceWorkingFiles:
            writable && !repo.bare && LinuxPaths.canWrite(repo.root),
      ),
    );
  }

  Future<RepositoryOperation> operationState(
    RepositoryId repo, {
    GitOid? head,
    bool unmerged = false,
  }) async {
    Future<bool> exists(String name) async => FileSystemEntity.type(
      await gitMetadataPath(ctx, repo, name),
    ).then((value) => value != FileSystemEntityType.notFound);
    GitOperationKind kind;
    if (await exists('rebase-merge') || await exists('rebase-apply')) {
      kind = await exists('rebase-apply/applying')
          ? GitOperationKind.applyMailbox
          : GitOperationKind.rebase;
    } else if (await exists('MERGE_HEAD')) {
      kind = GitOperationKind.merge;
    } else if (await exists('CHERRY_PICK_HEAD')) {
      kind = GitOperationKind.cherryPick;
    } else if (await exists('REVERT_HEAD')) {
      kind = GitOperationKind.revert;
    } else if (await exists('sequencer')) {
      final todo = File(await gitMetadataPath(ctx, repo, 'sequencer/todo'));
      final text = await todo.exists() ? await todo.readAsString() : '';
      kind = text.startsWith('revert ')
          ? GitOperationKind.revert
          : GitOperationKind.cherryPick;
    } else if (await exists('SQUASH_MSG')) {
      kind = GitOperationKind.squash;
    } else {
      kind = unmerged ? GitOperationKind.unmerged : GitOperationKind.none;
    }
    GitOid? other;
    if (kind != GitOperationKind.none) {
      final ref = switch (kind) {
        GitOperationKind.merge => 'MERGE_HEAD',
        GitOperationKind.rebase => 'REBASE_HEAD',
        GitOperationKind.cherryPick => 'CHERRY_PICK_HEAD',
        GitOperationKind.revert => 'REVERT_HEAD',
        _ => null,
      };
      if (ref != null) {
        final result = await ctx.runRepository(repo, [
          'rev-parse',
          '--verify',
          '--quiet',
          ref,
        ], allowFailure: true);
        if (result.success)
          other = GitOid(oneLine(result.text).split('\n').first);
      }
    }
    return RepositoryOperation(
      kind,
      head: head,
      other: other,
      unmerged: unmerged,
      editStop:
          kind == GitOperationKind.rebase && await exists('rebase-merge/amend'),
    );
  }

  Future<List<GitReference>> references(RepositoryId repo) async {
    await ctx.validateIdentity(repo);
    final result = await ctx.runRepository(repo, [
      'for-each-ref',
      '--format=%(refname)%00%(objectname)%00%(upstream)%00%(HEAD)%00%(worktreepath)%00%(subject)%00%(objecttype)%00',
      'refs/heads/',
      'refs/remotes/',
      'refs/tags/',
    ]);
    final rows = nulRecords(result.stdout);
    final refs = <GitReference>[];
    for (var i = 0; i + 6 < rows.length; i += 7) {
      String text(int f) => utf8.decode(rows[i + f]);
      final name = text(0).replaceFirst(RegExp(r'^\n'), '');
      if (name.isEmpty) continue;
      refs.add(
        GitReference(
          name: name,
          oid: GitOid(text(1)),
          upstream: text(2).isEmpty ? null : text(2),
          current: text(3) == '*',
          worktreePath: text(4).isEmpty ? null : text(4),
          subject: text(5),
          type: text(6),
        ),
      );
    }
    return refs;
  }
}

typedef _StatusRead = ({
  List<GitChange> changes,
  GitOid? head,
  String? branch,
  String? upstream,
  int ahead,
  int behind,
  bool unmerged,
  String token,
});

Future<_StatusRead> _backgroundStatus(
  RepositoryId repo,
  String index,
  List<int> bytes, {
  GitOid? bareHead,
}) => Isolate.run(() {
  final parsed = parseStatusV2(bytes),
      rootPrefix = utf8.encode('${repo.root}/');
  final records = <int>[];
  var unmerged = false;
  for (final change in parsed.changes) {
    final path = change.path.bytes;
    final stat = LinuxPaths.stat([...rootPrefix, ...path]);
    records.addAll([
      ...path,
      0,
      ...utf8.encode('${stat.identity}:${stat.stamp}:${stat.mode}'),
      0,
    ]);
    unmerged = unmerged || change.conflicted;
  }
  final head = repo.bare ? bareHead : parsed.head;
  final workingIdentity = fingerprint(records);
  final token = fingerprint([
    ...utf8.encode(
      '${repo.key}\u0000$index\u0000${head?.value}\u0000$workingIdentity',
    ),
    ...bytes,
  ]);
  return (
    changes: parsed.changes,
    head: head,
    branch: parsed.branch,
    upstream: parsed.upstream,
    ahead: parsed.ahead,
    behind: parsed.behind,
    unmerged: unmerged,
    token: token,
  );
});
