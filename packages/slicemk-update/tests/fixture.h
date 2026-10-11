/* Controller fixtures only. Production BLE, endpoint and behavior code is included unchanged. */
#pragma once

#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#ifndef CONFIG_ZMK_SPLIT_ROLE_CENTRAL
#define CONFIG_ZMK_SPLIT_ROLE_CENTRAL 1
#endif
#ifndef CONFIG_ZMK_BLE_PROFILE_ADVERTISING
#define CONFIG_ZMK_BLE_PROFILE_ADVERTISING 1
#endif
#define CONFIG_ZMK_SPLIT 1
#define CONFIG_ZMK_BLE 1
#define CONFIG_ZMK_USB 1
#define CONFIG_ZMK_SPLIT_BLE_CENTRAL_PERIPHERALS 2
#define CONFIG_BT_MAX_PAIRED 5
#define CONFIG_BT_DEVICE_NAME "Fixture"
#define CONFIG_BT_DEVICE_NAME_MAX 32
#define CONFIG_SETTINGS 0
#define CONFIG_ZMK_BLE_PASSKEY_ENTRY 1
#define CONFIG_ZMK_BLE_CLEAR_BONDS_ON_START 0
#define CONFIG_ZMK_BLE_KEYBOARD_NAME_MAC 0
#define CONFIG_BT_SMP_ALLOW_UNAUTH_OVERWRITE 0
#define CONFIG_ZMK_POINTING 0
#define CONFIG_ZMK_BEHAVIOR_METADATA 0
#define CONFIG_ZMK_BEHAVIOR_LOCAL_IDS_IN_BINDINGS 0
#define CONFIG_ZMK_LOG_LEVEL 0
#define CONFIG_ZMK_BLE_INIT_PRIORITY 0
#define CONFIG_APPLICATION_INIT_PRIORITY 0
#define CONFIG_KERNEL_INIT_PRIORITY_DEFAULT 0

#define IS_ENABLED(value) (value)
#define FIXTURE_UNWRAP(...) __VA_ARGS__
#define COND_CODE_1(flag, yes, no) ((flag) ? FIXTURE_UNWRAP yes : FIXTURE_UNWRAP no)
#define ARRAY_SIZE(value) (sizeof(value) / sizeof((value)[0]))
#define STRINGIFY_INNER(value) #value
#define STRINGIFY(value) STRINGIFY_INNER(value)
#define BUILD_ASSERT(condition, message) _Static_assert(condition, message)
#define LOG_MODULE_DECLARE(...)
#define LOG_DBG(...)
#define LOG_INF(...)
#define LOG_WRN(...)
#define LOG_ERR(...)
#define SYS_INIT(...)
#define DT_HAS_COMPAT_STATUS_OKAY(...) 1
#define BEHAVIOR_DT_INST_DEFINE(...)
#define K_FOREVER (-1)

struct device;
struct k_mutex { pthread_mutex_t native; };
#define K_MUTEX_DEFINE(name) static struct k_mutex name = {PTHREAD_MUTEX_INITIALIZER}
static inline int k_mutex_lock(struct k_mutex *mutex, int timeout) {
    (void)timeout;
    return pthread_mutex_lock(&mutex->native);
}
static inline int k_mutex_unlock(struct k_mutex *mutex) {
    return pthread_mutex_unlock(&mutex->native);
}
typedef atomic_int atomic_t;
#define ATOMIC_INIT(value) (value)
static inline int atomic_get(const atomic_t *value) { return atomic_load(value); }
static inline int atomic_set(atomic_t *value, int next) { return atomic_exchange(value, next); }

struct k_work {
    void (*handler)(struct k_work *);
    bool pending;
};
#define K_WORK_DEFINE(name, callback) static struct k_work name = {callback, false}
int k_work_submit(struct k_work *work);
static inline void *k_current_get(void) { return NULL; }

