part of 'client.dart';

enum GitInspectionKind {
  remotes,
  commitOptions,
  blame,
  fileHistory,
  tree,
  pushReview,
  stashes,
  worktrees,
  submodules,
  reflog,
  conflict,
  rebasePlan,
  compareRevisions,
  pushPage,
  workingStatus,
}

final class GitInspection {
  const GitInspection(
    this.kind, {
    this.path,
    this.revision,
    this.otherRevision,
    this.reference,
    this.remote,
    this.destination,
    this.reviewToken,
    this.offset = 0,
    this.limit = 100,
    this.root = false,
    this.preserveMerges = false,
    this.autosquash = false,
    this.tags = const [],
  });
  final GitInspectionKind kind;
  final RepoPath? path;
  final GitOid? revision, otherRevision;
  final String? reference, remote, destination, reviewToken;
  final int offset, limit;
  final bool root, preserveMerges, autosquash;
  final List<String> tags;
  Json toJson() => {
    'kind': kind.name,
    'path': path?.toJson(),
    'revision': revision?.value,
    'otherRevision': otherRevision?.value,
    'reference': reference,
    'remote': remote,
    'destination': destination,
    'offset': offset,
    'limit': limit,
    'reviewToken': reviewToken,
    'root': root,
    'preserveMerges': preserveMerges,
    'autosquash': autosquash,
    'tags': tags,
  };
  factory GitInspection.fromJson(Json j) => GitInspection(
    GitInspectionKind.values.byName(j['kind'] as String),
    path: j['path'] == null ? null : RepoPath.fromJson(j['path']),
    revision: oidOrNull(j['revision']),
    otherRevision: oidOrNull(j['otherRevision']),
    reference: j['reference'] as String?,
    remote: j['remote'] as String?,
    destination: j['destination'] as String?,
    reviewToken: j['reviewToken'] as String?,
    offset: j['offset'] as int? ?? 0,
    limit: j['limit'] as int? ?? 100,
    root: j['root'] == true,
    preserveMerges: j['preserveMerges'] == true,
    autosquash: j['autosquash'] == true,
    tags: (j['tags'] as List? ?? []).cast<String>(),
  );
}

enum BranchAction { create, switchBranch, rename, delete, setUpstream }

final class BranchMutation extends GitMutation {
  const BranchMutation(
    this.action,
    this.name, {
    required super.expectedHead,
    required super.expectedIndex,
    this.newName,
    this.start,
    this.upstream,
    this.expectedTip,
    this.forceDeleteReviewed = false,
    this.switchAfterCreate = false,
  });
  final BranchAction action;
  final String name;
  final String? newName, upstream;
  final GitOid? start, expectedTip;
  final bool forceDeleteReviewed, switchAfterCreate;
  @override
  bool get replacesWorkingFiles =>
      action == BranchAction.switchBranch || switchAfterCreate;
  @override
  String get kind => 'branch';
  @override
  Json get fields => {
    'action': action.name,
    'name': name,
    'newName': newName,
    'start': start?.value,
    'upstream': upstream,
    'expectedTip': expectedTip?.value,
    'forceDeleteReviewed': forceDeleteReviewed,
    'switchAfterCreate': switchAfterCreate,
  };
}

enum RemoteAction {
  add,
  rename,
  remove,
  setFetchUrl,
  addPushUrl,
  removePushUrl,
}

final class ConfigureIdentity extends GitMutation {
  const ConfigureIdentity(
    this.name,
    this.email, {
    required super.expectedHead,
    required super.expectedIndex,
  });
  final String name, email;
  @override
  String get kind => 'identity';
  @override
  Json get fields => {'name': name, 'email': email};
}

final class RemoteMutation extends GitMutation {
  const RemoteMutation(
    this.action,
    this.name, {
    required super.expectedHead,
    required super.expectedIndex,
    this.value,
    this.expectedConfiguration,
  });
  final RemoteAction action;
  final String name;
  final String? value, expectedConfiguration;
  @override
  String get kind => 'remote';
  @override
  Json get fields => {
    'action': action.name,
    'name': name,
    'value': value,
    'expectedConfiguration': expectedConfiguration,
  };
}

enum TagAction { create, delete }

