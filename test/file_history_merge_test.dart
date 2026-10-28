import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:busystack_git/busystack_git.dart';
import 'package:busystack_git/src/history_workflows.dart'
    show parseFollowHistory;
import 'package:test/test.dart';

import 'support/repository_fixture.dart';
import 'support/isolated_runner.dart';

void main() {
  test(
    'unborn file history is empty while an unavailable requested commit remains an error',
    () async {
      final f = await RepositoryFixture.create();
      addTearDown(f.close);
      final page = await f.engine.inspect(
        f.repository,
        GitInspection(
          GitInspectionKind.fileHistory,
          path: RepoPath.text('not-yet-committed.md'),
        ),
      );
      expect(page['entries'], isEmpty);
      expect(page['revision'], isNull);
      expect(page['hasMore'], isFalse);
      await expectLater(
        f.engine.inspect(
          f.repository,
          GitInspection(
            GitInspectionKind.fileHistory,
            path: RepoPath.text('not-yet-committed.md'),
            revision: GitOid('f' * 40),
          ),
        ),
        throwsA(isA<GitException>()),
      );
    },
  );
  test(
    'shallow file history retains actual merge parents instead of inventing a root comparison',
    () async {
      final f = await RepositoryFixture.create();
      addTearDown(f.close);
      await f.commit('file.md', utf8.encode('base\n'), 'Base');
      await f.git(['branch', 'side']);
      await f.commit('main.txt', utf8.encode('main'), 'Main');
      await f.git(['switch', 'side']);
      await f.commit('file.md', utf8.encode('side\n'), 'Side');
      final side = GitOid(await f.git(['rev-parse', 'HEAD']));
      await f.git(['switch', 'main']);
      final main = GitOid(await f.git(['rev-parse', 'HEAD']));
      await f.git(['merge', '--no-ff', 'side', '-m', 'Merge']);
      final target = '${f.directory.path}/shallow';
      await f.git(['clone', '--depth=1', '--no-local', f.root.path, target]);
      final shallow = (await f.engine.discover(target))!;
      final page = await f.engine.inspect(
        shallow,
        GitInspection(
          GitInspectionKind.fileHistory,
          path: RepoPath.text('file.md'),
          limit: 1,
        ),
      );
      final row = (page['entries'] as List).single as Json;
      final commit = GitCommit.fromJson(row['commit'] as Json);
      expect(commit.parents, [main, side]);
      expect(commit.boundary, isTrue);
      expect(
        (await f.engine.content(
          shallow,
          RepoPath.text('file.md'),
          ContentVersion(ContentKind.commit, revision: commit.oid),
        )).text,
        'side\n',
      );
      for (final parent in commit.parents) {
        await expectLater(
          f.engine.changedFiles(shallow, commit.oid, parent: parent),
          throwsA(
            isA<GitException>().having(
              (error) => error.code,
              'unavailable actual parent',
              GitErrorCode.missingContent,
            ),
          ),
        );
      }
    },
  );
  for (final status in ['MM', 'DD', 'RR']) {
    test('combined $status records have exactly one lossless result path', () {
      final path = RepoPath([0xff, 9, 110, 10, 109]);
      List<int> record(String id, String status, RepoPath path) => [
        ...utf8.encode(
          '\x00BUSYSTACK_COMMIT\x00${[id, '${'a' * 40} ${'b' * 40}', 'Fixture', 'fixture@example.invalid', '2026-10-28T00:00:00Z', 'Fixture', 'fixture@example.invalid', '2026-10-28T00:00:00Z', 'subject', 'message'].join('\x00')}\x00\n$status\x00',
        ),
        ...path.bytes,
        0,
      ];
      final rows = parseFollowHistory([
        ...record('c' * 40, status, path),
        ...record('d' * 40, 'MM', path),
      ], path);
      expect(rows, hasLength(2));
      expect(RepoPath.fromJson(rows.first['pathAtCommit']), path);
      expect(RepoPath.fromJson(rows.first['pathInParent']), path);
      expect(rows.first['status'], status);
      expect(rows.first['deleted'], status == 'DD');
      expect(
        GitCommit.fromJson(rows.last['commit'] as Json).oid,
        GitOid('d' * 40),
      );
    });
  }

  for (final independent in [false, true]) {
    test(
      'header-only merge preserves actual deletion independent=$independent',
      () async {
        final f = await RepositoryFixture.create();
        addTearDown(f.close);
        final bytes = utf8.encode('reviewed deleted content\r\n');
        await f.commit('file.md', bytes, 'Base');
        await f.git(['branch', 'side']);
        if (independent) {
          await f.git(['rm', 'file.md']);
          await f.git(['commit', '-m', 'Main deletes']);
        } else
          await f.commit('other.txt', utf8.encode('main'), 'Main unrelated');
        await f.git(['switch', 'side']);
        await f.git(['rm', 'file.md']);
        await f.git(['commit', '-m', 'Side deletes']);
        await f.git(['switch', 'main']);
        await f.git(['merge', '--no-ff', 'side', '-m', 'Merge deletion']);
        final tip = GitOid(await f.git(['rev-parse', 'HEAD']));
        final page = await f.engine.inspect(
          f.repository,
          GitInspection(
            GitInspectionKind.fileHistory,
            path: RepoPath.text('file.md'),
            limit: 1,
          ),
        );
        final row = (page['entries'] as List).single as Json;
        expect(GitCommit.fromJson(row['commit'] as Json).oid, tip);
        expect(
          RepoPath.fromJson(row['pathAtCommit']),
          RepoPath.text('file.md'),
        );
        expect(row['deleted'], isTrue);
        expect(
          (await f.engine.content(
            f.repository,
            RepoPath.text('file.md'),
            ContentVersion(ContentKind.commit, revision: tip),
          )).availability,
          ContentAvailability.absent,
        );
        expect(page['hasMore'], isTrue);
      },
    );
  }

  for (final failure in ['cancel', 'missing-tree']) {
    test(
      'merge path metadata preserves $failure instead of publishing an empty file',
      () async {
        final f = await RepositoryFixture.create();
        addTearDown(f.close);
        final bytes = utf8.encode('stable text\r\nwithout final newline');
        await f.commit('old.md', bytes, 'Base');
        await f.git(['switch', '-c', 'feature']);
        await f.git(['mv', 'old.md', 'new.md']);
        await f.git(['commit', '-m', 'Rename']);
        await f.git(['switch', 'main']);
        await f.commit('other.txt', utf8.encode('other'), 'Unrelated');
        await f.git(['merge', '--no-ff', 'feature', '-m', 'Merge rename']);
        final tip = GitOid(await f.git(['rev-parse', 'HEAD']));
        final tree = await f.git(['rev-parse', 'HEAD^{tree}']);
        final cancellation = GitCancellation();
        final commands = <List<String>>[];
        var injected = false;
        final engine = GitEngine(
          authorize: (_) => true,
          runner: IsolatedGitRunner(
            f.home,
            beforeRun: (args, env) async {
              commands.add(List.of(args));
              if (!injected &&
                  ((failure == 'cancel' && args.contains('diff-tree')) ||
                      (failure == 'missing-tree' &&
                          args.contains('ls-tree') &&
                          args.contains(tip.value)))) {
                injected = true;
                if (failure == 'cancel')
                  cancellation.cancel();
                else
                  await File(
                    '${f.repository.commonDir}/objects/${tree.substring(0, 2)}/${tree.substring(2)}',
                  ).rename('${f.directory.path}/held-tree');
              }
            },
          ),
        );
        await expectLater(
          engine.inspect(
            f.repository,
            GitInspection(
              GitInspectionKind.fileHistory,
              path: RepoPath.text('new.md'),
              limit: 1,
            ),
            cancellation: cancellation,
          ),
          throwsA(
            isA<GitException>().having(
              (error) => error.code,
              'preserved error category',
              failure == 'cancel'
                  ? GitErrorCode.cancelled
                  : GitErrorCode.commandFailed,
            ),
          ),
        );
        expect(injected, isTrue);
        expect(
          commands.where(
            (args) => args.contains('cat-file') && args.contains('--batch'),
          ),
          hasLength(1),
          reason:
              'Only one bounded batch of returned commit headers is read, never file blobs',
        );
      },
    );
  }

  test(
    'unresolved cumulative merge renames report unavailable instead of a guessed deletion',
    () async {
      final f = await RepositoryFixture.create();
      addTearDown(f.close);
      var path = 'file-0.md';
      final lines = List.generate(
        100,
        (i) => 'original paragraph ${i.toString().padLeft(3, '0')} long prose',
      );
      await f.commit(path, utf8.encode(lines.join('\n')), 'Base');
      final commands = <List<String>>[];
      for (var step = 1; step <= 4; step++) {
        final base = await f.git(['rev-parse', 'HEAD']);
        await f.git(['switch', '-c', 'left-$step']);
        await f.commit('left-$step.txt', utf8.encode('left'), 'Left $step');
        await f.git(['switch', '-c', 'right-$step', base]);
        await f.commit('right-$step.txt', utf8.encode('right'), 'Right $step');
        await f.git(['merge', '--no-ff', '--no-commit', 'left-$step']);
        final next = 'file-$step.md';
        await f.git(['mv', path, next]);
        final start = step.isOdd ? 0 : 40;
        for (var i = start; i < start + 40; i++)
          lines[i] =
              'changed-$step paragraph ${i.toString().padLeft(3, '0')} long prose';
        await File('${f.root.path}/$next').writeAsString(lines.join('\n'));
        await f.git(['add', '--', next]);
        await f.git(['commit', '-m', 'Merge rename $step']);
        path = next;
      }
      final before = await File('${f.root.path}/$path').readAsBytes();
      final engine = GitEngine(
        authorize: (_) => true,
        runner: IsolatedGitRunner(
          f.home,
          beforeRun: (args, env) async {
            commands.add(List.of(args));
          },
        ),
      );
      await expectLater(
        engine.inspect(
          f.repository,
          GitInspection(
            GitInspectionKind.fileHistory,
            path: RepoPath.text(path),
            offset: 2,
            limit: 1,
          ),
        ),
        throwsA(
          isA<GitException>().having(
            (error) => error.code,
            'unavailable lineage',
            GitErrorCode.missingContent,
          ),
        ),
      );
      expect(
        commands.where((args) => args.contains('log')).single,
        contains('--max-count=4'),
      );
      expect(
        commands.where((args) => args.contains('diff-tree')).length,
        lessThanOrEqualTo(3),
      );
      expect(await File('${f.root.path}/$path').readAsBytes(), before);
    },
  );

  test(
    'sparse merge path work is bounded to the returned page and nearest immutable anchors',
    () async {
      final f = await RepositoryFixture.create();
      addTearDown(f.close);
      await f.commit('old.md', utf8.encode('same\n'), 'Base');
      await f.git(['switch', '-c', 'feature']);
      await f.git(['mv', 'old.md', 'new.md']);
      await f.git(['commit', '-m', 'Rename']);
      await f.git(['switch', 'main']);
      await f.commit('main.txt', utf8.encode('main'), 'Main');
      await f.git(['merge', '--no-ff', 'feature', '-m', 'Merge']);
      final commands = <List<String>>[];
      final engine = GitEngine(
        authorize: (_) => true,
        runner: IsolatedGitRunner(
          f.home,
          beforeRun: (args, env) async {
            commands.add(List.of(args));
          },
        ),
      );
      final page = await engine.inspect(
        f.repository,
        GitInspection(
          GitInspectionKind.fileHistory,
          path: RepoPath.text('new.md'),
          limit: 1,
        ),
      );
      final immutableTip = GitOid(page['revision'] as String);
      expect(immutableTip, GitOid(await f.git(['rev-parse', 'HEAD'])));
      await f.commit(
        'new.md',
        utf8.encode('new HEAD text\n'),
        'Advance HEAD after first page',
      );
      expect((page['entries'] as List).single['deleted'], isFalse);
      expect(
        commands.where((args) => args.contains('log')).single,
        contains('--max-count=2'),
      );
      expect(
        commands.where((args) => args.contains('diff-tree')).length,
        lessThanOrEqualTo(3),
      );
      expect(
        commands.where((args) => args.contains('ls-tree')).length,
        lessThanOrEqualTo(7),
      );
      commands.clear();
      await engine.inspect(
        f.repository,
        GitInspection(
          GitInspectionKind.fileHistory,
          path: RepoPath.text('new.md'),
          revision: immutableTip,
          offset: 1,
          limit: 1,
        ),
      );
      final pageCommand = commands.where((args) => args.contains('log')).single;
      expect(pageCommand, contains(immutableTip.value));
      expect(pageCommand, isNot(contains('HEAD')));
      expect(
        commands.where((args) => args.contains('diff-tree')),
        isEmpty,
        reason:
            'Skipped merge prefix must not trigger path-resolution comparisons',
      );
      expect(
        commands.where((args) => args.contains('ls-tree')),
        isEmpty,
        reason: 'An explicit ordinary Git row already names its exact paths',
      );
    },
  );
  for (final raw in [false, true]) {
    test(
      'nested inherited and merge-created renames preserve each paged historical path raw=$raw',
      () async {
        final f = await RepositoryFixture.create();
        addTearDown(f.close);
        final notes = RepoPath.text('notes.md');
        final old = raw
            ? RepoPath([0xff, 111, 108, 100])
            : RepoPath.text('東京-old.md');
        final current = raw
            ? RepoPath([0xfe, 110, 101, 119])
            : RepoPath.text('日本語-new.md');
        final bytes = utf8.encode('one 東京\r\ntwo\r\nend without newline');
        final base = await f.commit(notes.utf8Path!, bytes, 'Base');
        final runner = IsolatedGitRunner(f.home);
        Future<void> move(RepoPath from, RepoPath to) async {
          final result = await runner.run(
            ['mv', '--', from.utf8Path ?? '', to.utf8Path ?? ''],
            cwd: f.root.path,
            byteArguments: {
              if (from.utf8Path == null) 2: from.bytes,
              if (to.utf8Path == null) 3: to.bytes,
            },
          );
          expect(result.success, isTrue, reason: result.diagnostic);
        }

        await f.git(['switch', '-c', 'feature']);
        await move(notes, old);
        await f.git(['commit', '-m', 'Rename on side branch']);
        final renamed = GitOid(await f.git(['rev-parse', 'HEAD']));
        await f.git(['switch', 'main']);
        await f.commit('main.txt', utf8.encode('main'), 'Main unrelated');
        await f.git(['merge', '--no-ff', 'feature', '-m', 'Inherit rename']);
        final inherited = GitOid(await f.git(['rev-parse', 'HEAD']));
        await f.git(['switch', '-c', 'branch-A']);
        await f.commit('A.txt', utf8.encode('A'), 'A unrelated');
        await f.git(['switch', '-c', 'branch-B', inherited.value]);
        await f.commit('B.txt', utf8.encode('B'), 'B unrelated');
        await f.git(['merge', '--no-ff', '--no-commit', 'branch-A']);
        await move(old, current);
        await f.git(['commit', '-m', 'Rename in merge']);
        final tip = GitOid(await f.git(['rev-parse', 'HEAD']));
        final expected = [
          (tip, current),
          (inherited, old),
          (renamed, old),
          (base, notes),
        ];
        for (var offset = 0; offset < expected.length; offset++) {
          final page = await f.engine.inspect(
            f.repository,
            GitInspection(
              GitInspectionKind.fileHistory,
              path: current,
              offset: offset,
              limit: 1,
            ),
          );
          final row = (page['entries'] as List).single as Json;
          expect(
            GitCommit.fromJson(row['commit'] as Json).oid,
            expected[offset].$1,
          );
          expect(RepoPath.fromJson(row['pathAtCommit']), expected[offset].$2);
          expect(row['deleted'], isFalse);
          expect(page['hasMore'], offset + 1 < expected.length);
          expect(
            (await f.engine.content(
              f.repository,
              RepoPath.fromJson(row['pathAtCommit']),
              ContentVersion(ContentKind.commit, revision: expected[offset].$1),
            )).bytes,
            bytes,
          );
        }
        for (final parent in GitCommit.fromJson(
          ((await f.engine.inspect(
                        f.repository,
                        GitInspection(
                          GitInspectionKind.fileHistory,
                          path: current,
                          limit: 1,
                        ),
                      ))['entries']
                      as List)
                  .single['commit']
              as Json,
        ).parents) {
          final files = await f.engine.changedFiles(
            f.repository,
            tip,
            parent: parent,
          );
          final change = files.singleWhere((file) => file.path == current);
          expect(change.originalPath, old);
          expect(
            (await f.engine.content(
              f.repository,
              old,
              ContentVersion(ContentKind.commit, revision: parent),
            )).bytes,
            bytes,
          );
        }
        final file = File.fromRawPath(
          Uint8List.fromList([
            ...utf8.encode(f.root.path),
            47,
            ...current.bytes,
          ]),
        );
        expect(await file.readAsBytes(), bytes);
      },
    );
  }
  test(
    'a rename merged from another branch retains its historical path',
    () async {
      final fixture = await RepositoryFixture.create();
      addTearDown(fixture.close);
      const oldPath = 'notes.md', newPath = 'docs/日本語-長い名前.md';
      final base =
          '${List.generate(35, (i) => 'paragraph $i 東京').join('\r\n')}\r\n';
      final root = await fixture.commit(oldPath, utf8.encode(base), 'Root');
      await fixture.git(['branch', 'feature']);
      await fixture.commit(
        'chapter.md',
        utf8.encode('Main chapter\r\n'),
        'Main',
      );
      await fixture.git(['switch', 'feature']);
      await Directory('${fixture.root.path}/docs').create();
      await fixture.git(['mv', oldPath, newPath]);
      final renamedBytes = utf8.encode(
        base.replaceFirst('paragraph 20', 'reviewed paragraph twenty'),
      );
      final renamed = await fixture.commit(
        newPath,
        renamedBytes,
        'Rename and edit',
      );
      await fixture.git(['switch', 'main']);
      await fixture.git([
        'merge',
        '--no-ff',
        '-m',
        'Merge renamed file',
        'feature',
      ]);
      final merge = GitOid(await fixture.git(['rev-parse', 'HEAD']));
      Future<Json> page(int offset) => fixture.engine.inspect(
        fixture.repository,
        GitInspection(
          GitInspectionKind.fileHistory,
          path: RepoPath.text(newPath),
          offset: offset,
          limit: 1,
        ),
      );
      final first = await page(0);
      final second = await page(1);
      final last = await page(2);
      final mergeRow = (first['entries'] as List).single as Json;
      final renameRow = (second['entries'] as List).single as Json;
      final rootRow = (last['entries'] as List).single as Json;
      expect(GitCommit.fromJson(mergeRow['commit'] as Json).oid, merge);
      expect(
        RepoPath.fromJson(mergeRow['pathAtCommit']),
        RepoPath.text(newPath),
      );
      expect(mergeRow['deleted'], isFalse);
      expect(first['hasMore'], isTrue);
      expect(GitCommit.fromJson(renameRow['commit'] as Json).oid, renamed);
      expect(
        RepoPath.fromJson(renameRow['pathAtCommit']),
        RepoPath.text(newPath),
      );
      expect(
        RepoPath.fromJson(renameRow['pathInParent']),
        RepoPath.text(oldPath),
      );
      expect(renameRow['status'], startsWith('R'));
      expect(renameRow['deleted'], isFalse);
      expect(second['hasMore'], isTrue);
      expect(GitCommit.fromJson(rootRow['commit'] as Json).oid, root);
      expect(
        RepoPath.fromJson(rootRow['pathAtCommit']),
        RepoPath.text(oldPath),
      );
      expect(last['hasMore'], isFalse);
      expect(
        (await fixture.engine.content(
          fixture.repository,
          RepoPath.fromJson(renameRow['pathAtCommit']),
          ContentVersion(ContentKind.commit, revision: renamed),
        )).bytes,
        renamedBytes,
      );
      expect(
        await File('${fixture.root.path}/$newPath').readAsBytes(),
        renamedBytes,
      );
    },
  );

  test(
    'follow history exposes merge and preserves parent-specific Unicode bytes',
    () async {
      final fixture = await RepositoryFixture.create();
      addTearDown(fixture.close);
      const path = 'chapters/東京.md';
      final base =
          '${List.generate(30, (i) => 'paragraph $i').join('\r\n')}\r\n';
      await fixture.commit(path, utf8.encode(base), 'Root');
      await fixture.git(['branch', 'side']);
      final firstText = base.replaceFirst('paragraph 2', 'main paragraph two');
      final first = await fixture.commit(path, utf8.encode(firstText), 'Main');
      await fixture.git(['switch', 'side']);
      final secondText = base.replaceFirst(
        'paragraph 25',
        'side paragraph twenty-five',
      );
      final second = await fixture.commit(
        path,
        utf8.encode(secondText),
        'Side',
      );
      await fixture.git(['switch', 'main']);
      await fixture.git([
        'merge',
        '--no-ff',
        '-m',
        'Merge reviewed parents',
        'side',
      ]);
      final merge = GitOid(await fixture.git(['rev-parse', 'HEAD']));
      final history = await fixture.engine.inspect(
        fixture.repository,
        GitInspection(GitInspectionKind.fileHistory, path: RepoPath.text(path)),
      );
      final row = (history['entries'] as List).cast<Json>().first;
      final commit = GitCommit.fromJson(row['commit'] as Json);
      expect(commit.oid, merge);
      expect(commit.parents, [first, second]);
      expect(RepoPath.fromJson(row['pathAtCommit']), RepoPath.text(path));
      for (final (parent, expected) in [
        (first, firstText),
        (second, secondText),
      ]) {
        final files = await fixture.engine.changedFiles(
          fixture.repository,
          merge,
          parent: parent,
        );
        expect(files.single.path, RepoPath.text(path));
        expect(
          (await fixture.engine.content(
            fixture.repository,
            files.single.path,
            ContentVersion(ContentKind.commit, revision: parent),
          )).bytes,
          utf8.encode(expected),
        );
      }
      expect(
        await File('${fixture.root.path}/$path').readAsString(),
        firstText.replaceFirst('paragraph 25', 'side paragraph twenty-five'),
      );
    },
  );
}
