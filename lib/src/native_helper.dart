import 'dart:io';
import 'package:path/path.dart' as p;

String? installedGitHelper({String? preferred}) {
  final directory = p.dirname(Platform.resolvedExecutable),
      snap = Platform.environment['SNAP'];
  for (final candidate in [
    if (preferred != null) preferred,
    if (Platform.environment['BUSYSTACK_GIT_HELPER_PATH'] case final value?)
      value,
    for (final root in [directory, if (snap != null) snap]) ...[
      p.join(root, 'busystack-git-helper'),
      for (final app in ['busymark', 'busyfiles', 'busystack'])
        p.join(root, 'libexec', app, 'busystack-git-helper'),
    ],
    p.normalize(p.join(directory, '../libexec/busyfiles/busystack-git-helper')),
  ]) {
    if (p.isAbsolute(candidate) && File(candidate).existsSync())
      return File(candidate).resolveSymbolicLinksSync();
  }
  return null;
}
