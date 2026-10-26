import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'models.dart';
import 'parsers.dart';
import 'context.dart';
import 'runner.dart';
import 'linux_paths.dart';

final class ContentQueries {
  ContentQueries(this.ctx, {this.maximumContentBytes = 4 * 1024 * 1024});
  final GitContext ctx;
  final int maximumContentBytes;
  final _trees = <String, List<IndexEntry>>{};
  int _treeEntries = 0;
  Future<List<IndexEntry>> tree(RepositoryId repo, GitOid revision) async {
    final key = '${repo.key}:${revision.value}';
    final cached = _trees[key];
    if (cached != null) return cached;
    final result = await ctx.runRepository(repo, [
      'ls-tree',
      '-r',
      '-z',
      '--full-tree',
      revision.value,
    ]);
    final entries = await Isolate.run(() => parseTree(result.stdout));
    if (entries.length <= 50000) {
      while (_trees.isNotEmpty &&
          (_treeEntries + entries.length > 75000 || _trees.length >= 12)) {
        _treeEntries -= _trees.remove(_trees.keys.first)!.length;
      }
      _trees[key] = entries;
      _treeEntries += entries.length;
    }
    return entries;
  }

  Future<List<IndexEntry>> index(
    RepositoryId repo, {
    RepoPath? path,
    GitCancellation? cancellation,
  }) async {
    final args = [
      'ls-files',
      '--stage',
      '-z',
      if (path != null) ...['--', path.utf8Path ?? ''],
    ];
    final result = await ctx.runRepository(
      repo,
      args,
      cancellation: cancellation,
      byteArguments: {
        if (path != null && path.utf8Path == null) args.length - 1: path.bytes,
      },
    );
    // Whole-index callers can return many entries. Parsing must not block an
    // in-process host's UI isolate; file review requests only its literal path.
    final entries = await Isolate.run(() => parseIndex(result.stdout));
    cancellation?.check();
    return entries;
  }

