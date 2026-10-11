/* Compile the production implementations, substituting only their platform boundaries. */
#include "fixture.h"

static int endpoint_listener(const zmk_event_t *event);
#include "app/src/ble.c"
#include "app/src/endpoints.c"
#include "app/src/behaviors/behavior_bt.c"

static struct bt_conn connections[5];
static struct k_work *work_queue[32];
static size_t work_count;
static bool controller_advertising;
static bool usb_ready;
static int advertising_stop_error;
static int advertising_start_error;
static unsigned advertising_starts;
static unsigned advertising_stops;
static unsigned bluetooth_enables;
static unsigned unpair_calls;
static unsigned usb_keyboard_reports;
static unsigned usb_consumer_reports;
static unsigned ble_reports;
static struct bt_conn_cb *registered_connections;
static const struct bt_conn_auth_cb *registered_auth;
static struct bt_conn_auth_info_cb *registered_auth_info;
static struct zmk_hid_keyboard_report keyboard_report;
static struct zmk_hid_consumer_report consumer_report;

int k_work_submit(struct k_work *work) {
    if (work->pending) {
        return 0;
    }
    assert(work_count < ARRAY_SIZE(work_queue));
    work->pending = true;
    work_queue[work_count++] = work;
    return 1;
}

static void drain_work(void) {
    unsigned iterations = 0;
    while (work_count) {
        assert(++iterations < 64);
        struct k_work *work = work_queue[0];
        memmove(work_queue, work_queue + 1, --work_count * sizeof(*work_queue));
        work->pending = false;
        work->handler(work);
    }
}

struct bt_conn *bt_conn_ref(struct bt_conn *conn) {
    ++conn->refs;
    return conn;
}
void bt_conn_unref(struct bt_conn *conn) {
    assert(conn->refs > 0);
    --conn->refs;
}
struct bt_conn *bt_conn_lookup_addr_le(uint8_t id, const bt_addr_le_t *addr) {
    assert(id == BT_ID_DEFAULT);
    for (size_t i = 0; i < ARRAY_SIZE(connections); ++i) {
        if (connections[i].state != BT_CONN_STATE_DISCONNECTED &&
            !bt_addr_le_cmp(addr, &connections[i].addr)) {
            return bt_conn_ref(&connections[i]);
        }
    }
    return NULL;
}
const bt_addr_le_t *bt_conn_get_dst(const struct bt_conn *conn) { return &conn->addr; }
int bt_conn_get_info(const struct bt_conn *conn, struct bt_conn_info *info) {
    *info = (struct bt_conn_info){.role = conn->role, .state = conn->state};
    return 0;
}
void bt_conn_foreach(enum bt_conn_type type, void (*callback)(struct bt_conn *, void *), void *data) {
    assert(type == BT_CONN_TYPE_LE);
    for (size_t i = 0; i < ARRAY_SIZE(connections); ++i) {
        struct bt_conn *conn = bt_conn_ref(&connections[i]);
        callback(conn, data);
        bt_conn_unref(conn);
    }
}
int bt_conn_disconnect(struct bt_conn *conn, uint8_t reason) {
    assert(reason == BT_HCI_ERR_REMOTE_USER_TERM_CONN);
    ++conn->disconnect_requests;
    if (conn->disconnect_error == -ENOTCONN) {
        conn->state = BT_CONN_STATE_DISCONNECTED; /* Concurrent peer disconnect. */
    }
    /* Success intentionally leaves CONNECTED until a later controller callback. */
    return conn->disconnect_error;
}
int bt_conn_auth_cancel(struct bt_conn *conn) {
    registered_auth->cancel(conn);
    return 0;
}
int bt_conn_auth_passkey_entry(struct bt_conn *conn, unsigned passkey) {
    (void)conn;
    (void)passkey;
    return 0;
}
void bt_conn_cb_register(struct bt_conn_cb *callbacks) { registered_connections = callbacks; }
int bt_conn_auth_cb_register(const struct bt_conn_auth_cb *callbacks) {
    registered_auth = callbacks;
    return 0;
}
void bt_conn_auth_info_cb_register(struct bt_conn_auth_info_cb *callbacks) {
    registered_auth_info = callbacks;
}
int bt_enable(void (*ready)(int)) {
    ++bluetooth_enables;
    if (ready) {
        ready(0);
    }
    return 0;
}
int bt_unpair(uint8_t id, const bt_addr_le_t *addr) {
    assert(id == BT_ID_DEFAULT);
    ++unpair_calls;
    for (size_t i = 0; i < ARRAY_SIZE(connections); ++i) {
        if (!addr || !bt_addr_le_cmp(addr, &connections[i].addr)) {
            connections[i].bonded = false;
        }
    }
    return 0;
}
int bt_set_name(const char *name) {
    assert(name && *name);
    return 0;
}
int bt_le_adv_start(const struct bt_le_adv_param *param, const struct bt_data *data, size_t count,
                    const struct bt_data *scan_response, size_t scan_count) {
    (void)scan_response;
    (void)scan_count;
    assert(param && data && count);
    ++advertising_starts;
    if (advertising_start_error) {
        return advertising_start_error;
    }
    if (controller_advertising) {
        return -EALREADY;
    }
    controller_advertising = true;
    return 0;
}
int bt_le_adv_stop(void) {
    ++advertising_stops;
    if (advertising_stop_error) {
        return advertising_stop_error;
    }
    controller_advertising = false;
    return 0;
}

