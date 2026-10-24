import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'client.dart';
import 'content_queries.dart';
import 'context.dart';
import 'models.dart';
import 'runner.dart';
import 'transactions.dart';
import 'reference_guards.dart';

final class IndexMutations {
  IndexMutations(this.ctx, this.contents, {this.helperPath})
    : transactions = IndexTransactions(ctx);
  final GitContext ctx;
  final ContentQueries contents;
  final IndexTransactions transactions;
  final String? helperPath;
  Future<GitRunResult?> execute(
    RepositoryId repo,
    GitMutation request, {
    GitCancellation? cancellation,
    void Function(String)? progress,
    Map<String, String> operationEnvironment = const {},
    void Function(CommitObservation)? onCommitObserved,
  }) async {
    GitRunResult? result;
    HeadReferenceGuard? guard;
    try {
      await transactions.update(
        repo,
        request.expectedHead,
        request.expectedIndex,
        (indexEnvironment) async {
          final environment = {...operationEnvironment, ...indexEnvironment};
          switch (request) {
            case StagePaths():
              if (request.paths.isEmpty || request.paths.length > 10000)
                throw const GitException(GitErrorCode.invalidRequest);
              final sourceTokens = <RepoPath, String>{};
              for (final path in request.paths) {
                await ctx.workingPath(repo, path);
                if (!request.unstage)
                  sourceTokens[path] = (await contents.content(
                    repo,
                    path,
                    const ContentVersion.working(),
                  )).token;
                if (request.contentTokens[path.key] case final expected?) {
                  if ((sourceTokens[path] ??
                          (await contents.content(
                            repo,
                            path,
                            const ContentVersion.working(),
                          )).token) !=
                      expected) {
                    throw const GitException(GitErrorCode.staleReview);
                  }
                }
              }
              final paths = BytesBuilder();
              for (final path in request.paths) {
                paths.add(path.bytes);
                paths.addByte(0);
              }
              if (!request.unstage) {
                result = await ctx.runRepository(
                  repo,
                  ['add', '--pathspec-from-file=-', '--pathspec-file-nul'],
                  input: paths.takeBytes(),
                  passive: false,
                  environment: environment,
                  cancellation: cancellation,
                  progress: progress,
                );
                for (final source in sourceTokens.entries) {
                  if ((await contents.content(
                        repo,
                        source.key,
                        const ContentVersion.working(),
                      )).token !=
                      source.value) {
                    throw const GitException(
                      GitErrorCode.staleReview,
                      diagnostic:
                          'Working content changed while Git prepared the index. The transactional index was not installed.',
                    );
                  }
                }
              } else if (request.expectedHead != null) {
                result = await ctx.runRepository(
                  repo,
                  [
                    'restore',
                    '--staged',
                    '--source=${request.expectedHead!.value}',
                    '--pathspec-from-file=-',
                    '--pathspec-file-nul',
                  ],
                  input: paths.takeBytes(),
                  passive: false,
                  environment: environment,
                  cancellation: cancellation,
                );
              } else {
                final input = BytesBuilder();
                for (final path in request.paths) {
                  input.add(
                    utf8.encode(
                      '0 ${'0' * (repo.objectFormat == 'sha256' ? 64 : 40)}\t',
                    ),
                  );
                  input.add(path.bytes);
                  input.addByte(0);
                }
                result = await ctx.runRepository(
                  repo,
                  ['update-index', '-z', '--index-info'],
                  input: input.takeBytes(),
                  passive: false,
                  environment: environment,
                  cancellation: cancellation,
                );
              }
            case WriteIndex():
              if (!const {
                    '100644',
                    '100755',
                    '120000',
                  }.contains(request.mode) ||
                  request.mode == '120000' &&
                      (request.bytes.isEmpty || request.bytes.contains(0))) {
                throw const GitException(GitErrorCode.invalidRequest);
              }
              final current = await contents.content(
                repo,
                request.path,
                const ContentVersion.index(),
              );
              if (current.token != request.expectedContent)
                throw const GitException(GitErrorCode.staleReview);
              if (request.expectedWorktree != null &&
                  (await contents.content(
                        repo,
                        request.path,
                        const ContentVersion.working(),
                      )).token !=
                      request.expectedWorktree) {
                throw const GitException(GitErrorCode.staleReview);
              }
              final oid = request.remove
                  ? '0' * (repo.objectFormat == 'sha256' ? 64 : 40)
                  : oneLine(
                      (await ctx.runRepository(
                        repo,
                        ['hash-object', '-w', '--stdin', '--no-filters'],
                        input: request.bytes,
                        passive: false,
                        cancellation: cancellation,
                      )).text,
                    );
              final input = BytesBuilder()
                ..add(
                  utf8.encode('${request.remove ? '0' : request.mode} $oid\t'),
                )
                ..add(request.path.bytes)
                ..addByte(0);
              result = await ctx.runRepository(
                repo,
                ['update-index', '-z', '--index-info'],
                input: input.takeBytes(),
                passive: false,
                environment: environment,
                cancellation: cancellation,
              );
              if (request.expectedWorktree != null &&
                  (await contents.content(
                        repo,
                        request.path,
                        const ContentVersion.working(),
                      )).token !=
                      request.expectedWorktree)
                throw const GitException(GitErrorCode.staleReview);
            case CommitIndex():
              if (request.message.trim().isEmpty ||
                  request.message.contains('\u0000') ||
                  request.author?.contains(RegExp(r'[\r\n\x00]')) == true) {
                throw const GitException(GitErrorCode.invalidRequest);
              }
              final target = await ctx.headReference(
                repo,
                cancellation: cancellation,
              );
              // Bind the captured symbolic target to the reviewed index token,
              // then have Git recheck it with its own reference locks held.
              await ctx.validatePreconditions(
                repo,
                request.expectedHead,
                request.expectedIndex,
                cancellation: cancellation,
              );
              guard = await ReferenceGuards(
                ctx,
                helperPath: helperPath,
              ).commit(repo, target, request.expectedHead);
              environment.addAll(guard!.environment);
              result = await ctx.runRepository(
                repo,
                [
                  ...guard!.arguments,
                  'commit',
                  '--file=-',
                  if (request.amend) '--amend',
                  if (request.signOff) '--signoff',
                  if (request.allowEmpty) '--allow-empty',
                  if (request.sign == true) '--gpg-sign',
                  if (request.sign == false) '--no-gpg-sign',
                  if (request.author != null) '--author=${request.author}',
                ],
                input: utf8.encode(request.message),
                passive: false,
                environment: environment,
                cancellation: cancellation,
                progress: progress,
                allowFailure: true,
              );
            default:
              throw const GitException(GitErrorCode.invalidRequest);
          }
        },
        cancellation: cancellation,
        allowHeadChange: request is CommitIndex,
      );
    } finally {
      final observed = guard;
      if (observed != null) {
        GitOid? created;
        GitException? failure;
        try {
          created = await observed.receipt();
        } on GitException catch (error) {
          failure = error;
        } on FileSystemException {
          failure = const GitException(
            GitErrorCode.unsafePath,
            diagnostic:
                'Cannot read the private commit outcome. Inspect Git state before another commit.',
          );
        }
        onCommitObserved?.call(
          CommitObservation(observed.target, created, failure),
        );
        await observed.close();
      }
    }
    return result;
  }
}
