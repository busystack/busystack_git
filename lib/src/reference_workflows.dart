import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'client.dart';
import 'context.dart';
import 'byte_text.dart';
import 'models.dart';
import 'parsers.dart';
import 'runner.dart';
import 'native_helper.dart';

final class ReferenceWorkflows {
  const ReferenceWorkflows(this.ctx, {this.helperPath});
  final GitContext ctx;
  final String? helperPath;
  Future<void> branchName(RepositoryId repo, String name) async {
    if (name.isEmpty || name.startsWith('-') || name.contains('\u0000'))
      throw const GitException(GitErrorCode.invalidRequest);
    await ctx.runRepository(repo, ['check-ref-format', '--branch', name]);
  }

  Future<void> refName(RepositoryId repo, String name) async {
    if (!name.startsWith('refs/'))
      throw const GitException(GitErrorCode.invalidRequest);
    await ctx.runRepository(repo, ['check-ref-format', name]);
  }

  Future<GitOid?> resolve(RepositoryId repo, String name) async {
    if (name.startsWith('-') || name.contains('\u0000') || name.contains('\n'))
      throw const GitException(GitErrorCode.invalidRequest);
    final result = await ctx.runRepository(repo, [
      'rev-parse',
      '--verify',
      '--quiet',
      '--end-of-options',
      name,
    ], allowFailure: true);
    return result.success ? GitOid(oneLine(result.text)) : null;
  }

  Future<List<Json>> remotes(RepositoryId repo) async {
    final names = oneLine(
      (await ctx.runRepository(repo, ['remote'])).text,
    ).split('\n').where((e) => e.isNotEmpty);
    final result = <Json>[];
    for (final name in names) {
      final raw = await remoteConfiguration(repo, name);
      result.add({
        'name': name,
        'fetchUrls': (raw['fetchUrls'] as List<String>)
            .map(sanitizeGitDiagnostic)
            .toList(),
        'pushUrls': (raw['pushUrls'] as List<String>)
            .map(sanitizeGitDiagnostic)
            .toList(),
        'token': raw['token'],
      });
    }
    return result;
  }

  Future<Json> remoteConfiguration(RepositoryId repo, String name) async {
    _remoteName(name);
    final fetch = (await ctx.runRepository(repo, [
      'remote',
      'get-url',
      '--all',
      '--',
      name,
    ])).text;
    final push = (await ctx.runRepository(repo, [
      'remote',
      'get-url',
      '--push',
      '--all',
      '--',
      name,
    ])).text;
    final config = await ctx.runRepository(repo, [
      'config',
      '--null',
      '--get-regexp',
      '^remote\.${RegExp.escape(name)}\.',
    ], allowFailure: true);
    return {
      'name': name,
      'fetchUrls': oneLine(fetch).split('\n'),
      'pushUrls': oneLine(push).split('\n'),
      'token': fingerprint(config.stdout),
      'rawConfig': config.stdout,
    };
  }

  void _remoteName(String name) {
    if (name.isEmpty || name.contains(RegExp(r'[\x00-\x20\x7f]'))) {
      throw const GitException(GitErrorCode.invalidRequest);
    }
  }

