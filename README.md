# busystack_git

Shared BusyStack Git engine for Linux, using a controlled Git executable. This
package has no Flutter, application workspace, cloud-account or global current
repository state. BusyMark consumes it directly; BusyFiles runs it in busyfilesd.

Requires Dart `>=3.12.1 <4.0.0` and Git **2.56 or newer**. Both applications
build and deliver the hash-verified Git 2.56.0 source in `native/vendor/`.
`native/CMakeLists.txt` installs the runtime, Git's libsecret credential helper,
and the libc-only `busystack-git-helper`; no Dart or Flutter SDK is used at
runtime. The native helper handles authenticated messages/askpass requests and
lossless Linux filename arguments. It also supervises each Git process group
through cancellation or parent death. It never runs a shell for path arguments.

The engine and helper sources use Apache-2.0. The separately executed upstream
Git runtime uses GPL-2.0-only; its complete source and copying terms are included
in `native/vendor/` and source archives. Application distribution must retain
that corresponding source and license. Build prerequisites are a C compiler,
Make, CMake 3.24, Ninja, pkg-config, zlib, curl, OpenSSL, expat and libsecret/GLib
development headers. Git is built offline without Rust, Perl or Tcl/Tk tools.
OpenSSH and configured signing/pinentry tools are application runtime inputs.

`GitClient` provides identity-bound discovery, status, content, paged history,
mutations and invalidation subscriptions. `GitWorkflowClient` provides closed,
typed workflow requests and bounded management metadata. `GitPatchClient`
provides patches between explicit content endpoints. `RepoPath` preserves Linux
path bytes; its display string is never a mutation path. Content distinguishes
working bytes, normalized index input, index entries, historical blobs, unmerged
stages, unavailable objects, binary data and large-content limits.

Hosts supply a repository-scoped authorization decision and prompt handler.
Passive inspection disables fsmonitor/external diff/textconv and refuses
configured executable clean/process filters even when a mutation grant exists.
An explicitly requested `GitReadPolicy.authorized` inspection additionally
requires the host's execution grant. Ownership
checks remain enabled. Authorized operations honor Git hooks, filters, signing,
credential helpers and SSH configuration. Prompt replies use private,
operation-bound sockets and are excluded from diagnostics.

Mutation requests bind reviewed HEAD/index/content identities. Index review
tokens also bind the current symbolic HEAD target, so an external switch or
rename to a branch at the same commit invalidates the old review. Granular staging
uses an ephemeral alternate index while holding the actual Git index lock, then
atomically installs that index; it never rewrites working files to stage them.
Repository/common-directory advisory locks coordinate BusyStack processes. Git's
locks and sequencer remain authoritative for other clients. Open-worktree leases
protect worktrees used by BusyStack views. A cancelled process is reconciled;
cancellation is separate from aborting a continuing operation. Push leases retain
the exact remote tips reviewed, including across a background fetch.
Branch deletion checks its reviewed tip inside Git's locked reference
transaction with an operation-local native guard; it retains Git's own merged
and worktree-occupancy checks and configured hooks.
Worktree changes bind the reviewed checkout identity and status. Submodule
updates bind the checked-out gitlink, coordinate initialized child repositories
with their discovered superproject, and require separate execution grants for
those children. Recursion is explicit; an existing child operation prevents an
incompatible update.

Historical and working content is bounded to 4 MiB per read. Editable text is
strict UTF-8; binary, unavailable or oversized content keeps whole-file actions.
Text decoding preserves leading byte-order marks, line endings and the final
newline. Linux filenames retain a leading U+FEFF as part of their byte identity;
display labels escape that invisible character.
Display settings never change selected index bytes. Applications own dirty
document protection, notifications, localized copy and repository trust storage.

For sibling consumption use `path: ../busystack_git` from an application at the
same directory level. The Flutter package must resolve this same core instance.
Source archives can be produced with `python3 tool/source_archive.py . OUTPUT`;
build/cache data and Git metadata are excluded.

Verification:

```sh
dart pub get --enforce-lockfile
python3 tool/build_runtime.py --build-dir /tmp/busystack-git-native
export BUSYSTACK_GIT_EXECUTABLE=/tmp/busystack-git-native/git-runtime/bin/git
export BUSYSTACK_TEST_GIT="$BUSYSTACK_GIT_EXECUTABLE"
export BUSYSTACK_TEST_GIT_256="$BUSYSTACK_GIT_EXECUTABLE"
export BUSYSTACK_GIT_HELPER_PATH=/tmp/busystack-git-native/busystack-git-helper
dart run tool/check_git.dart
dart analyze
dart test
dart test test/configured_hooks_fixture.dart
dart test test/ssh_transport_fixture.dart
```

Tests use disposable repositories and isolated configuration. Native-helper
fixtures require a C compiler; SSH-signing fixtures require OpenSSH. The explicit
2.56 fixture fails when its executable prerequisite is absent. Nothing contacts
the developer's remotes or modifies global Git configuration.

The explicit SSH transport fixture additionally requires `sshd` (or an absolute
`BUSYSTACK_TEST_SSHD` executable). It starts its own loopback server and generates
its own keys. Its temporary public authorized-key file lives in a private child
of the account home so OpenSSH can enforce normal ownership checks; existing
SSH files and settings are not changed. `BUSYSTACK_SSH_AUTH_ROOT` can select
another suitable owned parent. HTTPS uses an isolated test CA; the separate
askpass fixture exercises operation-bound prompt replies and cancellation.

`tool/benchmark.dart` is a separate, fixed engine performance fixture: 10,000
tracked files, 10,000 untracked files, 100 modifications and 501 commits. Compile
it with `dart compile exe tool/benchmark.dart -o /tmp/busystack-git-benchmark`
and run with the verification environment above on an otherwise quiet machine.
The budgets are 3 seconds per complete status, 1 second per 100-commit history
page, 1.5 seconds to cancel a read, a 50 ms maximum caller-isolate timer gap and
384 MiB peak Dart RSS. These keep complete repository scans bounded while
reserving the calling isolate for desktop interaction. The JSON result reports
each check independently; it does not measure native rendering, total child
process memory or prove application responsiveness. Host release/profile UI
measurements remain separate acceptance checks.
