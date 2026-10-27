import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'client.dart';
import 'editor_bridge.dart';
import 'engine.dart';
import 'models.dart';
import 'runner.dart';

/// A direct, in-process engine adapter. Git, filesystem checks and parsing run
/// on its owned isolate. Host authorization and prompts stay on the caller's
/// isolate and are bound to the originating request and repository.
///
/// This transport is private to the process; it is not daemon IPC. It accepts
/// the same typed Git requests, never commands or arbitrary execution options.
final class BackgroundGitClient
    implements GitClient, GitWorkflowClient, GitPatchClient {
  BackgroundGitClient({
    FutureOr<bool> Function(RepositoryId)? authorize,
    this.prompts,
    this.executable,
    this.helperPath,
  }) : _authorize = authorize ?? ((_) => false);

  final FutureOr<bool> Function(RepositoryId) _authorize;
  final GitPromptHandler? prompts;
  final String? executable, helperPath;
  final _calls = <int, _PendingCall>{};
  final _watches = <int, StreamController<void>>{};
  final _promptCancellations = <int, GitCancellation>{};
  final _closed = Completer<void>();
  Future<SendPort>? _starting;
  ReceivePort? _messages, _exits;
  SendPort? _worker;
  bool _closing = false, _finished = false;
  int _next = 0;

  Future<SendPort> _start() => _starting ??= _spawn();
  Future<SendPort> _spawn() async {
    final ready = Completer<SendPort>();
    final messages = _messages = ReceivePort();
    final exits = _exits = ReceivePort();
    messages.listen((Object? value) {
      if (value is SendPort) {
        _worker = value;
        if (!ready.isCompleted) ready.complete(value);
      } else if (value is _Result) {
        final call = _calls.remove(value.id);
        if (call == null) return;
        if (value.error != null) {
          call.result.completeError(value.error!);
        } else {
          call.result.complete(value.value);
        }
      } else if (value is _Progress) {
        _calls[value.id]?.progress?.call(value.value);
      } else if (value is _HostRequest) {
        unawaited(_answer(value));
      } else if (value is _PromptCancelled) {
        _promptCancellations[value.id]?.cancel();
      } else if (value is _WatchEvent) {
        final controller = _watches[value.id];
        if (controller == null || controller.isClosed) return;
        if (value.error != null) {
          controller.addError(value.error!);
        } else {
          controller.add(null);
        }
      } else if (value is _Closed) {
        _finish();
      }
    });
    exits.listen((Object? _) {
      if (!ready.isCompleted) {
        ready.completeError(const GitException(GitErrorCode.disconnected));
      }
      _finish(unexpected: true);
    });
    try {
      await Isolate.spawn(
        _workerMain,
        (messages.sendPort, executable, helperPath),
        debugName: 'BusyStack Git',
        onExit: exits.sendPort,
        onError: exits.sendPort,
        errorsAreFatal: true,
      );
      return await ready.future;
    } on Object {
      _finish(unexpected: true);
      rethrow;
    }
  }

  Future<void> _answer(_HostRequest request) async {
    final active = _calls.containsKey(request.call);
    if (!active || _closing) {
      _worker?.send(_HostReply(request.id, null));
      return;
    }
    Object? answer;
    final cancellation = GitCancellation();
    _promptCancellations[request.id] = cancellation;
    try {
      if (request.prompt case final prompt?) {
        answer = await Future.any<Object?>([
          Future<Uint8List?>.value(prompts?.call(prompt, cancellation)),
          cancellation.whenCancelled.then((_) => null),
        ]);
      } else {
        answer = await Future.any<Object?>([
          Future<bool>.value(_authorize(request.repository)),
          cancellation.whenCancelled.then((_) => null),
        ]);
      }
    } on Object {
      // A host callback failure cannot authorize executable repository behavior
      // or place its arbitrary error (possibly secret-bearing) in diagnostics.
      answer = null;
    } finally {
      _promptCancellations.remove(request.id);
    }
    if (!_finished) _worker?.send(_HostReply(request.id, answer));
  }

  Future<T> _call<T>(
    _Method method,
    List<Object?> arguments, {
    GitCancellation? cancellation,
    void Function(GitProgress)? progress,
    bool mutation = false,
  }) async {
    if (_closing || _finished) {
      throw const GitException(GitErrorCode.disconnected);
    }
    cancellation?.check();
    final port = await _start();
    if (_closing || _finished) {
      throw const GitException(GitErrorCode.disconnected);
    }
    cancellation?.check();
    final id = ++_next, pending = _PendingCall(mutation, progress);
    _calls[id] = pending;
    port.send(_Request(id, method, arguments));
    if (cancellation != null) {
      unawaited(
        cancellation.whenCancelled.then((_) {
          if (identical(_calls[id], pending)) port.send(_Cancel(id));
        }),
      );
    }
    return await pending.result.future as T;
  }

  @override
  Future<RepositoryId?> discover(
    String localPath, {
    GitCancellation? cancellation,
  }) => _call(_Method.discover, [localPath], cancellation: cancellation);
  @override
  Future<GitSnapshot> status(
    RepositoryId repository, {
    GitCancellation? cancellation,
    GitReadPolicy policy = GitReadPolicy.restricted,
  }) => _call(_Method.status, [repository, policy], cancellation: cancellation);
  @override
  Future<List<GitReference>> references(RepositoryId repository) =>
      _call(_Method.references, [repository]);
  @override
  Future<HistoryPage> history(
    RepositoryId repository, {
    HistoryFilter filter = const HistoryFilter(),
    int offset = 0,
    int limit = 100,
    String? anchor,
    GitCancellation? cancellation,
  }) => _call(_Method.history, [
    repository,
    filter,
    offset,
    limit,
    anchor,
  ], cancellation: cancellation);
  @override
  Future<GitContent> content(
    RepositoryId repository,
    RepoPath path,
    ContentVersion version, {
    GitCancellation? cancellation,
  }) => _call(_Method.content, [
    repository,
    path,
    version,
  ], cancellation: cancellation);
  @override
  Future<List<GitChange>> changedFiles(
    RepositoryId repository,
    GitOid revision, {
    GitOid? parent,
  }) => _call(_Method.changedFiles, [repository, revision, parent]);
  @override
  Future<GitPatch> patch(
    RepositoryId repository,
    GitDiffSpec comparison, {
    GitCancellation? cancellation,
  }) => _call(_Method.patch, [
    repository,
    comparison,
  ], cancellation: cancellation);
  @override
  Future<Json> inspect(
    RepositoryId repository,
    GitInspection request, {
    GitCancellation? cancellation,
    void Function(GitProgress)? onProgress,
  }) => _call(
    _Method.inspect,
    [repository, request],
    cancellation: cancellation,
    progress: onProgress,
    mutation: request.kind == GitInspectionKind.rebasePlan,
  );
  @override
  Future<GitCreationOutcome> create(
    GitCreation request, {
    GitCancellation? cancellation,
    void Function(GitProgress)? onProgress,
  }) => _call(
    _Method.create,
    [request],
    cancellation: cancellation,
    progress: onProgress,
    mutation: true,
  );
  @override
  Future<GitOutcome> mutate(
    RepositoryId repository,
    GitMutation request, {
    GitCancellation? cancellation,
    void Function(GitProgress)? onProgress,
  }) => _call(
    _Method.mutate,
    [repository, request],
    cancellation: cancellation,
    progress: onProgress,
    mutation: true,
  );

  @override
  Stream<void> watch(RepositoryId repository) {
    late StreamController<void> controller;
    final id = ++_next;
    var cancelled = false;
    controller = StreamController<void>(
      onListen: () async {
        try {
          if (_closing || _finished) {
            controller.addError(const GitException(GitErrorCode.disconnected));
            unawaited(controller.close());
            return;
          }
          final port = await _start();
          if (cancelled || controller.isClosed) return;
          if (_closing || _finished) {
            unawaited(controller.close());
            return;
          }
          _watches[id] = controller;
          port.send(_Watch(id, repository));
        } on Object catch (error) {
          if (!controller.isClosed) controller.addError(error);
        }
      },
      onCancel: () {
        cancelled = true;
        _watches.remove(id);
        _worker?.send(_Unwatch(id));
      },
    );
    return controller.stream;
  }

  /// Retire this attachment, cancelling passive work and subscriptions. An
  /// already authorized mutation finishes and reconciles before the worker
  /// exits; closing a view is not an implicit Cancel or Git Abort.
  Future<void> close() {
    if (_closing || _finished) return _closed.future;
    _closing = true;
    for (final cancellation in _promptCancellations.values) {
      cancellation.cancel();
    }
    if (_starting == null) {
      _finish();
    } else {
      unawaited(
        _start().then(
          (port) => port.send(const _Close()),
          onError: (Object _) {
            _finish(unexpected: true);
          },
        ),
      );
    }
    return _closed.future;
  }

  void _finish({bool unexpected = false}) {
    if (_finished) return;
    _finished = true;
    if (!unexpected) _worker?.send(const _CloseAck());
    for (final cancellation in _promptCancellations.values) {
      cancellation.cancel();
    }
    _promptCancellations.clear();
    for (final call in _calls.values) {
      call.result.completeError(
        GitException(
          unexpected && call.mutation
              ? GitErrorCode.uncertainOutcome
              : GitErrorCode.disconnected,
          diagnostic: call.mutation
              ? 'The Git worker disconnected. Reinspect repository state before repeating the operation.'
              : 'The Git worker disconnected.',
        ),
      );
    }
    _calls.clear();
    for (final controller in _watches.values) {
      if (!controller.isClosed) {
        if (unexpected)
          controller.addError(const GitException(GitErrorCode.disconnected));
        unawaited(controller.close());
      }
    }
    _watches.clear();
    _messages?.close();
    _exits?.close();
    if (!_closed.isCompleted) _closed.complete();
  }
}