final class TagMutation extends GitMutation {
  const TagMutation(
    this.action,
    this.name, {
    required super.expectedHead,
    required super.expectedIndex,
    required this.target,
    this.annotated = false,
    this.sign,
    this.message = '',
    this.expectedTip,
  });
  final TagAction action;
  final String name, message;
  final GitOid target;
  final GitOid? expectedTip;
  final bool annotated;
  final bool? sign;
  @override
  String get kind => 'tag';
  @override
  Json get fields => {
    'action': action.name,
    'name': name,
    'target': target.value,
    'annotated': annotated,
    'sign': sign,
    'message': message,
    'expectedTip': expectedTip?.value,
  };
}

final class FetchRemote extends GitMutation {
  const FetchRemote(
    this.remote, {
    required super.expectedHead,
    required super.expectedIndex,
    this.prune = false,
  });
  final String remote;
  final bool prune;
  @override
  String get kind => 'fetch';
  @override
  Json get fields => {'remote': remote, 'prune': prune};
}

enum PullStrategy { fastForwardOnly, merge, rebase }

final class FetchPushDestination extends GitMutation {
  const FetchPushDestination(
    this.reviewToken, {
    required super.expectedHead,
    required super.expectedIndex,
  });
  final String reviewToken;
  @override
  String get kind => 'fetchPushDestination';
  @override
  Json get fields => {'reviewToken': reviewToken};
}

final class PullRemote extends GitMutation {
  const PullRemote(
    this.remote,
    this.branch,
    this.strategy, {
    required super.expectedHead,
    required super.expectedIndex,
  });
  final String remote, branch;
  final PullStrategy strategy;
  @override
  bool get replacesWorkingFiles => true;
  @override
  String get kind => 'pull';
  @override
  Json get fields => {
    'remote': remote,
    'branch': branch,
    'strategy': strategy.name,
  };
}

final class PushReviewed extends GitMutation {
  const PushReviewed(
    this.reviewToken, {
    required super.expectedHead,
    required super.expectedIndex,
    this.forceWithLease = false,
    this.setUpstream = false,
    this.tags = const [],
  });
  final String reviewToken;
  final bool forceWithLease, setUpstream;
  final List<String> tags;
  @override
  String get kind => 'push';
  @override
  Json get fields => {
    'reviewToken': reviewToken,
    'forceWithLease': forceWithLease,
    'setUpstream': setUpstream,
    'tags': tags,
  };
}

enum MergePolicy { fastForward, noFastForward, fastForwardOnly, squash }

final class DeleteRemoteReference extends GitMutation {
  const DeleteRemoteReference(
    this.reviewToken, {
    required super.expectedHead,
    required super.expectedIndex,
  });
  final String reviewToken;
  @override
  String get kind => 'deleteRemoteReference';
  @override
  Json get fields => {'reviewToken': reviewToken};
}

final class MergeRevision extends GitMutation {
  const MergeRevision(
    this.source, {
    required super.expectedHead,
    required super.expectedIndex,
    this.policy = MergePolicy.fastForward,
    this.stopBeforeCommit = false,
    this.message,
  });
  final GitOid source;
  final MergePolicy policy;
  final bool stopBeforeCommit;
  final String? message;
  @override
  bool get replacesWorkingFiles => true;
  @override
  String get kind => 'merge';
  @override
  Json get fields => {
    'source': source.value,
    'policy': policy.name,
    'stopBeforeCommit': stopBeforeCommit,
    'message': message,
  };
}

final class PickCommits extends GitMutation {
  const PickCommits(
    this.commits, {
    required super.expectedHead,
    required super.expectedIndex,
    this.noCommit = false,
    this.mainline,
    this.revert = false,
  });
  final List<GitOid> commits;
  final int? mainline;
  final bool noCommit, revert;
  @override
  bool get replacesWorkingFiles => true;
  @override
  String get kind => 'pick';
  @override
  Json get fields => {
    'commits': commits.map((e) => e.value).toList(),
    'noCommit': noCommit,
    'mainline': mainline,
    'revert': revert,
  };
}

final class ContinueGitOperation extends GitMutation {
  const ContinueGitOperation(
    this.operation,
    this.action, {
    required super.expectedHead,
    required super.expectedIndex,
  });
  final GitOperationKind operation;
  final GitContinuation action;
  @override
  bool get replacesWorkingFiles => true;
  @override
  String get kind => 'continue';
  @override
  Json get fields => {'operation': operation.name, 'action': action.name};
}

enum RebaseAction { pick, reword, edit, squash, fixup, drop }

