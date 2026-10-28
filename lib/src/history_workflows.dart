import 'dart:convert';
import 'dart:typed_data';
import 'client.dart';
import 'content_queries.dart';
import 'context.dart';
import 'byte_text.dart';
import 'models.dart';
import 'parsers.dart';
import 'runner.dart';

final class HistoryWorkflows {
  const HistoryWorkflows(this.ctx, this.content);
  final GitContext ctx;
  final ContentQueries content;
  Future<Json> inspect(
    RepositoryId repo,
    GitInspection request, {
    GitCancellation? cancellation,
  }) async {
    if (request.offset < 0 ||
        request.offset > 100000 ||
        request.limit < 1 ||
        request.limit > 300)
      throw const GitException(GitErrorCode.invalidRequest);
    switch (request.kind) {
      case GitInspectionKind.tree:
        final entries = await content.tree(repo, request.revision!);
        return {
          'entries': entries
              .skip(request.offset)
              .take(request.limit)
              .map((e) => e.toJson())
              .toList(),
          'hasMore': entries.length > request.offset + request.limit,
        };
      case GitInspectionKind.compareRevisions:
        final files = await content.changedFiles(
          repo,
          request.revision!,
          parent: request.otherRevision!,
        );
        return {
          'changes': files
              .skip(request.offset)
              .take(request.limit)
              .map((e) => e.toJson())
              .toList(),
          'left': request.otherRevision!.value,
          'right': request.revision!.value,
          'hasMore': files.length > request.offset + request.limit,
        };
      case GitInspectionKind.blame:
        final path = request.path, revision = request.revision;
        if (path == null || revision == null)
          throw const GitException(GitErrorCode.invalidRequest);
        final result = await ctx.runRepository(
          repo,
          [
            'blame',
            '--line-porcelain',
            '--no-textconv',
            '--root',
            '-L',
            '${request.offset + 1},+${request.limit}',
            revision.value,
            '--',
            path.utf8Path ?? '',
          ],
          cancellation: cancellation,
          byteArguments: {if (path.utf8Path == null) 8: path.bytes},
        );
        return {
          'lines': parseBlameMetadata(result.stdout),
          'revision': revision.value,
          'path': request.path!.toJson(),
          'nextOffset': request.offset + request.limit,
        };
      case GitInspectionKind.fileHistory:
        final path = request.path;
        if (path == null)
          throw const GitException(GitErrorCode.unsupportedContent);
        // Bind the log and every subsequent comparison to one immutable tip.
        final tipResult = await ctx.runRepository(
          repo,
          [
            'rev-parse',
            '--verify',
            '--end-of-options',
            '${request.revision?.value ?? 'HEAD'}^{commit}',
          ],
          cancellation: cancellation,
          allowFailure: true,
        );
        if (!tipResult.success) {
          if (request.revision == null) {
            final symbolic = await ctx.runRepository(
              repo,
              ['symbolic-ref', '--quiet', 'HEAD'],
              cancellation: cancellation,
              allowFailure: true,
            );
            if (symbolic.success) {
              final exists = await ctx.runRepository(
                repo,
                ['show-ref', '--verify', '--quiet', oneLine(symbolic.text)],
                cancellation: cancellation,
                allowFailure: true,
              );
              if (exists.exitCode == 1) {
                return {
                  'entries': <Json>[],
                  'revision': null,
                  'hasMore': false,
                  'nextOffset': request.offset,
                };
              }
              if (!exists.success) throw exists.failure;
            } else if (symbolic.exitCode != 1) {
              throw symbolic.failure;
            }
          }
          throw tipResult.failure;
        }
        final tip = GitOid(oneLine(tipResult.text));
        final result = await ctx.runRepository(
          repo,
          [
            'log',
            '--follow',
            '--no-show-signature',
            '--no-notes',
            '--no-ext-diff',
            '--no-textconv',
            '--name-status',
            // A first-parent merge diff changes --follow's rename traversal:
            // a rename inherited from another parent can become a deletion in
            // that parent's earlier commit. Combined output retains the merge
            // boundary without changing the ordinary rename-following walk.
            '--diff-merges=combined',
            '-z',
            '--find-renames',
            '--max-count=${request.offset + request.limit + 1}',
            '--format=%x00BUSYSTACK_COMMIT%x00$historyFormat',
            tip.value,
            '--',
            path.utf8Path ?? '',
          ],
          cancellation: cancellation,
          byteArguments: {if (path.utf8Path == null) 14: path.bytes},
        );
        final entries = parseFollowHistory(result.stdout, path);
        final page = entries.skip(request.offset).take(request.limit).toList();
        final commits = await content.withActualParents(repo, [
          for (final row in page) GitCommit.fromJson(row['commit'] as Json),
        ], cancellation: cancellation);
        for (var i = 0; i < page.length; i++)
          page[i]['commit'] = commits[i].toJson();
        await _resolveMergePaths(
          repo,
          tip,
          path,
          entries,
          page,
          request.offset,
          cancellation,
        );
        return {
          'entries': page,
          'revision': tip.value,
          'hasMore': entries.length > request.offset + request.limit,
          'nextOffset': request.offset + request.limit,
        };
      default:
        throw const GitException(GitErrorCode.invalidRequest);
    }
  }

