import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'client.dart';
import 'context.dart';
import 'models.dart';
import 'parsers.dart';
import 'reference_workflows.dart';
import 'runner.dart';

final class NetworkWorkflows {
  NetworkWorkflows(this.ctx, this.references);
  final GitContext ctx;
  final ReferenceWorkflows references;
  final _reviews = <String, _PushPlan>{};
  final lastFetch = <String, DateTime>{};
  String _token() => List.generate(
    24,
    (_) => Random.secure().nextInt(256),
  ).map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  Future<Json> preparePush(
    RepositoryId repo,
    GitInspection request, {
    GitCancellation? cancellation,
    void Function(GitProgress)? onProgress,
    Map<String, String> operationEnvironment = const {},
  }) async {
    await ctx.requireAuthorization(repo);
    final remote = request.remote, destination = request.destination;
    if (remote == null ||
        destination == null ||
        !destination.startsWith('refs/heads/') &&
            !destination.startsWith('refs/tags/'))
      throw const GitException(GitErrorCode.invalidRequest);
    await references.refName(repo, destination);
    final head = await ctx.head(repo);
    final source = request.revision ?? head;
    if (source == null) throw const GitException(GitErrorCode.invalidRequest);
    final config = await references.remoteConfiguration(repo, remote);
    final destinations = <_PushDestination>[];
    final tags = <String, GitOid>{};
    if (request.tags.length > 100)
      throw const GitException(GitErrorCode.invalidRequest);
    for (final tag in request.tags) {
      if (!tag.startsWith('refs/tags/'))
        throw const GitException(GitErrorCode.invalidRequest);
      await references.refName(repo, tag);
      final oid = await references.resolve(repo, tag);
      if (oid == null) throw const GitException(GitErrorCode.staleReview);
      tags[tag] = oid;
    }
    for (final url in config['pushUrls'] as List<String>) {
      validateGitSource(url);
      final alias = remote;
      final environment = _remoteEnvironment(remote, url);
      final effective = await ctx.runRepository(repo, [
        'ls-remote',
        '--get-url',
        alias,
      ], environment: environment);
      if (oneLine(effective.text) != url)
        throw const GitException(
          GitErrorCode.invalidRequest,
          diagnostic:
              'Chained URL rewrites change this push destination during review. Review the remote URL configuration before pushing.',
        );
      onProgress?.call(
        GitProgress(
          GitOperationPhase.running,
          text: 'Reviewing ${sanitizeGitDiagnostic(url)}',
        ),
      );
      final tips = await _remoteTips(
        repo,
        alias,
        {...operationEnvironment, ...environment},
        [destination, ...tags.keys],
        cancellation: cancellation,
      );
      final tip = tips[destination],
          tagTips = {for (final tag in tags.keys) tag: tips[tag]};
      destinations.add(_PushDestination(url, alias, environment, tip, tagTips));
    }
    if (destinations.isEmpty)
      throw const GitException(GitErrorCode.invalidRequest);
    var needsFetch = false;
    for (final destination in destinations) {
      if (destination.tip != null &&
          !(await ctx.runRepository(repo, [
            'cat-file',
            '-e',
            '${destination.tip!.value}^{commit}',
          ], allowFailure: true)).success)
        needsFetch = true;
    }
    final outgoing = needsFetch
        ? <Json>[]
        : await _outgoing(
            repo,
            source,
            destinations,
            offset: request.offset,
            limit: request.limit,
            cancellation: cancellation,
          );
    final token = _token();
    _reviews.removeWhere((_, plan) => plan.expires.isBefore(DateTime.now()));
    if (_reviews.length >= 24) _reviews.remove(_reviews.keys.first);
    final branch = await ctx.runRepository(repo, [
      'symbolic-ref',
      '--quiet',
      '--short',
      'HEAD',
    ], allowFailure: true);
    _reviews[token] = _PushPlan(
      repo.key,
      remote,
      config['token'] as String,
      source,
      destination,
      destinations,
      branch.success ? oneLine(branch.text) : null,
      needsFetch,
      tags,
    );
    return {
      'token': token,
      'remote': remote,
      'source': source.value,
      'sourceBranch': branch.success ? oneLine(branch.text) : null,
      'destination': destination,
      'destinations': [
        for (final entry in destinations)
          {
            'url': sanitizeGitDiagnostic(entry.url),
            'expectedTip': entry.tip?.value,
            'tags': entry.tagTips.map(
              (key, value) => MapEntry(key, value?.value),
            ),
          },
      ],
      'outgoing': outgoing,
      'needsFetch': needsFetch,
      'observedAt': DateTime.now().toUtc().toIso8601String(),
      'tags': tags.map((key, value) => MapEntry(key, value.value)),
      'nextOffset': request.offset + request.limit,
      'hasMore': outgoing.any((e) => e['hasMore'] == true),
      'forceAllowed': !_protectedDestination(destination),
      if (_protectedDestination(destination))
        'forceDisabledReason':
            'Local branch policy protects this destination from force pushes.',
    };
  }

