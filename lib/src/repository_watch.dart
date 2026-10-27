import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'context.dart';
import 'linux_paths.dart';
import 'models.dart';
import 'runner.dart';

/// Watches Git-reported path parents, not a recursive directory traversal.
/// Git remains authoritative; events only invalidate query results. A slower
/// reconciliation covers missed events/reference backends. Incomplete watch
/// coverage retains the original five-second reconciliation behavior.
Stream<void> watchRepository(GitContext context, RepositoryId repository) =>
    _RepositoryWatch(context, repository).stream;

final class _RepositoryWatch {
  _RepositoryWatch(this.context, this.repository) {
    _controller = StreamController<void>(onListen: _start, onCancel: _close);
  }

  final GitContext context;
  final RepositoryId repository;
  late final StreamController<void> _controller;
  Stream<void> get stream => _controller.stream;
  final _cancellation = GitCancellation();
  final _directories = <String, _WatchedDirectory>{};
  final _metadataKeys = <String>{};
  Timer? _debounce, _reconcile;
  Future<void>? _scanning;
  int? _lease;
  bool _closed = false, _rescan = false, _fallback = false;
  static const _maximumDirectories = 256;

  void _start() {
    try {
      if (LinuxPaths.canWrite(repository.gitDir) &&
          LinuxPaths.canWrite(repository.commonDir)) {
        final descriptor = LinuxPaths.secureOpen(
          utf8.encode('${repository.gitDir}/busystack-open.lock'),
          create: true,
        );
        if (!LinuxPaths.trySharedLock(descriptor)) {
          LinuxPaths.close(descriptor);
          throw const GitException(GitErrorCode.locked);
        }
        _lease = descriptor;
      }
    } on GitException catch (error) {
      _controller.addError(error);
      _fallback = true;
    }
    _setReconciliation();
    unawaited(_scan());
  }

  void _setReconciliation() {
    if (_closed) return;
    _reconcile?.cancel();
    _reconcile = Timer.periodic(Duration(seconds: _fallback ? 5 : 30), (_) {
      _invalidate();
      unawaited(_scan());
    });
  }