  Future<GitRunResult> execute(
    RepositoryId repo,
    GitMutation request, {
    GitCancellation? cancellation,
    void Function(String)? progress,
    Map<String, String> operationEnvironment = const {},
  }) async {
    final List<String> args;
    var safetyArguments = <String>[];
    List<int>? input;
    switch (request) {
      case BranchMutation():
        if (request.action == BranchAction.create) {
          await branchName(repo, request.name);
        } else {
          await refName(repo, 'refs/heads/${request.name}');
        }
        if (request.expectedTip != null &&
            await resolve(repo, 'refs/heads/${request.name}') !=
                request.expectedTip) {
          throw const GitException(GitErrorCode.staleReview);
        }
        switch (request.action) {
          case BranchAction.create:
            if (request.start == null)
              throw const GitException(GitErrorCode.invalidRequest);
            if (request.upstream != null)
              await refName(repo, request.upstream!);
            args = request.switchAfterCreate
                ? [
                    'switch',
                    '--no-guess',
                    '--create',
                    request.name,
                    if (request.upstream != null)
                      '--track=direct'
                    else
                      '--no-track',
                    request.upstream ?? request.start!.value,
                  ]
                : [
                    'branch',
                    if (request.upstream != null)
                      '--track=direct'
                    else
                      '--no-track',
                    '--',
                    request.name,
                    request.upstream ?? request.start!.value,
                  ];
          case BranchAction.switchBranch:
            args = ['switch', '--no-guess', '--', request.name];
          case BranchAction.rename:
            if (request.newName == null)
              throw const GitException(GitErrorCode.invalidRequest);
            await branchName(repo, request.newName!);
            args = ['branch', '--move', '--', request.name, request.newName!];
          case BranchAction.delete:
            // Safe delete has no automatic force fallback. An explicit second
            // review may choose forceDeleteReviewed for an unmerged branch.
            final tip = request.expectedTip;
            if (tip == null)
              throw const GitException(GitErrorCode.invalidRequest);
            final enabled = await ctx.runRepository(
              repo,
              [
                'config',
                '--type=bool',
                '--get',
                'hook.reference-transaction.enabled',
              ],
              passive: false,
              allowFailure: true,
            );
            if (enabled.success && oneLine(enabled.text) == 'false') {
              throw const GitException(
                GitErrorCode.invalidRequest,
                diagnostic:
                    'Branch deletion needs its reference-transaction safety guard. Enable hook.reference-transaction.enabled, then review again.',
              );
            }
            if (!enabled.success && enabled.exitCode != 1)
              throw enabled.failure;
            final helper = installedGitHelper(preferred: helperPath);
            if (helper == null)
              throw const GitException(
                GitErrorCode.unavailable,
                diagnostic: 'Repair the installed native Git safety helper.',
              );
            String quote(String s) => "'${s.replaceAll("'", "'\\''")}'";
            final hook =
                'busystack-review-${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
            safetyArguments = [
              '-c',
              'hook.reference-transaction.enabled=true',
              '-c',
              'hook.$hook.event=reference-transaction',
              '-c',
              'hook.$hook.enabled=true',
              '-c',
              'hook.$hook.command=${quote(helper)} --reference-guard ${quote('refs/heads/${request.name}')} ${quote(tip.value)}',
            ];
            args = [
              'branch',
              request.forceDeleteReviewed ? '-D' : '--delete',
              '--',
              request.name,
            ];
          case BranchAction.setUpstream:
            if (request.upstream == null)
              args = ['branch', '--unset-upstream', '--', request.name];
            else {
              await refName(repo, request.upstream!);
              args = [
                'branch',
                '--set-upstream-to=${request.upstream}',
                '--',
                request.name,
              ];
            }
        }
      case TagMutation():
        await refName(repo, 'refs/tags/${request.name}');
        if (request.action == TagAction.delete) {
          if (request.expectedTip == null)
            throw const GitException(GitErrorCode.invalidRequest);
          args = [
            'update-ref',
            '-d',
            'refs/tags/${request.name}',
            request.expectedTip!.value,
          ];
        } else {
          args = [
            'tag',
            if (request.sign == true)
              '--sign'
            else if (request.annotated)
              '--annotate',
            if (request.sign == false) '--no-sign',
            if (request.annotated || request.sign == true) '--file=-',
            '--',
            request.name,
            request.target.value,
          ];
          if (request.annotated || request.sign == true)
            input = utf8.encode(request.message);
        }
      case RemoteMutation():
        _remoteName(request.name);
        if (request.expectedConfiguration != null &&
            (await remoteConfiguration(repo, request.name))['token'] !=
                request.expectedConfiguration) {
          throw const GitException(GitErrorCode.staleReview);
        }
        final value = request.value;
        if (value != null && request.action != RemoteAction.rename)
          validateGitSource(value);
        if (value != null && request.action == RemoteAction.rename)
          _remoteName(value);
        args = switch (request.action) {
          RemoteAction.add => ['remote', 'add', '--', request.name, value!],
          RemoteAction.rename => [
            'remote',
            'rename',
            '--',
            request.name,
            value!,
          ],
          RemoteAction.remove => ['remote', 'remove', '--', request.name],
          RemoteAction.setFetchUrl => [
            'remote',
            'set-url',
            '--',
            request.name,
            value!,
          ],
          RemoteAction.addPushUrl => [
            'remote',
            'set-url',
            '--push',
            '--add',
            '--',
            request.name,
            value!,
          ],
          RemoteAction.removePushUrl => [
            'remote',
            'set-url',
            '--push',
            '--delete',
            '--',
            request.name,
            RegExp.escape(value!),
          ],
        };
      case ConfigureIdentity():
        if (request.name.trim().isEmpty ||
            request.email.trim().isEmpty ||
            '${request.name}${request.email}'.contains(RegExp(r'[\r\n\x00<>]')))
          throw const GitException(GitErrorCode.invalidRequest);
        await ctx.runRepository(repo, [
          'config',
          '--local',
          'user.name',
          request.name,
        ], passive: false);
        args = ['config', '--local', 'user.email', request.email];
      default:
        throw const GitException(GitErrorCode.invalidRequest);
    }
    return ctx.runRepository(
      repo,
      [...safetyArguments, ...args],
      passive: false,
      input: input,
      cancellation: cancellation,
      progress: progress,
      environment: operationEnvironment,
      allowFailure: true,
    );
  }

