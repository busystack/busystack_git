@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';
import 'package:busystack_git/busystack_git.dart';
import 'package:test/test.dart';
import 'support/repository_fixture.dart';

void main() {
  test(
    'cancelled push requires reconciliation and consumes its reviewed intent',
    () async {
      final f = await RepositoryFixture.create();
      final cancellation = GitCancellation();
      try {
        final original = await f.commit(
          'note.md',
          utf8.encode('base\n'),
          'base',
        );
        final remote = '${f.directory.path}/remote.git';
        await f.git(['init', '--bare', remote]);
        await f.git(['remote', 'add', 'fixture', remote]);
        await f.git(['push', '-u', 'fixture', 'main']);
        final local = await f.commit(
          'note.md',
          utf8.encode('local\n'),
          'local',
        );
        final marker = File('${f.directory.path}/receiving');
        expect(RegExp(r'^[a-zA-Z0-9/_-]+$').hasMatch(marker.path), isTrue);
        final hook = File('$remote/hooks/pre-receive');
        await hook.writeAsString('''#!/bin/sh
printf ready > '${marker.path}'
sleep 30
''');
        expect(
          (await Process.run('/bin/chmod', ['0700', hook.path])).exitCode,
          0,
        );
        final plan = await f.engine.inspect(
          f.repository,
          const GitInspection(
            GitInspectionKind.pushReview,
            remote: 'fixture',
            destination: 'refs/heads/main',
          ),
        );
        final reviewed = await f.engine.status(f.repository);
        final index = await f.git(['ls-files', '--stage', '-z']);
        final request = PushReviewed(
          plan['token'] as String,
          expectedHead: reviewed.head,
          expectedIndex: reviewed.indexToken,
        );
        final pending = f.engine.mutate(
          f.repository,
          request,
          cancellation: cancellation,
        );
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!await marker.exists()) {
          if (DateTime.now().isAfter(deadline))
            fail('The real push did not reach the controlled receiver.');
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        cancellation.cancel();
        final result = await pending.timeout(const Duration(seconds: 5));
        expect(result.phase, GitOperationPhase.uncertain);
        expect(result.error?.code, GitErrorCode.cancelled);
        expect(await f.git(['rev-parse', 'HEAD']), local.value);
        expect(await f.git(['ls-files', '--stage', '-z']), index);
        expect(
          await f.git(['--git-dir=$remote', 'rev-parse', 'refs/heads/main']),
          original.value,
        );
        final repeated = await f.engine.mutate(f.repository, request);
        expect(repeated.error?.code, GitErrorCode.staleReview);
        expect(
          await f.git(['--git-dir=$remote', 'rev-parse', 'refs/heads/main']),
          original.value,
        );
      } finally {
        cancellation.cancel();
        await f.close();
      }
    },
  );
}