struct ring_buf { uint8_t data[6]; size_t size; };
#define RING_BUF_DECLARE(name, capacity) static struct ring_buf name
static inline void ring_buf_reset(struct ring_buf *buffer) { buffer->size = 0; }
static inline uint32_t ring_buf_size_get(const struct ring_buf *buffer) { return buffer->size; }
static inline uint32_t ring_buf_space_get(const struct ring_buf *buffer) {
    return sizeof(buffer->data) - buffer->size;
}
static inline uint32_t ring_buf_put(struct ring_buf *buffer, const uint8_t *data, uint32_t size) {
    uint32_t count = size < ring_buf_space_get(buffer) ? size : ring_buf_space_get(buffer);
    memcpy(buffer->data + buffer->size, data, count);
    buffer->size += count;
    return count;
}
static inline uint32_t ring_buf_get(struct ring_buf *buffer, uint8_t *data, uint32_t size) {
    uint32_t count = size < buffer->size ? size : buffer->size;
    memcpy(data, buffer->data, count);
    memmove(buffer->data, buffer->data + count, buffer->size - count);
    buffer->size -= count;
    return count;
}

typedef struct { uint8_t type; struct { uint8_t val[6]; } a; } bt_addr_le_t;
#define BT_ADDR_LE_ANY (&(const bt_addr_le_t){0})
#define BT_ADDR_LE_STR_LEN 32
#define BT_ID_DEFAULT 0
static inline int bt_addr_le_cmp(const bt_addr_le_t *a, const bt_addr_le_t *b) {
    return a->type != b->type ? (int)a->type - (int)b->type : memcmp(a->a.val, b->a.val, 6);
}
static inline void bt_addr_le_copy(bt_addr_le_t *to, const bt_addr_le_t *from) { *to = *from; }
static inline int bt_addr_le_to_str(const bt_addr_le_t *addr, char *buffer, size_t size) {
    return snprintf(buffer, size, "fixture-%u", addr->a.val[0]);
}

enum bt_conn_type { BT_CONN_TYPE_LE = 1 };
enum bt_conn_state {
    BT_CONN_STATE_DISCONNECTED,
    BT_CONN_STATE_CONNECTING,
    BT_CONN_STATE_CONNECTED,
    BT_CONN_STATE_DISCONNECTING,
};
#define BT_CONN_ROLE_CENTRAL 0
#define BT_CONN_ROLE_PERIPHERAL 1
#define BT_HCI_ERR_REMOTE_USER_TERM_CONN 0x13
#define BT_SECURITY_L2 2
typedef uint8_t bt_security_t;
enum bt_security_err { BT_SECURITY_ERR_SUCCESS, BT_SECURITY_ERR_PAIR_NOT_ALLOWED };
struct bt_conn {
    bt_addr_le_t addr;
    uint8_t role;
    enum bt_conn_state state;
    unsigned refs;
    unsigned disconnect_requests;
    int disconnect_error;
    bool bonded;
};
struct bt_conn_info { uint8_t role; enum bt_conn_state state; };
struct bt_conn_pairing_feat { uint8_t unused; };
struct bt_conn_cb {
    void (*connected)(struct bt_conn *, uint8_t);
    void (*disconnected)(struct bt_conn *, uint8_t);
    void (*security_changed)(struct bt_conn *, bt_security_t, enum bt_security_err);
    void (*le_param_updated)(struct bt_conn *, uint16_t, uint16_t, uint16_t);
};
struct bt_conn_auth_cb {
    enum bt_security_err (*pairing_accept)(struct bt_conn *, const struct bt_conn_pairing_feat *);
    void (*passkey_entry)(struct bt_conn *);
    void (*cancel)(struct bt_conn *);
};
struct bt_conn_auth_info_cb { void (*pairing_complete)(struct bt_conn *, bool); };
struct bt_conn *bt_conn_ref(struct bt_conn *conn);
void bt_conn_unref(struct bt_conn *conn);
struct bt_conn *bt_conn_lookup_addr_le(uint8_t id, const bt_addr_le_t *addr);
const bt_addr_le_t *bt_conn_get_dst(const struct bt_conn *conn);
int bt_conn_get_info(const struct bt_conn *conn, struct bt_conn_info *info);
void bt_conn_foreach(enum bt_conn_type type, void (*callback)(struct bt_conn *, void *), void *data);
int bt_conn_disconnect(struct bt_conn *conn, uint8_t reason);
int bt_conn_auth_cancel(struct bt_conn *conn);
int bt_conn_auth_passkey_entry(struct bt_conn *conn, unsigned passkey);
void bt_conn_cb_register(struct bt_conn_cb *callbacks);
int bt_conn_auth_cb_register(const struct bt_conn_auth_cb *callbacks);
void bt_conn_auth_info_cb_register(struct bt_conn_auth_info_cb *callbacks);
int bt_enable(void (*ready)(int));
int bt_unpair(uint8_t id, const bt_addr_le_t *addr);
int bt_set_name(const char *name);

