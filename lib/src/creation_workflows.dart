import 'dart:io';
import 'package:path/path.dart' as p;
import 'client.dart';
import 'context.dart';
import 'models.dart';
import 'reference_workflows.dart';
import 'repository_queries.dart';
import 'runner.dart';

final class CreationWorkflows {
  const CreationWorkflows(this.ctx, this.repositories);
  final GitContext ctx;
  final RepositoryQueries repositories;
  Future<GitCreationOutcome> create(
    GitCreation request, {
    GitCancellation? cancellation,
    void Function(GitProgress)? onProgress,
    Map<String, String> operationEnvironment = const {},
  }) async {
    final destination = p.normalize(p.absolute(request.destination));
    final parent = Directory(p.dirname(destination));
    final target = Directory(destination);
    var created = false;
    try {
      if (request is CloneRepository) validateGitSource(request.source);
      if (!p.isAbsolute(request.destination) ||
          destination != request.destination ||
          !await parent.exists() ||
          await parent.resolveSymbolicLinks() != parent.path ||
          p.basename(destination) == '.git' ||
          request.destination.contains('\u0000')) {
        throw const GitException(GitErrorCode.unsafePath);
      }
      final type = await FileSystemEntity.type(destination, followLinks: false);
      final existed = type != FileSystemEntityType.notFound;
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory)
        throw const GitException(GitErrorCode.unsafePath);
      if (request is CloneRepository && existed && !await target.list().isEmpty)
        throw const GitException(GitErrorCode.dirty);
      if (!existed) {
        await target.create();
        created = true;
      }
      final List<String> arguments;
      switch (request) {
        case CloneRepository():
          if (request.branch != null &&
              (request.branch!.isEmpty ||
                  request.branch!.startsWith('-') ||
                  request.branch!.contains('\u0000')))
            throw const GitException(GitErrorCode.invalidRequest);
          arguments = [
            'clone',
            '--progress',
            '--no-local',
            if (request.branch != null) '--branch=${request.branch}',
            if (request.recurseSubmodules) '--recurse-submodules',
            '--',
            request.source,
            destination,
          ];
        case InitializeRepository():
          final existing = await repositories.discover(destination);
          if (existing != null &&
              (p.equals(existing.root, destination) ||
                  p.equals(existing.gitDir, destination) ||
                  p.isWithin(existing.gitDir, destination) ||
                  p.equals(existing.commonDir, destination) ||
                  p.isWithin(existing.commonDir, destination))) {
            throw const GitException(
              GitErrorCode.invalidRequest,
              diagnostic:
                  'The selected target is already a repository or lies inside Git metadata.',
            );
          }
          if (await FileSystemEntity.type(
                '$destination/.git',
                followLinks: false,
              ) !=
              FileSystemEntityType.notFound) {
            throw const GitException(
              GitErrorCode.invalidRequest,
              diagnostic: 'The selected folder already has Git metadata.',
            );
          }
          arguments = [
            'init',
            if (request.initialBranch != null)
              '--initial-branch=${request.initialBranch}',
            '--',
            destination,
          ];
      }
      onProgress?.call(const GitProgress(GitOperationPhase.running));
      await ctx.run(
        parent.path,
        arguments,
        passive: false,
        cancellation: cancellation,
        environment: operationEnvironment,
        progress: (text) => onProgress?.call(
          GitProgress(GitOperationPhase.running, text: text),
        ),
      );
      final repository = await repositories.discover(destination);
      return GitCreationOutcome(
        phase: GitOperationPhase.completed,
        repository: repository,
        createdDirectory: created,
        destinationStillExists: await target.exists(),
      );
    } on GitException catch (error) {
      // Never remove pre-existing folders or recursively clean failed clones.
      // Retaining an attempt-owned directory permits deliberate inspection and
      // prevents a cancelled, possibly successful clone from being overwritten.
      return GitCreationOutcome(
        phase: error.code == GitErrorCode.cancelled
            ? GitOperationPhase.cancelled
            : GitOperationPhase.failed,
        error: error,
        createdDirectory: created,
        destinationStillExists: await target.exists(),
      );
    } on FileSystemException catch (error) {
      return GitCreationOutcome(
        phase: GitOperationPhase.failed,
        error: GitException(
          GitErrorCode.unsafePath,
          diagnostic:
              'Destination access failed (errno ${error.osError?.errorCode ?? 0}).',
        ),
        createdDirectory: created,
        destinationStillExists: await target.exists(),
      );
    } on ArgumentError {
      return GitCreationOutcome(
        phase: GitOperationPhase.failed,
        error: const GitException(GitErrorCode.invalidRequest),
        createdDirectory: created,
        destinationStillExists: await target.exists(),
      );
    }
  }
}
