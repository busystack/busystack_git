import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:busystack_git/busystack_git.dart';
import '../test/support/repository_fixture.dart';

// Fixed acceptance fixture and budgets. Run the compiled executable on a quiet
// machine; this measures the engine/caller isolate, not an application's frames.
const statusBudgetMs = 3000, historyBudgetMs = 1000;
const cancellationBudgetMs = 1500, callerGapBudgetMs = 50;
const dartMemoryBudget = 384 * 1024 * 1024;

Future<void> main() async {
  final fixture = await RepositoryFixture.create();
  try {
    for (var directory = 0; directory < 100; directory++) {
      await Directory(
        '${fixture.root.path}/tracked/$directory',
      ).create(recursive: true);
      for (var file = 0; file < 100; file++) {
        await File(
          '${fixture.root.path}/tracked/$directory/$file.md',
        ).writeAsString('Original prose.\n');
      }
    }
    await fixture.git(['add', '.']);
    await fixture.git(['commit', '-m', 'Ten thousand tracked prose files']);
    for (var commit = 0; commit < 500; commit++) {
      await fixture.git([
        'commit',
        '--allow-empty',
        '-m',
        'History fixture $commit',
      ]);
    }
    for (var directory = 0; directory < 100; directory++) {
      await Directory(
        '${fixture.root.path}/untracked/$directory',
      ).create(recursive: true);
      for (var file = 0; file < 100; file++) {
        await File(
          '${fixture.root.path}/untracked/$directory/$file.md',
        ).writeAsString('Untracked prose.\n');
      }
      await File(
        '${fixture.root.path}/tracked/$directory/0.md',
      ).writeAsString('Changed prose.\n');
    }
    final times = <int>[];
    var largestGap = 0, previousTick = 0;
    final callerClock = Stopwatch()..start();
    final timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      final now = callerClock.elapsedMilliseconds;
      final gap = now - previousTick;
      if (gap > largestGap) largestGap = gap;
      previousTick = now;
    });
    try {
      for (var i = 0; i < 5; i++) {
        final clock = Stopwatch()..start();
        final status = await fixture.engine.status(fixture.repository);
        if (status.changes.length != 10100)
          throw StateError('Status omitted fixture paths.');
        times.add(clock.elapsedMilliseconds);
      }
    } finally {
      timer.cancel();
    }
    final historyClock = Stopwatch()..start();
    final page = await fixture.engine.history(fixture.repository, limit: 100);
    final historyMs = historyClock.elapsedMilliseconds;
    if (page.commits.length != 100 || !page.hasMore)
      throw StateError('History fixture was not paginated.');
    final token = GitCancellation(), cancellationClock = Stopwatch()..start();
    final read = fixture.engine.status(fixture.repository, cancellation: token);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    cancellationClock.reset();
    token.cancel();
    try {
      await read;
      throw StateError('Obsolete read did not cancel.');
    } on GitException catch (error) {
      if (error.code != GitErrorCode.cancelled) rethrow;
    }
    final cancellationMs = cancellationClock.elapsedMilliseconds;
    final checks = {
      'status': times.every((value) => value <= statusBudgetMs),
      'historyPage': historyMs <= historyBudgetMs,
      'callerIsolate': largestGap <= callerGapBudgetMs,
      'readCancellation': cancellationMs <= cancellationBudgetMs,
      'dartPeakRss': ProcessInfo.maxRss <= dartMemoryBudget,
    };
    stdout.writeln(
      jsonEncode({
        'fixture': {
          'tracked': 10000,
          'untracked': 10000,
          'modified': 100,
          'commits': 501,
        },
        'statusMs': times,
        'history100Ms': historyMs,
        'maximumCallerTimerGapMs': largestGap,
        'cancelReadMs': cancellationMs,
        'dartPeakRssBytes': ProcessInfo.maxRss,
        'budgets': {
          'statusMs': statusBudgetMs,
          'history100Ms': historyBudgetMs,
          'callerGapMs': callerGapBudgetMs,
          'cancelReadMs': cancellationBudgetMs,
          'dartPeakRssBytes': dartMemoryBudget,
        },
        'checks': checks,
      }),
    );
    if (checks.values.any((passed) => !passed)) exitCode = 1;
  } finally {
    await fixture.close();
  }
}
