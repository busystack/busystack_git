import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:busystack_git/busystack_git.dart';
import 'package:test/test.dart';

import 'support/isolated_runner.dart';

void main() {
  late Directory fixture, root;
  late GitEngine engine;
  late RepositoryId repo;

  Future<List<int>> git(List<String> arguments, {bool check = true}) async {
    final result = await Process.run(
      '/usr/bin/git',
      arguments,
      workingDirectory: root.path,
      stdoutEncoding: null,
      environment: {
        'HOME': '${fixture.path}/home',
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': '/dev/null',
        'GIT_AUTHOR_NAME': 'Fixture',
        'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
        'GIT_COMMITTER_NAME': 'Fixture',
        'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
      },
    );
    if (check && result.exitCode != 0)
      fail('${arguments.first}: ${result.stderr}');
    return result.stdout as List<int>;
  }

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('bsg-utf8-');
    root = await Directory('${fixture.path}/repo').create();
    await IsolatedGitRunner.prepare('${fixture.path}/home');
    await git(['init', '-b', 'main']);
    await git(['config', 'core.autocrlf', 'false']);
    engine = GitEngine(
      authorize: (_) => true,
      runner: IsolatedGitRunner('${fixture.path}/home'),
    );
    repo = (await engine.discover(root.path))!;
  });
  tearDown(() async => fixture.delete(recursive: true));

  test('content text preserves one or multiple leading BOMs exactly', () {
    for (final text in [
      '',
      'plain\n',
      '\uFEFF',
      '\uFEFFprose\r\n',
      '\uFEFF\uFEFFprose',
    ]) {
      final bytes = utf8.encode(text);
      final content = GitContent(
        path: RepoPath.text('a'),
        version: const ContentVersion.index(),
        availability: ContentAvailability.present,
        token: 'fixture',
        bytes: bytes,
      );
      expect(content.text, text);
      expect(utf8.encode(content.text!), bytes);
    }
    expect(
      GitContent(
        path: RepoPath.text('a'),
        version: const ContentVersion.index(),
        availability: ContentAvailability.present,
        token: 'fixture',
        bytes: [0xef, 0xbb, 0xbf, 0xff],
      ).text,
      isNull,
    );
  });

  test(
    'leading BOM filenames remain distinct in mutations and historical reads',
    () async {
      final paths = ['\uFEFFnotes.md', 'notes.md', r'\uFEFFnotes.md'];
      for (var i = 0; i < paths.length; i++) {
        await File('${root.path}/${paths[i]}').writeAsString('File $i\n');
      }
      final before = await engine.status(repo);
      expect(before.changes.map((c) => c.path.utf8Path).toSet(), paths.toSet());
      expect(before.changes.map((c) => c.path.display).toSet(), hasLength(3));
      final target = before.changes
          .singleWhere((c) => c.path.utf8Path == paths.first)
          .path;
      expect(target.bytes, utf8.encode(paths.first));
      expect(target.display, r'\uFEFFnotes.md');
      final staged = await engine.mutate(
        repo,
        StagePaths(
          [target],
          expectedHead: before.head,
          expectedIndex: before.indexToken,
        ),
      );
      expect(staged.completed, isTrue, reason: '${staged.error}');
      expect(await git(['ls-files', '-z']), [...target.bytes, 0]);
      await git(['add', '.']);
      await git(['commit', '-m', '\uFEFFExact names and message']);
      final head = (await engine.status(repo)).head!;
      for (var i = 0; i < paths.length; i++) {
        final content = await engine.content(
          repo,
          RepoPath.text(paths[i]),
          ContentVersion(ContentKind.commit, revision: head),
        );
        expect(content.bytes, utf8.encode('File $i\n'));
      }
      final history = await engine.history(repo);
      expect(history.commits.single.subject, '\uFEFFExact names and message');
    },
  );

  for (final fixtureCase in [
    (
      name: 'LF with final newline',
      ending: '\n',
      finalNewline: true,
      normalize: false,
    ),
    (
      name: 'LF without final newline',
      ending: '\n',
      finalNewline: false,
      normalize: false,
    ),
    (
      name: 'CRLF with final newline',
      ending: '\r\n',
      finalNewline: true,
      normalize: false,
    ),
    (
      name: 'CRLF without final newline',
      ending: '\r\n',
      finalNewline: false,
      normalize: false,
    ),
    (
      name: 'normalized CRLF with final newline',
      ending: '\r\n',
      finalNewline: true,
      normalize: true,
    ),
    (
      name: 'normalized CRLF without final newline',
      ending: '\r\n',
      finalNewline: false,
      normalize: true,
    ),
  ]) {
    test(
      'BOM line staging and unstaging preserves ${fixtureCase.name}',
      () async {
        final diskEnding = fixtureCase.ending;
        final indexEnding = fixtureCase.normalize ? '\n' : diskEnding;
        String text(String first, String last, String ending) =>
            '\uFEFF$first${ending}two$ending$last${fixtureCase.finalNewline ? ending : ''}';
        final original = text('one', 'three', diskEnding);
        final working = text('ONE', 'THREE', diskEnding);
        await File('${root.path}/.gitattributes').writeAsString(
          fixtureCase.normalize ? '*.md text eol=crlf\n' : '*.md -text\n',
        );
        final file = File('${root.path}/prose.md');
        await file.writeAsBytes(utf8.encode(original));
        await git(['add', '.']);
        await git(['commit', '-m', 'Original BOM prose']);
        await file.writeAsBytes(utf8.encode(working));
        final unrelated = [0xff, 0, 0xef, 0xbb, 0xbf, 10];
        await File('${root.path}/unrelated.bin').writeAsBytes(unrelated);
        await git(['add', 'unrelated.bin']);
        final path = RepoPath.text('prose.md');
        final before = await engine.status(repo);
        final index = await engine.content(
          repo,
          path,
          const ContentVersion.index(),
        );
        final normalized = await engine.content(
          repo,
          path,
          const ContentVersion(ContentKind.normalizedWorking),
        );
        expect(index.text, text('one', 'three', indexEnding));
        expect(normalized.text, text('ONE', 'THREE', indexEnding));
        final diff = computeTextDiff(index.text!, normalized.text!);
        final partiallyStaged = await engine.mutate(
          repo,
          WriteIndex(
            path,
            diff.select(diff.changedIndices.take(2).toSet()),
            expectedHead: before.head,
            expectedIndex: before.indexToken,
            expectedContent: index.token,
            expectedWorktree: normalized.sourceToken,
          ),
        );
        expect(
          partiallyStaged.completed,
          isTrue,
          reason: '${partiallyStaged.error}',
        );
        expect(
          await git(['show', ':prose.md']),
          utf8.encode(text('ONE', 'three', indexEnding)),
        );
        expect(await file.readAsBytes(), utf8.encode(working));
        expect(await git(['show', ':unrelated.bin']), unrelated);

        final current = await engine.status(repo);
        final staged = await engine.content(
          repo,
          path,
          const ContentVersion.index(),
        );
        final head = await engine.content(
          repo,
          path,
          ContentVersion(ContentKind.commit, revision: current.head),
        );
        final unstage = computeTextDiff(head.text!, staged.text!);
        final unstaged = await engine.mutate(
          repo,
          WriteIndex(
            path,
            unstage.select(unstage.changedIndices.toSet(), exclude: true),
            expectedHead: current.head,
            expectedIndex: current.indexToken,
            expectedContent: staged.token,
            expectedWorktree: normalized.sourceToken,
          ),
        );
        expect(unstaged.completed, isTrue, reason: '${unstaged.error}');
        expect(
          await git(['show', ':prose.md']),
          utf8.encode(text('one', 'three', indexEnding)),
        );
        expect(await file.readAsBytes(), utf8.encode(working));
        expect(await git(['show', ':unrelated.bin']), unrelated);
      },
    );
  }

  test(
    'selecting another line does not implicitly stage a BOM addition or removal',
    () async {
      for (final hadBom in [false, true]) {
        final old = '${hadBom ? '\uFEFF' : ''}one\ntwo\nthree';
        final changed = '${hadBom ? '' : '\uFEFF'}one\ntwo\nTHREE';
        final path = RepoPath.text(hadBom ? 'removed.md' : 'added.md');
        await File('${root.path}/${path.utf8Path}').writeAsString(old);
        await git(['add', '.']);
        await git(['commit', '-m', 'BOM boundary']);
        await File('${root.path}/${path.utf8Path}').writeAsString(changed);
        final state = await engine.status(repo);
        final index = await engine.content(
          repo,
          path,
          const ContentVersion.index(),
        );
        final working = await engine.content(
          repo,
          path,
          const ContentVersion(ContentKind.normalizedWorking),
        );
        final diff = computeTextDiff(index.text!, working.text!);
        final selected = {
          for (var i = 0; i < diff.edits.length; i++)
            if (diff.edits[i].oldLine == 3 || diff.edits[i].newLine == 3) i,
        };
        final result = await engine.mutate(
          repo,
          WriteIndex(
            path,
            diff.select(selected),
            expectedHead: state.head,
            expectedIndex: state.indexToken,
            expectedContent: index.token,
            expectedWorktree: working.sourceToken,
          ),
        );
        expect(result.completed, isTrue, reason: '${result.error}');
        expect(
          await git(['show', ':${path.utf8Path}']),
          utf8.encode('${hadBom ? '\uFEFF' : ''}one\ntwo\nTHREE'),
        );
        expect(
          await File('${root.path}/${path.utf8Path}').readAsBytes(),
          utf8.encode(changed),
        );
      }
    },
  );

  test(
    'saved conflict result reopens and stages with its BOM intact',
    () async {
      final file = File('${root.path}/prose.md');
      await file.writeAsString('\uFEFFOriginal prose\n');
      await git(['add', '.']);
      await git(['commit', '-m', 'Base']);
      await git(['switch', '-c', 'incoming']);
      await file.writeAsString('\uFEFFIncoming prose\n');
      await git(['commit', '-am', 'Incoming']);
      await git(['switch', 'main']);
      await file.writeAsString('\uFEFFCurrent prose\n');
      await git(['commit', '-am', 'Current']);
      await git(['merge', 'incoming'], check: false);
      final path = RepoPath.text('prose.md');
      const resolved = '\uFEFFManually combined prose\r\n';
      for (final stage in [false, true]) {
        final state = await engine.status(repo);
        final info = await engine.inspect(
          repo,
          GitInspection(GitInspectionKind.conflict, path: path),
        );
        final stages = info['stages'] as Json;
        final outcome = await engine.mutate(
          repo,
          ResolveConflict(
            path,
            ConflictChoice.edited,
            expectedHead: state.head,
            expectedIndex: state.indexToken,
            expectedWorking: (info['working'] as Json)['token'] as String,
            expectedStages: {
              for (final e in stages.entries)
                int.parse(e.key):
                    '${(e.value as Json)['mode']}:${(e.value as Json)['oid']}',
            },
            bytes: Uint8List.fromList(utf8.encode(resolved)),
            stageResult: stage,
          ),
        );
        expect(outcome.error, isNull);
        expect(await file.readAsBytes(), utf8.encode(resolved));
        engine = GitEngine(
          authorize: (_) => true,
          runner: IsolatedGitRunner('${fixture.path}/home'),
        );
        expect(
          (await engine.content(
            repo,
            path,
            const ContentVersion.working(),
          )).text,
          resolved,
        );
      }
      expect(await git(['show', ':prose.md']), utf8.encode(resolved));
      expect((await engine.status(repo)).operation.unmerged, isFalse);
    },
  );
}
