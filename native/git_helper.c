#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/un.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t stopping;
static void force_group_exit(int number) {
  (void) number;
  kill(-getpgrp(), SIGKILL);
  _exit(137);
}
static void stop_group(int number) {
  (void) number;
  if (stopping) return;
  stopping = 1;
  signal(SIGALRM, force_group_exit);
  alarm(1);
  kill(-getpgrp(), SIGTERM);
}
/* Keep a Linux process-group owner while Git runs. Process pidfds distinguish
 * application death from the retirement of the Dart thread that spawned us.
 * PR_SET_PDEATHSIG alone observes that thread, not the application lifetime.
 * Cleanup remains native when Dart cannot run finally blocks after SIGKILL.
 * This mode accepts only the trusted runner's selected absolute executable; it
 * is never available as a UI/IPC operation and has no elevated privileges. */
static int supervise(int argc, char **argv) {
  (void) argc;
  if (argv[2][0] != '/') return 1;
  pid_t parent = getppid();
  if (parent <= 1 || setsid() < 0) return 1;
  int parent_fd = (int) syscall(SYS_pidfd_open, parent, 0);
  if (parent_fd < 0) {
    perror("Git supervisor requires process lifetime monitoring (Linux 5.3 or newer)");
    return 1;
  }
  if (getppid() != parent) { close(parent_fd); return 1; }
  struct sigaction action = { .sa_handler = stop_group };
  sigemptyset(&action.sa_mask);
  sigaction(SIGTERM, &action, NULL); sigaction(SIGINT, &action, NULL); sigaction(SIGHUP, &action, NULL);
  pid_t owner = getpid(), child = fork();
  if (child < 0) { close(parent_fd); return 1; }
  if (child == 0) {
    close(parent_fd);
    signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGHUP, SIG_DFL); signal(SIGALRM, SIG_DFL);
    alarm(0);
    if (prctl(PR_SET_PDEATHSIG, SIGTERM) < 0 || getppid() != owner) _exit(143);
    char owned_pid[32];
    snprintf(owned_pid, sizeof(owned_pid), "%ld", (long) getpid());
    if (setenv("BUSYSTACK_GIT_OWNER_PID", owned_pid, 1) < 0) _exit(127);
    execv(argv[2], argv + 2); _exit(127);
  }
  int child_fd = (int) syscall(SYS_pidfd_open, child, 0);
  if (child_fd < 0) {
    perror("Git supervisor cannot monitor its child process");
    stop_group(SIGTERM);
    for (;;) pause();
  }
  struct pollfd lifetimes[2] = {
    { .fd = parent_fd, .events = POLLIN },
    { .fd = child_fd, .events = POLLIN }
  };
  for (;;) {
    int ready = poll(lifetimes, 2, -1);
    if (ready < 0 && errno == EINTR) continue;
    if (ready < 0 || lifetimes[0].revents ||
        (lifetimes[1].revents & (POLLERR | POLLNVAL))) {
      stop_group(SIGTERM);
      for (;;) pause();
    }
    if (lifetimes[1].revents & (POLLIN | POLLHUP)) break;
  }
  int status;
  while (waitpid(child, &status, 0) < 0) { if (errno != EINTR) return 1; }
  close(child_fd); close(parent_fd);
  if (stopping) for (;;) pause();
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

static int transfer(int fd, void *buffer, size_t length, int writing) {
  unsigned char *bytes = buffer;
  while (length) {
    ssize_t count = writing ? write(fd, bytes, length) : read(fd, bytes, length);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) return 0;
    bytes += count; length -= (size_t) count;
  }
  return 1;
}

/* execv preserves Linux filename bytes that a Dart String cannot represent.
 * This local mode has no socket, file writes, shell, or elevated privileges;
 * the controlled runner supplies its already selected absolute Git executable.
 * Git's stdin and process group remain those of the controlled runner. */
static int hex_digit(char value) {
  if (value >= '0' && value <= '9') return value - '0';
  if (value >= 'a' && value <= 'f') return value - 'a' + 10;
  return -1;
}
static int git_argv(int argc, char **argv) {
  const char *git = argv[2];
  size_t length = strlen(git), total = 0;
  if (git[0] != '/' || length < 4 || strcmp(git + length - 4, "/git") != 0 || argc > 4099) return 1;
  char **arguments = calloc((size_t) argc - 1, sizeof(char *));
  if (!arguments) return 1;
  arguments[0] = argv[2];
  for (int i = 3; i < argc; ++i) {
    length = strlen(argv[i]); total += length;
    if (length % 2 || length > 1048576 || total > 8388608) return 1;
    char *decoded = calloc(length / 2 + 1, 1);
    if (!decoded) return 1;
    for (size_t j = 0; j < length; j += 2) {
      int high = hex_digit(argv[i][j]), low = hex_digit(argv[i][j + 1]);
      if (high < 0 || low < 0 || (high == 0 && low == 0)) return 1;
      decoded[j / 2] = (char) (high * 16 + low);
    }
    arguments[i - 2] = decoded;
  }
  execv(git, arguments);
  return 1;
}