enum _Method {
  discover,
  status,
  references,
  history,
  content,
  changedFiles,
  patch,
  inspect,
  create,
  mutate,
}

final class _PendingCall {
  _PendingCall(this.mutation, this.progress);
  final bool mutation;
  final void Function(GitProgress)? progress;
  final result = Completer<Object?>();
}

final class _Request {
  const _Request(this.id, this.method, this.arguments);
  final int id;
  final _Method method;
  final List<Object?> arguments;
  bool get mutation =>
      method == _Method.mutate ||
      method == _Method.create ||
      method == _Method.inspect &&
          (arguments[1] as GitInspection).kind == GitInspectionKind.rebasePlan;
}

final class _Result {
  const _Result(this.id, this.value, [this.error]);
  final int id;
  final Object? value;
  final GitException? error;
}

final class _Progress {
  const _Progress(this.id, this.value);
  final int id;
  final GitProgress value;
}

final class _Cancel {
  const _Cancel(this.id);
  final int id;
}

final class _Watch {
  const _Watch(this.id, this.repository);
  final int id;
  final RepositoryId repository;
}

final class _Unwatch {
  const _Unwatch(this.id);
  final int id;
}

final class _WatchEvent {
  const _WatchEvent(this.id, [this.error]);
  final int id;
  final GitException? error;
}

