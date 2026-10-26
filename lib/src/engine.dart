import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'client.dart';
import 'content_queries.dart';
import 'context.dart';
import 'index_mutations.dart';
import 'models.dart';
import 'repository_queries.dart';
import 'runner.dart';
import 'transactions.dart';
import 'reference_workflows.dart';
import 'network_workflows.dart';
import 'history_workflows.dart';
import 'creation_workflows.dart';
import 'editor_bridge.dart';
import 'integration_workflows.dart';
import 'conflict_workflows.dart';
import 'organization_workflows.dart';
import 'diff_queries.dart';
import 'linux_paths.dart';
import 'mutation_scopes.dart';
import 'reference_guards.dart';

/// Shared engine; owns no workspace, current repository, UI, or cloud state.
final class GitEngine implements GitClient, GitWorkflowClient, GitPatchClient {
  GitEngine({
    GitRunner? runner,
    bool Function(RepositoryId)? authorize,
    this.prompts,
    this.helperPath,
  }) {
    _ctx = GitContext(
      runner ?? ProcessGitRunner(helperPath: helperPath),
      authorize ?? (_) => false,
    );
    _repositories = RepositoryQueries(_ctx);
    _contents = ContentQueries(_ctx);
    _index = IndexMutations(_ctx, _contents, helperPath: helperPath);
    _references = ReferenceWorkflows(_ctx, helperPath: helperPath);
    _network = NetworkWorkflows(_ctx, _references);
    _history = HistoryWorkflows(_ctx, _contents);
    _creation = CreationWorkflows(_ctx, _repositories);
    _integration = IntegrationWorkflows(
      _ctx,
      _repositories,
      helperPath: helperPath,
    );
    _conflicts = ConflictWorkflows(_ctx, _contents, _repositories);
    _organization = OrganizationWorkflows(
      _ctx,
      _repositories,
      _contents,
      _references,
    );
    _diffs = DiffQueries(_ctx, _contents);
  }
  late final GitContext _ctx;
  late final RepositoryQueries _repositories;
  late final ContentQueries _contents;
  late final IndexMutations _index;
  late final ReferenceWorkflows _references;
  late final NetworkWorkflows _network;
  late final HistoryWorkflows _history;
  late final CreationWorkflows _creation;
  late final IntegrationWorkflows _integration;
  late final ConflictWorkflows _conflicts;
  late final OrganizationWorkflows _organization;
  late final DiffQueries _diffs;
  final RepositoryLocks _locks = RepositoryLocks();
  final GitPromptHandler? prompts;
  final String? helperPath;
  Future<T> _withProgress<T>(
    void Function(GitProgress)? callback,
    Future<T> Function(void Function(GitProgress)?) action,
  ) async {
    if (callback == null) return action(null);
    final relay = _ProgressRelay(callback);
    try {
      return await action(relay.add);
    } finally {
      relay.close();
    }
  }

