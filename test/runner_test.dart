import 'dart:async';
import 'dart:io';
import 'package:busystack_git/busystack_git.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('bsg-runner-');
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });
  Future<String> fixture(String body) async {
    final file = File('${temporary.path}/git-fixture');
    await file.writeAsString('#!/usr/bin/python3\n$body\n');
    await Process.run('/bin/chmod', ['700', file.path]);
    return file.path;
  }

  test(
    'simultaneous stdout/stderr drain without corrupting binary stdout',
    () async {
      final executable = await fixture('''import os, threading
def emit(fd, byte):
 for _ in range(128): os.write(fd, byte * 4096)
a=threading.Thread(target=emit,args=(1,b'\\x00\\xff'))
b=threading.Thread(target=emit,args=(2,b'p'))
a.start();b.start();a.join();b.join()
''');
      final result = await ProcessGitRunner(
        executable: executable,
      ).run([], cwd: temporary.path, deadline: const Duration(seconds: 10));
      expect(result.success, isTrue);
      expect(result.stdout.length, 128 * 8192);
      expect(result.stdout.take(4), [0, 255, 0, 255]);
      expect(result.stderr.length, 128 * 4096);
    },
  );
  test(
    'stdin is available and inherited Git redirection is not forwarded',
    () async {
      final executable = await fixture(
        "import os,sys\nsys.stdout.buffer.write(sys.stdin.buffer.read())\nsys.stderr.write(os.environ.get('GIT_INDEX_FILE','sanitized'))",
      );
      final result = await ProcessGitRunner(
        executable: executable,
      ).run([], cwd: temporary.path, input: [0, 255, 10]);
      expect(result.stdout, [0, 255, 10]);
      expect(result.diagnostic, 'sanitized');
    },
  );
  test(
    'progress redaction holds URL fragments until a complete progress line',
    () async {
      final executable = await fixture(
        "import os,time\nos.write(2,b'https://user:sec');time.sleep(.05);os.write(2,b'ret@example.invalid/repo\\rDone\\n')",
      );
      final progress = <String>[];
      await ProcessGitRunner(
        executable: executable,
      ).run([], cwd: temporary.path, onProgress: progress.add);
      expect(progress.join(), isNot(contains('secret')));
      expect(progress.join(), isNot(contains('user:sec')));
      expect(progress.last, 'Done');
    },
  );
  test('output limits stop and reap the process group', () async {
    final executable = await fixture(
      "import os\nwhile True: os.write(1,b'x'*8192)",
    );
    await expectLater(
      ProcessGitRunner(
        executable: executable,
        maximumOutputBytes: 65536,
      ).run([], cwd: temporary.path),
      throwsA(
        isA<GitException>().having(
          (e) => e.code,
          'code',
          GitErrorCode.outputLimit,
        ),
      ),
    );
  });
  test(
    'cancellation stops child helpers and returns within the cleanup budget',
    () async {
      final pidFile = File('${temporary.path}/child.pid');
      final executable = await fixture(
        "import subprocess,time,pathlib\np=subprocess.Popen(['/usr/bin/sleep','60'])\npathlib.Path('${pidFile.path}').write_text(str(p.pid))\ntime.sleep(60)",
      );
      final cancel = GitCancellation(), watch = Stopwatch()..start();
      final result = ProcessGitRunner(
        executable: executable,
      ).run([], cwd: temporary.path, cancellation: cancel);
      final asserted = expectLater(
        result,
        throwsA(
          isA<GitException>().having(
            (e) => e.code,
            'code',
            GitErrorCode.cancelled,
          ),
        ),
      );
      for (var i = 0; i < 100 && !await pidFile.exists(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final pid = int.parse(await pidFile.readAsString());
      cancel.cancel();
      await asserted;
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      final proc = File('/proc/$pid/stat');
      expect(
        !await proc.exists() ||
            (await proc.readAsString()).split(') ').last.startsWith('Z'),
        isTrue,
      );
    },
  );
  test('deadline is a distinct structured failure', () async {
    final executable = await fixture('import time\ntime.sleep(60)');
    await expectLater(
      ProcessGitRunner(executable: executable).run(
        [],
        cwd: temporary.path,
        deadline: const Duration(milliseconds: 80),
      ),
      throwsA(
        isA<GitException>().having(
          (e) => e.code,
          'code',
          GitErrorCode.deadline,
        ),
      ),
    );
  });
  test(
    'runtime probe failures retain native platform diagnostics and exit status',
    () async {
      final executable = await fixture(
        "import sys\nsys.stderr.write('Git supervisor requires process lifetime monitoring')\nsys.exit(7)",
      );
      await expectLater(
        ProcessGitRunner(executable: executable).verify(),
        throwsA(
          isA<GitException>()
              .having((e) => e.code, 'code', GitErrorCode.unavailable)
              .having((e) => e.exitCode, 'exitCode', 7)
              .having(
                (e) => e.diagnostic,
                'diagnostic',
                contains('process lifetime monitoring'),
              ),
        ),
      );
    },
  );
  test(
    'a spawning worker thread may retire while its application and Git remain alive',
    () async {
      final helper = '${temporary.path}/busystack-git-helper',
          parent = '${temporary.path}/thread-parent';
      for (final arguments in [
        ['native/git_helper.c', '-o', helper],
        ['-pthread', 'test/support/thread_parent.c', '-o', parent],
      ]) {
        final compiled = await Process.run('cc', [
          '-std=c11',
          '-O2',
          '-Wall',
          '-Wextra',
          '-Werror',
          ...arguments,
        ]);
        expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
      }
      final ready = File('${temporary.path}/ready'),
          survived = File('${temporary.path}/survived');
      final result = await Process.run(parent, [
        helper,
        ready.path,
        survived.path,
      ]).timeout(const Duration(seconds: 10));
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(await ready.readAsString(), 'ready');
      expect(await survived.readAsString(), 'survived');
    },
  );
  test(
    'native supervision kills Git and its children when the owning Dart process is killed',
    () async {
      final parentFile = File('${temporary.path}/git.pid'),
          childFile = File('${temporary.path}/child.pid');
      final executable = await fixture('''import os,sys,subprocess,time,signal
signal.signal(signal.SIGTERM,signal.SIG_IGN)
open('git.pid','w').write(str(os.getpid()))
subprocess.Popen([sys.executable,'-c',"import os,time,signal; signal.signal(signal.SIGTERM,signal.SIG_IGN); open('child.pid','w').write(str(os.getpid())); time.sleep(90)"])
time.sleep(90)
''');
      final driver = await Process.start(Platform.resolvedExecutable, [
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        'test/support/runner_death_driver.dart',
        executable,
        temporary.path,
      ]);
      final out = driver.stdout.drain<void>(),
          err = driver.stderr.drain<void>();
      try {
        final until = DateTime.now().add(const Duration(seconds: 10));
        while ((!await parentFile.exists() || !await childFile.exists()) &&
            DateTime.now().isBefore(until)) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        expect(await parentFile.exists(), isTrue);
        expect(await childFile.exists(), isTrue);
        final parent = int.parse(await parentFile.readAsString()),
            child = int.parse(await childFile.readAsString());
        driver.kill(ProcessSignal.sigkill);
        await driver.exitCode;
        bool alive(int pid) {
          final stat = File('/proc/$pid/stat');
          return stat.existsSync() &&
              !stat.readAsStringSync().split(') ').last.startsWith('Z');
        }

        final cleanup = DateTime.now().add(const Duration(seconds: 4));
        while ((alive(parent) || alive(child)) &&
            DateTime.now().isBefore(cleanup)) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        expect(alive(parent), isFalse);
        expect(alive(child), isFalse);
      } finally {
        driver.kill(ProcessSignal.sigkill);
        await driver.exitCode;
        await Future.wait([out, err]);
      }
    },
  );
}
