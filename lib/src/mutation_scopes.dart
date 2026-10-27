import 'content_queries.dart';
import 'context.dart';
import 'models.dart';
import 'linux_paths.dart';
import 'repository_queries.dart';
import 'runner.dart';
import 'client.dart';

/// Discover related lock scopes through Git, never through caller-supplied
/// metadata paths. A child mutation and an explicit parent submodule update
/// must coordinate even though their indexes and common directories differ.
final class MutationScopes {
  const MutationScopes(this.ctx, this.repositories, this.contents);
  final GitContext ctx;
  final RepositoryQueries repositories;
  final ContentQueries contents;

  Future<List<RepositoryId>> collect(
    RepositoryId repo,
    GitMutation request, {
    GitCancellation? cancellation,
  }) async {
    final found = <String, RepositoryId>{};
    Future<void> ancestors(RepositoryId current) async {
      while (!found.containsKey(current.key)) {
        found[current.key] = current;
        cancellation?.check();
        final parentPath = oneLine(
          (await ctx.runRepository(current, [
            'rev-parse',
            '--show-superproject-working-tree',
          ], cancellation: cancellation)).text,
        );
        if (parentPath.isEmpty) break;
        final parent = await repositories.discover(
          parentPath,
          cancellation: cancellation,
        );
        if (parent == null || parent.root != parentPath) {
          throw const GitException(GitErrorCode.staleReview);
        }
        current = parent;
      }
    }

    await ancestors(repo);
    if (request is SubmoduleMutation) {
      final visited = <String>{};
      Future<void> child(RepositoryId parent, RepoPath path) async {
        await ctx.workingPath(parent, path);
        final name = path.utf8Path;
        // Byte-named gitlinks remain bound to the parent's reviewed content
        // token and real index transaction. Host folder APIs cannot open them
        // as a second independent BusyStack workspace.
        if (name == null) return;
        final target = '${parent.root}/$name';
        final nested = await repositories.discover(
          target,
          cancellation: cancellation,
        );
        if (nested == null || nested.root != target || !visited.add(nested.key))
          return;
        await ancestors(nested);
        if (request.action != SubmoduleAction.stagePointer) {
          await ctx.requireAuthorization(nested);
          final entries = await contents.index(nested);
          final state = await repositories.operationState(
            nested,
            unmerged: entries.any((entry) => entry.stage != 0),
          );
          if (state.kind != GitOperationKind.none) {
            throw const GitException(
              GitErrorCode.conflict,
              diagnostic:
                  'Finish or abort the selected submodule’s existing Git operation before updating its checkout.',
            );
          }
          if (request.recursive) {
            for (final entry in entries.where(
              (entry) => entry.mode == '160000' && entry.stage == 0,
            )) {
              await child(nested, entry.path);
            }
          }
        }
      }

      for (final path in request.paths) {
        // An uninitialized checkout can be absent; Git creates it only during
        // the explicitly reviewed update, under the superproject's lock.
        final raw = await ctx.workingPath(repo, path);
        if (!LinuxPaths.stat(raw).exists) continue;
        await child(repo, path);
      }
    }
    return found.values.toList()..sort((a, b) => a.key.compareTo(b.key));
  }
}