/* Git invokes this extra, operation-local hook with the ref locks held. The
 * transaction's old-value can be all zeroes even when deleting an existing
 * branch, so read the actual ref through the same trusted Git executable.
 * User hooks remain Git's responsibility; no repository metadata is written. */
static int reference_guard(int argc, char **argv) {
  if (argc != 5) return 1;
  if (strcmp(argv[4], "prepared") != 0) return 0;
  const char *git = getenv("BUSYSTACK_GIT_RUNTIME"), *ref = argv[2], *expected = argv[3];
  size_t oid_length = strlen(expected);
  if (!git || git[0] != '/' || strncmp(ref, "refs/heads/", 11) != 0 ||
      strlen(ref) > 262144 || (oid_length != 40 && oid_length != 64)) return 1;
  for (size_t i = 0; i < oid_length; ++i) if (hex_digit(expected[i]) < 0) return 1;
  alarm(10);
  char *line = malloc(262146);
  if (!line) return 1;
  size_t total = 0;
  int matched = 0;
  while (fgets(line, 262146, stdin)) {
    size_t length = strlen(line);
    total += length;
    if (!length || line[length - 1] != '\n' || total > 8388608) { free(line); return 1; }
    line[length - 1] = 0;
    char *first = strchr(line, ' '), *second = first ? strchr(first + 1, ' ') : NULL;
    if (!second) { free(line); return 1; }
    if (strcmp(second + 1, ref) == 0) matched = 1;
  }
  free(line);
  if (ferror(stdin)) return 1;
  if (!matched) return 0;
  int descriptors[2];
  if (pipe2(descriptors, O_CLOEXEC) < 0) return 1;
  pid_t owner = getpid(), child = fork();
  if (child < 0) { close(descriptors[0]); close(descriptors[1]); return 1; }
  if (child == 0) {
    close(descriptors[0]);
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0 || getppid() != owner ||
        dup2(descriptors[1], STDOUT_FILENO) < 0) _exit(1);
    close(descriptors[1]);
    char *arguments[] = {(char *) git, "--no-pager", "-c", "core.fsmonitor=false",
      "rev-parse", "--verify", "--quiet", "--end-of-options", (char *) ref, NULL};
    execv(git, arguments); _exit(127);
  }
  close(descriptors[1]);
  char actual[67]; size_t count = 0;
  while (count < sizeof(actual)) {
    ssize_t received = read(descriptors[0], actual + count, sizeof(actual) - count);
    if (received < 0 && errno == EINTR) continue;
    if (received <= 0) break;
    count += (size_t) received;
  }
  close(descriptors[0]);
  int status;
  while (waitpid(child, &status, 0) < 0) { if (errno != EINTR) return 1; }
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0 || count != oid_length + 1 ||
      actual[oid_length] != '\n' || memcmp(actual, expected, oid_length) != 0) {
    fputs("BusyStack reviewed reference changed; refresh and review again.\n", stderr);
    return 1;
  }
  return 0;
}

/* Only the runner's own Git transaction is guarded/observed. A configured hook
 * may invoke another Git to publish a tag or advance an auxiliary reference;
 * those commands retain their normal behavior. The native supervisor stamps
 * the owning PID after fork, so inherited environment cannot select it. */
static int owned_git_callback(void) {
  const char *value = getenv("BUSYSTACK_GIT_OWNER_PID");
  char *end;
  errno = 0;
  long owned = value ? strtol(value, &end, 10) : 0;
  if (!value || !*value || *end || errno || owned <= 1) return -1;
  /* The installed command uses shell exec, preserving Git as our direct
   * parent. Nested Git commands in user hooks have a different parent PID. */
  return (long) getppid() == owned;
}

