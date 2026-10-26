import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:busystack_git/busystack_git.dart';
import 'package:test/test.dart';
import 'support/isolated_runner.dart';
import 'support/repository_fixture.dart';

/// Keep a single-file review bounded even when the repository index is large.
final class _BoundedIndexRunner implements GitRunner {
  _BoundedIndexRunner(this.inner);
  final GitRunner inner;
  final indexOutputSizes = <int>[];

  @override
  Future<GitRunResult> run(
    List<String> arguments, {
    required String cwd,
    List<int>? input,
    GitCancellation? cancellation,
    Duration? deadline,
    void Function(List<int>)? onStdout,
    void Function(String)? onProgress,
    String Function(String)? redactDiagnostic,
    Map<String, String> environment = const {},
    Map<int, List<int>> byteArguments = const {},
    int? maximumBytes,
  }) async {
    final indexQuery = arguments.contains('ls-files');
    final result = await inner.run(
      arguments,
      cwd: cwd,
      input: input,
      cancellation: cancellation,
      deadline: deadline,
      onStdout: onStdout,
      onProgress: onProgress,
      redactDiagnostic: redactDiagnostic,
      environment: environment,
      byteArguments: byteArguments,
      maximumBytes: indexQuery ? 1024 : maximumBytes,
    );
    if (indexQuery) indexOutputSizes.add(result.stdout.length);
    return result;
  }
}

void main() {
  test(
    'single-file index review stays bounded and literal in a large index',
    () async {
      final f = await RepositoryFixture.create();
      addTearDown(f.close);
      final files = await Directory('${f.root.path}/many').create();
      for (var i = 0; i < 2048; i++) {
        await File('${files.path}/document-$i.md').writeAsString('other $i\n');
      }
      final paths = [
        RepoPath.text(':(glob)*'),
        RepoPath.text('-leading dash'),
        RepoPath.text('tab\tline\n'),
        RepoPath.text('café'),
        RepoPath([0xff, 0x61]),
      ];
      for (var i = 0; i < paths.length; i++) {
        await File.fromRawPath(
          Uint8List.fromList([
            ...utf8.encode('${f.root.path}/'),
            ...paths[i].bytes,
          ]),
        ).writeAsString('selected $i\n');
      }
      await f.git(['add', '.']);
      Future<List<int>> indexBytes() async {
        final result = await Process.run(
          '/usr/bin/git',
          ['ls-files', '--stage', '-z'],
          workingDirectory: f.root.path,
          includeParentEnvironment: false,
          environment: f.environment,
          stdoutEncoding: null,
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return result.stdout as List<int>;
      }

      final before = await indexBytes();
      final runner = _BoundedIndexRunner(IsolatedGitRunner(f.home));
      final engine = GitEngine(runner: runner);
      for (var i = 0; i < paths.length; i++) {
        final content = await engine.content(
          f.repository,
          paths[i],
          const ContentVersion.index(),
        );
        expect(content.text, 'selected $i\n');
        expect(content.mode, '100644');
      }
      expect(runner.indexOutputSizes, hasLength(paths.length));
      expect(runner.indexOutputSizes, everyElement(lessThan(1024)));
      expect(await indexBytes(), before);
      expect(
        await File('${files.path}/document-2047.md').readAsString(),
        'other 2047\n',
      );

      // The same bounded query must retain all three actual unmerged stages.
      final conflicted = File('${f.root.path}/:(glob)*');
      await f.git(['commit', '-m', 'base']);
      await f.git(['switch', '-c', 'feature']);
      await conflicted.writeAsString('feature content\n');
      await f.git(['commit', '-am', 'feature']);
      await f.git(['switch', 'main']);
      await conflicted.writeAsString('main content\n');
      await f.git(['commit', '-am', 'main']);
      expect((await f.run(['merge', 'feature'])).exitCode, 1);
      final unmerged = await indexBytes();
      for (final (stage, text) in [
        (1, 'selected 0\n'),
        (2, 'main content\n'),
        (3, 'feature content\n'),
      ]) {
        final content = await engine.content(
          f.repository,
          paths.first,
          ContentVersion(ContentKind.conflictStage, stage: stage),
        );
        expect(content.text, text);
      }
      expect(
        (await engine.content(
          f.repository,
          paths.first,
          const ContentVersion.index(),
        )).availability,
        ContentAvailability.absent,
      );
      expect(await indexBytes(), unmerged);
      expect(runner.indexOutputSizes, everyElement(lessThan(1024)));
    },
  );
}