  bool _protectedDestination(String destination) => const {
    'refs/heads/main',
    'refs/heads/master',
    'refs/heads/release',
  }.contains(destination);
  Future<List<Json>> _outgoing(
    RepositoryId repo,
    GitOid source,
    List<_PushDestination> destinations, {
    required int offset,
    required int limit,
    GitCancellation? cancellation,
  }) async {
    if (offset < 0 || limit < 1 || limit > 300)
      throw const GitException(GitErrorCode.invalidRequest);
    final outgoing = <Json>[];
    for (final destination in destinations) {
      final result = await ctx.runRepository(repo, [
        'log',
        '--topo-order',
        '--no-show-signature',
        '--no-notes',
        '--format=$historyFormat',
        '--max-count=${limit + 1}',
        '--skip=$offset',
        source.value,
        if (destination.tip != null) '^${destination.tip!.value}',
        '--',
      ], cancellation: cancellation);
      final commits = parseHistory(result.stdout);
      outgoing.add({
        'destination': sanitizeGitDiagnostic(destination.url),
        'commits': commits.take(limit).map((e) => e.toJson()).toList(),
        'hasMore': commits.length > limit,
      });
    }
    return outgoing;
  }

  Future<Json> pushPage(
    RepositoryId repo,
    GitInspection request, {
    GitCancellation? cancellation,
  }) async {
    await ctx.requireAuthorization(repo);
    final plan = _reviews[request.reviewToken];
    if (plan == null ||
        plan.repository != repo.key ||
        plan.expires.isBefore(DateTime.now()) ||
        plan.needsFetch ||
        (await references.remoteConfiguration(repo, plan.remote))['token'] !=
            plan.configuration) {
      throw const GitException(GitErrorCode.staleReview);
    }
    final outgoing = await _outgoing(
      repo,
      plan.source,
      plan.destinations,
      offset: request.offset,
      limit: request.limit,
      cancellation: cancellation,
    );
    return {
      'token': request.reviewToken,
      'outgoing': outgoing,
      'nextOffset': request.offset + request.limit,
      'hasMore': outgoing.any((e) => e['hasMore'] == true),
    };
  }

  Map<String, String> _remoteEnvironment(String remote, String url) {
    // Git 2.56's empty URL entries reset multi-valued URL configuration. Keep
    // the real remote name and all its policy/helper options, while binding
    // each command to the exact reviewed destination. Hooks see the expected
    // remote name; no repository/global configuration is rewritten.
    final values = <MapEntry<String, String>>[
      MapEntry('remote.$remote.url', ''),
      MapEntry('remote.$remote.url', url),
      MapEntry('remote.$remote.pushurl', ''),
      MapEntry('remote.$remote.pushurl', url),
      MapEntry('remote.$remote.mirror', 'false'),
    ];
    return {
      'GIT_CONFIG_COUNT': '${values.length}',
      for (var i = 0; i < values.length; i++) ...{
        'GIT_CONFIG_KEY_$i': values[i].key,
        'GIT_CONFIG_VALUE_$i': values[i].value,
      },
    };
  }

  Future<Map<String, GitOid>> _remoteTips(
    RepositoryId repo,
    String alias,
    Map<String, String> environment,
    List<String> names, {
    GitCancellation? cancellation,
  }) async {
    final result = await ctx.runRepository(
      repo,
      ['ls-remote', '--refs', '--', alias, ...names],
      passive: false,
      environment: environment,
      cancellation: cancellation,
    );
    final rows = result.text
        .split('\n')
        .where((e) => e.isNotEmpty)
        .map((e) => e.split('\t'));
    return {
      for (final row in rows)
        if (row.length == 2 && names.contains(row[1])) row[1]: GitOid(row[0]),
    };
  }