  Future<void> _resolveMergePaths(
    RepositoryId repo,
    GitOid tip,
    RepoPath requestedPath,
    List<Json> entries,
    List<Json> page,
    int offset,
    GitCancellation? cancellation,
  ) async {
    // Git --follow can change its internal path at a merge without emitting a
    // combined change body. A preceding row's name is not that merge's name.
    // Resolve only returned sparse rows using immutable Git-provided endpoints;
    // never replay parent queries for the skipped history prefix.
    final metadata = <(GitOid, String), IndexEntry?>{};
    final comparisons = <(GitOid, GitOid), List<GitChange>>{};
    final ancestors = <(GitOid, GitOid), bool>{};
    Future<bool> ancestor(GitOid a, GitOid b) async {
      if (a == b) return true;
      final key = (a, b);
      if (ancestors.containsKey(key)) return ancestors[key]!;
      final result = await ctx.runRepository(
        repo,
        ['merge-base', '--is-ancestor', a.value, b.value],
        allowFailure: true,
        cancellation: cancellation,
      );
      if (result.success) return ancestors[key] = true;
      if (result.exitCode != 1) throw result.failure;
      return ancestors[key] = false;
    }

    Future<bool> related(GitOid source, GitOid target) async =>
        // Every streamed commit is reachable from this immutable query tip.
        source == tip ||
        await ancestor(source, target) ||
        await ancestor(target, source);
    Future<IndexEntry?> entry(GitOid revision, RepoPath path) async {
      cancellation?.check();
      final key = (revision, path.key);
      if (metadata.containsKey(key)) return metadata[key];
      final result = await ctx.runRepository(
        repo,
        [
          'ls-tree',
          '-z',
          '--full-tree',
          revision.value,
          '--',
          path.utf8Path ?? '',
        ],
        cancellation: cancellation,
        byteArguments: {if (path.utf8Path == null) 5: path.bytes},
      );
      return metadata[key] = parseTree(
        result.stdout,
      ).where((value) => value.path == path).firstOrNull;
    }

    Future<List<GitChange>> compare(GitOid revision, GitOid parent) async {
      cancellation?.check();
      final key = (revision, parent);
      return comparisons[key] ??= await content.changedFiles(
        repo,
        revision,
        parent: parent,
        cancellation: cancellation,
      );
    }

    _HistoryPathAnchor? anchor(Json row) {
      final commit = GitCommit.fromJson(row['commit'] as Json);
      if (row['deleted'] == true) {
        // An ordinary deletion still gives an exact present-side endpoint.
        return commit.parents.length == 1
            ? _HistoryPathAnchor(
                commit.parents.single,
                RepoPath.fromJson(row['pathInParent']),
              )
            : null;
      }
      return _HistoryPathAnchor(
        commit.oid,
        RepoPath.fromJson(row['pathAtCommit']),
      );
    }

    final explicit = <int>[
      for (var i = 0; i < entries.length; i++)
        if ((entries[i]['status'] as String).isNotEmpty) i,
    ];
    for (var pageIndex = 0; pageIndex < page.length; pageIndex++) {
      final row = page[pageIndex], status = row['status'] as String;
      if (status.isNotEmpty && !_combinedStatus(status)) continue;
      cancellation?.check();
      final commit = GitCommit.fromJson(row['commit'] as Json);
      if (status.isNotEmpty) {
        // A combined record supplies one literal result path, even for RR.
        // Its columns never supply any chosen parent's rename source.
        row['deleted'] =
            await entry(commit.oid, RepoPath.fromJson(row['pathAtCommit'])) ==
            null;
        continue;
      }
      final index = offset + pageIndex;
      var low = 0, high = explicit.length;
      while (low < high) {
        final middle = (low + high) ~/ 2;
        if (explicit[middle] < index)
          low = middle + 1;
        else
          high = middle;
      }
      final anchors = <_HistoryPathAnchor>[
        _HistoryPathAnchor(tip, requestedPath),
        if (low > 0)
          if (anchor(entries[explicit[low - 1]]) case final value?) value,
        if (low < explicit.length)
          if (anchor(entries[explicit[low]]) case final value?) value,
      ];
      final candidates = <String, RepoPath>{};
      final seen = <(GitOid, String)>{};
      for (final source in anchors) {
        if (!seen.add((source.revision, source.path.key)) ||
            !await related(source.revision, commit.oid) ||
            await entry(source.revision, source.path) == null)
          continue;
        RepoPath? target;
        if (source.revision == commit.oid) {
          target = source.path;
        } else {
          final changes = await compare(commit.oid, source.revision);
          final renames = changes
              .where(
                (change) =>
                    change.index == 'R' && change.originalPath == source.path,
              )
              .toList();
          if (renames.length == 1) {
            target = renames.single.path;
          } else if (renames.isEmpty &&
              !changes.any(
                (change) => change.path == source.path && change.index == 'D',
              )) {
            target = source.path;
          }
        }
        if (target != null && await entry(commit.oid, target) != null)
          candidates[target.key] = target;
      }
      if (candidates.isEmpty &&
          await entry(tip, requestedPath) == null &&
          await entry(commit.oid, requestedPath) == null) {
        // A present query-tip file can never authorize a guessed absence.
        // For a deleted query path, an explicit ordinary Git deletion on this
        // merge's ancestry proves the literal name; metadata proves absence.
        for (final explicitIndex in [
          if (low > 0) explicit[low - 1],
          if (low < explicit.length) explicit[low],
        ]) {
          final deletion = entries[explicitIndex];
          if (deletion['status'] == 'D' &&
              RepoPath.fromJson(deletion['pathAtCommit']) == requestedPath &&
              await ancestor(
                GitCommit.fromJson(deletion['commit'] as Json).oid,
                commit.oid,
              )) {
            row['pathAtCommit'] = requestedPath.toJson();
            row['pathInParent'] = requestedPath.toJson();
            row['deleted'] = true;
            break;
          }
        }
        if (row['deleted'] == true) continue;
      }
      if (candidates.length != 1) {
        // Failed rename inference is unavailable lineage, not proof that a
        // guessed path was deleted. Expose a reviewable failure rather than an
        // unrelated empty file. No graph/merge algorithm is recreated here.
        throw const GitException(
          GitErrorCode.missingContent,
          diagnostic:
              'The historical path for this merge is unavailable or ambiguous in Git rename history.',
        );
      }
      final resolved = candidates.values.single;
      row['pathAtCommit'] = resolved.toJson();
      row['pathInParent'] = resolved.toJson();
      row['deleted'] = false;
    }
  }
}

