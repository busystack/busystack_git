import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

typedef Json = Map<String, Object?>;

String fingerprint(List<int> bytes) => sha256.convert(bytes).toString();

/// Repository paths are bytes on Linux. Display text is never a pathspec.
final class RepoPath implements Comparable<RepoPath> {
  RepoPath(List<int> bytes)
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView() {
    if (bytes.isEmpty || bytes.first == 47 || bytes.contains(0)) {
      throw ArgumentError('Expected a repository-relative path.');
    }
    for (final component in _split(bytes, 47)) {
      if (component.isEmpty ||
          _equal(component, [46]) ||
          _equal(component, [46, 46]) ||
          _equal(component, [46, 103, 105, 116])) {
        throw ArgumentError('Unsafe repository-relative path.');
      }
    }
  }
  factory RepoPath.text(String path) => RepoPath(utf8.encode(path));
  factory RepoPath.fromJson(Object? value) =>
      RepoPath(base64Decode(value as String));
  final Uint8List bytes;
  String toJson() => base64Encode(bytes);
  String get key => toJson();
  String? get utf8Path {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  String get display {
    final text = utf8Path;
    if (text != null) {
      return text
          .replaceAll('\\', r'\\')
          .replaceAll('\n', r'\n')
          .replaceAll('\r', r'\r')
          .replaceAll('\t', r'\t');
    }
    return bytes
        .map(
          (b) => b >= 32 && b < 127 && b != 92
              ? String.fromCharCode(b)
              : '\\x${b.toRadixString(16).padLeft(2, '0')}',
        )
        .join();
  }

  String get basename => display.split('/').last;
  String get parent => display.contains('/')
      ? display.substring(0, display.lastIndexOf('/'))
      : '';
  @override
  bool operator ==(Object other) =>
      other is RepoPath && _equal(bytes, other.bytes);
  @override
  int get hashCode => Object.hashAll(bytes);
  @override
  int compareTo(RepoPath other) => display.compareTo(other.display);
}

bool _equal(List<int> a, List<int> b) =>
    a.length == b.length &&
    Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);
List<List<int>> _split(List<int> bytes, int separator) {
  final result = <List<int>>[];
  var start = 0;
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] == separator) {
      result.add(bytes.sublist(start, i));
      start = i + 1;
    }
  }
  result.add(bytes.sublist(start));
  return result;
}

final class GitOid {
  GitOid(this.value) {
    if (!RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$').hasMatch(value)) {
      throw ArgumentError('Expected a full Git object identity.');
    }
  }
  final String value;
  String get abbreviated => value.substring(0, 10);
  @override
  bool operator ==(Object other) => other is GitOid && value == other.value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

final class RepositoryId {
  const RepositoryId({
    required this.root,
    required this.gitDir,
    required this.commonDir,
    required this.objectFormat,
    this.bare = false,
    this.shallow = false,
    this.filesystemToken = '',
    this.referenceFormat = 'unknown',
  });
  factory RepositoryId.fromJson(Json j) => RepositoryId(
    root: j['root'] as String,
    gitDir: j['gitDir'] as String,
    commonDir: j['commonDir'] as String,
    objectFormat: j['objectFormat'] as String,
    bare: j['bare'] == true,
    shallow: j['shallow'] == true,
    filesystemToken: j['filesystemToken'] as String? ?? '',
    referenceFormat: j['referenceFormat'] as String? ?? 'unknown',
  );
  final String root, gitDir, commonDir, objectFormat;
  final bool bare, shallow;
  final String filesystemToken, referenceFormat;
  String get key => fingerprint(
    utf8.encode('$commonDir\u0000$gitDir\u0000$root\u0000$filesystemToken'),
  );

