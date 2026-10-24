import 'dart:io';
import 'package:busystack_git/busystack_git.dart';

Future<void> main() async {
  try {
    stdout.writeln(
      'Supported Git runtime: ${await ProcessGitRunner().verify()} (minimum 2.56)',
    );
  } on GitException catch (error) {
    stderr.writeln('${error.code.name}: ${error.diagnostic}');
    exitCode = 1;
  }
}