  Future<GitRunResult> execute(
    RepositoryId repo,
    GitMutation request, {
    GitCancellation? cancellation,
    void Function(String)? progress,
    Map<String, String> operationEnvironment = const {},
  }) async {
    switch (request) {
      case DeleteRemoteReference():
        final plan = _reviews.remove(request.reviewToken);
        if (plan == null ||
            plan.repository != repo.key ||
            plan.expires.isBefore(DateTime.now()) ||
            plan.tags.isNotEmpty ||
            (await references.remoteConfiguration(
                  repo,
                  plan.remote,
                ))['token'] !=
                plan.configuration) {
          throw const GitException(GitErrorCode.staleReview);
        }
        GitRunResult? result;
        for (final destination in plan.destinations) {
          if (destination.tip == null)
            throw const GitException(
              GitErrorCode.staleReview,
              diagnostic: 'This reviewed remote reference does not exist.',
            );
          result = await ctx.runRepository(
            repo,
            [
              'push',
              '--porcelain',
              '--progress',
              '--no-follow-tags',
              '--force-with-lease=${plan.destination}:${destination.tip!.value}',
              '--',
              destination.alias,
              ':${plan.destination}',
            ],
            passive: false,
            cancellation: cancellation,
            progress: progress,
            environment: {...destination.environment, ...operationEnvironment},
            allowFailure: true,
          );
          if (!result.success) return _pushFailure(result);
        }
        return result!;
      case FetchPushDestination():
        final plan = _reviews.remove(request.reviewToken);
        if (plan == null ||
            plan.repository != repo.key ||
            plan.expires.isBefore(DateTime.now()))
          throw const GitException(GitErrorCode.staleReview);
        GitRunResult? last;
        for (final destination in plan.destinations) {
          if (destination.tip == null) continue;
          last = await ctx.runRepository(
            repo,
            [
              'fetch',
              '--no-tags',
              '--no-recurse-submodules',
              '--progress',
              '--',
              destination.alias,
              destination.tip!.value,
            ],
            passive: false,
            environment: {...destination.environment, ...operationEnvironment},
            cancellation: cancellation,
            progress: progress,
            allowFailure: true,
          );
          if (!last.success) return _pushFailure(last);
        }
        return last ??
            await ctx.runRepository(repo, ['rev-parse', '--verify', 'HEAD']);
      case FetchRemote():
        final config = await references.remoteConfiguration(
          repo,
          request.remote,
        );
        for (final url in config['fetchUrls'] as List<String>) {
          validateGitSource(url);
        }
        final result = await ctx.runRepository(
          repo,
          [
            'fetch',
            '--progress',
            '--no-recurse-submodules',
            if (request.prune) '--prune',
            '--',
            request.remote,
          ],
          passive: false,
          cancellation: cancellation,
          progress: progress,
          environment: operationEnvironment,
          allowFailure: true,
        );
        if (result.success)
          lastFetch['${repo.key}:${request.remote}'] = DateTime.now().toUtc();
        return result;
      case PullRemote():
        if (request.preserveMerges && request.strategy != PullStrategy.rebase ||
            request.noFastForward && request.strategy != PullStrategy.merge)
          throw const GitException(GitErrorCode.invalidRequest);
        await references.branchName(repo, request.branch);
        final config = await references.remoteConfiguration(
          repo,
          request.remote,
        );
        for (final url in config['fetchUrls'] as List<String>) {
          validateGitSource(url);
        }
        // Every reviewed intent is explicit, including disabling configured
        // autostash and submodule recursion. There is no fallback strategy.
        return ctx.runRepository(
          repo,
          [
            '-c',
            'rebase.autoStash=false',
            '-c',
            'merge.autoStash=false',
            '-c',
            'pull.autostash=false',
            '-c',
            'rebase.updateRefs=false',
            'pull',
            '--progress',
            '--no-recurse-submodules',
            '--no-squash',
            if (request.strategy == PullStrategy.fastForwardOnly) ...[
              '--no-rebase',
              '--ff-only',
            ],
            if (request.strategy == PullStrategy.merge) ...[
              '--no-rebase',
              request.noFastForward ? '--no-ff' : '--ff',
            ],
            if (request.strategy == PullStrategy.rebase) ...[
              request.preserveMerges ? '--rebase=merges' : '--rebase=true',
              '--ff',
            ],
            '--',
            request.remote,
            request.branch,
          ],
          passive: false,
          cancellation: cancellation,
          progress: progress,
          environment: operationEnvironment,
          allowFailure: true,
        );
      case PushReviewed():
        final plan = _reviews.remove(request.reviewToken);
        if (plan == null ||
            plan.repository != repo.key ||
            plan.expires.isBefore(DateTime.now()) ||
            plan.needsFetch ||
            request.tags
                .toSet()
                .difference(plan.tags.keys.toSet())
                .isNotEmpty ||
            plan.tags.keys
                .toSet()
                .difference(request.tags.toSet())
                .isNotEmpty ||
            await ctx.head(repo) != plan.source ||
            (await references.remoteConfiguration(
                  repo,
                  plan.remote,
                ))['token'] !=
                plan.configuration) {
          throw const GitException(GitErrorCode.staleReview);
        }
        for (final tag in plan.tags.entries) {
          if (await references.resolve(repo, tag.key) != tag.value)
            throw const GitException(GitErrorCode.staleReview);
        }
        if (request.forceWithLease && _protectedDestination(plan.destination)) {
          throw const GitException(
            GitErrorCode.rejected,
            diagnostic:
                'Local protected-branch policy prevents force pushing this branch.',
          );
        }
        GitRunResult? last;
        for (final destination in plan.destinations) {
          last = await ctx.runRepository(
            repo,
            [
              'push',
              '--porcelain',
              '--progress',
              '--no-follow-tags',
              '--recurse-submodules=no',
              if (request.forceWithLease)
                '--force-with-lease=${plan.destination}:${destination.tip?.value ?? ''}',
              if (request.forceWithLease) ...[
                for (final tag in destination.tagTips.entries)
                  '--force-with-lease=${tag.key}:${tag.value?.value ?? ''}',
              ],
              '--',
              destination.alias,
              '${plan.source.value}:${plan.destination}',
              ...plan.tags.entries.map((e) => '${e.value.value}:${e.key}'),
            ],
            passive: false,
            environment: {...destination.environment, ...operationEnvironment},
            cancellation: cancellation,
            progress: progress,
            allowFailure: true,
          );
          if (!last.success) return _pushFailure(last);
        }
        if (request.setUpstream && plan.branch != null) {
          await ctx.runRepository(repo, [
            'config',
            '--local',
            'branch.${plan.branch}.remote',
            plan.remote,
          ], passive: false);
          await ctx.runRepository(repo, [
            'config',
            '--local',
            'branch.${plan.branch}.merge',
            plan.destination,
          ], passive: false);
        }
        return last!;
      default:
        throw const GitException(GitErrorCode.invalidRequest);
    }
  }

  GitRunResult _pushFailure(GitRunResult result) => GitRunResult(
    result.exitCode,
    result.stdout,
    Uint8List.fromList(
      utf8.encode(
        '${utf8.decode(result.stderr, allowMalformed: true)}\n${utf8.decode(result.stdout, allowMalformed: true)}',
      ),
    ),
  );
}

final class _PushDestination {
  const _PushDestination(
    this.url,
    this.alias,
    this.environment,
    this.tip,
    this.tagTips,
  );
  final String url, alias;
  final Map<String, String> environment;
  final GitOid? tip;
  final Map<String, GitOid?> tagTips;
}

final class _PushPlan {
  _PushPlan(
    this.repository,
    this.remote,
    this.configuration,
    this.source,
    this.destination,
    this.destinations,
    this.branch,
    this.needsFetch,
    this.tags,
  );
  final String repository, remote, configuration, destination;
  final GitOid source;
  final List<_PushDestination> destinations;
  final String? branch;
  final bool needsFetch;
  final Map<String, GitOid> tags;
  final DateTime expires = DateTime.now().add(const Duration(minutes: 10));
}
