#define _GNU_SOURCE

#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define FRAME_HEADER_SIZE 12
#define SOURCE_LIMIT ((uint64_t)67108864)
#define PROTOCOL_ERROR 64
#define INTERNAL_ERROR 125
#define TERM_GRACE_MS 200
#define CLEANUP_LIMIT_MS 600

static const unsigned char frame_prefix[4] = {'S', 'G', 'P', 1};
static volatile sig_atomic_t stop_requested = 0;

static void request_stop(int signal_number) {
  (void)signal_number;
  stop_requested = 1;
}

static void install_handlers(void) {
  struct sigaction action = {0};
  action.sa_handler = request_stop;
  sigemptyset(&action.sa_mask);

  if (sigaction(SIGTERM, &action, NULL) < 0 ||
      sigaction(SIGINT, &action, NULL) < 0 ||
      sigaction(SIGHUP, &action, NULL) < 0) {
    _exit(INTERNAL_ERROR);
  }

  struct sigaction ignored = {0};
  ignored.sa_handler = SIG_IGN;
  sigemptyset(&ignored.sa_mask);
  if (sigaction(SIGPIPE, &ignored, NULL) < 0) {
    _exit(INTERNAL_ERROR);
  }
}

static void reset_handlers(void) {
  struct sigaction action = {0};
  action.sa_handler = SIG_DFL;
  sigemptyset(&action.sa_mask);

  (void)sigaction(SIGTERM, &action, NULL);
  (void)sigaction(SIGINT, &action, NULL);
  (void)sigaction(SIGHUP, &action, NULL);
  (void)sigaction(SIGPIPE, &action, NULL);
}

static bool read_exact(int fd, unsigned char *buffer, size_t size) {
  size_t offset = 0;

  while (offset < size && !stop_requested) {
    ssize_t count = read(fd, buffer + offset, size - offset);
    if (count > 0) {
      offset += (size_t)count;
    } else if (count == 0) {
      return false;
    } else if (errno != EINTR) {
      return false;
    }
  }

  return offset == size;
}

static bool parse_frame_length(uint64_t *length) {
  unsigned char header[FRAME_HEADER_SIZE];
  if (!read_exact(STDIN_FILENO, header, sizeof(header)) ||
      memcmp(header, frame_prefix, sizeof(frame_prefix)) != 0) {
    return false;
  }

  uint64_t value = 0;
  for (size_t index = sizeof(frame_prefix); index < sizeof(header); index++) {
    value = (value << 8) | header[index];
  }

  if (value > SOURCE_LIMIT) {
    return false;
  }

  *length = value;
  return true;
}

static int64_t monotonic_ms(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) < 0) {
    return -1;
  }
  return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static bool signal_group(pid_t pgid, int signal_number) {
  if (kill(-pgid, signal_number) == 0 || errno == ESRCH) {
    return true;
  }
  return false;
}

static bool child_exited(pid_t child, bool *exited) {
  siginfo_t information = {0};
  if (waitid(P_PID, (id_t)child, &information,
             WEXITED | WNOHANG | WNOWAIT) < 0) {
    if (errno == EINTR) {
      return true;
    }
    return false;
  }
  *exited = information.si_pid == child;
  return true;
}

static void pause_briefly(void) {
  const struct timespec delay = {.tv_sec = 0, .tv_nsec = 10000000};
  (void)nanosleep(&delay, NULL);
}

typedef bool (*child_visitor)(pid_t child, void *context);