final class _Close {
  const _Close();
}

final class _CloseAck {
  const _CloseAck();
}

final class _Closed {
  const _Closed();
}

final class _HostRequest {
  const _HostRequest(this.id, this.call, this.repository, this.prompt);
  final int id, call;
  final RepositoryId repository;
  final GitPrompt? prompt;
}

final class _HostReply {
  const _HostReply(this.id, this.value);
  final int id;
  final Object? value;
}

final class _PromptCancelled {
  const _PromptCancelled(this.id);
  final int id;
}

void _workerMain((SendPort, String?, String?) settings) {
  _GitWorker(settings.$1, settings.$2, settings.$3).start();
}

final class _GitWorker {
  _GitWorker(this.host, String? executable, String? helperPath) {
    engine = GitEngine(
      runner: ProcessGitRunner(executable: executable, helperPath: helperPath),
      helperPath: helperPath,
      authorize: (repository) async => await _askHost(repository, null) == true,
      prompts: (prompt, cancellation) async =>
          await _askHost(prompt.repository, prompt, cancellation: cancellation)
              as Uint8List?,
    );
  }
  final SendPort host;
  final inbox = ReceivePort();
  late final GitEngine engine;
  final _requests = <int, (_Request, GitCancellation, Future<void>)>{};
  final _watches = <int, StreamSubscription<void>>{};
  final _callbacks = <int, (int, Completer<Object?>)>{};
  final Object _callZone = Object();
  var _nextCallback = 0;
  bool _closing = false;
  Timer? _exitTimer;

