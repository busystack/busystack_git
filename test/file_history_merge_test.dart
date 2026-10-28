import 'dart:convert';
import 'dart:io';

import 'package:busystack_git/busystack_git.dart';
import 'package:test/test.dart';

import 'support/repository_fixture.dart';

void main() {
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