  Future<T> _query<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on GitException {
      rethrow;
    } on FileSystemException catch (error) {
      throw GitException(
        GitErrorCode.unsafePath,
        diagnostic:
            'Filesystem access failed (errno ${error.osError?.errorCode ?? 0}).',
      );
    } on FormatException {
      throw const GitException(GitErrorCode.invalidRequest);
    } on ArgumentError {
      throw const GitException(GitErrorCode.invalidRequest);
    } on TypeError {
      throw const GitException(GitErrorCode.invalidRequest);
    }
  }

  @override
  Future<RepositoryId?> discover(
    String localPath, {
    GitCancellation? cancellation,
  }) => _query(
    () => _repositories.discover(localPath, cancellation: cancellation),
  );
  @override
  Future<GitSnapshot> status(
    RepositoryId repository, {
    GitCancellation? cancellation,
    GitReadPolicy policy = GitReadPolicy.restricted,
  }) => _query(
    () => _repositories.status(
      repository,
      cancellation: cancellation,
      policy: policy,
    ),
  );
  @override
  Future<List<GitReference>> references(RepositoryId repository) =>
      _query(() => _repositories.references(repository));
  @override
  Future<HistoryPage> history(
    RepositoryId repository, {
    HistoryFilter filter = const HistoryFilter(),
    int offset = 0,
    int limit = 100,
    String? anchor,
    GitCancellation? cancellation,
  }) => _query(
    () => _contents.history(
      repository,
      filter: filter,
      offset: offset,
      limit: limit,
      anchor: anchor,
      cancellation: cancellation,
    ),
  );
  @override
  Future<GitContent> content(
    RepositoryId repository,
    RepoPath path,
    ContentVersion version, {
    GitCancellation? cancellation,
  }) => _query(
    () => _contents.content(
      repository,
      path,
      version,
      cancellation: cancellation,
    ),
  );
  @override
  Future<List<GitChange>> changedFiles(
    RepositoryId repository,
    GitOid revision, {
    GitOid? parent,
  }) => _query(
    () => _contents.changedFiles(repository, revision, parent: parent),
  );
  @override
  Stream<void> watch(RepositoryId repository) => watchRepository(repository);
  @override
  Future<GitPatch> patch(
    RepositoryId repository,
    GitDiffSpec comparison, {
    GitCancellation? cancellation,
  }) => _query(
    () => _diffs.patch(repository, comparison, cancellation: cancellation),
  );
  @override
  Future<Json> inspect(
    RepositoryId repository,
    GitInspection request, {
    GitCancellation? cancellation,
    void Function(GitProgress)? onProgress,
  }) => _query(
    () => _inspect(
      repository,
      request,
      cancellation: cancellation,
      onProgress: onProgress,
    ),
  );
  Future<Json> _inspect(
    RepositoryId repository,
    GitInspection request, {
    GitCancellation? cancellation,
    void Function(GitProgress)? onProgress,
  }) async {
    await _ctx.validateIdentity(repository);
    if (request.kind == GitInspectionKind.pushReview) {
      final bridge = await _bridge(repository, cancellation, onProgress);
      try {
        return await _network.preparePush(
          repository,
          request,
          cancellation: cancellation,
          onProgress: onProgress,
          operationEnvironment: bridge?.environment ?? const {},
        );
      } on GitException catch (error) {
        if (bridge?.promptCancelled == true)
          throw const GitException(GitErrorCode.cancelled);
        throw bridge?.redactFailure(error) ?? error;
      } finally {
        await _closeBridge(bridge);
      }
    }
    return switch (request.kind) {
      GitInspectionKind.remotes => {
        'remotes': await _references.remotes(repository),
        'lastFetch': {
          for (final entry in _network.lastFetch.entries)
            entry.key: entry.value.toIso8601String(),
        },
      },
      GitInspectionKind.commitOptions => await _references.commitOptions(
        repository,
      ),
      GitInspectionKind.workingStatus => (await status(
        repository,
        cancellation: cancellation,
        policy: GitReadPolicy.authorized,
      )).toJson(),
      GitInspectionKind.pushPage => await _network.pushPage(
        repository,
        request,
        cancellation: cancellation,
      ),
      GitInspectionKind.conflict => await _conflicts.inspect(
        repository,
        request.path!,
      ),
      GitInspectionKind.rebasePlan => await _locks.withLocks(
        repository,
        () =>
            _integration.plan(repository, request, cancellation: cancellation),
        cancellation: cancellation,
      ),
      GitInspectionKind.stashes ||
      GitInspectionKind.worktrees ||
      GitInspectionKind.submodules ||
      GitInspectionKind.reflog => await _organization.inspect(
        repository,
        request,
        cancellation: cancellation,
      ),
      _ => await _history.inspect(
        repository,
        request,
        cancellation: cancellation,
      ),
    };
  }

  @override
  Future<GitCreationOutcome> create(
    GitCreation request, {
    GitCancellation? cancellation,
    void Function(GitProgress)? onProgress,
  }) => _withProgress(
    onProgress,
    (emit) => _create(request, cancellation: cancellation, onProgress: emit),
  );
  Future<GitCreationOutcome> _create(
    GitCreation request, {
    GitCancellation? cancellation,
    void Function(GitProgress)? onProgress,
  }) async {
    final planned = RepositoryId(
      root: request.destination,
      gitDir: '${request.destination}/.git',
      commonDir: '${request.destination}/.git',
      objectFormat: 'sha1',
    );
    final bridge = await _bridge(planned, cancellation, onProgress);
    try {
      final result = await _creation.create(
        request,
        cancellation: cancellation,
        onProgress: onProgress,
        operationEnvironment: bridge?.environment ?? const {},
      );
      if (bridge?.promptCancelled == true)
        return GitCreationOutcome(
          phase: GitOperationPhase.cancelled,
          repository: result.repository,
          error: const GitException(GitErrorCode.cancelled),
          createdDirectory: result.createdDirectory,
          destinationStillExists: result.destinationStillExists,
        );
      return result;
    } finally {
      await _closeBridge(bridge);
    }
  }

  Future<GitEditorBridge?> _bridge(
    RepositoryId repository,
    GitCancellation? cancellation,
    void Function(GitProgress)? onProgress, {
    String? todo,
  }) async {
    if (prompts == null && helperPath == null && todo == null) return null;
    final bridge = await GitEditorBridge.open(
      repository,
      handler: prompts,
      cancellation: cancellation,
      helperPath: helperPath,
      preparedTodo: todo,
    );
    _ctx.diagnosticRedactors[bridge.operationId] = bridge.redact;
    onProgress?.call(
      GitProgress(GitOperationPhase.preparing, operationId: bridge.operationId),
    );
    return bridge;
  }

  Future<void> _closeBridge(GitEditorBridge? bridge) async {
    if (bridge == null) return;
    try {
      await bridge.close();
    } finally {
      _ctx.diagnosticRedactors.remove(bridge.operationId);
    }
  }

  @override
  Future<GitOutcome> mutate(
    RepositoryId repository,
    GitMutation request, {
    GitCancellation? cancellation,
    void Function(GitProgress)? onProgress,
  }) => _withProgress(
    onProgress,
    (emit) => _mutate(
      repository,
      request,
      cancellation: cancellation,
      onProgress: emit,
    ),
  );
  Future<GitOutcome> _mutate(
    RepositoryId repository,
    GitMutation request, {
    GitCancellation? cancellation,
    void Function(GitProgress)? onProgress,
  }) async {
    _ctx.requireAuthorization(repository);
    if (!LinuxPaths.canWrite(repository.gitDir) ||
        !LinuxPaths.canWrite(repository.commonDir)) {
      throw const GitException(
        GitErrorCode.readOnly,
        diagnostic:
            'Repository metadata is read-only for this application. Inspection remains available.',
      );
    }
    GitException? error;
    GitRunResult? result;
    CommitObservation? commitObservation;
    onProgress?.call(const GitProgress(GitOperationPhase.preparing));
    try {
      await _query(() async {
        final scopes = MutationScopes(_ctx, _repositories, _contents);
        final reviewedScopes = await scopes.collect(
          repository,
          request,
          cancellation: cancellation,
        );
        return _locks.withLocks(
          repository,
          () async {
            final currentScopes = await scopes.collect(
              repository,
              request,
              cancellation: cancellation,
            );
            if (reviewedScopes.map((repo) => repo.key).join('\u0000') !=
                currentScopes.map((repo) => repo.key).join('\u0000')) {
              throw const GitException(GitErrorCode.staleReview);
            }
            for (final scope in currentScopes) {
              await _ctx.validateIdentity(scope);
            }
            await _ctx.validatePreconditions(
              repository,
              request.expectedHead,
              request.expectedIndex,
              cancellation: cancellation,
            );
            final before = await status(
              repository,
              cancellation: cancellation,
              policy: GitReadPolicy.authorized,
            );
            if (request is StagePaths &&
                request.expectedSnapshot != null &&
                request.expectedSnapshot != before.token) {
              throw const GitException(
                GitErrorCode.staleReview,
                diagnostic:
                    'The status selection changed after review. Refresh before staging.',
              );
            }
            if (request is ResetBranch &&
                request.replacesWorkingFiles &&
                (request.expectedWorkingToken == null ||
                    request.expectedWorkingToken != before.token)) {
              throw const GitException(
                GitErrorCode.staleReview,
                diagnostic:
                    'Working files changed after reset review. Refresh and review their effects before resetting.',
              );
            }
            if (request is StashMutation &&
                request.replacesWorkingFiles &&
                (request.expectedWorkingToken == null ||
                    request.expectedWorkingToken != before.token)) {
              throw const GitException(
                GitErrorCode.staleReview,
                diagnostic:
                    'Working files changed after stash review. Refresh and review their contents before applying this action.',
              );
            }
            if (before.operation.kind != GitOperationKind.none &&
                request is! StagePaths &&
                request is! WriteIndex &&
                request is! ResolveConflict &&
                request is! ContinueGitOperation &&
                !(request is CommitIndex &&
                    {
                      GitOperationKind.merge,
                      GitOperationKind.squash,
                      GitOperationKind.rebase,
                      GitOperationKind.cherryPick,
                      GitOperationKind.revert,
                    }.contains(before.operation.kind))) {
              throw const GitException(GitErrorCode.conflict);
            }
            onProgress?.call(const GitProgress(GitOperationPhase.running));
            final todo = request is RebaseCommits
                ? await _integration.prepareTodo(repository, request)
                : null;
            final bridge = await _bridge(
              repository,
              cancellation,
              onProgress,
              todo: todo,
            );
            void progress(String text) => onProgress?.call(
              GitProgress(
                GitOperationPhase.running,
                text: bridge?.redact(text) ?? text,
              ),
            );
            try {
              final environment =
                  bridge?.environment ?? const <String, String>{};
              result = switch (request) {
                StagePaths() ||
                WriteIndex() ||
                CommitIndex() => await _index.execute(
                  repository,
                  request,
                  cancellation: cancellation,
                  progress: progress,
                  operationEnvironment: environment,
                  onCommitObserved: (observed) => commitObservation = observed,
                ),
                BranchMutation() ||
                RemoteMutation() ||
                TagMutation() ||
                ConfigureIdentity() => await _references.execute(
                  repository,
                  request,
                  cancellation: cancellation,
                  progress: progress,
                  operationEnvironment: environment,
                ),
                FetchRemote() ||
                FetchPushDestination() ||
                PullRemote() ||
                PushReviewed() ||
                DeleteRemoteReference() => await _network.execute(
                  repository,
                  request,
                  cancellation: cancellation,
                  progress: progress,
                  operationEnvironment: environment,
                ),
                MergeRevision() ||
                PickCommits() ||
                ContinueGitOperation() ||
                RebaseCommits() => await _integration.execute(
                  repository,
                  request,
                  cancellation: cancellation,
                  progress: progress,
                  operationEnvironment: environment,
                ),
                ResolveConflict() => await _conflicts.resolve(
                  repository,
                  request,
                  cancellation: cancellation,
                  operationEnvironment: environment,
                ),
                StashMutation() ||
                WorktreeMutation() ||
                SubmoduleMutation() ||
                RestorePaths() ||
                RestoreFileRevision() ||
                ResetBranch() => await _organization.execute(
                  repository,
                  request,
                  cancellation: cancellation,
                  progress: progress,
                  operationEnvironment: environment,
                ),
              };
              if (result != null) {
                final diagnosticBytes = [
                  ...result!.stderr,
                  // Commit hooks often report a rejection on stdout. This output is
                  // diagnostic only; binary query output never passes through here.
                  if (request is CommitIndex && !result!.success) ...[
                    10,
                    ...result!.stdout,
                  ],
                ];
                final raw = utf8.decode(diagnosticBytes, allowMalformed: true);
                result = GitRunResult(
                  result!.exitCode,
                  result!.stdout,
                  Uint8List.fromList(utf8.encode(bridge?.redact(raw) ?? raw)),
                );
              }
              if (bridge?.failure case final failure?
                  when result?.success != true)
                throw failure;
              if (bridge?.promptCancelled == true && result?.success != true)
                throw const GitException(GitErrorCode.cancelled);
            } on GitException catch (failure) {
              throw bridge?.redactFailure(failure) ?? failure;
            } finally {
              await _closeBridge(bridge);
            }
            if (result != null && !result!.success) error = result!.failure;
          },
          cancellation: cancellation,
          related: reviewedScopes,
        );
      });
    } on GitException catch (failure) {
      error = failure;
    }
    GitSnapshot? after;
    try {
      after = await status(repository, policy: GitReadPolicy.authorized);
    } on GitException catch (failure) {
      error ??= result?.success == true
          ? GitException(
              GitErrorCode.uncertainOutcome,
              diagnostic:
                  'Git exited successfully, but repository reconciliation failed: ${failure.code.name}. Inspect the current state before another operation.',
            )
          : failure;
    }
    final created = commitObservation?.created;
    if (commitObservation?.failure case final failure?
        when error == null ||
            {
              GitErrorCode.commandFailed,
              GitErrorCode.hook,
            }.contains(error?.code)) {
      error = failure;
    }
    if (request is CommitIndex && result?.success == true && created == null) {
      error ??= const GitException(
        GitErrorCode.uncertainOutcome,
        diagnostic:
            'Git reported commit success but its outcome record is unavailable. Review Log and the index before attempting another commit.',
      );
    }
    if (request is CommitIndex && created != null) {
      try {
        if (after?.head != created ||
            await _ctx.headReference(repository) != commitObservation!.target) {
          error ??= const GitException(
            GitErrorCode.uncertainOutcome,
            diagnostic:
                'The local commit exists, but a hook or another client changed HEAD afterward. Inspect the recorded commit and current branch before another operation.',
          );
        }
      } on GitException catch (failure) {
        error ??= failure;
      }
    }
    final phase = switch (error?.code) {
      GitErrorCode.cancelled
          when request is PushReviewed || request is DeleteRemoteReference =>
        GitOperationPhase.uncertain,
      GitErrorCode.cancelled =>
        created != null
            ? GitOperationPhase.uncertain
            : GitOperationPhase.cancelled,
      GitErrorCode.deadline ||
      GitErrorCode.disconnected ||
      GitErrorCode.uncertainOutcome => GitOperationPhase.uncertain,
      _
          when (request is PushReviewed || request is DeleteRemoteReference) &&
              error?.code == GitErrorCode.transport =>
        GitOperationPhase.uncertain,
      _
          when after != null &&
              !{
                GitOperationKind.none,
                GitOperationKind.squash,
              }.contains(after.operation.kind) =>
        GitOperationPhase.stopped,
      _ when error != null =>
        created != null
            ? GitOperationPhase.uncertain
            : GitOperationPhase.failed,
      _ => GitOperationPhase.completed,
    };
    onProgress?.call(GitProgress(phase));
    return GitOutcome(
      phase: phase,
      snapshot: after,
      error: error,
      createdCommit: created,
      diagnostic: result?.diagnostic ?? error?.diagnostic ?? '',
    );
  }
}

/// Bound network output to twenty presentation updates per second. Phase and
/// authenticated operation identity changes are delivered immediately.
final class _ProgressRelay {
  _ProgressRelay(this.callback);
  final void Function(GitProgress) callback;
  GitProgress? pending;
  GitOperationPhase? phase;
  Timer? timer;
  void add(GitProgress value) {
    if (value.phase != phase || value.operationId.isNotEmpty) {
      timer?.cancel();
      timer = null;
      pending = null;
      phase = value.phase;
      callback(value);
      return;
    }
    pending = value;
    timer ??= Timer(const Duration(milliseconds: 50), flush);
  }

  void flush() {
    timer = null;
    final value = pending;
    pending = null;
    if (value != null) callback(value);
  }

  void close() {
    timer?.cancel();
    flush();
  }
}