static int guarded_git_read(const char *git, int symbolic, const char *ref, char *output, size_t capacity, size_t *length) {
  int descriptors[2];
  if (pipe2(descriptors, O_CLOEXEC) < 0) return -1;
  pid_t owner = getpid(), child = fork();
  if (child < 0) { close(descriptors[0]); close(descriptors[1]); return -1; }
  if (child == 0) {
    close(descriptors[0]);
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0 || getppid() != owner ||
        dup2(descriptors[1], STDOUT_FILENO) < 0) _exit(1);
    close(descriptors[1]);
    char *symbolic_args[] = {(char *) git, "--no-pager", "-c", "core.fsmonitor=false",
      "symbolic-ref", "--quiet", (char *) ref, NULL};
    char *oid_args[] = {(char *) git, "--no-pager", "-c", "core.fsmonitor=false",
      "rev-parse", "--verify", "--quiet", "--end-of-options", (char *) ref, NULL};
    execv(git, symbolic ? symbolic_args : oid_args); _exit(127);
  }
  close(descriptors[1]);
  *length = 0;
  while (*length < capacity) {
    ssize_t received = read(descriptors[0], output + *length, capacity - *length);
    if (received < 0 && errno == EINTR) continue;
    if (received <= 0) break;
    *length += (size_t) received;
  }
  close(descriptors[0]);
  int status;
  while (waitpid(child, &status, 0) < 0) { if (errno != EINTR) return -1; }
  if (!WIFEXITED(status) || *length == capacity) return -1;
  return WEXITSTATUS(status);
}

static int commit_receipt(const char *oid) {
  const char *path = getenv("BUSYSTACK_GIT_RECEIPT_PATH"),
    *token = getenv("BUSYSTACK_GIT_RECEIPT_TOKEN"),
    *identity = getenv("BUSYSTACK_GIT_RECEIPT_ID");
  if (!path || path[0] != '/' || !token || strlen(token) != 64 || !identity) return 0;
  for (int i = 0; i < 64; ++i) if (hex_digit(token[i]) < 0) return 0;
  int fd = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) return 0;
  struct stat info;
  char actual_identity[128], header[65];
  int valid = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) &&
    info.st_uid == geteuid() && (info.st_mode & 0777) == 0600 && info.st_nlink == 1;
  if (valid) {
    snprintf(actual_identity, sizeof(actual_identity), "%u:%u:%llu",
      major(info.st_dev), minor(info.st_dev), (unsigned long long) info.st_ino);
    valid = strcmp(identity, actual_identity) == 0 && pread(fd, header, sizeof(header), 0) == 65 &&
      memcmp(header, token, 64) == 0 && header[64] == '\n';
  }
  if (valid && oid) {
    size_t length = strlen(oid);
    char body[66]; memcpy(body, oid, length); body[length++] = '\n';
    valid = pwrite(fd, body, length, 65) == (ssize_t) length &&
      ftruncate(fd, (off_t) (65 + length)) == 0 && fsync(fd) == 0;
  }
  close(fd);
  return valid;
}

static int head_guard(int argc, char **argv) {
  if (argc != 5) return 1;
  int prepared = strcmp(argv[4], "prepared") == 0,
      committed = strcmp(argv[4], "committed") == 0;
  if (!prepared && !committed) return 0;
  const char *git = getenv("BUSYSTACK_GIT_RUNTIME"), *ref = argv[2], *expected = argv[3];
  size_t oid_length = strlen(expected);
  if (!git || git[0] != '/' || strlen(ref) > 262144 ||
      (strcmp(ref, "-") != 0 && strncmp(ref, "refs/heads/", 11) != 0) ||
      (strcmp(expected, "-") != 0 && oid_length != 40 && oid_length != 64)) return 1;
  if (strcmp(expected, "-") != 0)
    for (size_t i = 0; i < oid_length; ++i) if (hex_digit(expected[i]) < 0) return 1;
  alarm(10);
  int owned = owned_git_callback();
  if (owned < 0) return 1;
  char *line = malloc(262146);
  if (!line) return 1;
  size_t total = 0;
  int unexpected_target = 0;
  char new_oid[65] = {0};
  while (fgets(line, 262146, stdin)) {
    size_t length = strlen(line); total += length;
    if (!length || line[length - 1] != '\n' || total > 8388608) { free(line); return 1; }
    line[length - 1] = 0;
    char *first = strchr(line, ' '), *second = first ? strchr(first + 1, ' ') : NULL;
    if (!second) { free(line); return 1; }
    int branch = strncmp(second + 1, "refs/heads/", 11) == 0;
    if (owned && (strcmp(second + 1, "HEAD") == 0 || branch)) {
      size_t length = (size_t) (second - first - 1);
      if (length != 40 && length != 64) { free(line); return 1; }
      for (size_t i = 0; i < length; ++i) if (hex_digit(first[1 + i]) < 0) { free(line); return 1; }
      if (*new_oid && (strlen(new_oid) != length || memcmp(new_oid, first + 1, length) != 0)) { free(line); return 1; }
      memcpy(new_oid, first + 1, length); new_oid[length] = 0;
      if (prepared && branch && strcmp(second + 1, ref) != 0) {
        char *target = malloc(262146);
        size_t count = 0;
        if (!target) { free(line); return 1; }
        int code = guarded_git_read(git, 1, second + 1, target, 262146, &count);
        /* Intermediate symbolic branch aliases are allowed only when they
         * resolve to the exact final target that was reviewed. */
        if (code != 0 || count != strlen(ref) + 1 ||
            target[count - 1] != '\n' || memcmp(target, ref, count - 1) != 0) unexpected_target = 1;
        free(target);
      }
    }
  }
  free(line);
  if (ferror(stdin)) return 1;
  if (owned == 0) return 0;
  /* commit also cleans sequencer pseudorefs after updating HEAD. Those are
   * separate transactions and must neither recheck the old tip nor replace
   * the recorded commit outcome. */
  if (!*new_oid) return 0;
  if (unexpected_target) {
    fputs("BusyStack reviewed reference changed (commit target); refresh and review again.\n", stderr);
    return 1;
  }
  if (!commit_receipt(NULL)) return 1;
  if (committed) return *new_oid && commit_receipt(new_oid) ? 0 : 1;
  char *actual = malloc(262146);
  if (!actual) return 1;
  size_t length;
  int result = guarded_git_read(git, 1, "HEAD", actual, 262146, &length);
  int valid = strcmp(ref, "-") == 0 ? result == 1 && length == 0 :
    result == 0 && length == strlen(ref) + 1 && actual[length - 1] == '\n' && memcmp(actual, ref, length - 1) == 0;
  if (valid) {
    result = guarded_git_read(git, 0, "HEAD", actual, 262146, &length);
    valid = strcmp(expected, "-") == 0 ? result == 1 && length == 0 :
      result == 0 && length == oid_length + 1 && actual[length - 1] == '\n' && memcmp(actual, expected, oid_length) == 0;
  }
  free(actual);
  if (!valid) {
    fputs("BusyStack reviewed reference changed (HEAD); refresh and review again.\n", stderr);
    return 1;
  }
  return 0;
}

