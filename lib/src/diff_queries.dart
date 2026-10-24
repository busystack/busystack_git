import 'dart:io';
import 'client.dart';
import 'content_queries.dart';
import 'context.dart';
import 'models.dart';
import 'runner.dart';

final class DiffQueries {
  const DiffQueries(this.ctx, this.contents);
  final GitContext ctx;
  final ContentQueries contents;
  Future<GitPatch> patch(
    RepositoryId repo,
    GitDiffSpec comparison, {
    GitCancellation? cancellation,
  }) async {
    await ctx.validateIdentity(repo);
    if (comparison.left.kind == ContentKind.workingTree ||
        comparison.right.kind == ContentKind.workingTree) {
      await ctx.passiveStatusPolicy(repo, allowExecutableFilters: true);
    }
    for (final path in comparison.paths) {
      await ctx.workingPath(repo, path);
    }
    final left = comparison.left, right = comparison.right;
    if (left.kind == ContentKind.absent &&
        right.kind == ContentKind.workingTree &&
        comparison.paths.length == 1) {
      final content = await contents.content(
        repo,
        comparison.paths.single,
        right,
        cancellation: cancellation,
      );
      if (content.availability == ContentAvailability.tooLarge)
        throw const GitException(GitErrorCode.outputLimit);
      final directory = await Directory.systemTemp.createTemp('bsg-patch-');
      try {
        await File('${directory.path}/before').writeAsBytes([]);
        await File('${directory.path}/after').writeAsBytes(content.bytes);
        final result = await ctx.runRepository(
          repo,
          [
            'diff',
            '--no-index',
            '--no-ext-diff',
            '--no-textconv',
            '--no-color',
            '--',
            '${directory.path}/before',
            '${directory.path}/after',
          ],
          cancellation: cancellation,
          allowFailure: true,
        );
        if (result.exitCode != 0 && result.exitCode != 1) throw result.failure;
        return GitPatch(result.stdout);
      } finally {
        await directory.delete(recursive: true);
      }
    }
    Future<String> tree(ContentVersion version) async {
      if (version.kind == ContentKind.commit && version.revision != null)
        return version.revision!.value;
      if (version.kind == ContentKind.absent)
        return oneLine(
          (await ctx.runRepository(repo, ['mktree'], input: [])).text,
        );
      throw const GitException(GitErrorCode.invalidRequest);
    }

    final args = <String>[
      '-c',
      'core.quotepath=true',
      'diff',
      '--no-ext-diff',
      '--no-textconv',
      '--no-color',
      '--find-renames',
      '--find-copies',
    ];
    if (right.kind == ContentKind.indexVersion) {
      args.add('--cached');
      if (left.kind == ContentKind.commit)
        args.add(await tree(left));
      else if (left.kind != ContentKind.absent)
        throw const GitException(GitErrorCode.invalidRequest);
    } else if (right.kind == ContentKind.workingTree) {
      if (left.kind == ContentKind.commit || left.kind == ContentKind.absent)
        args.add(await tree(left));
      else if (left.kind != ContentKind.indexVersion)
        throw const GitException(GitErrorCode.invalidRequest);
    } else {
      args.addAll([await tree(left), await tree(right)]);
    }
    args.add('--');
    final byteArguments = <int, List<int>>{};
    for (final path in comparison.paths) {
      if (path.utf8Path == null) byteArguments[args.length] = path.bytes;
      args.add(path.utf8Path ?? '');
    }
    final result = await ctx.runRepository(
      repo,
      args,
      cancellation: cancellation,
      byteArguments: byteArguments,
    );
    return GitPatch(result.stdout);
  }
}