static bool visit_direct_children(child_visitor visitor, void *context,
                                  int64_t deadline) {
  DIR *tasks = opendir("/proc/self/task");
  if (tasks == NULL) {
    return false;
  }

  bool ok = true;
  struct dirent *entry;
  while (ok && (entry = readdir(tasks)) != NULL) {
    int64_t now = monotonic_ms();
    if (now < 0 || now >= deadline) {
      ok = false;
      break;
    }
    char *end = NULL;
    errno = 0;
    (void)strtol(entry->d_name, &end, 10);
    if (errno != 0 || end == entry->d_name || *end != '\0') {
      continue;
    }

    char path[128];
    int length = snprintf(path, sizeof(path), "/proc/self/task/%s/children",
                          entry->d_name);
    if (length < 0 || (size_t)length >= sizeof(path)) {
      ok = false;
      break;
    }

    FILE *children = fopen(path, "re");
    if (children == NULL) {
      if (errno == ENOENT) {
        continue;
      }
      ok = false;
      break;
    }

    long value;
    while (fscanf(children, "%ld", &value) == 1) {
      now = monotonic_ms();
      if (now < 0 || now >= deadline) {
        ok = false;
        break;
      }
      if (value <= 0 || value > INT32_MAX ||
          !visitor((pid_t)value, context)) {
        ok = false;
        break;
      }
    }
    if (ferror(children)) {
      ok = false;
    }
    (void)fclose(children);
  }

  (void)closedir(tasks);
  return ok;
}

struct find_child_context {
  pid_t wanted;
  bool found;
};

static bool find_child(pid_t child, void *opaque) {
  struct find_child_context *context = opaque;
  if (child == context->wanted) {
    context->found = true;
  }
  return true;
}

static bool is_direct_child(pid_t child, bool *direct, int64_t deadline) {
  struct find_child_context context = {.wanted = child, .found = false};
  if (!visit_direct_children(find_child, &context, deadline)) {
    return false;
  }
  *direct = context.found;
  return true;
}

struct adopted_context {
  pid_t leader;
  int signal_number;
  bool remaining;
  int64_t deadline;
};

static bool signal_adopted_child(pid_t child, void *opaque) {
  struct adopted_context *context = opaque;
  if (child == context->leader) {
    return true;
  }

  int pidfd = (int)syscall(SYS_pidfd_open, child, 0);
  if (pidfd < 0) {
    return errno == ESRCH;
  }

  bool direct = false;
  bool ok = is_direct_child(child, &direct, context->deadline);
  if (ok && direct &&
      syscall(SYS_pidfd_send_signal, pidfd, context->signal_number, NULL, 0) <
          0 &&
      errno != ESRCH) {
    ok = false;
  }
  (void)close(pidfd);

  if (!ok || !direct) {
    return ok;
  }

  int status = 0;
  pid_t reaped = waitpid(child, &status, WNOHANG);
  if (reaped == 0) {
    context->remaining = true;
  } else if (reaped < 0) {
    return false;
  }
  return true;
}

static bool adopted_children_remain(pid_t leader, int signal_number,
                                    bool *remaining, int64_t deadline) {
  struct adopted_context context = {
      .leader = leader,
      .signal_number = signal_number,
      .remaining = false,
      .deadline = deadline,
  };
  if (!visit_direct_children(signal_adopted_child, &context, deadline)) {
    return false;
  }

  struct adopted_context verify = {
      .leader = leader,
      .signal_number = signal_number,
      .remaining = false,
      .deadline = deadline,
  };
  if (!visit_direct_children(signal_adopted_child, &verify, deadline)) {
    return false;
  }
  *remaining = context.remaining || verify.remaining;
  return true;
}

static bool teardown_tree(pid_t leader) {
  int64_t started = monotonic_ms();
  if (started < 0) {
    return false;
  }
  int64_t term_deadline = started + TERM_GRACE_MS;
  int64_t cleanup_deadline = started + CLEANUP_LIMIT_MS;

  if (!signal_group(leader, SIGTERM)) {
    return false;
  }

  int signal_number = SIGTERM;
  while (true) {
    int64_t now = monotonic_ms();
    if (now < 0 || now >= cleanup_deadline) {
      return false;
    }
    if (signal_number == SIGTERM && now >= term_deadline) {
      signal_number = SIGKILL;
      if (!signal_group(leader, SIGKILL)) {
        return false;
      }
    }

    bool exited = false;
    bool adopted_remain = false;
    if (!child_exited(leader, &exited) ||
        !adopted_children_remain(leader, signal_number, &adopted_remain,
                                 cleanup_deadline)) {
      return false;
    }
    if (exited && !adopted_remain) {
      return true;
    }
    pause_briefly();
  }
}