  Future<GitContent> content(
    RepositoryId repo,
    RepoPath path,
    ContentVersion version, {
    GitCancellation? cancellation,
  }) async {
    await ctx.validateIdentity(repo);
    cancellation?.check();
    if (version.kind == ContentKind.commit && version.revision == null ||
        version.kind == ContentKind.conflictStage &&
            !{1, 2, 3}.contains(version.stage)) {
      throw const GitException(GitErrorCode.invalidRequest);
    }
    if (version.kind == ContentKind.mergePreview)
      return _mergePreview(repo, path, version, cancellation);
    if (version.kind == ContentKind.normalizedWorking)
      return _normalizedWorking(repo, path, version, cancellation);
    GitContent absent() => GitContent(
      path: path,
      version: version,
      availability: ContentAvailability.absent,
      token: fingerprint(utf8.encode('${repo.key}:${path.key}:absent')),
    );
    if (version.kind == ContentKind.absent) return absent();
    List<int> bytes;
    String mode;
    GitOid? oid;
    if (version.kind == ContentKind.workingTree) {
      final raw = await ctx.workingPath(repo, path);
      final stat = LinuxPaths.stat(raw);
      if (!stat.exists) return absent();
      if (stat.mode & 0xf000 == 0x4000) {
        GitOid? head;
        final fd = LinuxPaths.secureOpen(raw, directory: true);
        try {
          // A private, pinned descriptor permits a byte-named checkout without
          // decoding its path or letting replacement of that path retarget us.
          final cwd = '/proc/$pid/fd/$fd';
          final prefix = await ctx.run(
            cwd,
            ['rev-parse', '--show-prefix'],
            allowFailure: true,
            cancellation: cancellation,
          );
          if (prefix.success && oneLine(prefix.text).isEmpty) {
            final revision = await ctx.run(
              cwd,
              ['rev-parse', '--verify', '--quiet', 'HEAD^{commit}'],
              allowFailure: true,
              cancellation: cancellation,
            );
            if (revision.success) head = GitOid(oneLine(revision.text));
          }
          if (LinuxPaths.descriptorStat(fd).identity !=
              LinuxPaths.stat(raw).identity) {
            throw const GitException(GitErrorCode.staleReview);
          }
        } finally {
          LinuxPaths.close(fd);
        }
        return GitContent(
          path: path,
          version: version,
          availability: ContentAvailability.gitlink,
          token: fingerprint(
            utf8.encode('${stat.identity}:${head?.value ?? 'uninitialized'}'),
          ),
          mode: '160000',
          oid: head,
        );
      }
      if (stat.mode & 0xf000 == 0xa000) {
        bytes = LinuxPaths.linkTarget(raw);
        mode = '120000';
      } else {
        final fd = LinuxPaths.secureOpen(raw, readOnly: true);
        try {
          final before = LinuxPaths.descriptorStat(fd);
          if (before.mode & 0xf000 != 0x8000)
            throw const GitException(GitErrorCode.unsupportedContent);
          mode = before.mode & 0x49 != 0 ? '100755' : '100644';
          final stream = File('/proc/self/fd/$fd').openRead().map((chunk) {
            cancellation?.check();
            return chunk;
          });
          if (before.size > maximumContentBytes) {
            final digest = await sha256.bind(stream).first;
            if (before.stamp != LinuxPaths.descriptorStat(fd).stamp ||
                before.identity != LinuxPaths.stat(raw).identity)
              throw const GitException(GitErrorCode.staleReview);
            return GitContent(
              path: path,
              version: version,
              availability: ContentAvailability.tooLarge,
              size: before.size,
              mode: mode,
              token: fingerprint(
                utf8.encode('${repo.key}:${path.key}:$mode:$digest'),
              ),
            );
          }
          final builder = BytesBuilder();
          await for (final chunk in stream) {
            if (builder.length + chunk.length > maximumContentBytes)
              throw const GitException(GitErrorCode.staleReview);
            builder.add(chunk);
          }
          if (before.stamp != LinuxPaths.descriptorStat(fd).stamp ||
              before.identity != LinuxPaths.stat(raw).identity)
            throw const GitException(GitErrorCode.staleReview);
          bytes = builder.takeBytes();
        } finally {
          LinuxPaths.close(fd);
        }
      }
    } else {
      final entries = version.kind == ContentKind.commit
          ? path.utf8Path == null
                ? await tree(repo, version.revision!)
                : parseTree(
                    (await ctx.runRepository(repo, [
                      'ls-tree',
                      '-z',
                      '--full-tree',
                      version.revision!.value,
                      '--',
                      path.utf8Path!,
                    ], cancellation: cancellation)).stdout,
                  )
          : await index(repo, path: path, cancellation: cancellation);
      final stage = version.kind == ContentKind.conflictStage
          ? version.stage
          : 0;
      final entry = entries
          .where((e) => e.path == path && e.stage == stage)
          .firstOrNull;
      if (entry == null) return absent();
      mode = entry.mode;
      oid = entry.oid;
      if (mode == '160000')
        return GitContent(
          path: path,
          version: version,
          availability: ContentAvailability.gitlink,
          oid: oid,
          mode: mode,
          token: oid.value,
        );
      final size = int.parse(
        oneLine(
          (await ctx.runRepository(repo, [
            'cat-file',
            '-s',
            oid.value,
          ], cancellation: cancellation)).text,
        ),
      );
      if (size > maximumContentBytes)
        return GitContent(
          path: path,
          version: version,
          availability: ContentAvailability.tooLarge,
          oid: oid,
          mode: mode,
          token: oid.value,
          size: size,
        );
      bytes = (await ctx.runRepository(
        repo,
        ['cat-file', 'blob', oid.value],
        cancellation: cancellation,
        maximumBytes: maximumContentBytes + 16384,
      )).stdout;
    }
    var availability = mode == '120000'
        ? ContentAvailability.symlink
        : ContentAvailability.present;
    if (bytes.contains(0)) availability = ContentAvailability.binary;
    try {
      utf8.decode(bytes);
    } on FormatException {
      availability = ContentAvailability.binary;
    }
    return GitContent(
      path: path,
      version: version,
      bytes: bytes,
      oid: oid,
      mode: mode,
      size: bytes.length,
      availability: availability,
      token: fingerprint([
        ...utf8.encode('${repo.key}:${path.key}:$mode:'),
        ...bytes,
      ]),
    );
  }

