#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/prctl.h>
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
/* Keep a Linux process-group owner while Git runs. Parent death is handled in
 * native code, including when Dart cannot run its finally blocks after SIGKILL.
 * This mode accepts only the trusted runner's selected absolute executable; it
 * is never available as a UI/IPC operation and has no elevated privileges. */
static int supervise(int argc, char **argv) {
  (void) argc;
  if (argv[2][0] != '/') return 1;
  pid_t parent = getppid();
  if (parent <= 1 || setsid() < 0) return 1;
  struct sigaction action = { .sa_handler = stop_group };
  sigemptyset(&action.sa_mask);
  sigaction(SIGTERM, &action, NULL); sigaction(SIGINT, &action, NULL); sigaction(SIGHUP, &action, NULL);
  if (prctl(PR_SET_PDEATHSIG, SIGTERM) < 0 || getppid() != parent) return 1;
  pid_t owner = getpid(), child = fork();
  if (child < 0) return 1;
  if (child == 0) {
    signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGHUP, SIG_DFL); signal(SIGALRM, SIG_DFL);
    alarm(0);
    if (prctl(PR_SET_PDEATHSIG, SIGTERM) < 0 || getppid() != owner) _exit(143);
    execv(argv[2], argv + 2); _exit(127);
  }
  int status;
  while (waitpid(child, &status, 0) < 0) { if (errno != EINTR) return 1; }
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

/* Installed prompt helper: no SDK or repository-owned helper scripts.
 * Socket requests are authenticated and operation scoped. */
int main(int argc, char **argv) {
  if (argc >= 3 && strcmp(argv[1], "--supervise") == 0) return supervise(argc, argv);
  if (argc >= 3 && strcmp(argv[1], "--git-argv") == 0) return git_argv(argc, argv);
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
