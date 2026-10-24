import 'dart:convert';
import 'dart:io';
import 'package:busystack_git/busystack_git.dart';
import 'package:busystack_git/src/transactions.dart';
import 'isolated_runner.dart';

Future<void> main(List<String> args) async {
  final repository = (await GitEngine(
    runner: IsolatedGitRunner(args[1]),
  ).discover(args[0]))!;
  await RepositoryLocks().withLocks(repository, () async {
    stdout.writeln('locked');
    await stdout.flush();
    await stdin.transform(utf8.decoder).first;
  });
}
