import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:busystack_git/busystack_git.dart';
import 'package:test/test.dart';
import 'support/isolated_runner.dart';

void main() {
  late Directory fixture, root, helperBuild;
  late String helper;
  Future<String> git(List<String> args, {String? cwd}) async {
    final result = await Process.run(
      '/usr/bin/git',
      args,
      workingDirectory: cwd ?? root.path,
      environment: {
        'HOME': '${fixture.path}/home',
        'GIT_CONFIG_GLOBAL': '/dev/null',
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_AUTHOR_NAME': 'Fixture',
        'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
        'GIT_COMMITTER_NAME': 'Fixture',
        'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
      },
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return (result.stdout as String).trimRight();
  }

  setUpAll(() async {
    helperBuild = await Directory.systemTemp.createTemp('bsg-native-helper-');
    helper = '${helperBuild.path}/busystack-git-helper';
    final built = await Process.run('cc', [
      '-std=c11',
      '-O2',
      '-Wall',
      '-Wextra',
      '-Werror',
      'native/git_helper.c',
      '-o',
      helper,
    ]);
    expect(built.exitCode, 0, reason: '${built.stderr}');
  });
  tearDownAll(() => helperBuild.delete(recursive: true));
  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('bsg-secure-');
    root = await Directory('${fixture.path}/repo').create();
    await IsolatedGitRunner.prepare('${fixture.path}/home');
    await git(['init', '-b', 'feature']);
    await File('${root.path}/a').writeAsString('base');
    await git(['add', '.']);
    await git(['commit', '-m', 'base']);
    await git(['config', 'user.name', 'Fixture']);
    await git(['config', 'user.email', 'fixture@example.invalid']);
  });
  tearDown(() => fixture.delete(recursive: true));
  test(
    'native askpass binds prompts to the reviewed operation and reports cancellation',
    () async {
      final remote = '${fixture.path}/remote.git';
      await git(['init', '--bare', remote]);
      final ssh = File('${fixture.path}/fixture-ssh');
      await ssh.writeAsString('''#!/bin/sh
if [ "\$1" = "-G" ]; then exit 0; fi
answer="\$("\$GIT_ASKPASS" 'Fixture transport password:')" || exit 1
if [ "\$answer" != 'fixture-secret' ]; then exit 1; fi
for argument do
  case "\$argument" in
    git-upload-pack*) exec /usr/bin/git-upload-pack '$remote' ;;
    git-receive-pack*) exec /usr/bin/git-receive-pack '$remote' ;;
  esac
done
exit 2
''');
      await Process.run('/bin/chmod', ['0700', ssh.path]);
      await git(['config', 'core.sshCommand', ssh.path]);
      await git([
        'remote',
        'add',
        'fixture',
        'ssh://fixture.invalid/repository.git',
      ]);
      final prompts = <GitPrompt>[], progress = <GitProgress>[];
      final engine = GitEngine(
        authorize: (_) => true,
        runner: IsolatedGitRunner('${fixture.path}/home'),
        helperPath: helper,
        prompts: (prompt, cancellation) async {
          prompts.add(prompt);
          return Uint8List.fromList(utf8.encode('fixture-secret'));
        },
      );
      final repo = (await engine.discover(root.path))!,
          before = await engine.status((await engine.discover(root.path))!);
      final plan = await engine.inspect(
        repo,
        const GitInspection(
          GitInspectionKind.pushReview,
          remote: 'fixture',
          destination: 'refs/heads/feature',
        ),
        onProgress: progress.add,
      );
      expect(prompts.single.repository, repo);
      expect(prompts.single.kind, GitPromptKind.credential);
      expect(
        progress.map((e) => e.operationId),
        contains(prompts.single.operationId),
      );
      expect(jsonEncode(plan), isNot(contains('fixture-secret')));
      final pushed = await engine.mutate(
        repo,
        PushReviewed(
          plan['token'] as String,
          expectedHead: before.head,
          expectedIndex: before.indexToken,
        ),
      );
      expect(pushed.completed, isTrue, reason: '${pushed.error}');
      expect(
        await git(['rev-parse', 'refs/heads/feature'], cwd: remote),
        before.head!.value,
      );
      final cancelled = GitEngine(
        authorize: (_) => true,
        runner: IsolatedGitRunner('${fixture.path}/home'),
        helperPath: helper,
        prompts: (_, _) async => null,
      );
      await expectLater(
        cancelled.inspect(
          repo,
          const GitInspection(
            GitInspectionKind.pushReview,
            remote: 'fixture',
            destination: 'refs/heads/feature',
          ),
        ),
        throwsA(
          isA<GitException>().having(
            (e) => e.code,
            'code',
            GitErrorCode.cancelled,
          ),
        ),
      );
    },
  );
  test(
    'passive review rejects executable filters and never runs drivers or hooks',
    () async {
      final marker = '${fixture.path}/executed';
      await git(['config', 'core.fsmonitor', 'touch $marker']);
      await git(['config', 'diff.fixture.textconv', 'touch $marker']);
      await git(['config', 'diff.external', 'touch $marker']);
      await File(
        '${root.path}/.gitattributes',
      ).writeAsString('a diff=fixture\n');
      await File('${root.path}/a').writeAsString('changed');
      final engine = GitEngine(
        runner: IsolatedGitRunner('${fixture.path}/home'),
      );
      final repo = (await engine.discover(root.path))!;
      await engine.status(repo);
      await engine.patch(
        repo,
        const GitDiffSpec(ContentVersion.index(), ContentVersion.working()),
      );
      expect(await File(marker).exists(), isFalse);
      await git(['config', 'filter.fixture.clean', 'touch "$marker"; cat']);
      await File(
        '${root.path}/.gitattributes',
      ).writeAsString('a filter=fixture\n');
      await expectLater(
        engine.content(
          repo,
          RepoPath.text('a'),
          const ContentVersion(ContentKind.normalizedWorking),
        ),
        throwsA(
          isA<GitException>().having(
            (e) => e.code,
            'code',
            GitErrorCode.trustRequired,
          ),
        ),
      );
      expect(await File(marker).exists(), isFalse);
      final trusted = GitEngine(
        runner: IsolatedGitRunner('${fixture.path}/home'),
        authorize: (_) => true,
      );
      await expectLater(
        trusted.status(repo),
        throwsA(
          isA<GitException>().having(
            (e) => e.code,
            'passive policy despite mutation trust',
            GitErrorCode.trustRequired,
          ),
        ),
      );
      expect(await File(marker).exists(), isFalse);
      await trusted.status(repo, policy: GitReadPolicy.authorized);
      expect(
        (await trusted.content(
          repo,
          RepoPath.text('a'),
          const ContentVersion(ContentKind.normalizedWorking),
        )).text,
        'changed',
      );
      expect(await File(marker).exists(), isTrue);
    },
  );
  test(
    'verified HTTPS smart transport uses private prompts and never exposes credentials',
    () async {
      final key = '${fixture.path}/tls-key',
          certificate = '${fixture.path}/tls-ca.pem';
      final generated = await Process.run('/usr/bin/openssl', [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-subj',
        '/CN=localhost',
        '-addext',
        'subjectAltName=DNS:localhost,IP:127.0.0.1',
        '-keyout',
        key,
        '-out',
        certificate,
        '-days',
        '1',
      ]);
      expect(generated.exitCode, 0);
      final remote = '${fixture.path}/secure.git';
      await git(['init', '--bare', remote]);
      await git(['config', 'http.receivepack', 'true'], cwd: remote);
      final context = SecurityContext()
        ..useCertificateChain(certificate)
        ..usePrivateKey(key);
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      final serving = <Future<void>>[], failures = <Object>[];
      final expected =
          'Basic ${base64Encode(utf8.encode('fixture-user:fixture-https-secret'))}';
      Future<void> handle(HttpRequest request) async {
        try {
          if (request.headers.value('authorization') != expected) {
            request.response.statusCode = 401;
            request.response.headers.set(
              'www-authenticate',
              'Basic realm="isolated Git fixture"',
            );
            await request.response.close();
            return;
          }
          final backend = await Process.start(
            '/usr/bin/git',
            ['http-backend'],
            includeParentEnvironment: false,
            environment: {
              'PATH': '/usr/bin:/bin',
              'HOME': '${fixture.path}/home',
              'GIT_CONFIG_NOSYSTEM': '1',
              'GIT_CONFIG_GLOBAL': '/dev/null',
              'GIT_PROJECT_ROOT': fixture.path,
              'GIT_HTTP_EXPORT_ALL': '1',
              'PATH_INFO': request.uri.path,
              'QUERY_STRING': request.uri.query,
              'REQUEST_METHOD': request.method,
              'CONTENT_TYPE': request.headers.contentType?.toString() ?? '',
              'CONTENT_LENGTH':
                  '${request.contentLength < 0 ? 0 : request.contentLength}',
              'REMOTE_USER': 'fixture-user',
              'REMOTE_ADDR': '127.0.0.1',
              'AUTH_TYPE': 'Basic',
              if (request.headers.value('Git-Protocol') case final protocol?)
                'HTTP_GIT_PROTOCOL': protocol,
            },
          );
          final out = backend.stdout.fold<BytesBuilder>(BytesBuilder(), (
            bytes,
            chunk,
          ) {
            if (bytes.length + chunk.length > 8 * 1024 * 1024)
              throw StateError('Fixture response exceeded its limit.');
            return bytes..add(chunk);
          });
          final err = backend.stderr.drain<void>();
          await backend.stdin.addStream(request);
          await backend.stdin.close();
          final bytes = (await out).takeBytes();
          expect(await backend.exitCode, 0);
          await err;
          var boundary = -1;
          for (var i = 0; i + 3 < bytes.length; i++) {
            if (bytes[i] == 13 &&
                bytes[i + 1] == 10 &&
                bytes[i + 2] == 13 &&
                bytes[i + 3] == 10) {
              boundary = i;
              break;
            }
          }
          expect(boundary, greaterThanOrEqualTo(0));
          for (final line
              in ascii.decode(bytes.sublist(0, boundary)).split('\r\n')) {
            final colon = line.indexOf(':');
            if (colon < 0) continue;
            if (line.startsWith('Status:')) {
              request.response.statusCode = int.parse(
                line.substring(colon + 1).trim().split(' ').first,
              );
            } else {
              request.response.headers.set(
                line.substring(0, colon),
                line.substring(colon + 1).trim(),
              );
            }
          }
          request.response.add(bytes.sublist(boundary + 4));
          await request.response.close();
        } on Object catch (error) {
          failures.add(error);
          request.response.statusCode = 500;
          await request.response.close();
        }
      }

      final subscription = server.listen((request) {
        serving.add(handle(request));
      });
      try {
        await git(['config', 'http.sslCAInfo', certificate]);
        await git(['config', 'credential.helper', '']);
        await git([
          'remote',
          'add',
          'secure',
          'https://localhost:${server.port}/secure.git',
        ]);
        final prompts = <GitPrompt>[], progress = <GitProgress>[];
        final engine = GitEngine(
          authorize: (_) => true,
          runner: IsolatedGitRunner('${fixture.path}/home'),
          helperPath: helper,
          prompts: (prompt, cancellation) async {
            prompts.add(prompt);
            return Uint8List.fromList(
              utf8.encode(
                prompt.title.toLowerCase().contains('username')
                    ? 'fixture-user'
                    : 'fixture-https-secret',
              ),
            );
          },
        );
        final repo = (await engine.discover(root.path))!,
            state = await engine.status((await engine.discover(root.path))!);
        final preview = await engine.inspect(
          repo,
          const GitInspection(
            GitInspectionKind.pushReview,
            remote: 'secure',
            destination: 'refs/heads/feature',
          ),
          onProgress: progress.add,
        );
        expect(
          prompts.map((p) => p.kind),
          everyElement(GitPromptKind.credential),
        );
        expect(prompts.length, greaterThanOrEqualTo(2));
        expect(jsonEncode(preview), isNot(contains('fixture-https-secret')));
        final outcome = await engine.mutate(
          repo,
          PushReviewed(
            preview['token'] as String,
            expectedHead: state.head,
            expectedIndex: state.indexToken,
          ),
          onProgress: progress.add,
        );
        expect(outcome.completed, isTrue, reason: '${outcome.error}');
        expect(
          await git(['rev-parse', 'refs/heads/feature'], cwd: remote),
          state.head!.value,
        );
        expect(
          jsonEncode(outcome.toJson()),
          isNot(contains('fixture-https-secret')),
        );
        expect(
          progress.map((e) => e.text).join(),
          isNot(contains('fixture-https-secret')),
        );
        expect(failures, isEmpty);
      } finally {
        await subscription.cancel();
        await server.close(force: true);
        await Future.wait(serving);
      }
    },
  );
}