  Future<GitContent> _normalizedWorking(
    RepositoryId repo,
    RepoPath path,
    ContentVersion version,
    GitCancellation? cancellation,
  ) async {
    final raw = await content(
      repo,
      path,
      const ContentVersion.working(),
      cancellation: cancellation,
    );
    if (!{
      ContentAvailability.present,
      ContentAvailability.binary,
    }.contains(raw.availability))
      return raw;
    await ctx.passiveStatusPolicy(repo, allowExecutableFilters: true);
    // --stdin-paths accepts Git's byte-preserving quoted pathname syntax and
    // runs the same path-specific clean conversion as add, without rewriting
    // the working file or touching the index.
    final quoted =
        '"${path.bytes.map((e) => e >= 32 && e < 127 && e != 34 && e != 92 ? String.fromCharCode(e) : '\\${e.toRadixString(8).padLeft(3, '0')}').join()}"\n';
    final objects = await Directory.systemTemp.createTemp(
      'bsg-review-objects-',
    );
    LinuxPaths.chmod(objects.path, 0x1c0);
    try {
      // Review conversion writes only to this short-lived object directory. It
      // neither changes the repository nor requires a writable repository/index.
      final environment = {'GIT_OBJECT_DIRECTORY': objects.path};
      final hashed = await ctx.runRepository(
        repo,
        ['hash-object', '-w', '--stdin-paths'],
        input: ascii.encode(quoted),
        cancellation: cancellation,
        environment: environment,
      );
      if ((await content(
            repo,
            path,
            const ContentVersion.working(),
            cancellation: cancellation,
          )).token !=
          raw.token) {
        throw const GitException(GitErrorCode.staleReview);
      }
      final oid = GitOid(oneLine(hashed.text));
      final result = await ctx.runRepository(
        repo,
        ['cat-file', 'blob', oid.value],
        cancellation: cancellation,
        environment: environment,
        maximumBytes: maximumContentBytes + 16384,
      );
      var availability = ContentAvailability.present;
      try {
        utf8.decode(result.stdout);
        if (result.stdout.contains(0))
          availability = ContentAvailability.binary;
      } on FormatException {
        availability = ContentAvailability.binary;
      }
      return GitContent(
        path: path,
        version: version,
        availability: availability,
        bytes: result.stdout,
        mode: raw.mode,
        size: result.stdout.length,
        sourceToken: raw.token,
        token: oid.value,
        oid: oid,
      );
    } finally {
      await objects.delete(recursive: true);
    }
  }

  Future<GitContent> _mergePreview(
    RepositoryId repo,
    RepoPath path,
    ContentVersion version,
    GitCancellation? cancellation,
  ) async {
    final entries = (await index(
      repo,
    )).where((e) => e.path == path && e.stage != 0).toList();
    final marker = conflictMarker(entries);
    final values = <GitContent>[];
    for (final stage in [2, 1, 3]) {
      values.add(
        await content(
          repo,
          path,
          ContentVersion(ContentKind.conflictStage, stage: stage),
          cancellation: cancellation,
        ),
      );
    }
    if (values.any(
      (e) => !{
        ContentAvailability.present,
        ContentAvailability.absent,
      }.contains(e.availability),
    )) {
      return GitContent(
        path: path,
        version: version,
        availability: ContentAvailability.unavailable,
        token: marker,
      );
    }
    final directory = await Directory.systemTemp.createTemp(
      'bsg-merge-preview-',
    );
    LinuxPaths.chmod(directory.path, 0x1c0);
    try {
      for (var i = 0; i < 3; i++) {
        await File('${directory.path}/$i').writeAsBytes(values[i].bytes);
      }
      final result = await ctx.runRepository(
        repo,
        [
          'merge-file',
          '--stdout',
          '--diff3',
          '--marker-size=32',
          '-L',
          '${marker}_LEFT',
          '-L',
          '${marker}_BASE',
          '-L',
          '${marker}_RIGHT',
          '${directory.path}/0',
          '${directory.path}/1',
          '${directory.path}/2',
        ],
        allowFailure: true,
        cancellation: cancellation,
        maximumBytes: maximumContentBytes + 65536,
      );
      if (result.exitCode > 127 || result.exitCode < 0) throw result.failure;
      return GitContent(
        path: path,
        version: version,
        availability: ContentAvailability.present,
        token: fingerprint(result.stdout),
        bytes: result.stdout,
        size: result.stdout.length,
        mode: '100644',
      );
    } finally {
      await directory.delete(recursive: true);
    }
  }