int raise_zmk_ble_active_profile_changed(struct zmk_ble_active_profile_changed event) {
    (void)event;
    return endpoint_listener(NULL);
}
int raise_zmk_endpoint_changed(struct zmk_endpoint_changed event) {
    (void)event;
    return 0;
}
struct zmk_keycode_state_changed *as_zmk_keycode_state_changed(const zmk_event_t *event) {
    return event ? event->data : NULL;
}
struct zmk_hid_keyboard_report *zmk_hid_get_keyboard_report(void) { return &keyboard_report; }
struct zmk_hid_consumer_report *zmk_hid_get_consumer_report(void) { return &consumer_report; }
void zmk_hid_keyboard_clear(void) { keyboard_report.body.data = 0; }
void zmk_hid_consumer_clear(void) { consumer_report.body.data = 0; }
bool zmk_usb_is_hid_ready(void) { return usb_ready; }
int zmk_usb_hid_send_keyboard_report(void) {
    if (!usb_ready) {
        return -ENODEV;
    }
    ++usb_keyboard_reports;
    return 0;
}
int zmk_usb_hid_send_consumer_report(void) {
    if (!usb_ready) {
        return -ENODEV;
    }
    ++usb_consumer_reports;
    return 0;
}
static int fixture_hog_send(void) {
    struct bt_conn *conn = zmk_ble_active_profile_conn();
    if (!conn) {
        return -ENOTCONN;
    }
    ++ble_reports;
    bt_conn_unref(conn);
    return 0;
}
int zmk_hog_send_keyboard_report(struct zmk_hid_keyboard_report_body *body) {
    (void)body;
    return fixture_hog_send();
}
int zmk_hog_send_consumer_report(struct zmk_hid_consumer_report_body *body) {
    (void)body;
    return fixture_hog_send();
}

static const uint32_t off_command[] = {BT_HOST_OFF_CMD, 0};
static const uint32_t on_command[] = {BT_HOST_ON_CMD, 0};
static const uint32_t toggle_command[] = {BT_HOST_TOG_CMD, 0};
static int press_command(const uint32_t command[2]) {
    struct zmk_behavior_binding binding = {.param1 = command[0], .param2 = command[1]};
    return behavior_bt_driver_api.binding_pressed(&binding, (struct zmk_behavior_binding_event){0});
}

static void assert_existing_bonds(void) {
    assert(unpair_calls == 0);
    for (size_t i = 0; i < 4; ++i) {
        assert(connections[i].bonded);
    }
    assert(!bt_addr_le_cmp(&profiles[0].peer, &connections[0].addr));
    assert(!bt_addr_le_cmp(&profiles[1].peer, &connections[1].addr));
}
static void assert_split_unchanged(void) {
    for (size_t i = 2; i < 4; ++i) {
        assert(connections[i].state == BT_CONN_STATE_CONNECTED);
        assert(connections[i].disconnect_requests == 0);
    }
}
static void assert_no_reference_leaks(void) {
    assert(!auth_passkey_entry_conn);
    for (size_t i = 0; i < ARRAY_SIZE(connections); ++i) {
        assert(connections[i].refs == 0);
    }
}

