// Waits for Super+Alt+F on any keyboard, then exits 0. Exits 2 when
// TIMEOUT_MS passes without the chord, so the caller can look for new
// keyboards and check whether it is still needed. Prints nothing: the
// chord is not announced on the console.
//
//   chord TIMEOUT_MS
#include <dirent.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define MAX_DEVICES 64
#define BITS_PER_LONG (sizeof(long) * 8)
#define TEST_BIT(bit, array) ((array[(bit) / BITS_PER_LONG] >> ((bit) % BITS_PER_LONG)) & 1)

static bool is_keyboard(int fd) {
  unsigned long keys[KEY_MAX / BITS_PER_LONG + 1] = {0};
  if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keys)), keys) < 0) return false;
  return TEST_BIT(KEY_F, keys) && TEST_BIT(KEY_LEFTALT, keys);
}

static long now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

int main(int argc, char **argv) {
  long timeout = argc > 1 ? atol(argv[1]) : 1000;
  struct pollfd fds[MAX_DEVICES];
  int count = 0;

  DIR *dir = opendir("/dev/input");
  if (dir == NULL) {
    usleep(timeout * 1000);
    return 2;
  }
  struct dirent *entry;
  while ((entry = readdir(dir)) != NULL && count < MAX_DEVICES) {
    if (strncmp(entry->d_name, "event", 5) != 0) continue;
    int fd = openat(dirfd(dir), entry->d_name, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) continue;
    if (!is_keyboard(fd)) {
      close(fd);
      continue;
    }
    fds[count].fd = fd;
    fds[count].events = POLLIN;
    count++;
  }
  closedir(dir);

  // Modifier state is per keyboard: Super on one and F on another is no chord.
  bool meta[MAX_DEVICES] = {false}, alt[MAX_DEVICES] = {false};
  long deadline = now_ms() + timeout;
  for (;;) {
    long left = deadline - now_ms();
    if (left <= 0) return 2;
    if (count == 0) {
      usleep(left * 1000);
      return 2;
    }
    if (poll(fds, count, (int)left) <= 0) continue;
    for (int i = 0; i < count; i++) {
      if (!(fds[i].revents & POLLIN)) continue;
      struct input_event events[64];
      ssize_t n = read(fds[i].fd, events, sizeof(events));
      if (n <= 0) continue;
      for (size_t j = 0; j < (size_t)n / sizeof(events[0]); j++) {
        const struct input_event *e = &events[j];
        if (e->type != EV_KEY) continue;
        bool down = e->value != 0;
        switch (e->code) {
          case KEY_LEFTMETA:
          case KEY_RIGHTMETA:
            meta[i] = down;
            break;
          case KEY_LEFTALT:
          case KEY_RIGHTALT:
            alt[i] = down;
            break;
          case KEY_F:
            if (e->value == 1 && meta[i] && alt[i]) return 0;
            break;
        }
      }
    }
  }
}
