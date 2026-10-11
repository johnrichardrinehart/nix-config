#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>

#include "virtual-pointer-client-protocol.h"

#define MAX_OUTPUTS 32
#define MAX_SEATS 16

struct output {
  struct wl_output *object;
  char name[128];
};

struct seat {
  struct wl_seat *object;
  char name[128];
};

struct state {
  struct zwlr_virtual_pointer_manager_v1 *manager;
  struct output outputs[MAX_OUTPUTS];
  size_t output_count;
  struct seat seats[MAX_SEATS];
  size_t seat_count;
};

static void output_geometry(void *data, struct wl_output *output, int32_t x,
                            int32_t y, int32_t physical_width,
                            int32_t physical_height, int32_t subpixel,
                            const char *make, const char *model,
                            int32_t transform) {
  (void)data;
  (void)output;
  (void)x;
  (void)y;
  (void)physical_width;
  (void)physical_height;
  (void)subpixel;
  (void)make;
  (void)model;
  (void)transform;
}

static void output_mode(void *data, struct wl_output *output, uint32_t flags,
                        int32_t width, int32_t height, int32_t refresh) {
  (void)data;
  (void)output;
  (void)flags;
  (void)width;
  (void)height;
  (void)refresh;
}

static void output_done(void *data, struct wl_output *output) {
  (void)data;
  (void)output;
}

static void output_scale(void *data, struct wl_output *output, int32_t factor) {
  (void)data;
  (void)output;
  (void)factor;
}

static void output_name(void *data, struct wl_output *output,
                        const char *name) {
  (void)output;
  struct output *item = data;
  snprintf(item->name, sizeof(item->name), "%s", name);
}

static void output_description(void *data, struct wl_output *output,
                               const char *description) {
  (void)data;
  (void)output;
  (void)description;
}

static const struct wl_output_listener output_listener = {
    .geometry = output_geometry,
    .mode = output_mode,
    .done = output_done,
    .scale = output_scale,
    .name = output_name,
    .description = output_description,
};

static void seat_capabilities(void *data, struct wl_seat *seat,
                              uint32_t capabilities) {
  (void)data;
  (void)seat;
  (void)capabilities;
}

static void seat_name(void *data, struct wl_seat *seat, const char *name) {
  (void)seat;
  struct seat *item = data;
  snprintf(item->name, sizeof(item->name), "%s", name);
}

static const struct wl_seat_listener seat_listener = {
    .capabilities = seat_capabilities,
    .name = seat_name,
};

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
  struct state *state = data;
  if (strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name) == 0 &&
      version >= 2) {
    state->manager = wl_registry_bind(
        registry, name, &zwlr_virtual_pointer_manager_v1_interface, 2);
  } else if (strcmp(interface, wl_seat_interface.name) == 0 && version >= 2 &&
             state->seat_count < MAX_SEATS) {
    struct seat *item = &state->seats[state->seat_count++];
    item->object = wl_registry_bind(registry, name, &wl_seat_interface, 2);
    wl_seat_add_listener(item->object, &seat_listener, item);
  } else if (strcmp(interface, wl_output_interface.name) == 0 && version >= 4 &&
             state->output_count < MAX_OUTPUTS) {
    struct output *item = &state->outputs[state->output_count++];
    item->object = wl_registry_bind(registry, name, &wl_output_interface, 4);
    wl_output_add_listener(item->object, &output_listener, item);
  }
}

static void global_remove(void *data, struct wl_registry *registry,
                          uint32_t name) {
  (void)data;
  (void)registry;
  (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = global,
    .global_remove = global_remove,
};

static uint32_t monotonic_msec(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
    return 0;
  }
  return (uint32_t)((uint64_t)now.tv_sec * 1000U + now.tv_nsec / 1000000U);
}

static struct wl_output *find_output(struct state *state, const char *name) {
  for (size_t index = 0; index < state->output_count; index++) {
    if (strcmp(state->outputs[index].name, name) == 0) {
      return state->outputs[index].object;
    }
  }
  return NULL;
}

static struct wl_seat *find_seat(struct state *state, const char *name) {
  for (size_t index = 0; index < state->seat_count; index++) {
    if (strcmp(state->seats[index].name, name) == 0) {
      return state->seats[index].object;
    }
  }
  return NULL;
}

static void destroy_state(struct state *state, struct wl_registry *registry,
                          struct wl_display *display) {
  for (size_t index = 0; index < state->output_count; index++) {
    wl_output_destroy(state->outputs[index].object);
  }
  for (size_t index = 0; index < state->seat_count; index++) {
    wl_seat_destroy(state->seats[index].object);
  }
  if (state->manager != NULL) {
    zwlr_virtual_pointer_manager_v1_destroy(state->manager);
  }
  wl_registry_destroy(registry);
  wl_display_disconnect(display);
}

int main(int argc, char **argv) {
  if (argc > 3) {
    fprintf(stderr, "usage: niri-remote-pointer [OUTPUT [SEAT]]\n");
    return EXIT_FAILURE;
  }

  struct wl_display *display = wl_display_connect(NULL);
  if (display == NULL) {
    fprintf(stderr, "niri-remote-pointer: cannot connect to Wayland\n");
    return EXIT_FAILURE;
  }

  struct state state = {0};
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, &state);
  if (wl_display_roundtrip(display) < 0 || wl_display_roundtrip(display) < 0 ||
      state.manager == NULL || state.seat_count == 0) {
    fprintf(stderr, "niri-remote-pointer: virtual pointer is unavailable\n");
    destroy_state(&state, registry, display);
    return EXIT_FAILURE;
  }

  struct wl_output *output = NULL;
  struct wl_seat *seat = state.seats[0].object;
  if (argc >= 2) {
    output = find_output(&state, argv[1]);
    const char *seat_name = argc == 3 ? argv[2] : NULL;
    if (seat_name != NULL) {
      seat = find_seat(&state, seat_name);
    }
    if (output == NULL || seat == NULL) {
      fprintf(stderr,
              "niri-remote-pointer: output %s or seat %s is unavailable\n",
              argv[1], seat_name == NULL ? "<default>" : seat_name);
      destroy_state(&state, registry, display);
      return EXIT_FAILURE;
    }
  }

  struct zwlr_virtual_pointer_v1 *pointer =
      output == NULL
          ? zwlr_virtual_pointer_manager_v1_create_virtual_pointer(state.manager,
                                                                    seat)
          : zwlr_virtual_pointer_manager_v1_create_virtual_pointer_with_output(
                state.manager, seat, output);
  char line[256];
  while (fgets(line, sizeof(line), stdin) != NULL) {
    uint32_t x;
    uint32_t y;
    uint32_t width;
    uint32_t height;
    if (sscanf(line, "A %u %u %u %u", &x, &y, &width, &height) != 4 ||
        width == 0 || height == 0 || x >= width || y >= height) {
      fprintf(stderr, "niri-remote-pointer: rejected malformed motion\n");
      continue;
    }
    zwlr_virtual_pointer_v1_motion_absolute(pointer, monotonic_msec(), x, y,
                                             width, height);
    zwlr_virtual_pointer_v1_frame(pointer);
    if (wl_display_roundtrip(display) < 0) {
      fprintf(stderr, "niri-remote-pointer: motion roundtrip failed\n");
      zwlr_virtual_pointer_v1_destroy(pointer);
      destroy_state(&state, registry, display);
      return EXIT_FAILURE;
    }
  }

  zwlr_virtual_pointer_v1_destroy(pointer);
  destroy_state(&state, registry, display);
  return EXIT_SUCCESS;
}
