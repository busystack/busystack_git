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
            '--diff-merges=first-parent',
            '-z',
            '--find-renames',
            '--max-count=${request.offset + request.limit + 1}',
            '--format=%x00BUSYSTACK_COMMIT%x00$historyFormat',
            request.revision?.value ?? 'HEAD',
            '--',
            path.utf8Path ?? '',
          ],
          cancellation: cancellation,
          byteArguments: {if (path.utf8Path == null) 14: path.bytes},
        );
        final entries = parseFollowHistory(result.stdout);
        return {
          'entries': entries.skip(request.offset).take(request.limit).toList(),
          'hasMore': entries.length > request.offset + request.limit,
          'nextOffset': request.offset + request.limit,
        };
      default:
        throw const GitException(GitErrorCode.invalidRequest);
    }
  }
}

List<Json> parseFollowHistory(List<int> bytes) {
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
    while (i < records.length) {
      if (records[i].isEmpty) {
        i++;
        continue;
      }
      final value = ascii
          .decode(records[i], allowInvalid: true)
          .replaceFirst(RegExp(r'^\n+'), '');
      if (value == 'BUSYSTACK_COMMIT') break;
      if (!RegExp(r'^[ACDMRTUXB][0-9]*$').hasMatch(value))
        throw const FormatException('Invalid file-history change record.');
      i++;
      if (i >= records.length)
        throw const FormatException('Missing historical path.');
      final first = RepoPath(records[i++]);
      final second = value.startsWith('R') || value.startsWith('C')
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
    }
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