final class _HistoryPathAnchor {
  const _HistoryPathAnchor(this.revision, this.path);
  final GitOid revision;
  final RepoPath path;
}

bool _combinedStatus(String status) =>
    RegExp(r'^[ACDMRTUXB]{2,}$').hasMatch(status);

List<Json> parseFollowHistory(List<int> bytes, RepoPath followedPath) {
  final records = nulRecords(bytes), result = <Json>[];
  var i = 0;
  while (i < records.length) {
    if (records[i].isEmpty ||
        ascii.decode(records[i], allowInvalid: true).trim().isEmpty) {
      i++;
      continue;
    }
    if (ascii.decode(records[i++]) != 'BUSYSTACK_COMMIT' ||
        i + 10 > records.length)
      throw const FormatException('Invalid file-history header.');
    final header = BytesBuilder();
    for (var field = 0; field < 10; field++) {
      header.add(records[i++]);
      header.addByte(0);
    }
    final commit = parseHistory(header.takeBytes()).single;
    var hasChanges = false;
    while (i < records.length) {
      if (records[i].isEmpty) {
        i++;
        continue;
      }
      final value = ascii
          .decode(records[i], allowInvalid: true)
          .replaceFirst(RegExp(r'^\n+'), '');
      if (value == 'BUSYSTACK_COMMIT') break;
      final combined = _combinedStatus(value);
      if (!RegExp(r'^[ACDMRTUXB][0-9]*$').hasMatch(value) && !combined)
        throw const FormatException('Invalid file-history change record.');
      i++;
      if (i >= records.length)
        throw const FormatException('Missing historical path.');
      final first = RepoPath(records[i++]);
      final second =
          !combined && (value.startsWith('R') || value.startsWith('C'))
          ? (i < records.length
                ? RepoPath(records[i++])
                : throw const FormatException('Missing rename destination.'))
          : first;
      result.add({
        'commit': commit.toJson(),
        'pathAtCommit': second.toJson(),
        'pathInParent': first.toJson(),
        'status': value,
        'deleted': value.startsWith('D'),
      });
      hasChanges = true;
      // Combined status columns describe several parents and have one result
      // path. They never provide one parent's rename source. Ordinary R/C
      // records alone carry the two paths used by Git's backwards follow walk.
      followedPath = first;
    }
    if (!hasChanges && commit.parents.length > 1)
      result.add({
        'commit': commit.toJson(),
        'pathAtCommit': followedPath.toJson(),
        'pathInParent': followedPath.toJson(),
        'status': '',
        // Resolved against this commit's literal tree before publication.
        'deleted': false,
      });
  }
  return result;
}