  void start() {
    inbox.listen((Object? packet) {
      if (packet is _Request && !_closing) {
        final cancellation = GitCancellation();
        // Install before the asynchronous body can ask its host for permission.
        final finished = Completer<void>();
        _requests[packet.id] = (packet, cancellation, finished.future);
        unawaited(
          runZoned(() async {
            try {
              final value = await _dispatch(packet, cancellation);
              host.send(_Result(packet.id, value));
            } on GitException catch (error) {
              host.send(_Result(packet.id, null, error));
            } on Object {
              host.send(
                _Result(
                  packet.id,
                  null,
                  const GitException(
                    GitErrorCode.commandFailed,
                    diagnostic: 'Git worker request failed.',
                  ),
                ),
              );
            } finally {
              _requests.remove(packet.id);
              for (final entry
                  in _callbacks.entries
                      .where((entry) => entry.value.$1 == packet.id)
                      .toList()) {
                if (!entry.value.$2.isCompleted) entry.value.$2.complete(null);
                _callbacks.remove(entry.key);
                host.send(_PromptCancelled(entry.key));
              }
              finished.complete();
            }
          }, zoneValues: {_callZone: packet.id}),
        );
      } else if (packet is _Cancel) {
        _requests[packet.id]?.$2.cancel();
      } else if (packet is _HostReply) {
        final callback = _callbacks.remove(packet.id);
        if (callback != null && !callback.$2.isCompleted)
          callback.$2.complete(packet.value);
      } else if (packet is _Watch && !_closing) {
        _watches[packet.id] = engine
            .watch(packet.repository)
            .listen(
              (_) => host.send(_WatchEvent(packet.id)),
              onError: (Object error) => host.send(
                _WatchEvent(
                  packet.id,
                  error is GitException
                      ? error
                      : const GitException(GitErrorCode.commandFailed),
                ),
              ),
            );
      } else if (packet is _Unwatch) {
        unawaited(_watches.remove(packet.id)?.cancel());
      } else if (packet is _CloseAck && _closing) {
        _exitTimer?.cancel();
        inbox.close();
      } else if (packet is _Close && !_closing) {
        _closing = true;
        unawaited(_close());
      }
    });
    host.send(inbox.sendPort);
  }

  Future<Object?> _askHost(
    RepositoryId repository,
    GitPrompt? prompt, {
    GitCancellation? cancellation,
  }) async {
    final call = Zone.current[_callZone] as int?;
    if (call == null || !_requests.containsKey(call)) return null;
    final id = ++_nextCallback, reply = Completer<Object?>();
    _callbacks[id] = (call, reply);
    host.send(_HostRequest(id, call, repository, prompt));
    final token = cancellation ?? _requests[call]!.$2;
    try {
      final response =
          await Future.any([
            reply.future,
            token.whenCancelled.then((_) => null),
          ]).timeout(
            prompt == null
                ? const Duration(seconds: 30)
                : const Duration(minutes: 10),
            onTimeout: () => null,
          );
      token.check();
      return response;
    } finally {
      _callbacks.remove(id);
      host.send(_PromptCancelled(id));
    }
  }

  Future<Object?> _dispatch(
    _Request request,
    GitCancellation cancellation,
  ) async {
    cancellation.check();
    final a = request.arguments;
    void progress(GitProgress value) => host.send(_Progress(request.id, value));
    return switch (request.method) {
      _Method.discover => await engine.discover(
        a[0] as String,
        cancellation: cancellation,
      ),
      _Method.status => await engine.status(
        a[0] as RepositoryId,
        policy: a[1] as GitReadPolicy,
        cancellation: cancellation,
      ),
      _Method.references => await engine.references(a[0] as RepositoryId),
      _Method.history => await engine.history(
        a[0] as RepositoryId,
        filter: a[1] as HistoryFilter,
        offset: a[2] as int,
        limit: a[3] as int,
        anchor: a[4] as String?,
        cancellation: cancellation,
      ),
      _Method.content => await engine.content(
        a[0] as RepositoryId,
        a[1] as RepoPath,
        a[2] as ContentVersion,
        cancellation: cancellation,
      ),
      _Method.changedFiles => await engine.changedFiles(
        a[0] as RepositoryId,
        a[1] as GitOid,
        parent: a[2] as GitOid?,
      ),
      _Method.patch => await engine.patch(
        a[0] as RepositoryId,
        a[1] as GitDiffSpec,
        cancellation: cancellation,
      ),
      _Method.inspect => await engine.inspect(
        a[0] as RepositoryId,
        a[1] as GitInspection,
        cancellation: cancellation,
        onProgress: progress,
      ),
      _Method.create => await engine.create(
        a[0] as GitCreation,
        cancellation: cancellation,
        onProgress: progress,
      ),
      _Method.mutate => await engine.mutate(
        a[0] as RepositoryId,
        a[1] as GitMutation,
        cancellation: cancellation,
        onProgress: progress,
      ),
    };
  }

  Future<void> _close() async {
    for (final item in _requests.values) {
      if (!item.$1.mutation) item.$2.cancel();
    }
    await Future.wait(_watches.values.map((watch) => watch.cancel()));
    _watches.clear();
    await Future.wait(_requests.values.map((value) => value.$3).toList());
    host.send(const _Closed());
    // Give the host a chance to drain ordered results before the isolate's
    // independent exit notification. The timeout also bounds a lost host.
    _exitTimer = Timer(const Duration(seconds: 2), inbox.close);
  }
}
