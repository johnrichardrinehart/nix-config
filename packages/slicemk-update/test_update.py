import errno
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from update import (
    BOARD_ID,
    KEYBOARD_PRODUCT,
    KEYBOARD_VENDOR,
    bootloader_device,
    darwin_bootloader_volume,
    darwin_device_serial,
    darwin_keyboard_returned,
    flash,
    keyboard_returned,
)


class UpdateTests(unittest.TestCase):
    def test_refuses_zero_or_multiple_bootloaders(self):
        device = {
            "name": "/dev/sdb",
            "label": "SliceMK",
            "fstype": "vfat",
            "tran": "usb",
        }
        for devices in ([], [device, {**device, "name": "/dev/sdc"}]):
            with self.subTest(devices=devices), self.assertRaises(ValueError):
                bootloader_device(devices)

    def test_detects_usb_partition_with_parent_transport(self):
        partition = {"name": "/dev/sdb1", "label": "SliceMK", "fstype": "vfat"}
        self.assertEqual(
            bootloader_device([{"tran": "usb", "children": [partition]}]), partition
        )

    def test_refuses_non_usb_or_non_fat_volume(self):
        for transport, filesystem in (("nvme", "vfat"), ("usb", "ext4")):
            with self.subTest(transport=transport), self.assertRaises(ValueError):
                bootloader_device(
                    [{"label": "SliceMK", "tran": transport, "fstype": filesystem}]
                )

    def test_wrong_board_does_not_overwrite_firmware(self):
        with tempfile.TemporaryDirectory() as directory:
            volume = Path(directory)
            (volume / "INFO_UF2.TXT").write_text("Board-ID: nRF52840-MDBT50Q_CX-blue\n")
            firmware = volume / "source.uf2"
            firmware.write_bytes(b"new firmware")
            destination = volume / "zmk-left.uf2"
            destination.write_bytes(b"existing data")
            with self.assertRaises(ValueError):
                flash(volume, firmware)
            self.assertEqual(destination.read_bytes(), b"existing data")

    def test_transfers_complete_firmware_to_correct_board(self):
        with tempfile.TemporaryDirectory() as directory:
            volume = Path(directory)
            (volume / "INFO_UF2.TXT").write_text(
                f"Model: SliceMK\nBoard-ID: {BOARD_ID}\n"
            )
            firmware = Path(os.environ["SLICEMK_FIRMWARE"])
            flash(volume, firmware)
            self.assertEqual(
                (volume / "zmk-left.uf2").read_bytes(), firmware.read_bytes()
            )

    def test_post_transfer_io_error_requires_same_keyboard_return(self):
        with tempfile.TemporaryDirectory() as directory:
            volume = Path(directory)
            (volume / "INFO_UF2.TXT").write_text(f"Board-ID: {BOARD_ID}\n")
            firmware = Path(os.environ["SLICEMK_FIRMWARE"])
            usb = volume / "usb"
            usb.mkdir()
            keyboard = usb / "1-1"
            keyboard.mkdir()
            (keyboard / "idVendor").write_text("1d50")
            (keyboard / "idProduct").write_text("615e")
            (keyboard / "serial").write_text("other-device")
            error = OSError(errno.EIO, "bootloader disconnected")
            with (
                patch("update.sync_to_device", side_effect=error),
                patch(
                    "update.wait_for_keyboard",
                    side_effect=lambda serial: keyboard_returned(serial, usb),
                ),
            ):
                with self.assertRaises(OSError):
                    flash(volume, firmware, "target-device")
                (keyboard / "serial").write_text("target-device")
                flash(volume, firmware, "target-device")
                self.assertEqual(
                    (volume / "zmk-left.uf2").read_bytes(), firmware.read_bytes()
                )
                (keyboard / "idProduct").write_text("0001")
                with self.assertRaises(OSError):
                    flash(volume, firmware, "target-device")

    def test_early_write_failure_is_not_a_successful_reboot(self):
        with tempfile.TemporaryDirectory() as directory:
            volume = Path(directory)
            (volume / "INFO_UF2.TXT").write_text(f"Board-ID: {BOARD_ID}\n")
            firmware = Path(os.environ["SLICEMK_FIRMWARE"])
            with (
                patch(
                    "update.shutil.copyfileobj",
                    side_effect=OSError(errno.EIO, "write failed"),
                ),
                patch("update.wait_for_keyboard", return_value=True),
            ):
                with self.assertRaises(OSError):
                    flash(volume, firmware, "target-device")

    def test_non_disconnect_sync_error_remains_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            volume = Path(directory)
            (volume / "INFO_UF2.TXT").write_text(f"Board-ID: {BOARD_ID}\n")
            firmware = Path(os.environ["SLICEMK_FIRMWARE"])
            with (
                patch(
                    "update.sync_to_device",
                    side_effect=OSError(errno.ENOSPC, "disk full"),
                ),
                patch("update.wait_for_keyboard", return_value=True),
            ):
                with self.assertRaises(OSError):
                    flash(volume, firmware, "target-device")

    # macOS: `diskutil info -plist` records and `ioreg -a -l -r -c IOUSBHostDevice`.
    def darwin_volume(self, **overrides):
        return {
            "DeviceIdentifier": "disk4",
            "ParentWholeDisk": "disk4",
            "VolumeName": "SliceMK",
            "BusProtocol": "USB",
            "FilesystemType": "msdos",
            "MountPoint": "/Volumes/SliceMK",
            **overrides,
        }

    def test_darwin_refuses_zero_or_multiple_bootloaders(self):
        other = self.darwin_volume(DeviceIdentifier="disk5", ParentWholeDisk="disk5")
        for volumes in ([], [self.darwin_volume(), other]):
            with self.subTest(volumes=volumes), self.assertRaises(ValueError):
                darwin_bootloader_volume(volumes)

    def test_darwin_picks_the_slicemk_volume_among_others(self):
        volume = self.darwin_volume()
        unrelated = self.darwin_volume(VolumeName="BACKUP", DeviceIdentifier="disk5s1")
        self.assertIs(darwin_bootloader_volume([unrelated, volume]), volume)

    def test_darwin_refuses_non_usb_or_non_fat_volume(self):
        for overrides in ({"BusProtocol": "PCI-Express"}, {"FilesystemType": "apfs"}):
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                darwin_bootloader_volume([self.darwin_volume(**overrides)])

    def test_darwin_serial_comes_from_the_device_that_holds_the_disk(self):
        # The shape ioreg reports for the SliceMK bootloader: its interfaces
        # and mass-storage nubs repeat the device's idVendor.
        bootloader = {
            "IOObjectClass": "IOUSBHostDevice",
            "idVendor": 0x239A,
            "idProduct": 0x00B3,
            "USB Serial Number": "target-device",
            "IORegistryEntryChildren": [
                {
                    "IOObjectClass": "IOUSBHostInterface",
                    "idVendor": 0x239A,
                    "IORegistryEntryChildren": [
                        {
                            "IOObjectClass": "IOUSBMassStorageInterfaceNub",
                            "idVendor": 0x239A,
                            "IORegistryEntryChildren": [
                                {"IOObjectClass": "IOMedia", "BSD Name": "disk4"}
                            ],
                        }
                    ],
                }
            ],
        }
        # ioreg lists a hub with the device below it, and the device again on
        # its own; the hub must not be taken for the bootloader.
        hub = {
            "IOObjectClass": "IOUSBHostDevice",
            "idVendor": 0x05E3,
            "idProduct": 0x0610,
            "USB Serial Number": "hub",
            "IORegistryEntryChildren": [bootloader],
        }
        self.assertEqual(
            darwin_device_serial([hub, bootloader], "disk4"), "target-device"
        )
        with self.assertRaises(ValueError):
            darwin_device_serial([hub, bootloader], "disk5")

    def test_darwin_keyboard_return_needs_same_serial_and_zmk_ids(self):
        keyboard = {
            "idVendor": KEYBOARD_VENDOR,
            "idProduct": KEYBOARD_PRODUCT,
            "USB Serial Number": "target-device",
        }
        self.assertTrue(darwin_keyboard_returned("target-device", [keyboard]))
        self.assertFalse(darwin_keyboard_returned("other-device", [keyboard]))
        self.assertFalse(
            darwin_keyboard_returned("target-device", [{**keyboard, "idProduct": 1}])
        )


if __name__ == "__main__":
    unittest.main()
