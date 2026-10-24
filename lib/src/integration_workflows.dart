import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'client.dart';
import 'context.dart';
import 'editor_bridge.dart';
import 'byte_text.dart';
import 'models.dart';
import 'repository_queries.dart';
import 'runner.dart';

/// Git's merge/sequencer/rebase machinery owns all continuing operations.
final class IntegrationWorkflows {
  IntegrationWorkflows(this.ctx, this.repositories, {this.helperPath});
  final GitContext ctx;
  final RepositoryQueries repositories;
  final String? helperPath;
  final _plans = <String, _Plan>{};

  Future<Json> plan(
    RepositoryId repo,
    GitInspection request, {
    GitCancellation? cancellation,
  }) async {
    ctx.requireAuthorization(repo);
    final before = await repositories.status(
      repo,
      cancellation: cancellation,
      policy: GitReadPolicy.authorized,
    );
    if (before.head == null ||
        before.operation.kind != GitOperationKind.none ||
        before.changes.isNotEmpty) {
      throw const GitException(
        GitErrorCode.conflict,
        diagnostic:
            'A rebase plan requires a clean working tree and index, with no operation in progress.',
      );
    }
    final bridge = await GitEditorBridge.open(
      repo,
      helperPath: helperPath,
      cancellation: cancellation,
      captureSequence: true,
    );
    try {
      await ctx.runRepository(
        repo,
        _arguments(
          boundary: request.revision,
          onto: request.otherRevision,
          root: request.root,
          preserve: request.preserveMerges,
          autosquash: request.autosquash,
          interactive: true,
        ),
        passive: false,
        cancellation: cancellation,
        environment: bridge.environment,
        allowFailure: true,
      );
      final todo = bridge.capturedTodo;
      if (todo == null)
        throw const GitException(
          GitErrorCode.invalidRequest,
          diagnostic: 'Git did not produce an editable rebase plan.',
        );
      final after = await repositories.status(
        repo,
        policy: GitReadPolicy.authorized,
      );
      if (after.head != before.head ||
          after.indexToken != before.indexToken ||
          after.operation.kind != GitOperationKind.none ||
          after.token != before.token) {
        throw const GitException(
          GitErrorCode.staleReview,
          diagnostic:
              'Repository state changed while preparing the rebase plan.',
        );
      }
      final text = decodeGitUtf8(todo), lines = text.split('\n');
      final steps = <Json>[],
          parsedLines = <(int, (String, String, String, String))>[];
      final blocks = <int, int>{};
      var block = 0;
      for (var i = 0; i < lines.length; i++) {
        if (RegExp(r'^(label|reset|merge)\s').hasMatch(lines[i])) block++;
        blocks[i] = block;
        final parsed = _commitLine(lines[i]);
        if (parsed == null) continue;
        parsedLines.add((i, parsed));
      }
      if (parsedLines.isNotEmpty) {
        final objects = await ctx.runRepository(
          repo,
          ['cat-file', '--batch-check=%(objectname) %(objecttype)'],
          input: utf8.encode('${parsedLines.map((e) => e.$2.$2).join('\n')}\n'),
          cancellation: cancellation,
        );
        final rows = objects.text.trimRight().split('\n');
        if (rows.length != parsedLines.length)
          throw const GitException(GitErrorCode.missingContent);
        for (var i = 0; i < rows.length; i++) {
          final fields = rows[i].split(' '), parsed = parsedLines[i].$2;
          if (fields.length != 2 || fields[1] != 'commit')
            throw const GitException(GitErrorCode.missingContent);
          steps.add({
            'line': parsedLines[i].$1,
            'action': parsed.$1,
            'commit': GitOid(fields[0]).value,
            'subject': parsed.$3,
            'modifier': parsed.$4,
            'block': blocks[parsedLines[i].$1],
          });
        }
      }
      final token = List.generate(
        32,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      if (_plans.length >= 12) _plans.remove(_plans.keys.first);
      _plans[token] = _Plan(
        repo.key,
        before.head!,
        before.indexToken,
        request,
        text,
        steps,
        DateTime.now().add(const Duration(minutes: 30)),
      );
      return {
        'token': token,
        'head': before.head!.value,
        'index': before.indexToken,
        'boundaryExcluded': request.revision?.value,
        'onto': request.otherRevision?.value,
        'root': request.root,
        'preserveMerges': request.preserveMerges,
        'todo': text,
        'steps': steps,
      };
    } finally {
      await bridge.close();
    }
  }

  Future<String?> prepareTodo(RepositoryId repo, RebaseCommits request) async {
    if (!request.interactive) return null;
    final plan = _plans[request.planToken];
    if (plan == null ||
        plan.repo != repo.key ||
        plan.expires.isBefore(DateTime.now()) ||
        plan.head != request.expectedHead ||
        plan.index != request.expectedIndex ||
        plan.request.revision != request.boundary ||
        plan.request.otherRevision != request.onto ||
        plan.request.root != request.root ||
        plan.request.preserveMerges != request.preserveMerges ||
        plan.request.autosquash != request.autosquash)
      throw const GitException(GitErrorCode.staleReview);
    final available = {
      for (final step in plan.steps) step['commit'] as String: step,
    };
    if (request.steps.length != available.length ||
        request.steps.map((e) => e.commit.value).toSet().length !=
            available.length ||
        request.steps.any((e) => !available.containsKey(e.commit.value)))
      throw const GitException(GitErrorCode.invalidRequest);
    var hasTarget = false;
    int? previousBlock;
    for (final step in request.steps) {
      if (request.preserveMerges) {
        final block = available[step.commit.value]!['block'] as int;
        if (block != previousBlock) hasTarget = false;
        previousBlock = block;
      }
      if (step.action == RebaseAction.drop) continue;
      if ({RebaseAction.squash, RebaseAction.fixup}.contains(step.action) &&
          !hasTarget) {
        throw const GitException(
          GitErrorCode.invalidRequest,
          diagnostic:
              'Squash and fixup need a preceding retained commit in the same branch block.',
        );
      }
      hasTarget = true;
    }
    String command(RebaseStep step) {
      final original = available[step.commit.value]!;
      final modifier =
          step.action == RebaseAction.fixup && original['action'] == 'fixup'
          ? original['modifier'] as String
          : '';
      return '${step.action.name} ${modifier.isEmpty ? '' : '$modifier '}${step.commit.value} ${original['subject']}';
    }

    if (!request.preserveMerges) {
      _plans.remove(request.planToken);
      return '${request.steps.map(command).join('\n')}\n';
    }
    // Structural commands stay byte-for-byte in their original branch blocks.
    // Reordering across a reset/label/merge boundary would alter the topology.
    final lines = plan.todo.split('\n'), edited = List<String>.from(lines);
    final positions = [
      for (var i = 0; i < lines.length; i++)
        if (_commitLine(lines[i]) != null) i,
    ];
    final groups = <int, int>{};
    var group = 0;
    for (var i = 0; i < lines.length; i++) {
      if (RegExp(r'^(label|reset|merge)\s').hasMatch(lines[i])) group++;
      groups[i] = group;
    }
    for (var i = 0; i < positions.length; i++) {
      final step = request.steps[i],
          sourceLine = available[step.commit.value]!['line'] as int;
      if (groups[sourceLine] != groups[positions[i]])
        throw const GitException(
          GitErrorCode.invalidRequest,
          diagnostic:
              'Move commits within the same branch block when preserving merges.',
        );
      edited[positions[i]] = command(step);
    }
    _plans.remove(request.planToken);
    return edited.join('\n');
  }

  Future<GitRunResult> execute(
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
      case MergeRevision():
        if (request.stopBeforeCommit &&
            request.policy == MergePolicy.fastForwardOnly) {
          throw const GitException(
            GitErrorCode.invalidRequest,
            diagnostic: 'Fast-forward-only cannot stop before moving HEAD.',
          );
        }
        return run([
          'merge',
          '--no-autostash',
          '--no-edit',
          switch (request.policy) {
            MergePolicy.squash => '--squash',
            MergePolicy.fastForwardOnly => '--ff-only',
            MergePolicy.noFastForward => '--no-ff',
            MergePolicy.fastForward =>
              request.stopBeforeCommit ? '--no-ff' : '--ff',
          },
          if (request.stopBeforeCommit || request.policy == MergePolicy.squash)
            '--no-commit'
          else
            '--commit',
          if (request.message != null) ...['-m', request.message!],
          request.source.value,
        ]);
      case PickCommits():
        if (request.commits.isEmpty ||
            request.commits.length > 1000 ||
            (request.mainline != null && request.mainline! < 1)) {
          throw const GitException(GitErrorCode.invalidRequest);
        }
        for (final oid in request.commits) {
          final parents = oneLine(
            (await ctx.runRepository(repo, [
              'rev-list',
              '--parents',
              '-n',
              '1',
              oid.value,
            ])).text,
          ).split(' ');
          if (parents.length > 2 &&
              (request.mainline == null ||
                  request.mainline! >= parents.length)) {
            throw const GitException(
              GitErrorCode.invalidRequest,
              diagnostic: 'Select a mainline parent for each merge commit.',
            );
          }
        }
        return run([
          request.revert ? 'revert' : 'cherry-pick',
          '--no-edit',
          if (request.noCommit) '--no-commit',
          if (request.mainline != null) ...[
            '--mainline',
            '${request.mainline}',
          ],
          ...request.commits.map((e) => e.value),
        ]);
      case ContinueGitOperation():
        final actual = await repositories.status(
          repo,
          policy: GitReadPolicy.authorized,
        );
        if (actual.operation.kind != request.operation ||
            !actual.operation.actions.contains(request.action)) {
          throw const GitException(GitErrorCode.staleReview);
        }
        if (request.action == GitContinuation.continueOperation &&
            actual.changes.any((e) => e.conflicted)) {
          throw const GitException(GitErrorCode.conflict);
        }
        if (request.action == GitContinuation.continueOperation &&
            request.operation == GitOperationKind.rebase) {
          final todo = File(
            await gitMetadataPath(ctx, repo, 'rebase-merge/git-rebase-todo'),
          );
          if (await todo.exists() &&
              RegExp(
                r'^(exec|x)\s',
                multiLine: true,
              ).hasMatch(await todo.readAsString())) {
            throw const GitException(
              GitErrorCode.trustRequired,
              diagnostic:
                  'This externally created plan includes shell commands. Review its executable behavior before continuing.',
            );
          }
        }
        final command = switch (request.operation) {
          GitOperationKind.merge => 'merge',
          GitOperationKind.rebase => 'rebase',
          GitOperationKind.cherryPick => 'cherry-pick',
          GitOperationKind.revert => 'revert',
          GitOperationKind.applyMailbox => 'am',
          _ => throw const GitException(GitErrorCode.invalidRequest),
        };
        final action = switch (request.action) {
          GitContinuation.continueOperation => '--continue',
          GitContinuation.abort => '--abort',
          GitContinuation.skip => '--skip',
          GitContinuation.quit => '--quit',
        };
        return run([command, action]);
      case RebaseCommits():
        final current = await repositories.status(
          repo,
          policy: GitReadPolicy.authorized,
        );
        if (current.changes.isNotEmpty)
          throw const GitException(
            GitErrorCode.conflict,
            diagnostic: 'Commit or explicitly stash changes before rebasing.',
          );
        return run(
          _arguments(
            boundary: request.boundary,
            onto: request.onto,
            root: request.root,
            preserve: request.preserveMerges,
            autosquash: request.autosquash,
            interactive: request.interactive,
          ),
        );
      default:
        throw const GitException(GitErrorCode.invalidRequest);
    }
  }