static void reset_fixture(bool hosts_connected) {
    assert_no_reference_leaks();
    memset(connections, 0, sizeof(connections));
    memset(profiles, 0, sizeof(profiles));
#if IS_ENABLED(CONFIG_ZMK_SPLIT_ROLE_CENTRAL)
    memset(peripheral_addrs, 0, sizeof(peripheral_addrs));
#endif
    for (size_t i = 0; i < ARRAY_SIZE(connections); ++i) {
        connections[i].addr.a.val[0] = i + 1;
        connections[i].role = i == 2 || i == 3 ? BT_CONN_ROLE_CENTRAL : BT_CONN_ROLE_PERIPHERAL;
        connections[i].state = i == 2 || i == 3 || (i < 2 && hosts_connected)
                                   ? BT_CONN_STATE_CONNECTED : BT_CONN_STATE_DISCONNECTED;
        connections[i].bonded = i < 4;
    }
    profiles[0].peer = connections[0].addr;
    profiles[1].peer = connections[1].addr;
    active_profile = 0;
    atomic_set(&host_enabled, 1);
    atomic_set(&advertising_stopped, 0);
    advertising_status = ZMK_ADV_NONE;
    controller_advertising = false;
    usb_ready = true;
    advertising_stop_error = advertising_start_error = 0;
    advertising_starts = advertising_stops = 0;
    bluetooth_enables = unpair_calls = 0;
    usb_keyboard_reports = usb_consumer_reports = ble_reports = 0;
    work_count = 0;
    raise_profile_changed_event_work.pending = update_advertising_work.pending = false;
    ring_buf_reset(&passkey_entries);
    preferred_transport = ZMK_TRANSPORT_BLE;
    assert(zmk_ble_init() == 0);
    assert(zmk_endpoints_init() == 0);
}

static void complete_disconnect(struct bt_conn *conn) {
    conn->state = BT_CONN_STATE_DISCONNECTED;
    if (auth_passkey_entry_conn == conn) {
        registered_auth->cancel(conn);
    }
    registered_connections->disconnected(conn, BT_HCI_ERR_REMOTE_USER_TERM_CONN);
}
static void connect_host(struct bt_conn *conn) {
    conn->state = BT_CONN_STATE_CONNECTED;
    controller_advertising = false; /* The real ONE_TIME advertiser stops on connection. */
    registered_connections->connected(conn, 0);
}