  Future<Json> commitOptions(RepositoryId repo) async {
    Future<String?> config(String key) async {
      final result = await ctx.runRepository(repo, [
        'config',
        '--get',
        key,
      ], allowFailure: true);
      return result.success ? oneLine(result.text) : null;
    }

    // `hook list` is a read-only Git interface: it resolves the effective
    // enabled configuration and hooksPath without executing a hook. In
    // particular, do not pass the passive command overrides that intentionally
    // suppress hooks for status/diff commands to this inventory query.
    const commitEvents = [
      'pre-commit',
      'prepare-commit-msg',
      'commit-msg',
      'post-commit',
      'post-rewrite',
      'reference-transaction',
      'post-index-change',
    ];
    final hooks = <String>[], activeEvents = <String>[];
    for (final event in commitEvents) {
      final listed = await ctx.runRepository(
        repo,
        ['hook', 'list', '-z', '--show-scope', event],
        passive: false,
        allowFailure: true,
        deadline: const Duration(seconds: 10),
      );
      if (listed.exitCode != 0 && listed.exitCode != 1) throw listed.failure;
      if (listed.stdout.isNotEmpty) {
        var active = false;
        for (final record in nulRecords(listed.stdout)) {
          final value = decodeGitUtf8(record, allowMalformed: true);
          hooks.add('$event: ${sanitizeGitDiagnostic(value)}');
          if (!RegExp(
            r'^(?:system|global|local|worktree|command)\t(?:disabled|event-disabled)\t',
          ).hasMatch(value))
            active = true;
        }
        if (active) activeEvents.add(event);
      }
    }
    String? template;
    final templatePath = await config('commit.template');
    if (templatePath != null && ctx.authorized(repo)) {
      final path = templatePath.startsWith('~/')
          ? '${Platform.environment['HOME']}/${templatePath.substring(2)}'
          : templatePath;
      final file = File(path.startsWith('/') ? path : '${repo.root}/$path');
      if (await file.exists() && await file.length() <= 128 * 1024)
        template = await file.readAsString();
    }
    return {
      'name': await config('user.name'),
      'email': await config('user.email'),
      'gitVersion': await ctx.runtimeVersion(repo),
      'signing': await config('commit.gpgsign'),
      'signingFormat': await config('gpg.format') ?? 'openpgp',
      'template': template,
      'hooks': hooks,
      'activeCommitHookEvents': activeEvents,
      'hasConfiguredHooks': activeEvents.isNotEmpty,
      'pullRebase': await config('pull.rebase'),
      'pullFf': await config('pull.ff'),
    };
  }
}

void validateGitSource(String source) {
  if (source.isEmpty ||
      source.startsWith('-') ||
      source.contains(RegExp(r'[\x00\r\n]')) ||
      source.contains('::'))
    throw const GitException(GitErrorCode.invalidRequest);
  final uri = Uri.tryParse(source);
  if (uri != null && source.contains('://')) {
    if (!const {'https', 'http', 'ssh', 'file', 'git'}.contains(uri.scheme) ||
        uri.userInfo.contains(':') ||
        const {'http', 'https'}.contains(uri.scheme) &&
            uri.userInfo.isNotEmpty ||
        uri.queryParameters.keys.any(
          (k) => const {
            'token',
            'access_token',
            'password',
            'key',
          }.contains(k.toLowerCase()),
        )) {
      throw const GitException(
        GitErrorCode.invalidRequest,
        diagnostic:
            'Use an HTTP(S) URL without user information or secret query values. Git credential helpers and private prompts provide authentication. SSH usernames remain supported.',
      );
    }
  }
}
