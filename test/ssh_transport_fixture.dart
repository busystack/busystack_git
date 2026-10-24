// Explicit localhost OpenSSH acceptance fixture. Requires sshd, ssh-keygen and
// the normal native Git verification environment; no system service is started.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:busystack_git/busystack_git.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'support/repository_fixture.dart';

void main() {
  test(
    'real SSH authenticates a reviewed push/fetch and refuses unknown hosts and unapproved keys',
    () async {
      final sshd =
          Platform.environment['BUSYSTACK_TEST_SSHD'] ?? '/usr/sbin/sshd';
      expect(
        File(sshd).existsSync(),
        isTrue,
        reason:
            'Install the OpenSSH server test prerequisite or supply BUSYSTACK_TEST_SSHD.',
      );
      final fixture = await RepositoryFixture.create();
      Process? server;
      Directory? authenticationDirectory;
      final subscriptions = <StreamSubscription<List<int>>>[];
      final log = BytesBuilder(), diagnostics = StringBuffer();
      void collect(List<int> bytes) {
        if (log.length < 16384)
          log.add(bytes.take(16384 - log.length).toList());
      }

      Future<String> command(String executable, List<String> args) async {
        final result = await Process.run(
          executable,
          args,
          environment: fixture.environment,
          includeParentEnvironment: false,
        );
        expect(
          result.exitCode,
          0,
          reason: sanitizeGitDiagnostic('${result.stderr}'),
        );
        return '${result.stdout}'.trim();
      }

      try {
        final directory = fixture.directory.path;
        await command('/bin/chmod', ['0700', directory]);
        final user = await command('/usr/bin/id', ['-un']);
        final hostKey = '$directory/host-key',
            key = '$directory/client-key',
            rejectedKey = '$directory/rejected-key';
        for (final target in [hostKey, key, rejectedKey]) {
          await command('/usr/bin/ssh-keygen', [
            '-q',
            '-t',
            'ed25519',
            '-N',
            '',
            '-f',
            target,
          ]);
        }
        // sshd validates every ancestor of AuthorizedKeysFile up to the real
        // account home. Keep that public-key fixture under a private home child;
        // /tmp's intentionally shared permissions must not be bypassed.
        final authenticationRoot =
            Platform.environment['BUSYSTACK_SSH_AUTH_ROOT'] ??
            Platform.environment['HOME'];
        if (authenticationRoot == null)
          throw StateError('A private account-home fixture root is required.');
        authenticationDirectory = await Directory(
          authenticationRoot,
        ).createTemp('.busystack-ssh-fixture-');
        await command('/bin/chmod', ['0700', authenticationDirectory.path]);
        final authorized = File(
          '${authenticationDirectory.path}/authorized_keys',
        );
        await authorized.writeAsString(await File('$key.pub').readAsString());
        await command('/bin/chmod', ['0600', authorized.path]);
        final reservation = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final port = reservation.port;
        await reservation.close();
        final config = File('$directory/sshd_config');
        final libexec = p.normalize(p.join(p.dirname(sshd), '../lib/openssh'));
        await config.writeAsString(
          [
                'ListenAddress 127.0.0.1', 'Port $port', 'HostKey $hostKey',
                'PidFile $directory/sshd.pid',
                'AuthorizedKeysFile ${authorized.path}',
                'AllowUsers $user',
                'StrictModes yes',
                'PubkeyAuthentication yes',
                'AuthenticationMethods publickey', 'PasswordAuthentication no',
                'KbdInteractiveAuthentication no',
                'UsePAM no',
                'PermitRootLogin no',
                'AllowTcpForwarding no', 'X11Forwarding no', 'PermitTunnel no',
                'PermitUserEnvironment no', 'LogLevel VERBOSE',
                // OpenSSH 9.8+ splits these executables. Its documented test paths
                // allow an extracted server package without installing system files.
                if (File('$libexec/sshd-session').existsSync())
                  'SshdSessionPath $libexec/sshd-session',
                if (File('$libexec/sshd-auth').existsSync())
                  'SshdAuthPath $libexec/sshd-auth',
              ].join('\n') +
              '\n',
        );
        await command(sshd, ['-t', '-f', config.path]);
        server = await Process.start(
          sshd,
          ['-D', '-e', '-f', config.path],
          environment: fixture.environment,
          includeParentEnvironment: false,
        );
        subscriptions.add(server.stdout.listen(collect));
        subscriptions.add(server.stderr.listen(collect));
        int? ended;
        unawaited(
          server.exitCode.then((code) {
            ended = code;
          }),
        );
        var ready = false;
        for (var attempt = 0; attempt < 100 && ended == null; attempt++) {
          try {
            final socket = await Socket.connect(
              InternetAddress.loopbackIPv4,
              port,
              timeout: const Duration(milliseconds: 100),
            );
            socket.destroy();
            ready = true;
            break;
          } on SocketException {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }
        expect(
          ready,
          isTrue,
          reason: utf8.decode(log.toBytes(), allowMalformed: true),
        );
        final known = File('$directory/known_hosts');
        final public = (await File(
          '$hostKey.pub',
        ).readAsString()).trim().split(' ');
        final expectedHost = '[127.0.0.1]:$port ${public[0]} ${public[1]}\n';
        await known.writeAsString(expectedHost);
        String sshCommand(String identity) =>
            '/usr/bin/ssh -F /dev/null -i $identity '
            '-oIdentitiesOnly=yes -oBatchMode=yes -oStrictHostKeyChecking=yes '
            '-oUserKnownHostsFile=${known.path} -oGlobalKnownHostsFile=/dev/null '
            '-oConnectionAttempts=1 -oConnectTimeout=5';
        final remote = '$directory/remote.git';
        await fixture.git(['init', '--bare', remote]);
        await fixture.commit(
          'prose.md',
          utf8.encode('Authenticated local fixture.\n'),
          'Initial prose',
        );
        await fixture.git(['config', 'core.sshCommand', sshCommand(key)]);
        await fixture.git([
          'remote',
          'add',
          'secure',
          'ssh://$user@127.0.0.1:$port$remote',
        ]);
        final before = await fixture.engine.status(fixture.repository);
        final review = await fixture.engine.inspect(
          fixture.repository,
          const GitInspection(
            GitInspectionKind.pushReview,
            remote: 'secure',
            destination: 'refs/heads/feature',
          ),
        );
        final pushed = await fixture.engine.mutate(
          fixture.repository,
          PushReviewed(
            review['token'] as String,
            expectedHead: before.head,
            expectedIndex: before.indexToken,
          ),
        );
        expect(pushed.completed, isTrue, reason: '${pushed.error}');
        expect(
          await fixture.git(['rev-parse', 'refs/heads/feature'], cwd: remote),
          before.head!.value,
        );
        final state = await fixture.engine.status(fixture.repository);
        final fetched = await fixture.engine.mutate(
          fixture.repository,
          FetchRemote(
            'secure',
            expectedHead: state.head,
            expectedIndex: state.indexToken,
          ),
        );
        expect(fetched.completed, isTrue, reason: '${fetched.error}');
        expect(
          await fixture.git(['rev-parse', 'refs/remotes/secure/feature']),
          before.head!.value,
        );
        await known.writeAsString('');
        await expectLater(
          fixture.engine.inspect(
            fixture.repository,
            const GitInspection(
              GitInspectionKind.pushReview,
              remote: 'secure',
              destination: 'refs/heads/feature',
            ),
          ),
          throwsA(
            isA<GitException>().having(
              (e) => e.code,
              'code',
              GitErrorCode.unknownHost,
            ),
          ),
        );
        expect(
          await known.readAsString(),
          isEmpty,
          reason: 'Unknown keys are never accepted automatically.',
        );
        await known.writeAsString(expectedHost);
        await fixture.git([
          'config',
          'core.sshCommand',
          sshCommand(rejectedKey),
        ]);
        await expectLater(
          fixture.engine.inspect(
            fixture.repository,
            const GitInspection(
              GitInspectionKind.pushReview,
              remote: 'secure',
              destination: 'refs/heads/feature',
            ),
          ),
          throwsA(
            isA<GitException>().having(
              (e) => e.code,
              'code',
              GitErrorCode.authentication,
            ),
          ),
        );
      } catch (error, stack) {
        diagnostics.write(
          sanitizeGitDiagnostic(
            utf8.decode(log.toBytes(), allowMalformed: true),
          ),
        );
        Error.throwWithStackTrace(StateError('$error\n$diagnostics'), stack);
      } finally {
        if (server != null) {
          server.kill();
          try {
            await server.exitCode.timeout(const Duration(seconds: 3));
          } on TimeoutException {
            server.kill(ProcessSignal.sigkill);
            await server.exitCode;
          }
        }
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        await authenticationDirectory?.delete(recursive: true);
        await fixture.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
