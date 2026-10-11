{ pkgs, firmwareSource }:
pkgs.runCommand "slicemk-host-bluetooth-check"
  {
    nativeBuildInputs = [ pkgs.stdenv.cc ];
  }
  ''
    # Keep real ZMK API/DT headers. Only platform, event dispatch and HID fixtures
    # shadow their production headers; no production implementation is copied.
    mkdir -p stubs
    for header in \
      zephyr/device.h zephyr/init.h zephyr/kernel.h zephyr/types.h \
      zephyr/settings/settings.h zephyr/sys/ring_buffer.h zephyr/sys/atomic.h \
      zephyr/bluetooth/bluetooth.h zephyr/bluetooth/conn.h zephyr/bluetooth/hci.h \
      zephyr/bluetooth/uuid.h zephyr/bluetooth/gatt.h zephyr/bluetooth/hci_types.h \
      zephyr/bluetooth/addr.h zephyr/logging/log.h \
      zmk/keys.h zmk/hid.h zmk/event_manager.h zmk/split/bluetooth/uuid.h \
      zmk/events/keycode_state_changed.h zmk/events/usb_conn_state_changed.h \
      drivers/behavior.h
    do
      mkdir -p "stubs/$(dirname "$header")"
      printf '#include "fixture.h"\n' > "stubs/$header"
    done

    for variant in central peripheral profile-advertising-disabled; do
      case "$variant" in
        central) flags="" ;;
        peripheral) flags="-DCONFIG_ZMK_SPLIT_ROLE_CENTRAL=0" ;;
        profile-advertising-disabled) flags="-DCONFIG_ZMK_BLE_PROFILE_ADVERTISING=0" ;;
      esac
      ${pkgs.stdenv.cc}/bin/cc \
        -std=gnu11 -UNDEBUG -pthread \
        -Werror=implicit-function-declaration -Werror=incompatible-pointer-types \
        $flags \
        -I "$PWD/stubs" -I ${./tests} \
        -I ${firmwareSource}/app/include -I ${firmwareSource} \
        ${./tests/controller-fixture.c} -o "$variant"
      "./$variant"
    done

    mkdir -p "$out"
    touch "$out/passed"
  ''