  /// Presentation persistence follows the same directories through a Git-aware
  /// worktree move. This key never authorizes a command or replaces [key].
  String get presentationKey => filesystemToken.isEmpty
      ? key
      : fingerprint(
          utf8.encode(
            'worktree-presentation\u0000$objectFormat\u0000$filesystemToken',
          ),
        );
  Json toJson() => {
    'root': root,
    'gitDir': gitDir,
    'commonDir': commonDir,
    'objectFormat': objectFormat,
    'bare': bare,
    'shallow': shallow,
    'filesystemToken': filesystemToken,
    'referenceFormat': referenceFormat,
  };
  @override
  bool operator ==(Object other) => other is RepositoryId && key == other.key;
  @override
  int get hashCode => key.hashCode;
}

enum GitErrorCode {
  unavailable,
  unsupportedVersion,
  notRepository,
  ownership,
  trustRequired,
  invalidRequest,
  unsafePath,
  staleReview,
  locked,
  dirty,
  authentication,
  unknownHost,
  signing,
  hook,
  rejected,
  transport,
  conflict,
  cancelled,
  deadline,
  outputLimit,
  missingContent,
  unsupportedContent,
  disconnected,
  commandFailed,
  authorIdentity,
  uncertainOutcome,
  readOnly,
}

final class GitException implements Exception {
  const GitException(
    this.code, {
    this.command = '',
    this.diagnostic = '',
    this.exitCode,
  });
  final GitErrorCode code;
  final String command, diagnostic;
  final int? exitCode;
  Json toJson() => {
    'code': code.name,
    'command': command,
    'diagnostic': diagnostic,
    'exitCode': exitCode,
  };
  factory GitException.fromJson(Json j) => GitException(
    GitErrorCode.values.byName(j['code'] as String),
    command: j['command'] as String? ?? '',
    diagnostic: j['diagnostic'] as String? ?? '',
    exitCode: j['exitCode'] as int?,
  );
  @override
  String toString() => 'GitException(${code.name}, $command, $diagnostic)';
}

enum GitOperationKind {
  none,
  merge,
  rebase,
  cherryPick,
  revert,
  applyMailbox,
  squash,
  unmerged,
}

enum GitReadPolicy { restricted, authorized }

enum GitOperationPhase {
  preparing,
  running,
  waitingForPrompt,
  stopped,
  completed,
  failed,
  cancelled,
  uncertain,
}

enum GitContinuation { continueOperation, abort, skip, quit }

final class RepositoryOperation {
  const RepositoryOperation(
    this.kind, {
    this.head,
    this.other,
    this.message = '',
    this.editStop = false,
    this.unmerged = false,
  });
  final GitOperationKind kind;
  final GitOid? head, other;
  final String message;
  final bool editStop, unmerged;
  Set<GitContinuation> get actions => switch (kind) {
    GitOperationKind.merge => {
      if (!unmerged) GitContinuation.continueOperation,
      GitContinuation.abort,
      GitContinuation.quit,
    },
    GitOperationKind.rebase ||
    GitOperationKind.cherryPick ||
    GitOperationKind.revert ||
    GitOperationKind.applyMailbox => {
      if (!unmerged) GitContinuation.continueOperation,
      GitContinuation.abort,
      GitContinuation.skip,
      GitContinuation.quit,
    },
    _ => {},
  };
  Json toJson() => {
    'kind': kind.name,
    'head': head?.value,
    'other': other?.value,
    'message': message,
    'editStop': editStop,
    'unmerged': unmerged,
  };
  factory RepositoryOperation.fromJson(Json j) => RepositoryOperation(
    GitOperationKind.values.byName(j['kind'] as String),
    head: oidOrNull(j['head']),
    other: oidOrNull(j['other']),
    message: j['message'] as String? ?? '',
    editStop: j['editStop'] == true,
    unmerged: j['unmerged'] == true,
  );
}

GitOid? oidOrNull(Object? value) =>
    value == null ? null : GitOid(value as String);

final class GitChange {
  const GitChange({
    required this.path,
    this.originalPath,
    required this.index,
    required this.worktree,
    this.submodule = 'N...',
    this.headMode = '000000',
    this.indexMode = '000000',
    this.worktreeMode = '000000',
    this.headOid,
    this.indexOid,
    this.conflictStages = const {},
    this.directory = false,
  });
  final RepoPath path;
  final RepoPath? originalPath;
  final String index, worktree, submodule, headMode, indexMode, worktreeMode;
  final GitOid? headOid, indexOid;
  final Map<int, IndexEntry> conflictStages;