final class RebaseStep {
  const RebaseStep(this.action, this.commit);
  final RebaseAction action;
  final GitOid commit;
  Json toJson() => {'action': action.name, 'commit': commit.value};
  factory RebaseStep.fromJson(Json j) => RebaseStep(
    RebaseAction.values.byName(j['action'] as String),
    GitOid(j['commit'] as String),
  );
}

final class RebaseCommits extends GitMutation {
  const RebaseCommits({
    required super.expectedHead,
    required super.expectedIndex,
    this.boundary,
    this.onto,
    this.root = false,
    this.interactive = false,
    this.preserveMerges = false,
    this.autosquash = false,
    this.steps = const [],
    this.planToken,
  });
  final GitOid? boundary, onto;
  final bool root, interactive, preserveMerges, autosquash;
  final List<RebaseStep> steps;
  final String? planToken;
  @override
  bool get replacesWorkingFiles => true;
  @override
  String get kind => 'rebase';
  @override
  Json get fields => {
    'boundary': boundary?.value,
    'onto': onto?.value,
    'root': root,
    'interactive': interactive,
    'preserveMerges': preserveMerges,
    'autosquash': autosquash,
    'steps': steps.map((e) => e.toJson()).toList(),
    'planToken': planToken,
  };
}

enum StashAction { create, apply, pop, drop, branch }

final class StashMutation extends GitMutation {
  const StashMutation(
    this.action, {
    required super.expectedHead,
    required super.expectedIndex,
    this.identity,
    this.message = '',
    this.paths = const [],
    this.includeUntracked = false,
    this.keepIndex = false,
    this.stagedOnly = false,
    this.restoreIndex = false,
    this.branchName,
  });
  final StashAction action;
  final GitOid? identity;
  final String message;
  final List<RepoPath> paths;
  final bool includeUntracked, keepIndex, stagedOnly, restoreIndex;
  final String? branchName;
  @override
  bool get replacesWorkingFiles => action != StashAction.drop;
  @override
  String get kind => 'stash';
  @override
  Json get fields => {
    'action': action.name,
    'identity': identity?.value,
    'message': message,
    'paths': paths.map((e) => e.toJson()).toList(),
    'includeUntracked': includeUntracked,
    'keepIndex': keepIndex,
    'stagedOnly': stagedOnly,
    'restoreIndex': restoreIndex,
    'branchName': branchName,
  };
}

enum WorktreeAction { create, move, remove, lock, unlock }

final class WorktreeMutation extends GitMutation {
  const WorktreeMutation(
    this.action,
    this.path, {
    required super.expectedHead,
    required super.expectedIndex,
    this.destination,
    this.branch,
    this.start,
    this.forceReviewed = false,
  });
  final WorktreeAction action;
  final String path;
  final String? destination, branch;
  final GitOid? start;
  final bool forceReviewed;
  @override
  bool get replacesWorkingFiles => true;
  @override
  String get kind => 'worktree';
  @override
  Json get fields => {
    'action': action.name,
    'path': path,
    'destination': destination,
    'branch': branch,
    'start': start?.value,
    'forceReviewed': forceReviewed,
  };
}

enum SubmoduleAction {
  initialize,
  updateRecorded,
  updateRemote,
  synchronize,
  stagePointer,
}

final class SubmoduleMutation extends GitMutation {
  const SubmoduleMutation(
    this.action,
    this.paths, {
    required super.expectedHead,
    required super.expectedIndex,
    this.recursive = false,
  });
  final SubmoduleAction action;
  final List<RepoPath> paths;
  final bool recursive;
  @override
  bool get replacesWorkingFiles =>
      action != SubmoduleAction.stagePointer &&
      action != SubmoduleAction.synchronize;
  @override
  String get kind => 'submodule';
  @override
  Json get fields => {
    'action': action.name,
    'paths': paths.map((e) => e.toJson()).toList(),
    'recursive': recursive,
  };
}

enum RestoreTarget { workingTree, staged, both }

enum ResetMode { soft, mixed, hard, keep }

final class RestorePaths extends GitMutation {
  const RestorePaths(
    this.paths, {
    required super.expectedHead,
    required super.expectedIndex,
    this.revision,
    this.target = RestoreTarget.workingTree,
    this.discardUntracked = false,
    this.contentTokens = const {},
  });
  final List<RepoPath> paths;
  final GitOid? revision;
  final RestoreTarget target;
  final bool discardUntracked;
  final Map<String, String> contentTokens;
  @override
  bool get replacesWorkingFiles => target != RestoreTarget.staged;
  @override
  String get kind => 'restore';
  @override
  Json get fields => {
    'paths': paths.map((e) => e.toJson()).toList(),
    'revision': revision?.value,
    'target': target.name,
    'discardUntracked': discardUntracked,
    'contentTokens': contentTokens,
  };
}