#if CONFIG_ZMK_SPLIT_ROLE_CENTRAL && CONFIG_ZMK_BLE_PROFILE_ADVERTISING
static void test_off_routes_usb_before_async_disconnect(void) {
    reset_fixture(true);
    assert(zmk_ble_active_profile_is_connected());
    assert(zmk_endpoints_selected().transport == ZMK_TRANSPORT_BLE);
    assert(press_command(off_command) == 0);
    assert(!zmk_ble_host_is_enabled());
    assert(!controller_advertising);
    assert(advertising_stops > 0);
    assert(connections[0].disconnect_requests == 1);
    assert(connections[1].disconnect_requests == 1);
    assert(connections[0].state == BT_CONN_STATE_CONNECTED);
    assert(!zmk_ble_active_profile_is_connected());
    assert(zmk_ble_active_profile_conn() == NULL);
    assert(zmk_endpoints_selected().transport == ZMK_TRANSPORT_USB);
    assert_split_unchanged();
    assert_existing_bonds();

    usb_ready = false;
    endpoint_listener(NULL);
    assert(zmk_endpoints_selected().transport == ZMK_TRANSPORT_USB);
    usb_ready = true;
    assert(zmk_endpoints_select_transport(ZMK_TRANSPORT_USB) == 0);
    assert(zmk_endpoints_select_transport(ZMK_TRANSPORT_BLE) == 0);
    assert(!zmk_ble_host_is_enabled());
    assert(zmk_endpoints_selected().transport == ZMK_TRANSPORT_USB);
    unsigned old_ble_reports = ble_reports;
    unsigned old_usb_reports = usb_keyboard_reports + usb_consumer_reports;
    assert(zmk_endpoints_send_report(HID_USAGE_KEY) == 0);
    assert(zmk_endpoints_send_report(HID_USAGE_CONSUMER) == 0);
    assert(ble_reports == old_ble_reports);
    assert(usb_keyboard_reports + usb_consumer_reports == old_usb_reports + 2);

    unsigned old_starts = advertising_starts;
    assert(zmk_ble_prof_select(2) == 0);
    assert(zmk_ble_set_device_name("Renamed while off") == 0);
    assert(!zmk_ble_host_is_enabled());
    assert(!controller_advertising);
    assert(advertising_starts == old_starts);
    assert(zmk_ble_prof_select(0) == 0);

    registered_connections->connected(&connections[2], 0);
    registered_connections->security_changed(&connections[2], BT_SECURITY_L2, BT_SECURITY_ERR_SUCCESS);
    assert(registered_auth->pairing_accept(&connections[2], NULL) == BT_SECURITY_ERR_SUCCESS);
    registered_auth_info->pairing_complete(&connections[2], true);
    assert_split_unchanged();

    connect_host(&connections[4]); /* Unbonded host arriving after enumeration. */
    assert(connections[4].disconnect_requests == 1);
    assert(registered_auth->pairing_accept(&connections[4], NULL) == BT_SECURITY_ERR_PAIR_NOT_ALLOWED);
    registered_connections->security_changed(&connections[4], BT_SECURITY_L2, BT_SECURITY_ERR_SUCCESS);
    assert(connections[4].disconnect_requests == 2);
    registered_auth->passkey_entry(&connections[4]);
    assert(!auth_passkey_entry_conn);
    registered_auth_info->pairing_complete(&connections[1], true);
    assert_existing_bonds(); /* Old invalid-profile path must not unpair this host. */

    auth_passkey_entry_conn = bt_conn_ref(&connections[0]); /* In-flight pre-Off request. */
    struct zmk_keycode_state_changed key = {.keycode = 4, .state = true};
    zmk_event_t event = {.data = &key};
    assert(zmk_ble_listener(&event) == ZMK_EV_EVENT_BUBBLE);
    registered_auth->cancel(&connections[0]);
    drain_work();
    assert(!controller_advertising);
    assert(advertising_starts == old_starts);
    assert_split_unchanged();
    assert_existing_bonds();

    complete_disconnect(&connections[0]);
    complete_disconnect(&connections[1]);
    complete_disconnect(&connections[4]);
    drain_work();
    assert(press_command(on_command) == 0);
    assert(zmk_ble_host_is_enabled());
    assert(controller_advertising);
    assert(zmk_endpoints_selected().transport == ZMK_TRANSPORT_USB);
    connect_host(&connections[0]);
    drain_work();
    assert(zmk_ble_active_profile_is_connected());
    assert(zmk_endpoints_selected().transport == ZMK_TRANSPORT_BLE);
    unsigned old_reports = ble_reports;
    assert(zmk_endpoints_send_report(HID_USAGE_KEY) == 0);
    assert(ble_reports == old_reports + 1);
    assert(bluetooth_enables == 1);
    assert_existing_bonds();
    assert_split_unchanged();
    assert_no_reference_leaks();
    puts("PASS host-only Off, async USB routing, late callbacks, bonds and On reconnect");
}

static void test_toggle_and_enabled_pairing(void) {
    reset_fixture(false);
    assert(controller_advertising);
    assert(press_command(toggle_command) == 0);
    assert(!zmk_ble_host_is_enabled());
    assert(!controller_advertising);
    assert(press_command(toggle_command) == 0);
    assert(zmk_ble_host_is_enabled());
    assert(controller_advertising);
    assert(zmk_ble_prof_select(2) == 0);
    assert(registered_auth->pairing_accept(&connections[4], NULL) == BT_SECURITY_ERR_SUCCESS);
    connect_host(&connections[4]);
    registered_auth->passkey_entry(&connections[4]);
    assert(auth_passkey_entry_conn == &connections[4]);
    registered_auth->cancel(&connections[4]);
    connections[4].bonded = true;
    registered_auth_info->pairing_complete(&connections[4], true);
    drain_work();
    assert(zmk_ble_active_profile_is_connected());
    assert(!bt_addr_le_cmp(&profiles[2].peer, &connections[4].addr));
    assert(connections[4].disconnect_requests == 0);
    assert_existing_bonds();
    assert_split_unchanged();
    assert_no_reference_leaks();
    puts("PASS runtime Toggle and ordinary enabled pairing");
}