/* Installed prompt helper: no SDK or repository-owned helper scripts.
 * Socket requests are authenticated and operation scoped. */
int main(int argc, char **argv) {
  if (argc >= 3 && strcmp(argv[1], "--supervise") == 0) return supervise(argc, argv);
  if (argc >= 3 && strcmp(argv[1], "--git-argv") == 0) return git_argv(argc, argv);
  if (argc >= 2 && strcmp(argv[1], "--reference-guard") == 0) return reference_guard(argc, argv);
  if (argc >= 2 && strcmp(argv[1], "--head-guard") == 0) return head_guard(argc, argv);
  const char *socket_path = getenv("BUSYSTACK_GIT_PROMPT_SOCKET");
  const char *token = getenv("BUSYSTACK_GIT_PROMPT_TOKEN");
  const char *operation = getenv("BUSYSTACK_GIT_OPERATION");
  if (!socket_path || !token || !operation || strlen(token) != 64 || strlen(operation) != 32) return 1;
  const char *payload = NULL;
  unsigned char kind = 3;
  if (argc == 3 && strcmp(argv[1], "editor") == 0) { kind = 1; payload = argv[2]; }
  else if (argc == 3 && strcmp(argv[1], "sequence") == 0) { kind = 2; payload = argv[2]; }
  else if (argc == 2) { payload = argv[1]; }
  else return 1;
  size_t length = strlen(payload);
  if (length > 262144) return 1;
  struct sockaddr_un address = { .sun_family = AF_UNIX };
  if (strlen(socket_path) >= sizeof(address.sun_path)) return 1;
  memcpy(address.sun_path, socket_path, strlen(socket_path) + 1);
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return 1;
  alarm(600);
  if (connect(fd, (struct sockaddr *) &address, sizeof(address)) != 0) { close(fd); return 1; }
  struct ucred peer; socklen_t peer_length = sizeof(peer);
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &peer_length) != 0 || peer.uid != geteuid()) { close(fd); return 1; }
  uint32_t size = htonl((uint32_t) length);
  if (!transfer(fd, "BSG1", 4, 1) || !transfer(fd, (void *) token, 64, 1) ||
      !transfer(fd, (void *) operation, 32, 1) || !transfer(fd, &kind, 1, 1) ||
      !transfer(fd, &size, 4, 1) || !transfer(fd, (void *) payload, length, 1)) { close(fd); return 1; }
  unsigned char status;
  if (!transfer(fd, &status, 1, 0) || !transfer(fd, &size, 4, 0)) { close(fd); return 1; }
  size = ntohl(size);
  if (status != 0 || size > 65536) { close(fd); return 1; }
  unsigned char *answer = calloc((size_t) size + 1, 1);
  if (!answer) { close(fd); return 1; }
  int success = transfer(fd, answer, size, 0);
  if (success && kind == 3) success = transfer(STDOUT_FILENO, answer, size, 1) && transfer(STDOUT_FILENO, "\n", 1, 1);
  explicit_bzero(answer, (size_t) size + 1); free(answer); close(fd);
  return success ? 0 : 1;
}