final class RestoreFileRevision extends GitMutation {
  const RestoreFileRevision(
    this.source,
    this.target,
    this.revision, {
    required this.expectedWorking,
    required super.expectedHead,
    required super.expectedIndex,
  });
  final RepoPath source, target;
  final GitOid revision;
  final String expectedWorking;
  @override
  bool get replacesWorkingFiles => true;
  @override
  String get kind => 'restoreFileRevision';
  @override
  Json get fields => {
    'source': source.toJson(),
    'target': target.toJson(),
    'revision': revision.value,
    'expectedWorking': expectedWorking,
  };
}

final class ResetBranch extends GitMutation {
  const ResetBranch(
    this.revision,
    this.mode, {
    required super.expectedHead,
    required super.expectedIndex,
    this.expectedWorkingToken,
  });
  final GitOid revision;
  final ResetMode mode;
  final String? expectedWorkingToken;
  @override
  bool get replacesWorkingFiles =>
      mode == ResetMode.hard || mode == ResetMode.keep;
  @override
  String get kind => 'reset';
  @override
  Json get fields => {
    'revision': revision.value,
    'mode': mode.name,
    'expectedWorkingToken': expectedWorkingToken,
  };
}

enum ConflictChoice { edited, left, right, delete, gitlink }

final class ResolveConflict extends GitMutation {
  ResolveConflict(
    this.path,
    this.choice, {
    required super.expectedHead,
    required super.expectedIndex,
    required this.expectedWorking,
    required this.expectedStages,
    this.bytes,
    this.mode,
    this.gitlink,
    this.stageResult = true,
  });
  final RepoPath path;
  final ConflictChoice choice;
  final String expectedWorking;
  final Map<int, String> expectedStages;
  final Uint8List? bytes;
  final String? mode;
  final GitOid? gitlink;
  final bool stageResult;
  @override
  bool get replacesWorkingFiles => true;
  @override
  String get kind => 'resolve';
  @override
  Json get fields => {
    'path': path.toJson(),
    'choice': choice.name,
    'expectedWorking': expectedWorking,
    'expectedStages': expectedStages.map((k, v) => MapEntry('$k', v)),
    'mode': mode,
    'gitlink': gitlink?.value,
    'stageResult': stageResult,
  };
}

sealed class GitCreation {
  const GitCreation(this.destination);
  final String destination;
  Json toJson();
}

final class CloneRepository extends GitCreation {
  const CloneRepository(
    this.source,
    super.destination, {
    this.branch,
    this.recurseSubmodules = false,
  });
  final String source;
  final String? branch;
  final bool recurseSubmodules;
  @override
  Json toJson() => {
    'kind': 'clone',
    'source': source,
    'destination': destination,
    'branch': branch,
    'recurseSubmodules': recurseSubmodules,
  };
}

final class InitializeRepository extends GitCreation {
  const InitializeRepository(super.destination, {this.initialBranch});
  final String? initialBranch;
  @override
  Json toJson() => {
    'kind': 'init',
    'destination': destination,
    'initialBranch': initialBranch,
  };
}

final class GitCreationOutcome {
  const GitCreationOutcome({
    required this.phase,
    this.repository,
    this.error,
    this.createdDirectory = false,
    this.destinationStillExists = false,
  });
  final GitOperationPhase phase;
  final RepositoryId? repository;
  final GitException? error;
  final bool createdDirectory, destinationStillExists;
  Json toJson() => {
    'phase': phase.name,
    'repository': repository?.toJson(),
    'error': error?.toJson(),
    'createdDirectory': createdDirectory,
    'destinationStillExists': destinationStillExists,
  };
  factory GitCreationOutcome.fromJson(Json j) => GitCreationOutcome(
    phase: GitOperationPhase.values.byName(j['phase'] as String),
    repository: j['repository'] == null
        ? null
        : RepositoryId.fromJson(j['repository'] as Json),
    error: j['error'] == null
        ? null
        : GitException.fromJson(j['error'] as Json),
    createdDirectory: j['createdDirectory'] == true,
    destinationStillExists: j['destinationStillExists'] == true,
  );
}