struct bt_le_adv_param { unsigned options; const bt_addr_le_t *peer; };
struct bt_data { uint8_t type; };
#define BT_DATA_BYTES(kind, ...) {.type = (kind)}
#define BT_DATA_GAP_APPEARANCE 1
#define BT_DATA_FLAGS 2
#define BT_DATA_UUID16_SOME 3
#define BT_LE_AD_GENERAL 1
#define BT_LE_AD_NO_BREDR 2
#define BT_LE_ADV_OPT_CONNECTABLE 1
#define BT_LE_ADV_OPT_ONE_TIME 2
#define BT_LE_ADV_OPT_USE_NAME 4
#define BT_LE_ADV_OPT_FORCE_NAME_IN_AD 8
#define BT_GAP_ADV_FAST_INT_MIN_2 1
#define BT_GAP_ADV_FAST_INT_MAX_2 2
#define BT_LE_ADV_PARAM(opts, min, max, target) (&(const struct bt_le_adv_param){opts, target})
#define BT_LE_ADV_CONN_DIR_LOW_DUTY(target) BT_LE_ADV_PARAM(1, 0, 0, target)
int bt_le_adv_start(const struct bt_le_adv_param *, const struct bt_data *, size_t,
                    const struct bt_data *, size_t);
int bt_le_adv_stop(void);

typedef uint32_t zmk_key_t;
#define HID_USAGE_KEY_KEYBOARD_ESCAPE 0x29
#define HID_USAGE_KEY_KEYBOARD_RETURN 0x28
#define HID_USAGE_KEY_KEYBOARD_RETURN_ENTER 0x28
#define HID_USAGE_KEY_KEYBOARD_1_AND_EXCLAMATION 0x1e
#define HID_USAGE_KEY_KEYBOARD_0_AND_RIGHT_PARENTHESIS 0x27
#define HID_USAGE_KEY_KEYPAD_1_AND_END 0x59
#define HID_USAGE_KEY_KEYPAD_0_AND_INSERT 0x62

typedef struct { void *data; } zmk_event_t;
#define ZMK_EV_EVENT_BUBBLE 0
#define ZMK_EV_EVENT_HANDLED 1
#define ZMK_EVENT_DECLARE(name) int raise_##name(struct name); struct name *as_##name(const zmk_event_t *)
#define ZMK_LISTENER(...)
#define ZMK_SUBSCRIPTION(...)
struct zmk_keycode_state_changed { zmk_key_t keycode; bool state; };
struct zmk_keycode_state_changed *as_zmk_keycode_state_changed(const zmk_event_t *event);

struct zmk_hid_keyboard_report_body { uint8_t data; };
struct zmk_hid_consumer_report_body { uint8_t data; };
struct zmk_hid_keyboard_report { struct zmk_hid_keyboard_report_body body; };
struct zmk_hid_consumer_report { struct zmk_hid_consumer_report_body body; };
struct zmk_hid_keyboard_report *zmk_hid_get_keyboard_report(void);
struct zmk_hid_consumer_report *zmk_hid_get_consumer_report(void);
void zmk_hid_keyboard_clear(void);
void zmk_hid_consumer_clear(void);
bool zmk_usb_is_hid_ready(void);

struct zmk_behavior_binding;
struct zmk_behavior_binding_event;
struct behavior_driver_api {
    int (*binding_pressed)(struct zmk_behavior_binding *, struct zmk_behavior_binding_event);
    int (*binding_released)(struct zmk_behavior_binding *, struct zmk_behavior_binding_event);
};