  /// Opaque untracked/ignored directory record, including nested repositories.
  /// Its children are never aggregated as ordinary files of this repository.
  final bool directory;
  bool get conflicted =>
      conflictStages.isNotEmpty || index == 'U' || worktree == 'U';
  bool get untracked => index == '?';
  bool get ignored => index == '!';
  bool get staged => !conflicted && !untracked && !ignored && index != '.';
  bool get unstaged => !conflicted && !ignored && worktree != '.' && !untracked;
  Json toJson() => {
    'path': path.toJson(),
    'originalPath': originalPath?.toJson(),
    'index': index,
    'worktree': worktree,
    'submodule': submodule,
    'headMode': headMode,
    'indexMode': indexMode,
    'worktreeMode': worktreeMode,
    'headOid': headOid?.value,
    'indexOid': indexOid?.value,
    'stages': conflictStages.values.map((e) => e.toJson()).toList(),
    'directory': directory,
  };
  factory GitChange.fromJson(Json j) => GitChange(
    path: RepoPath.fromJson(j['path']),
    originalPath: j['originalPath'] == null
        ? null
        : RepoPath.fromJson(j['originalPath']),
    index: j['index'] as String,
    worktree: j['worktree'] as String,
    submodule: j['submodule'] as String,
    headMode: j['headMode'] as String,
    indexMode: j['indexMode'] as String,
    worktreeMode: j['worktreeMode'] as String,
    headOid: oidOrNull(j['headOid']),
    indexOid: oidOrNull(j['indexOid']),
    conflictStages: {
      for (final e in (j['stages'] as List).cast<Json>().map(
        IndexEntry.fromJson,
      ))
        e.stage: e,
    },
    directory: j['directory'] == true,
  );
}

final class IndexEntry {
  const IndexEntry(this.path, this.mode, this.oid, {this.stage = 0});
  final RepoPath path;
  final String mode;
  final GitOid oid;
  final int stage;
  Json toJson() => {
    'path': path.toJson(),
    'mode': mode,
    'oid': oid.value,
    'stage': stage,
  };
  factory IndexEntry.fromJson(Json j) => IndexEntry(
    RepoPath.fromJson(j['path']),
    j['mode'] as String,
    GitOid(j['oid'] as String),
    stage: j['stage'] as int,
  );
}

final class GitCapabilities {
  const GitCapabilities({
    this.writeMetadata = true,
    this.replaceWorkingFiles = true,
  });
  final bool writeMetadata, replaceWorkingFiles;
  Json toJson() => {
    'writeMetadata': writeMetadata,
    'replaceWorkingFiles': replaceWorkingFiles,
  };
  factory GitCapabilities.fromJson(Json j) => GitCapabilities(
    writeMetadata: j['writeMetadata'] == true,
    replaceWorkingFiles: j['replaceWorkingFiles'] == true,
  );
}

final class GitSnapshot {
  const GitSnapshot({
    required this.repository,
    required this.token,
    required this.indexToken,
    required this.changes,
    required this.operation,
    required this.observedAt,
    this.head,
    this.branch,
    this.upstream,
    this.ahead = 0,
    this.behind = 0,
    this.capabilities = const GitCapabilities(),
  });
  final RepositoryId repository;
  final String token, indexToken;
  final GitOid? head;
  final String? branch, upstream;
  final int ahead, behind;
  final List<GitChange> changes;
  final RepositoryOperation operation;
  final DateTime observedAt;
  final GitCapabilities capabilities;
  Json toJson() => {
    'repository': repository.toJson(),
    'token': token,
    'indexToken': indexToken,
    'head': head?.value,
    'branch': branch,
    'upstream': upstream,
    'ahead': ahead,
    'behind': behind,
    'changes': changes.map((e) => e.toJson()).toList(),
    'operation': operation.toJson(),
    'observedAt': observedAt.toIso8601String(),
    'capabilities': capabilities.toJson(),
  };
  factory GitSnapshot.fromJson(Json j) => GitSnapshot(
    repository: RepositoryId.fromJson(j['repository'] as Json),
    token: j['token'] as String,
    indexToken: j['indexToken'] as String,
    head: oidOrNull(j['head']),
    branch: j['branch'] as String?,
    upstream: j['upstream'] as String?,
    ahead: j['ahead'] as int,
    behind: j['behind'] as int,
    changes: (j['changes'] as List)
        .cast<Json>()
        .map(GitChange.fromJson)
        .toList(),
    operation: RepositoryOperation.fromJson(j['operation'] as Json),
    observedAt: DateTime.parse(j['observedAt'] as String),
    capabilities: j['capabilities'] == null
        ? const GitCapabilities()
        : GitCapabilities.fromJson(j['capabilities'] as Json),
  );
}

enum ContentKind {
  workingTree,
  indexVersion,
  commit,
  conflictStage,
  absent,
  mergePreview,
  normalizedWorking,
}

final class ContentVersion {
  const ContentVersion(this.kind, {this.revision, this.stage = 0});
  const ContentVersion.working() : this(ContentKind.workingTree);
  const ContentVersion.index() : this(ContentKind.indexVersion);
  const ContentVersion.absent() : this(ContentKind.absent);
  final ContentKind kind;
  final GitOid? revision;
  final int stage;
  String get label => switch (kind) {
    ContentKind.workingTree => 'Working Tree',
    ContentKind.indexVersion => 'Index',
    ContentKind.commit => revision!.abbreviated,
    ContentKind.conflictStage => 'Stage $stage',
    ContentKind.absent => 'Absent',
    ContentKind.mergePreview => 'Git merge preview',
    ContentKind.normalizedWorking => 'Working Tree · Git normalized',
  };
  Json toJson() => {
    'kind': kind.name,
    'revision': revision?.value,
    'stage': stage,
  };
  factory ContentVersion.fromJson(Json j) => ContentVersion(
    ContentKind.values.byName(j['kind'] as String),
    revision: oidOrNull(j['revision']),
    stage: j['stage'] as int? ?? 0,
  );
}

enum ContentAvailability {
  present,
  absent,
  binary,
  tooLarge,
  unavailable,
  gitlink,
  symlink,
}

final class GitContent {
  GitContent({
    required this.path,
    required this.version,
    required this.availability,
    required this.token,
    this.oid,
    this.mode = '000000',
    this.size = 0,
    this.sourceToken = '',
    List<int> bytes = const [],
  }) : bytes = Uint8List.fromList(bytes).asUnmodifiableView();
  final RepoPath path;
  final ContentVersion version;
  final ContentAvailability availability;
  final String token, mode;
  final String sourceToken;
  final GitOid? oid;
  final int size;
  final Uint8List bytes;
  late final String? _text = _decodeText();
  String? get text => _text;
  String? _decodeText() {
    if (availability != ContentAvailability.present) return null;
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  Json toJson({bool includeBytes = true}) => {
    'path': path.toJson(),
    'version': version.toJson(),
    'availability': availability.name,
    'token': token,
    'oid': oid?.value,
    'mode': mode,
    'size': size,
    'sourceToken': sourceToken,
    if (includeBytes) 'bytes': base64Encode(bytes),
  };
  factory GitContent.fromJson(Json j, {List<int>? bytes}) => GitContent(
    path: RepoPath.fromJson(j['path']),
    version: ContentVersion.fromJson(j['version'] as Json),
    availability: ContentAvailability.values.byName(
      j['availability'] as String,
    ),
    token: j['token'] as String,
    oid: oidOrNull(j['oid']),
    mode: j['mode'] as String,
    size: j['size'] as int,
    sourceToken: j['sourceToken'] as String? ?? '',
    bytes: bytes ?? base64Decode(j['bytes'] as String? ?? ''),
  );
}

final class GitComparison {
  const GitComparison(this.path, this.left, this.right, {this.leftPath});
  final RepoPath path;
  final RepoPath? leftPath;
  final ContentVersion left, right;
  Json toJson() => {
    'path': path.toJson(),
    'leftPath': leftPath?.toJson(),
    'left': left.toJson(),
    'right': right.toJson(),
  };
  factory GitComparison.fromJson(Json j) => GitComparison(
    RepoPath.fromJson(j['path']),
    ContentVersion.fromJson(j['left'] as Json),
    ContentVersion.fromJson(j['right'] as Json),
    leftPath: j['leftPath'] == null ? null : RepoPath.fromJson(j['leftPath']),
  );
}

final class GitReference {
  const GitReference({
    required this.name,
    required this.oid,
    this.upstream,
    this.current = false,
    this.worktreePath,
    this.subject = '',
    this.type = 'commit',
  });
  final String name, subject, type;
  final GitOid oid;
  final String? upstream, worktreePath;
  final bool current;
  String get shortName =>
      name.replaceFirst(RegExp(r'^refs/(heads|remotes|tags)/'), '');
  Json toJson() => {
    'name': name,
    'oid': oid.value,
    'upstream': upstream,
    'current': current,
    'worktreePath': worktreePath,
    'subject': subject,
    'type': type,
  };
  factory GitReference.fromJson(Json j) => GitReference(
    name: j['name'] as String,
    oid: GitOid(j['oid'] as String),
    upstream: j['upstream'] as String?,
    current: j['current'] == true,
    worktreePath: j['worktreePath'] as String?,
    subject: j['subject'] as String,
    type: j['type'] as String,
  );
}

final class GitCommit {
  const GitCommit({
    required this.oid,
    required this.parents,
    required this.subject,
    required this.author,
    required this.email,
    required this.date,
    this.committer = '',
    this.committerEmail = '',
    this.committerDate,
    this.message = '',
    this.boundary = false,
  });
  final GitOid oid;
  final List<GitOid> parents;
  final String subject, author, email, committer, committerEmail, message;
  final DateTime date;
  final DateTime? committerDate;
  final bool boundary;
  Json toJson() => {
    'oid': oid.value,
    'parents': parents.map((e) => e.value).toList(),
    'subject': subject,
    'author': author,
    'email': email,
    'date': date.toIso8601String(),
    'committer': committer,
    'committerEmail': committerEmail,
    'committerDate': committerDate?.toIso8601String(),
    'message': message,
    'boundary': boundary,
  };
  factory GitCommit.fromJson(Json j) => GitCommit(
    oid: GitOid(j['oid'] as String),
    parents: (j['parents'] as List).cast<String>().map(GitOid.new).toList(),
    subject: j['subject'] as String,
    author: j['author'] as String,
    email: j['email'] as String,
    date: DateTime.parse(j['date'] as String),
    committer: j['committer'] as String,
    committerEmail: j['committerEmail'] as String,
    committerDate: j['committerDate'] == null
        ? null
        : DateTime.parse(j['committerDate'] as String),
    message: j['message'] as String,
    boundary: j['boundary'] == true,
  );
}

final class HistoryFilter {
  const HistoryFilter({
    this.reference,
    this.author = '',
    this.message = '',
    this.since,
    this.until,
    this.path,
    this.follow = false,
  });
  final String? reference;
  final String author, message;
  final DateTime? since, until;
  final RepoPath? path;
  final bool follow;
  Json toJson() => {
    'reference': reference,
    'author': author,
    'message': message,
    'since': since?.toIso8601String(),
    'until': until?.toIso8601String(),
    'path': path?.toJson(),
    'follow': follow,
  };
  factory HistoryFilter.fromJson(Json j) => HistoryFilter(
    reference: j['reference'] as String?,
    author: j['author'] as String? ?? '',
    message: j['message'] as String? ?? '',
    since: j['since'] == null ? null : DateTime.parse(j['since'] as String),
    until: j['until'] == null ? null : DateTime.parse(j['until'] as String),
    path: j['path'] == null ? null : RepoPath.fromJson(j['path']),
    follow: j['follow'] == true,
  );
}

final class HistoryPage {
  const HistoryPage(
    this.commits, {
    required this.nextOffset,
    required this.hasMore,
    required this.anchor,
  });
  final List<GitCommit> commits;
  final int nextOffset;
  final bool hasMore;
  final String anchor;
  Json toJson() => {
    'commits': commits.map((e) => e.toJson()).toList(),
    'nextOffset': nextOffset,
    'hasMore': hasMore,
    'anchor': anchor,
  };
  factory HistoryPage.fromJson(Json j) => HistoryPage(
    (j['commits'] as List).cast<Json>().map(GitCommit.fromJson).toList(),
    nextOffset: j['nextOffset'] as int,
    hasMore: j['hasMore'] == true,
    anchor: j['anchor'] as String,
  );
}

final class GitProgress {
  const GitProgress(
    this.phase, {
    this.operationId = '',
    this.text = '',
    this.bytes = 0,
  });
  final GitOperationPhase phase;
  final String operationId, text;
  final int bytes;
  Json toJson() => {
    'phase': phase.name,
    'operationId': operationId,
    'text': text,
    'bytes': bytes,
  };
  factory GitProgress.fromJson(Json j) => GitProgress(
    GitOperationPhase.values.byName(j['phase'] as String),
    operationId: j['operationId'] as String,
    text: j['text'] as String,
    bytes: j['bytes'] as int,
  );
}

final class GitOutcome {
  const GitOutcome({
    required this.phase,
    required this.snapshot,
    this.createdCommit,
    this.error,
    this.diagnostic = '',
  });
  final GitOperationPhase phase;
  final GitSnapshot? snapshot;
  final GitOid? createdCommit;
  final GitException? error;
  final String diagnostic;
  bool get completed => phase == GitOperationPhase.completed;
  Json toJson() => {
    'phase': phase.name,
    'snapshot': snapshot?.toJson(),
    'createdCommit': createdCommit?.value,
    'error': error?.toJson(),
    'diagnostic': diagnostic,
  };
  factory GitOutcome.fromJson(Json j) => GitOutcome(
    phase: GitOperationPhase.values.byName(j['phase'] as String),
    snapshot: j['snapshot'] == null
        ? null
        : GitSnapshot.fromJson(j['snapshot'] as Json),
    createdCommit: oidOrNull(j['createdCommit']),
    error: j['error'] == null
        ? null
        : GitException.fromJson(j['error'] as Json),
    diagnostic: j['diagnostic'] as String? ?? '',
  );
}
