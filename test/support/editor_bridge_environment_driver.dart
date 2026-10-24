import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:busystack_git/busystack_git.dart';
import 'package:busystack_git/src/editor_bridge.dart';
import 'repository_fixture.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main(List<String> arguments) async {
  final helper = arguments[0];
  if (arguments[1] == 'unavailable') {
    try {
      final bridge = await GitEditorBridge.open(
        const RepositoryId(
          root: '/fixture',
          gitDir: '/fixture/.git',
          commonDir: '/fixture/.git',
          objectFormat: 'sha1',
        ),
        helperPath: helper,
      );
      await bridge.close();
      throw StateError('An unusable temporary root unexpectedly succeeded.');
    } on GitException catch (error) {
      require(
        error.code == GitErrorCode.unavailable,
        'Unexpected failure category.',
      );
      require(
        error.diagnostic.contains('private Git prompt channel'),
        'Missing actionable diagnostic.',
      );
      stdout.writeln('structured private-channel failure verified');
      return;
    }
  }
  final fixture = await RepositoryFixture.create();
  try {
    final boundary = await fixture.commit(
      'notes.md',
      utf8.encode('base\n'),
      'base',
    );
    final head = await fixture.commit(
      'notes.md',
      utf8.encode('reviewed prose\n'),
      'topic',
    );
    final index = await File(
      '${fixture.repository.gitDir}/index',
    ).readAsBytes();
    final bridge = await GitEditorBridge.open(
      fixture.repository,
      helperPath: helper,
      handler: (prompt, cancellation) async {
        require(
          prompt.kind == GitPromptKind.message,
          'Unexpected prompt type.',
        );
        return Uint8List.fromList(utf8.encode('Reviewed message\n'));
      },
    );
    final directory = bridge.directory.path;
    try {
      require(
        utf8.encode(bridge.environment['BUSYSTACK_GIT_PROMPT_SOCKET']!).length <
            108,
        'Socket address is too long.',
      );
      require(
        (await bridge.directory.stat()).mode & 0x1ff == 0x1c0,
        'Prompt directory is not private.',
      );
      require(
        (await File('$directory/s').stat()).mode & 0x1ff == 0x180,
        'Prompt socket is not private.',
      );
      final message = File('${fixture.repository.gitDir}/COMMIT_EDITMSG');
      final result = await Process.run(helper, [
        'editor',
        message.path,
      ], environment: bridge.environment);
      require(
        result.exitCode == 0,
        'Native editor callback failed: ${result.stderr}',
      );
      require(
        await message.readAsString() == 'Reviewed message\n',
        'Editor result bytes differ.',
      );
    } finally {
      await bridge.close();
    }
    require(
      !await Directory(directory).exists(),
      'Private bridge data survived close.',
    );
    final plan = await fixture.engine.inspect(
      fixture.repository,
      GitInspection(GitInspectionKind.rebasePlan, revision: boundary),
    );
    require(
      (plan['steps'] as List).length == 1,
      'Git produced the wrong sequence.',
    );
    final after = await fixture.engine.status(fixture.repository);
    require(
      after.head == head && after.operation.kind == GitOperationKind.none,
      'Plan inspection changed repository state.',
    );
    require(
      base64Encode(
            await File('${fixture.repository.gitDir}/index').readAsBytes(),
          ) ==
          base64Encode(index),
      'Plan inspection changed the index.',
    );
    stdout.writeln('private editor and sequence callbacks verified');
  } finally {
    await fixture.close();
  }
}