  void _invalidate({bool rescan = false}) {
    if (_closed) return;
    _rescan = _rescan || rescan;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), () {
      if (_closed) return;
      _controller.add(null);
      if (_rescan) {
        _rescan = false;
        unawaited(_scan());
      }
    });
  }

  Future<void> _scan() {
    if (_closed) return Future.value();
    if (_scanning != null) {
      _rescan = true;
      return _scanning!;
    }
    return _scanning ??= _readDirectories().whenComplete(
      () => _scanning = null,
    );
  }

  Future<void> _readDirectories() async {
    try {
      await context.validateIdentity(repository);
      final paths = <String, List<int>>{};
      void add(List<int> path) => paths[base64Encode(path)] = path;
      for (final root in {
        repository.root,
        repository.gitDir,
        repository.commonDir,
      }) {
        add(utf8.encode(root));
      }
      _metadataKeys.addAll({
        base64Encode(utf8.encode(repository.gitDir)),
        base64Encode(utf8.encode(repository.commonDir)),
      });
      if (!repository.bare) {
        final result = await context.runRepository(
          repository,
          ['ls-files', '--cached', '--others', '--exclude-standard', '-z'],
          cancellation: _cancellation,
          maximumBytes: 4 * 1024 * 1024,
        );
        final parents = await Isolate.run(
          () => _pathParents(result.stdout, _maximumDirectories),
        );
        if (parents.limited) _fallback = true;
        final root = utf8.encode('${repository.root}/');
        for (final parent in parents.paths) {
          add([...root, ...parent]);
        }
      }
      // These are invalidation directories, never a custom reference database.
      // Watch existing descendants of refs/reftable/logs within the same bound.
      for (final root in {
        '${repository.commonDir}/refs',
        '${repository.commonDir}/reftable',
        '${repository.gitDir}/logs',
      }) {
        final queue = <Directory>[Directory(root)];
        var entries = 0;
        while (queue.isNotEmpty && paths.length < _maximumDirectories) {
          final directory = queue.removeLast();
          if (await FileSystemEntity.type(directory.path, followLinks: false) !=
              FileSystemEntityType.directory) {
            continue;
          }
          add(utf8.encode(directory.path));
          _metadataKeys.add(base64Encode(utf8.encode(directory.path)));
          await for (final entry in directory.list(followLinks: false)) {
            if (_closed) return;
            if (++entries > 4096) {
              _fallback = true;
              queue.clear();
              break;
            }
            if (entry is Directory) {
              if (queue.length + paths.length >= _maximumDirectories) {
                _fallback = true;
                break;
              }
              queue.add(entry);
            }
          }
        }
        if (queue.isNotEmpty) _fallback = true;
      }
      if (paths.length > _maximumDirectories) _fallback = true;
      for (final entry in paths.entries.take(_maximumDirectories)) {
        if (_closed) return;
        await _watch(entry.key, entry.value);
      }
      // Retain existing parents (including newly empty directories) until
      // cancellation. Descriptor count remains bounded across path churn.
      _setReconciliation();
      _invalidate(); // Reconcile the initial status-to-watch installation gap.
    } on GitException catch (error) {
      if (_closed || error.code == GitErrorCode.cancelled) return;
      _fallback = true;
      _setReconciliation();
      if (error.code != GitErrorCode.outputLimit) _controller.addError(error);
    } on FileSystemException catch (error) {
      if (_closed) return;
      _fallback = true;
      _setReconciliation();
      _controller.addError(
        GitException(
          GitErrorCode.unsafePath,
          diagnostic:
              'Repository watch failed (errno ${error.osError?.errorCode ?? 0}).',
        ),
      );
    }
  }

  Future<void> _watch(String key, List<int> path) async {
    if (_closed) return;
    final previous = _directories[key];
    if (previous == null && _directories.length >= _maximumDirectories) {
      _fallback = true;
      return;
    }
    int? descriptor;
    try {
      descriptor = LinuxPaths.secureOpen(path, directory: true);
      final pinned = descriptor;
      if (previous != null) {
        if (LinuxPaths.descriptorStat(previous.descriptor).identity ==
            LinuxPaths.descriptorStat(pinned).identity) {
          return;
        }
        _directories.remove(key);
        await previous.subscription.cancel();
        LinuxPaths.close(previous.descriptor);
        if (_closed) return;
      }
      // A pinned descriptor also represents a non-UTF-8 directory losslessly.
      // O_NOFOLLOW is enforced for every ancestor by secureOpen.
      final subscription = Directory('/proc/$pid/fd/$pinned').watch().listen(
        (event) {
          if (event.isDirectory) {
            // An empty/new subtree may not yet appear in Git's file output.
            // Keep prompt polling as well as installing newly reported parents.
            if (!_fallback) {
              _fallback = true;
              _setReconciliation();
            }
          }
          _invalidate(rescan: event.isDirectory || _metadataKeys.contains(key));
        },
        onError: (Object error, StackTrace stack) {
          if (_closed) return;
          _fallback = true;
          _setReconciliation();
          _controller.addError(error, stack);
        },
        onDone: () {
          if (_closed) return;
          _fallback = true;
          _setReconciliation();
          _invalidate(rescan: true);
        },
      );
      _directories[key] = _WatchedDirectory(pinned, subscription);
      descriptor = null;
    } on GitException {
      // A path may have disappeared since ls-files, or be a symlink. Never
      // follow it; the authoritative status query and fallback handle it.
      _fallback = true;
    } finally {
      if (descriptor != null) LinuxPaths.close(descriptor);
    }
  }

  Future<void> _close() async {
    _closed = true;
    _cancellation.cancel();
    _debounce?.cancel();
    _reconcile?.cancel();
    await _scanning;
    if (_lease case final descriptor?) LinuxPaths.close(descriptor);
    _lease = null;
    final directories = _directories.values.toList();
    _directories.clear();
    for (final directory in directories) {
      await directory.subscription.cancel();
      LinuxPaths.close(directory.descriptor);
    }
  }
}

final class _WatchedDirectory {
  const _WatchedDirectory(this.descriptor, this.subscription);
  final int descriptor;
  final StreamSubscription<FileSystemEvent> subscription;
}

({List<List<int>> paths, bool limited}) _pathParents(
  List<int> bytes,
  int maximum,
) {
  final paths = <String, List<int>>{};
  var start = 0;
  for (var end = 0; end < bytes.length; end++) {
    if (bytes[end] != 0) continue;
    final path = RepoPath(bytes.sublist(start, end)).bytes;
    for (var i = 0; i < path.length; i++) {
      if (path[i] != 47) continue;
      final parent = path.sublist(0, i);
      paths[base64Encode(parent)] = parent;
      if (paths.length > maximum) {
        return (paths: paths.values.take(maximum).toList(), limited: true);
      }
    }
    start = end + 1;
  }
  return (paths: paths.values.toList(), limited: false);
}