  Future<HistoryPage> history(
    RepositoryId repo, {
    HistoryFilter filter = const HistoryFilter(),
    int offset = 0,
    int limit = 100,
    String? anchor,
    GitCancellation? cancellation,
  }) async {
    await ctx.validateIdentity(repo);
    if (offset < 0 || limit < 1 || limit > 300)
      throw const GitException(GitErrorCode.invalidRequest);
    final refs = (await ctx.runRepository(repo, [
      'for-each-ref',
      '--format=%(refname) %(objectname)',
    ])).stdout;
    final current = fingerprint(refs);
    if (anchor != null && anchor != current)
      throw const GitException(GitErrorCode.staleReview);
    final reference = filter.reference;
    if (reference != null &&
        (reference.startsWith('-') || reference.contains('\u0000'))) {
      throw const GitException(GitErrorCode.invalidRequest);
    }
    final path = filter.path;
    final arguments = <String>[
      'log',
      '--topo-order',
      '--date=iso-strict',
      '--no-show-signature',
      '--no-notes',
      '--format=$historyFormat',
      '--max-count=${limit + 1}',
      '--skip=$offset',
      if (filter.author.isNotEmpty) '--author=${filter.author}',
      if (filter.message.isNotEmpty) ...[
        '--fixed-strings',
        '--grep=${filter.message}',
      ],
      if (filter.since != null) '--since=${filter.since!.toIso8601String()}',
      if (filter.until != null) '--until=${filter.until!.toIso8601String()}',
      if (filter.follow && path != null) '--follow',
      if (reference != null)
        reference
      else if (!filter.follow)
        '--all'
      else
        'HEAD',
      '--',
      if (path != null) path.utf8Path ?? '',
    ];
    final result = await ctx.runRepository(
      repo,
      arguments,
      cancellation: cancellation,
      allowFailure: true,
      byteArguments: {
        if (path != null && path.utf8Path == null)
          arguments.length - 1: path.bytes,
      },
    );
    if (!result.success) {
      if ((await ctx.head(repo)) == null &&
          result.diagnostic.contains('does not have any commits')) {
        return HistoryPage(
          [],
          nextOffset: offset,
          hasMore: false,
          anchor: current,
        );
      }
      throw result.failure;
    }
    var commits = await Isolate.run(() => parseHistory(result.stdout));
    if (commits.isNotEmpty) {
      final objects = await ctx.runRepository(
        repo,
        ['cat-file', '--batch'],
        input: ascii.encode('${commits.map((e) => e.oid.value).join('\n')}\n'),
        cancellation: cancellation,
      );
      final parents = await _parseCommitParents(objects.stdout);
      final parentIds = parents.values.expand((e) => e).toSet();
      final missing = <GitOid>{};
      if (parentIds.isNotEmpty) {
        final check = await ctx.runRepository(
          repo,
          ['cat-file', '--batch-check=%(objectname) %(objecttype)'],
          input: ascii.encode('${parentIds.map((e) => e.value).join('\n')}\n'),
          cancellation: cancellation,
        );
        for (final line
            in check.text.split('\n').where((e) => e.endsWith(' missing'))) {
          missing.add(GitOid(line.split(' ').first));
        }
      }
      commits = [
        for (final commit in commits)
          GitCommit(
            oid: commit.oid,
            parents: parents[commit.oid] ?? commit.parents,
            subject: commit.subject,
            author: commit.author,
            email: commit.email,
            date: commit.date,
            committer: commit.committer,
            committerEmail: commit.committerEmail,
            committerDate: commit.committerDate,
            message: commit.message,
            boundary: (parents[commit.oid] ?? commit.parents).any(
              missing.contains,
            ),
          ),
      ];
    }
    return HistoryPage(
      commits.take(limit).toList(),
      nextOffset: offset + commits.take(limit).length,
      hasMore: commits.length > limit,
      anchor: current,
    );
  }

