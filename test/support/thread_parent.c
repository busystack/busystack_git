#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static char **arguments;
static pid_t child;

static void *spawn_from_worker(void *unused) {
  (void) unused;
  child = fork();
  if (child == 0) {
    execl(arguments[1], arguments[1], "--supervise", "/bin/sh", "-c",
          "printf ready > \"$1\"; sleep 1; printf survived > \"$2\"",
          "busystack-thread-parent", arguments[2], arguments[3], (char *) NULL);
    _exit(127);
  }
  const struct timespec delay = { .tv_sec = 0, .tv_nsec = 10000000 };
  for (int i = 0; i < 500 && access(arguments[2], F_OK) != 0; i++) {
    nanosleep(&delay, NULL);
  }
  // The application remains alive after this spawning thread retires.
  return NULL;
}

int main(int argc, char **argv) {
  if (argc != 4) return 64;
  arguments = argv;
  pthread_t worker;
  if (pthread_create(&worker, NULL, spawn_from_worker, NULL) != 0) return 2;
  if (pthread_join(worker, NULL) != 0 || child < 0) return 2;
  int status;
  while (waitpid(child, &status, 0) < 0) {
    if (errno != EINTR) return 3;
  }
  const int survived = access(argv[3], F_OK) == 0;
  printf("supervisor_status=%d application_alive=yes child_survived=%s\n",
         status, survived ? "yes" : "no");
  return WIFEXITED(status) && WEXITSTATUS(status) == 0 && survived ? 0 : 1;
}