static bool await_readiness(int fd) {
  int64_t deadline = monotonic_ms();
  if (deadline < 0) {
    return false;
  }
  deadline += CLEANUP_LIMIT_MS;

  while (!stop_requested) {
    int64_t now = monotonic_ms();
    if (now < 0 || now >= deadline) {
      return false;
    }
    struct pollfd readiness = {
        .fd = fd,
        .events = POLLIN | POLLHUP | POLLERR,
        .revents = 0,
    };
    int remaining = (int)(deadline - now);
    int result = poll(&readiness, 1, remaining);
    if (result < 0 && errno == EINTR) {
      continue;
    }
    if (result <= 0 || (readiness.revents & POLLIN) == 0) {
      return false;
    }

    unsigned char ready = 0;
    return read(fd, &ready, 1) == 1 && ready == 1;
  }
  return false;
}

static bool kill_unready_child(pid_t child) {
  if (kill(child, SIGKILL) < 0 && errno != ESRCH) {
    return false;
  }
  int64_t deadline = monotonic_ms();
  if (deadline < 0) {
    return false;
  }
  deadline += CLEANUP_LIMIT_MS;

  while (true) {
    int64_t now = monotonic_ms();
    if (now < 0 || now >= deadline) {
      return false;
    }
    int status = 0;
    pid_t reaped = waitpid(child, &status, WNOHANG);
    if (reaped == child || (reaped < 0 && errno == ECHILD)) {
      return true;
    }
    if (reaped < 0 && errno != EINTR) {
      return false;
    }
    pause_briefly();
  }
  return false;
}

static int exit_code(int status) {
  if (WIFEXITED(status)) {
    return WEXITSTATUS(status);
  }
  if (WIFSIGNALED(status)) {
    return 128 + WTERMSIG(status);
  }
  return INTERNAL_ERROR;
}

static int deliver_payload(int target_stdin, const unsigned char *payload,
                           size_t size) {
  size_t offset = 0;

  while (offset < size && !stop_requested) {
    struct pollfd descriptors[2] = {
        {
            .fd = STDIN_FILENO,
            .events = POLLIN | POLLHUP | POLLERR,
            .revents = 0,
        },
        {
            .fd = target_stdin,
            .events = POLLOUT | POLLHUP | POLLERR,
            .revents = 0,
        },
    };

    int result = poll(descriptors, 2, -1);
    if (result < 0) {
      if (errno == EINTR) {
        continue;
      }
      return INTERNAL_ERROR;
    }

    if ((descriptors[0].revents &
         (POLLIN | POLLHUP | POLLERR | POLLNVAL)) != 0) {
      return 143;
    }

    if ((descriptors[1].revents & (POLLHUP | POLLERR | POLLNVAL)) != 0) {
      return INTERNAL_ERROR;
    }

    if ((descriptors[1].revents & POLLOUT) != 0) {
      size_t remaining = size - offset;
      size_t wanted = remaining < 65536 ? remaining : 65536;
      ssize_t count = write(target_stdin, payload + offset, wanted);

      if (count > 0) {
        offset += (size_t)count;
      } else if (count < 0 && errno != EINTR && errno != EAGAIN &&
                 errno != EWOULDBLOCK) {
        return INTERNAL_ERROR;
      }
    }
  }

  return offset == size ? 0 : 143;
}

static bool control_cancelled(void) {
  struct pollfd control = {
      .fd = STDIN_FILENO,
      .events = POLLIN | POLLHUP | POLLERR,
      .revents = 0,
  };
  int result;

  do {
    result = poll(&control, 1, 10);
  } while (result < 0 && errno == EINTR && !stop_requested);

  if (stop_requested || result < 0) {
    return true;
  }
  if (result == 0) {
    return false;
  }
  if ((control.revents & (POLLHUP | POLLERR | POLLNVAL)) != 0) {
    return true;
  }
  if ((control.revents & POLLIN) != 0) {
    unsigned char unexpected;
    ssize_t count = read(STDIN_FILENO, &unexpected, 1);
    (void)count;
    return true;
  }

  return false;
}