  Future<List<GitChange>> changedFiles(
    RepositoryId repo,
    GitOid revision, {
    GitOid? parent,
  }) async {
    await ctx.validateIdentity(repo);
    if (parent == null) {
      final raw = await ctx.runRepository(repo, [
        'cat-file',
        'commit',
        revision.value,
      ]);
      final headerEnd = _headerEnd(raw.stdout);
      if (ascii
          .decode(raw.stdout.sublist(0, headerEnd), allowInvalid: true)
          .contains('\nparent ')) {
        throw const GitException(
          GitErrorCode.missingContent,
          diagnostic:
              'Choose an explicit parent comparison. A missing shallow parent is not an empty tree.',
        );
      }
    }
    if (parent != null &&
        !(await ctx.runRepository(repo, [
          'cat-file',
          '-e',
          '${parent.value}^{tree}',
        ], allowFailure: true)).success) {
      throw const GitException(
        GitErrorCode.missingContent,
        diagnostic:
            'The selected parent is unavailable, possibly at a shallow boundary.',
      );
    }
    final result = await ctx.runRepository(repo, [
      'diff-tree',
      '-r',
      '-z',
      '--raw',
      '--no-abbrev',
      '--no-commit-id',
      '--no-ext-diff',
      '--no-textconv',
      '--find-renames',
      if (parent == null) '--root',
      if (parent != null) parent.value,
      revision.value,
      '--',
    ]);
    return parseRawChanges(result.stdout);
  }
}

List<GitChange> parseRawChanges(List<int> bytes) {
  final records = nulRecords(bytes), changes = <GitChange>[];
  for (var i = 0; i < records.length;) {
    final fields = ascii.decode(records[i++]).split(' ');
    if (fields.length != 5 || !fields[0].startsWith(':') || i >= records.length)
      throw const FormatException('Invalid raw diff record.');
    final status = fields[4][0], first = RepoPath(records[i++]);
    final renamed = status == 'R' || status == 'C';
    if (renamed && i >= records.length)
      throw const FormatException('Missing rename destination.');
    final path = renamed ? RepoPath(records[i++]) : first;
    GitOid? oid(String value) =>
        RegExp(r'^0+$').hasMatch(value) ? null : GitOid(value);
    changes.add(
      GitChange(
        path: path,
        originalPath: renamed ? first : null,
        index: status,
        worktree: '.',
        headMode: fields[0].substring(1),
        indexMode: fields[1],
        headOid: oid(fields[2]),
        indexOid: oid(fields[3]),
      ),
    );
  }
  return changes;
}

String conflictMarker(List<IndexEntry> entries) =>
    'BSG_${fingerprint(utf8.encode(entries.map((e) => '${e.stage}:${e.mode}:${e.oid.value}').join('|'))).substring(0, 24)}';
Future<Map<GitOid, List<GitOid>>> _parseCommitParents(List<int> bytes) =>
    Isolate.run(() => _commitParents(bytes));
Map<GitOid, List<GitOid>> _commitParents(List<int> bytes) {
  final result = <GitOid, List<GitOid>>{};
  var offset = 0;
  while (offset < bytes.length) {
    final end = bytes.indexOf(10, offset);
    if (end < 0) throw const FormatException('Missing object header.');
    final header = ascii.decode(bytes.sublist(offset, end)).split(' ');
    if (header.length != 3 || header[1] != 'commit')
      throw const FormatException('Unavailable commit object.');
    final size = int.parse(header[2]), start = end + 1;
    if (start + size >= bytes.length)
      throw const FormatException('Truncated commit object.');
    final body = bytes.sublist(start, start + size),
        headers = ascii.decode(
          body.sublist(0, _headerEnd(body)),
          allowInvalid: true,
        );
    result[GitOid(header[0])] = [
      for (final line in headers.split('\n'))
        if (line.startsWith('parent ')) GitOid(line.substring(7)),
    ];
    offset = start + size + 1;
  }
  return result;
}

int _headerEnd(List<int> bytes) {
  for (var i = 0; i + 1 < bytes.length; i++) {
    if (bytes[i] == 10 && bytes[i + 1] == 10) return i;
  }
  throw const FormatException('Commit has no message separator.');
}