static void test_controller_failures(void) {
    reset_fixture(true);
    assert(zmk_ble_prof_select(2) == 0);
    assert(controller_advertising);
    advertising_stop_error = -EIO;
    connections[0].disconnect_error = -EBUSY;
    connections[1].disconnect_error = -ENOTCONN;
    assert(press_command(off_command) == -EIO); /* First error wins; every host still attempted. */
    assert(!zmk_ble_host_is_enabled());
    assert(controller_advertising); /* Controller failure is not falsely reported as success. */
    assert(connections[0].disconnect_requests == 1);
    assert(connections[1].disconnect_requests == 1);
    assert(zmk_ble_active_profile_conn() == NULL);
    assert(zmk_endpoints_selected().transport == ZMK_TRANSPORT_USB);
    assert_split_unchanged();
    assert_existing_bonds();
    connect_host(&connections[4]);
    assert(connections[4].disconnect_requests == 1);
    assert(registered_auth->pairing_accept(&connections[4], NULL) == BT_SECURITY_ERR_PAIR_NOT_ALLOWED);
    drain_work();
    advertising_stop_error = 0;
    connections[0].disconnect_error = 0;
    assert(press_command(off_command) == 0);
    assert(!controller_advertising);
    assert_existing_bonds();
    assert_split_unchanged();

    reset_fixture(true);
    connections[0].disconnect_error = -EBUSY;
    assert(press_command(off_command) == -EBUSY);
    assert(!zmk_ble_host_is_enabled());
    assert(connections[1].disconnect_requests == 1);
    assert(zmk_ble_active_profile_conn() == NULL);
    assert(!zmk_ble_active_profile_is_connected());
    assert_existing_bonds();
    assert_split_unchanged();

    reset_fixture(true);
    connections[0].disconnect_error = -ENOTCONN;
    assert(press_command(off_command) == 0);
    assert(!zmk_ble_host_is_enabled());
    assert(connections[1].disconnect_requests == 1);
    assert_existing_bonds();
    assert_split_unchanged();

    reset_fixture(false);
    assert(press_command(off_command) == 0);
    advertising_start_error = -ENOMEM;
    assert(press_command(on_command) == -ENOMEM);
    assert(zmk_ble_host_is_enabled()); /* Requested policy remains applied on failure. */
    assert(!controller_advertising);
    assert(zmk_endpoints_selected().transport == ZMK_TRANSPORT_USB);
    advertising_start_error = 0;
    registered_connections->disconnected(&connections[0], BT_HCI_ERR_REMOTE_USER_TERM_CONN);
    drain_work();
    assert(controller_advertising);
    assert_existing_bonds();
    assert_split_unchanged();
    assert_no_reference_leaks();
    puts("PASS stop/disconnect/start failures, error precedence and disconnect races");
}

static void test_stale_callback_after_enable(void) {
    reset_fixture(false);
    assert(press_command(off_command) == 0);
    assert(press_command(on_command) == 0);
    assert(controller_advertising);
    unsigned old_starts = advertising_starts;
    registered_connections->connected(&connections[0], 1); /* Failed older advertiser generation. */
    drain_work();
    assert(zmk_ble_host_is_enabled());
    assert(controller_advertising);
    assert(advertising_status == ZMK_ADV_CONN);
    assert(advertising_starts == old_starts + 1);
    assert_existing_bonds();
    assert_split_unchanged();
    assert_no_reference_leaks();
    puts("PASS late advertising callback reconciles the current advertiser");
}
#endif

int main(void) {
    assert(zmk_ble_host_is_enabled()); /* Actual static initialization: enabled on reboot. */
#if CONFIG_ZMK_SPLIT_ROLE_CENTRAL && CONFIG_ZMK_BLE_PROFILE_ADVERTISING
    test_off_routes_usb_before_async_disconnect();
    test_toggle_and_enabled_pairing();
    test_controller_failures();
    test_stale_callback_after_enable();
#elif CONFIG_ZMK_SPLIT_ROLE_CENTRAL
    reset_fixture(true);
    assert(press_command(off_command) == 0);
    assert(!zmk_ble_host_is_enabled());
    assert(press_command(on_command) == -ENOTSUP);
    assert(press_command(toggle_command) == -ENOTSUP);
    assert(!zmk_ble_host_is_enabled());
    assert(!controller_advertising);
    assert_existing_bonds();
    assert_split_unchanged();
    assert_no_reference_leaks();
    puts("PASS compile-time host advertising disabled cannot be implicitly enabled");
#else
    reset_fixture(true);
    assert(press_command(off_command) == -ENOTSUP);
    assert(press_command(on_command) == -ENOTSUP);
    assert(press_command(toggle_command) == -ENOTSUP);
    assert(zmk_ble_host_is_enabled());
    for (size_t i = 0; i < ARRAY_SIZE(connections); ++i) {
        assert(connections[i].disconnect_requests == 0);
    }
    assert_existing_bonds();
    assert_split_unchanged();
    assert_no_reference_leaks();
    puts("PASS split peripheral commands never disable their keyboard link");
#endif
    return 0;
}