int main(int argc, char **argv) {
  if (argc < 2 || argv[1][0] != '/') {
    return 126;
  }

  if (prctl(PR_SET_CHILD_SUBREAPER, 1) < 0) {
    return INTERNAL_ERROR;
  }

  install_handlers();

  uint64_t payload_length = 0;
  if (!parse_frame_length(&payload_length)) {
    return PROTOCOL_ERROR;
  }

  unsigned char *payload = NULL;
  if (payload_length > 0) {
    payload = malloc((size_t)payload_length);
    if (payload == NULL) {
      return INTERNAL_ERROR;
    }

    if (!read_exact(STDIN_FILENO, payload, (size_t)payload_length)) {
      free(payload);
      return stop_requested ? INTERNAL_ERROR : PROTOCOL_ERROR;
    }
  }

  int target_pipe[2];
  int readiness_pipe[2];
  if (pipe2(target_pipe, O_CLOEXEC) < 0) {
    free(payload);
    return INTERNAL_ERROR;
  }
  if (pipe2(readiness_pipe, O_CLOEXEC) < 0) {
    (void)close(target_pipe[0]);
    (void)close(target_pipe[1]);
    free(payload);
    return INTERNAL_ERROR;
  }

  int pipe_flags = fcntl(target_pipe[1], F_GETFL, 0);
  if (pipe_flags < 0 ||
      fcntl(target_pipe[1], F_SETFL, pipe_flags | O_NONBLOCK) < 0) {
    (void)close(target_pipe[0]);
    (void)close(target_pipe[1]);
    (void)close(readiness_pipe[0]);
    (void)close(readiness_pipe[1]);
    free(payload);
    return INTERNAL_ERROR;
  }

  pid_t child = fork();
  if (child < 0) {
    (void)close(target_pipe[0]);
    (void)close(target_pipe[1]);
    (void)close(readiness_pipe[0]);
    (void)close(readiness_pipe[1]);
    free(payload);
    return INTERNAL_ERROR;
  }

  if (child == 0) {
    reset_handlers();
    (void)close(readiness_pipe[0]);
    unsigned char ready = 1;
    if (setpgid(0, 0) < 0 ||
        write(readiness_pipe[1], &ready, sizeof(ready)) != sizeof(ready) ||
        dup2(target_pipe[0], STDIN_FILENO) < 0) {
      _exit(INTERNAL_ERROR);
    }
    (void)close(readiness_pipe[1]);
    (void)close(target_pipe[0]);
    (void)close(target_pipe[1]);
    execv(argv[1], &argv[1]);
    _exit(errno == ENOENT ? 127 : 126);
  }

  (void)close(target_pipe[0]);
  (void)close(readiness_pipe[1]);
  if (!await_readiness(readiness_pipe[0])) {
    (void)close(readiness_pipe[0]);
    (void)close(target_pipe[1]);
    free(payload);
    (void)kill_unready_child(child);
    return INTERNAL_ERROR;
  }
  (void)close(readiness_pipe[0]);

  int child_status = 0;
  bool leader_exited = false;
  int result =
      deliver_payload(target_pipe[1], payload, (size_t)payload_length);
  (void)close(target_pipe[1]);
  free(payload);

  if (result == 0) {
    while (!leader_exited && !control_cancelled()) {
      if (!child_exited(child, &leader_exited)) {
        result = INTERNAL_ERROR;
        break;
      }
    }

    if (result == 0 && !leader_exited) {
      result = 143;
    }
  }

  if (!teardown_tree(child)) {
    return INTERNAL_ERROR;
  }
  if (waitpid(child, &child_status, WNOHANG) != child) {
    return INTERNAL_ERROR;
  }

  return result == 0 ? exit_code(child_status) : result;
}
