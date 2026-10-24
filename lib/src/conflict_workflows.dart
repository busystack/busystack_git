import 'dart:convert';
import 'dart:typed_data';
import 'client.dart';
import 'content_queries.dart';
import 'context.dart';
import 'linux_paths.dart';
import 'models.dart';
import 'repository_queries.dart';
import 'runner.dart';
import 'transactions.dart';

final class ConflictWorkflows {
  ConflictWorkflows(this.ctx, this.contents, this.repositories)
    : transactions = IndexTransactions(ctx);
  final GitContext ctx;
  final ContentQueries contents;
  final RepositoryQueries repositories;
  final IndexTransactions transactions;
  Future<Json> inspect(RepositoryId repo, RepoPath path) async {
    final entries = (await contents.index(
      repo,
    )).where((e) => e.path == path && e.stage != 0).toList();
    if (entries.isEmpty) throw const GitException(GitErrorCode.staleReview);
    final working = await contents.content(
      repo,
      path,
      const ContentVersion.working(),
    );
    final operation = await repositories.operationState(
      repo,
      head: await ctx.head(repo),
      unmerged: true,
    );
    final left = operation.head, right = operation.other;
    final stages = {
      for (final entry in entries) '${entry.stage}': entry.toJson(),
    };
    return {
      'path': path.toJson(),
      'stages': stages,
      'working': working.toJson(includeBytes: false),
      'operation': operation.toJson(),
      'leftRevision': left?.value,
      'rightRevision': right?.value,
      'leftLabel': operation.kind == GitOperationKind.rebase
          ? 'Rebased history · ${left?.abbreviated ?? "HEAD"}'
          : 'Current history · ${left?.abbreviated ?? "HEAD"}',
      'rightLabel': operation.kind == GitOperationKind.rebase
          ? 'Replayed commit · ${right?.abbreviated ?? "stage 3"}'
          : 'Incoming content · ${right?.abbreviated ?? "stage 3"}',
      'baseAvailable': entries.any((e) => e.stage == 1),
      'marker': conflictMarker(entries),
      'kind': entries.any((e) => e.mode == '160000')
          ? 'submodule'
          : entries.any((e) => e.mode == '120000')
          ? 'symlink'
          : entries.length == 2 && !entries.any((e) => e.stage == 1)
          ? 'add/add'
          : !entries.any((e) => e.stage == 2) ||
                !entries.any((e) => e.stage == 3)
          ? 'modify/delete or rename/delete'
          : 'content',
    };
  }

  Future<GitRunResult?> resolve(
    RepositoryId repo,
    ResolveConflict request, {
    GitCancellation? cancellation,
    Map<String, String> operationEnvironment = const {},
  }) async {
    GitRunResult? result;
    await transactions.update(repo, request.expectedHead, request.expectedIndex, (
      indexEnvironment,
    ) async {
      final entries = (await contents.index(
        repo,
      )).where((e) => e.path == request.path && e.stage != 0).toList();
      final expected = request.expectedStages;
      if (entries.length != expected.length ||
          entries.any((e) => expected[e.stage] != '${e.mode}:${e.oid.value}') ||
          (await contents.content(
                repo,
                request.path,
                const ContentVersion.working(),
              )).token !=
              request.expectedWorking) {
        throw const GitException(GitErrorCode.staleReview);
      }
      final environment = {...operationEnvironment, ...indexEnvironment};
      String mode =
          request.mode ??
          entries.where((e) => e.stage == 2).firstOrNull?.mode ??
          entries.where((e) => e.stage == 3).firstOrNull?.mode ??
          '100644';
      Uint8List? bytes = request.bytes;
      IndexEntry? selected;
      final path = await ctx.workingPath(repo, request.path);
      if (request.choice == ConflictChoice.left ||
          request.choice == ConflictChoice.right) {
        final stage = request.choice == ConflictChoice.left ? 2 : 3;
        final entry = entries.where((e) => e.stage == stage).firstOrNull;
        if (entry == null) {
          bytes = null;
        } else {
          selected = entry;
          mode = entry.mode;
          if (mode == '160000') {
            if (!request.stageResult)
              throw const GitException(GitErrorCode.invalidRequest);
          } else {
            // Git streams the chosen index stage through its configured working
            // conversion, including binary/large blobs, modes and symlinks.
            // No content body crosses an adapter and no UTF-8 roundtrip occurs.
            result = await ctx.runRepository(
              repo,
              [
                'restore',
                stage == 2 ? '--ours' : '--theirs',
                '--worktree',
                '--pathspec-from-file=-',
                '--pathspec-file-nul',
              ],
              passive: false,
              environment: environment,
              input: [...request.path.bytes, 0],
              cancellation: cancellation,
            );
          }
        }
      } else if (request.choice == ConflictChoice.delete) {
        bytes = null;
      } else if (request.choice == ConflictChoice.edited && bytes == null)
        throw const GitException(GitErrorCode.invalidRequest);
      if (request.choice == ConflictChoice.gitlink) {
        if (!request.stageResult || request.gitlink == null)
          throw const GitException(GitErrorCode.invalidRequest);
        mode = '160000';
      } else if (selected == null) {
        if (!const {'100644', '100755', '120000'}.contains(mode))
          throw const GitException(GitErrorCode.invalidRequest);
        LinuxPaths.replaceWorking(path, bytes, mode);
      }
      if (!request.stageResult) return;
      final input = BytesBuilder()
        ..add(
          utf8.encode('0 ${'0' * (repo.objectFormat == 'sha256' ? 64 : 40)}\t'),
        )
        ..add(request.path.bytes)
        ..addByte(0);
      if (selected != null) {
        input.add(utf8.encode('${selected.mode} ${selected.oid.value}\t'));
        input.add(request.path.bytes);
        input.addByte(0);
      } else if (request.choice == ConflictChoice.gitlink) {
        input.add(utf8.encode('160000 ${request.gitlink!.value}\t'));
        input.add(request.path.bytes);
        input.addByte(0);
      }
      result = await ctx.runRepository(
        repo,
        ['update-index', '-z', '--index-info'],
        passive: false,
        environment: environment,
        input: input.takeBytes(),
        cancellation: cancellation,
      );
      if (selected == null &&
          bytes != null &&
          request.choice != ConflictChoice.gitlink) {
        // git add performs the configured clean conversion, preserving Git's
        // distinction between working bytes and the normalized index result.
        result = await ctx.runRepository(
          repo,
          ['add', '--pathspec-from-file=-', '--pathspec-file-nul'],
          passive: false,
          environment: environment,
          input: [...request.path.bytes, 0],
          cancellation: cancellation,
        );
      }
    }, cancellation: cancellation);
    return result;
  }
}