List<Json> parseBlameMetadata(List<int> bytes) {
  final lines = _byteLines(bytes), result = <Json>[];
  Json? current;
  for (final line in lines) {
    if (line.isEmpty) continue;
    if (line.first == 9) {
      if (current != null) result.add(current);
      current = null;
      continue;
    }
    final text = decodeGitUtf8(line, allowMalformed: true);
    final header = RegExp(
      r'^([0-9a-f]{40}|[0-9a-f]{64}) (\d+) (\d+)(?: \d+)?$',
    ).firstMatch(text);
    if (header != null) {
      current = {
        'revision': header[1],
        'originalLine': int.parse(header[2]!),
        'line': int.parse(header[3]!),
        'boundary': false,
      };
      continue;
    }
    if (current == null) continue;
    if (text == 'boundary') {
      current['boundary'] = true;
      continue;
    }
    final space = line.indexOf(32);
    if (space < 0) continue;
    final key = ascii.decode(line.sublist(0, space));
    if (key == 'filename') {
      current['path'] = RepoPath(
        decodeGitQuotedPath(line.sublist(space + 1)),
      ).toJson();
    } else if (const {
      'author',
      'author-mail',
      'author-time',
      'summary',
      'previous',
    }.contains(key))
      current[key] = text.substring(space + 1);
  }
  return result;
}

List<Uint8List> _byteLines(List<int> bytes) {
  final result = <Uint8List>[];
  var start = 0;
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] == 10) {
      result.add(Uint8List.fromList(bytes.sublist(start, i)));
      start = i + 1;
    }
  }
  if (start < bytes.length)
    result.add(Uint8List.fromList(bytes.sublist(start)));
  return result;
}

Uint8List decodeGitQuotedPath(List<int> value) {
  if (value.isEmpty || value.first != 34) return Uint8List.fromList(value);
  if (value.last != 34) throw const FormatException('Invalid quoted Git path.');
  final out = BytesBuilder();
  for (var i = 1; i < value.length - 1; i++) {
    var byte = value[i];
    if (byte == 92) {
      if (++i >= value.length - 1)
        throw const FormatException('Truncated quoted path.');
      byte = value[i];
      if (byte >= 48 && byte <= 55) {
        var octal = byte - 48;
        for (
          var count = 0;
          count < 2 &&
              i + 1 < value.length - 1 &&
              value[i + 1] >= 48 &&
              value[i + 1] <= 55;
          count++
        ) {
          octal = octal * 8 + value[++i] - 48;
        }
        byte = octal;
      } else {
        byte =
            const {
              97: 7,
              98: 8,
              116: 9,
              110: 10,
              118: 11,
              102: 12,
              114: 13,
              34: 34,
              92: 92,
            }[byte] ??
            (throw const FormatException('Invalid path escape.'));
      }
    }
    out.addByte(byte);
  }
  return out.takeBytes();
}
