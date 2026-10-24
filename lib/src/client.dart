import 'dart:typed_data';
import 'models.dart';
import 'runner.dart';

part 'workflow_requests.dart';
part 'workflow_codec.dart';

/// Focused read contract for the less frequent management and history surfaces.
/// Responses are versioned domain metadata; content always has a separate handle.
abstract interface class GitWorkflowClient {
  Future<Json> inspect(
    RepositoryId repository,
    GitInspection request, {
    GitCancellation? cancellation,
    void Function(GitProgress)? onProgress,
  });
  Future<GitCreationOutcome> create(
    GitCreation request, {
    GitCancellation? cancellation,
    void Function(GitProgress)? onProgress,
  });
}

abstract interface class GitPatchClient {
  Future<GitPatch> patch(
    RepositoryId repository,
    GitDiffSpec comparison, {
    GitCancellation? cancellation,
  });
}

final class GitDiffSpec {
  const GitDiffSpec(this.left, this.right, {this.paths = const []});
  final ContentVersion left, right;
  final List<RepoPath> paths;
  Json toJson() => {
    'left': left.toJson(),
    'right': right.toJson(),
    'paths': paths.map((e) => e.toJson()).toList(),
  };
  factory GitDiffSpec.fromJson(Json j) => GitDiffSpec(
    ContentVersion.fromJson(j['left'] as Json),
    ContentVersion.fromJson(j['right'] as Json),
    paths: (j['paths'] as List).map(RepoPath.fromJson).toList(),
  );
}

final class GitPatch {
  GitPatch(List<int> bytes)
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();
  final Uint8List bytes;
}

/// Both host adapters implement this contract. Repository identity is explicit
/// on every call; cancellation never implies aborting a Git sequencer.
abstract interface class GitClient {
  Future<RepositoryId?> discover(
    String localPath, {
    GitCancellation? cancellation,
  });
  Future<GitSnapshot> status(
    RepositoryId repository, {
    GitCancellation? cancellation,
    GitReadPolicy policy = GitReadPolicy.restricted,
  });
  Future<List<GitReference>> references(RepositoryId repository);
  Future<HistoryPage> history(
    RepositoryId repository, {
    HistoryFilter filter = const HistoryFilter(),
    int offset = 0,
    int limit = 100,
    String? anchor,
    GitCancellation? cancellation,
  });
  Future<GitContent> content(
    RepositoryId repository,
    RepoPath path,
    ContentVersion version, {
    GitCancellation? cancellation,
  });
  Future<List<GitChange>> changedFiles(
    RepositoryId repository,
    GitOid revision, {
    GitOid? parent,
  });
  Future<GitOutcome> mutate(
    RepositoryId repository,
    GitMutation request, {
    GitCancellation? cancellation,
    void Function(GitProgress)? onProgress,
  });
  Stream<void> watch(RepositoryId repository);
}

sealed class GitMutation {
  const GitMutation({required this.expectedHead, required this.expectedIndex});
  final GitOid? expectedHead;
  final String expectedIndex;
  bool get replacesWorkingFiles => false;
  Json get fields;
  String get kind;
  Json toJson() => {
    'kind': kind,
    'expectedHead': expectedHead?.value,
    'expectedIndex': expectedIndex,
    ...fields,
  };
}

final class StagePaths extends GitMutation {
  const StagePaths(
    this.paths, {
    required super.expectedHead,
    required super.expectedIndex,
    this.unstage = false,
    this.contentTokens = const {},
    this.expectedSnapshot,
  });
  final List<RepoPath> paths;
  final bool unstage;
  final Map<String, String> contentTokens;
  final String? expectedSnapshot;
  @override
  String get kind => 'stage';
  @override
  Json get fields => {
    'paths': paths.map((e) => e.toJson()).toList(),
    'unstage': unstage,
    'contentTokens': contentTokens,
    'expectedSnapshot': expectedSnapshot,
  };
}

final class WriteIndex extends GitMutation {
  WriteIndex(
    this.path,
    this.bytes, {
    required super.expectedHead,
    required super.expectedIndex,
    required this.expectedContent,
    this.expectedWorktree,
    this.mode = '100644',
    this.remove = false,
  });
  final RepoPath path;
  final Uint8List bytes;
  final String expectedContent;
  final String? expectedWorktree;
  final String mode;
  final bool remove;
  @override
  String get kind => 'writeIndex';
  @override
  Json get fields => {
    'path': path.toJson(),
    'expectedContent': expectedContent,
    'expectedWorktree': expectedWorktree,
    'mode': mode,
    'remove': remove,
  };
}

final class CommitIndex extends GitMutation {
  const CommitIndex(
    this.message, {
    required super.expectedHead,
    required super.expectedIndex,
    this.amend = false,
    this.signOff = false,
    this.sign,
    this.author,
    this.allowEmpty = false,
  });
  final String message;
  final bool amend, signOff, allowEmpty;
  final bool? sign;
  final String? author;
  @override
  String get kind => 'commit';
  @override
  Json get fields => {
    'message': message,
    'amend': amend,
    'signOff': signOff,
    'sign': sign,
    'author': author,
    'allowEmpty': allowEmpty,
  };
}
