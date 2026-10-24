import 'dart:convert';
import 'dart:typed_data';
import 'models.dart';

List<Uint8List> nulRecords(List<int> bytes) {
  final records = <Uint8List>[];
  var start = 0;
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] == 0) {
      records.add(Uint8List.fromList(bytes.sublist(start, i)));
      start = i + 1;
    }
  }
  if (start < bytes.length)
    records.add(Uint8List.fromList(bytes.sublist(start)));
  return records;
}

(List<String>, Uint8List) fixedFields(List<int> bytes, int count) {
  var start = 0;
  final fields = <String>[];
  for (var i = 0; i < bytes.length && fields.length < count; i++) {
    if (bytes[i] == 32) {
      fields.add(ascii.decode(bytes.sublist(start, i)));
      start = i + 1;
    }
  }
  if (fields.length != count)
    throw const FormatException('Truncated Git record.');
  return (fields, Uint8List.fromList(bytes.sublist(start)));
}

GitOid? nonzeroOid(String value) =>
    RegExp(r'^0+$').hasMatch(value) ? null : GitOid(value);

({
  List<GitChange> changes,
  GitOid? head,
  String? branch,
  String? upstream,
  int ahead,
  int behind,
})
parseStatusV2(List<int> bytes) {
  final records = nulRecords(bytes), changes = <GitChange>[];
  GitOid? head;
  String? branch, upstream;
  var ahead = 0, behind = 0;
  for (var i = 0; i < records.length; i++) {
    final row = records[i];
    if (row.isEmpty) continue;
    if (row.first == 35) {
      final header = utf8.decode(row);
      if (header.startsWith('# branch.oid ') && !header.endsWith('(initial)'))
        head = GitOid(header.substring(13));
      if (header.startsWith('# branch.head ') && !header.endsWith('(detached)'))
        branch = header.substring(14);
      if (header.startsWith('# branch.upstream '))
        upstream = header.substring(18);
      if (header.startsWith('# branch.ab ')) {
        final ab = header.substring(12).split(' ');
        ahead = int.parse(ab[0]);
        behind = -int.parse(ab[1]);
      }
      continue;
    }
    if (row.first == 63 || row.first == 33) {
      final symbol = String.fromCharCode(row.first);
      final directory = row.last == 47;
      changes.add(
        GitChange(
          path: RepoPath(
            row.sublist(2, directory ? row.length - 1 : row.length),
          ),
          directory: directory,
          index: symbol,
          worktree: symbol,
        ),
      );
      continue;
    }
    if (row.first == 49 || row.first == 50) {
      final (f, path) = fixedFields(row, row.first == 49 ? 8 : 9);
      RepoPath? original;
      if (row.first == 50) {
        if (++i >= records.length)
          throw const FormatException('Missing rename source.');
        original = RepoPath(records[i]);
      }
      changes.add(
        GitChange(
          path: RepoPath(path),
          originalPath: original,
          index: f[1][0],
          worktree: f[1][1],
          submodule: f[2],
          headMode: f[3],
          indexMode: f[4],
          worktreeMode: f[5],
          headOid: nonzeroOid(f[6]),
          indexOid: nonzeroOid(f[7]),
        ),
      );
    } else if (row.first == 117) {
      final (f, path) = fixedFields(row, 10);
      final p = RepoPath(path);
      changes.add(
        GitChange(
          path: p,
          index: f[1][0],
          worktree: f[1][1],
          submodule: f[2],
          worktreeMode: f[6],
          conflictStages: {
            for (var stage = 1; stage <= 3; stage++)
              if (nonzeroOid(f[stage + 6]) case final oid?)
                stage: IndexEntry(p, f[stage + 2], oid, stage: stage),
          },
        ),
      );
    } else {
      throw const FormatException('Unsupported Git status record.');
    }
  }
  return (
    changes: changes,
    head: head,
    branch: branch,
    upstream: upstream,
    ahead: ahead,
    behind: behind,
  );
}

List<IndexEntry> parseIndex(List<int> bytes) => [
  for (final row in nulRecords(bytes))
    if (row.isNotEmpty) _indexEntry(row),
];
IndexEntry _indexEntry(Uint8List row) {
  final tab = row.indexOf(9);
  if (tab < 0) throw const FormatException('Invalid index record.');
  final fields = ascii.decode(row.sublist(0, tab)).split(' ');
  return IndexEntry(
    RepoPath(row.sublist(tab + 1)),
    fields[0],
    GitOid(fields[1]),
    stage: int.parse(fields[2]),
  );
}

List<IndexEntry> parseTree(List<int> bytes) => [
  for (final row in nulRecords(bytes))
    if (row.isNotEmpty) _treeEntry(row),
];
IndexEntry _treeEntry(Uint8List row) {
  final tab = row.indexOf(9);
  if (tab < 0) throw const FormatException('Invalid tree record.');
  final f = ascii.decode(row.sublist(0, tab)).split(' ');
  return IndexEntry(RepoPath(row.sublist(tab + 1)), f[0], GitOid(f[2]));
}

const historyFormat =
    '%H%x00%P%x00%an%x00%ae%x00%aI%x00%cn%x00%ce%x00%cI%x00%s%x00%B%x00';
List<GitCommit> parseHistory(List<int> bytes) {
  final fields = nulRecords(bytes);
  final result = <GitCommit>[];
  for (var i = 0; i + 9 < fields.length; i += 10) {
    String text(int j) => utf8.decode(fields[i + j]);
    final id = text(0).replaceFirst(RegExp(r'^\n+'), '');
    if (id.isEmpty) break;
    result.add(
      GitCommit(
        oid: GitOid(id),
        parents: text(
          1,
        ).split(' ').where((e) => e.isNotEmpty).map(GitOid.new).toList(),
        author: text(2),
        email: text(3),
        date: DateTime.parse(text(4)),
        committer: text(5),
        committerEmail: text(6),
        committerDate: DateTime.parse(text(7)),
        subject: text(8),
        message: text(9),
      ),
    );
  }
  return result;
}