  List<String> _arguments({
    GitOid? boundary,
    GitOid? onto,
    required bool root,
    required bool preserve,
    required bool autosquash,
    required bool interactive,
  }) {
    if (root == (boundary != null))
      throw const GitException(GitErrorCode.invalidRequest);
    return [
      '-c',
      'rebase.instructionFormat=%s',
      '-c',
      'rebase.abbreviateCommands=false',
      'rebase',
      '--merge',
      '--no-autostash',
      '--no-update-refs',
      '--no-fork-point',
      '--empty=stop',
      preserve ? '--rebase-merges=no-rebase-cousins' : '--no-rebase-merges',
      autosquash ? '--autosquash' : '--no-autosquash',
      if (interactive) '--interactive',
      if (onto != null) ...['--onto', onto.value],
      if (root) '--root' else boundary!.value,
    ];
  }
}

(String, String, String, String)? _commitLine(String line) {
  final match = RegExp(
    r'^(pick|reword|edit|squash|fixup|drop)\s+(?:(-[cC])\s+)?([0-9a-f]+)(?:\s+(.*))?$',
  ).firstMatch(line);
  return match == null
      ? null
      : (match[1]!, match[3]!, match[4] ?? '', match[2] ?? '');
}

final class _Plan {
  _Plan(
    this.repo,
    this.head,
    this.index,
    this.request,
    this.todo,
    this.steps,
    this.expires,
  );
  final String repo, index, todo;
  final GitOid head;
  final GitInspection request;
  final List<Json> steps;
  final DateTime expires;
}
