import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:busystack_git/busystack_git.dart';
import 'repository_fixture.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> rejected(Future<Object?> call, GitErrorCode code) async {
  try {
    await call;
  } on GitException catch (error) {
    check(error.code == code, 'Unexpected error: ${error.code}');
    return;
  }
  throw StateError('Request was not rejected');
}

Future<void> main(List<String> args) async {
  final fixture = await RepositoryFixture.create();
  final other = await RepositoryFixture.create();
  final caller = Isolate.current;
  final granted = <String>{fixture.repository.key};
  final seen = <String>[];
  final promptReached = Completer<void>();
  final releasePrompt = Completer<void>();
  var holdPrompt = false;
  final client = BackgroundGitClient(
    authorize: (repo) async {
      check(Isolate.current == caller, 'Authorization left the host isolate');
      seen.add(repo.key);
      return granted.contains(repo.key);
    },
    prompts: (prompt, cancellation) async {
      check(Isolate.current == caller, 'Prompt left the host isolate');
      check(
        prompt.repository == fixture.repository,
        'Prompt retargeted repository',
      );
      check(prompt.operationId.isNotEmpty, 'Prompt lacks operation binding');
      check(prompt.kind == GitPromptKind.message, 'Unexpected prompt');
      if (!promptReached.isCompleted) promptReached.complete();
      if (holdPrompt)
        await Future.any([releasePrompt.future, cancellation.whenCancelled]);
      return cancellation.isCancelled
          ? null
          : Uint8List.fromList(utf8.encode('Reviewed worker message\n'));
    },
  );
  try {
    final mode = args.single;
    for (final target in [fixture, other]) {
      await target.git(['config', 'user.name', 'Fixture']);
      await target.git(['config', 'user.email', 'fixture@example.invalid']);
    }
    final base = await fixture.commit(
      'a.md',
      utf8.encode('one\ntwo\nthree'),
      'base',
    );
    final repo = (await client.discover(fixture.root.path))!;
    check(repo == fixture.repository, 'Discovery identity changed');
    switch (mode) {
      case 'queries':
        final path = RepoPath([0xff, 0x61]);
        final file = File.fromRawPath(
          Uint8List.fromList([
            ...utf8.encode('${fixture.root.path}/'),
            ...path.bytes,
          ]),
        );
        await file.writeAsBytes([0xef, 0xbb, 0xbf, 65, 13, 10, 66]);
        final state = await client.status(repo);
        check(state.changes.single.path == path, 'Non-UTF8 path was decoded');
        final content = await client.content(
          repo,
          path,
          const ContentVersion.working(),
        );
        check(
          base64Encode(content.bytes) == base64Encode(await file.readAsBytes()),
          'Content bytes changed',
        );
        check(
          content.text == '\uFEFFA\r\nB',
          'Content text conversion changed bytes',
        );
        check(
          (await client.history(repo)).commits.single.oid == base,
          'History identity lost',
        );
        check(
          (await client.references(
            repo,
          )).any((ref) => ref.name.endsWith('/main')),
          'References missing',
        );
        check(
          (await client.changedFiles(repo, base)).single.path ==
              RepoPath.text('a.md'),
          'Changed files missing',
        );
        check(
          (await client.inspect(
                repo,
                const GitInspection(GitInspectionKind.remotes),
              ))['remotes']
              is List,
          'Inspection missing',
        );
        final patch = await client.patch(
          repo,
          GitDiffSpec(
            ContentVersion(ContentKind.commit, revision: base),
            const ContentVersion.index(),
          ),
        );
        check(patch.bytes.isEmpty, 'Equal trees produced a difference');
        final initial = Directory('${fixture.directory.path}/initialized');
        final initialized = await client.create(
          InitializeRepository(initial.path, initialBranch: 'chosen'),
        );
        check(
          initialized.error == null && initialized.repository != null,
          'Initialization failed',
        );
        check(
          (await client.status(initialized.repository!)).branch == 'chosen',
          'Initial branch changed',
        );
        check(
          (await fixture.engine.status(repo)).indexToken == state.indexToken,
          'Queries mutated the index',
        );
      case 'mutations':
        final file = File('${fixture.root.path}/a.md');
        await file.writeAsString('ONE\ntwo\nTHREE');
        await File(
          '${fixture.root.path}/b.md',
        ).writeAsString('unrelated staged\n');
        await fixture.git(['add', 'b.md']);
        final state = await client.status(repo);
        final index = await client.content(
          repo,
          RepoPath.text('a.md'),
          const ContentVersion.index(),
        );
        final working = await client.content(
          repo,
          RepoPath.text('a.md'),
          const ContentVersion.working(),
        );
        final result = await client.mutate(
          repo,
          WriteIndex(
            RepoPath.text('a.md'),
            Uint8List.fromList(utf8.encode('ONE\ntwo\nthree')),
            expectedHead: state.head,
            expectedIndex: state.indexToken,
            expectedContent: index.token,
            expectedWorktree: working.token,
          ),
        );
        check(result.completed, 'Index transaction failed: ${result.error}');
        check(
          await fixture.git(['show', ':a.md']) == 'ONE\ntwo\nthree',
          'Wrong partial index',
        );
        check(
          await fixture.git(['show', ':b.md']) == 'unrelated staged',
          'Unrelated index changed',
        );
        check(
          await file.readAsString() == 'ONE\ntwo\nTHREE',
          'Working bytes changed',
        );
        final otherState = await client.status(other.repository);
        await rejected(
          client.mutate(
            other.repository,
            CommitIndex(
              'forbidden',
              allowEmpty: true,
              expectedHead: otherState.head,
              expectedIndex: otherState.indexToken,
            ),
          ),
          GitErrorCode.trustRequired,
        );
        granted.clear();
        final fresh = await client.status(repo);
        await rejected(
          client.mutate(
            repo,
            CommitIndex(
              'revoked',
              expectedHead: fresh.head,
              expectedIndex: fresh.indexToken,
            ),
          ),
          GitErrorCode.trustRequired,
        );
        check(
          [repo.key, other.repository.key].every(seen.contains),
          'Host authorization was cached or retargeted',
        );
      case 'prompts':
        final next = await fixture.commit(
          'b.md',
          utf8.encode('second\n'),
          'second',
        );
        final state = await client.status(repo);
        final plan = await client.inspect(
          repo,
          GitInspection(GitInspectionKind.rebasePlan, revision: base),
        );
        final phases = <GitOperationPhase>[];
        final result = await client.mutate(
          repo,
          RebaseCommits(
            expectedHead: state.head,
            expectedIndex: state.indexToken,
            boundary: base,
            interactive: true,
            planToken: plan['token'] as String,
            steps: [RebaseStep(RebaseAction.reword, next)],
          ),
          onProgress: (event) {
            check(Isolate.current == caller, 'Progress left host');
            phases.add(event.phase);
          },
        );
        check(result.completed, 'Reword failed: ${result.error}');
        check(
          promptReached.isCompleted && phases.isNotEmpty,
          'Prompt/progress missing',
        );
        check(
          await fixture.git(['log', '-1', '--format=%s']) ==
              'Reviewed worker message',
          'Wrong sequencer message',
        );
        check(
          await fixture.git(['show', 'HEAD:b.md']) == 'second',
          'Reword lost content',
        );
      case 'lifecycle':
        final watching = client.watch(repo).listen((_) {});
        await watching.cancel();
        final next = await fixture.commit(
          'b.md',
          utf8.encode('second\n'),
          'second',
        );
        holdPrompt = true;
        final state = await client.status(repo);
        final plan = await client.inspect(
          repo,
          GitInspection(GitInspectionKind.rebasePlan, revision: base),
        );
        final operation = client.mutate(
          repo,
          RebaseCommits(
            expectedHead: state.head,
            expectedIndex: state.indexToken,
            boundary: base,
            interactive: true,
            planToken: plan['token'] as String,
            steps: [RebaseStep(RebaseAction.reword, next)],
          ),
        );
        await promptReached.future;
        final closed = client.close();
        final result = await operation;
        await closed.timeout(const Duration(seconds: 10));
        check(result.snapshot != null, 'Closing lost reconciliation');
        check(
          result.phase != GitOperationPhase.completed,
          'Closing a prompt fabricated success',
        );
        check(
          (await fixture.engine.status(repo)).operation.kind ==
              GitOperationKind.rebase,
          'Closing implicitly aborted the sequencer',
        );
        await rejected(client.status(repo), GitErrorCode.disconnected);
        await client.close();
        final race = BackgroundGitClient();
        final watchDone = Completer<void>();
        final subscription = race
            .watch(repo)
            .listen((_) {}, onDone: watchDone.complete);
        await race.close();
        await watchDone.future.timeout(const Duration(seconds: 5));
        await subscription.cancel();
        final unused = BackgroundGitClient();
        await unused.close();
        await rejected(
          unused.discover(fixture.root.path),
          GitErrorCode.disconnected,
        );
      case 'cancellation':
        final cancel = GitCancellation()..cancel();
        await rejected(
          client.status(repo, cancellation: cancel),
          GitErrorCode.cancelled,
        );
        final entered = Completer<void>(), unblock = Completer<void>();
        final waiting = BackgroundGitClient(
          authorize: (_) async {
            entered.complete();
            await unblock.future;
            return true;
          },
        );
        try {
          final state = await waiting.status(repo), token = GitCancellation();
          final operation = waiting.mutate(
            repo,
            CommitIndex(
              'not created',
              allowEmpty: true,
              expectedHead: state.head,
              expectedIndex: state.indexToken,
            ),
            cancellation: token,
          );
          await entered.future;
          token.cancel();
          await rejected(operation, GitErrorCode.cancelled);
          check(
            await fixture.git(['rev-parse', 'HEAD']) == base.value,
            'Cancelled authorization created a commit',
          );
        } finally {
          await waiting.close();
          unblock.complete();
        }
      default:
        throw ArgumentError('Unknown scenario');
    }
    print('PASS $mode');
  } finally {
    releasePrompt.complete();
    await client.close();
    await fixture.close();
    await other.close();
  }
}
