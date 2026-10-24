import 'package:busystack_git/busystack_git.dart';

Future<void> main(List<String> arguments) async {
  await ProcessGitRunner(
    executable: arguments[0],
  ).run([], cwd: arguments[1], deadline: const Duration(minutes: 2));
}
