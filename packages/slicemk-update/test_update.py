import errno
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from update import BOARD_ID, bootloader_device, flash, keyboard_returned


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
            firmware = Path(__file__).parent / "firmware" / "zmk-left.uf2"
            flash(volume, firmware)
            self.assertEqual(
                (volume / "zmk-left.uf2").read_bytes(), firmware.read_bytes()
            )

    def test_post_transfer_io_error_requires_same_keyboard_return(self):
        with tempfile.TemporaryDirectory() as directory:
            volume = Path(directory)
            (volume / "INFO_UF2.TXT").write_text(f"Board-ID: {BOARD_ID}\n")
            firmware = Path(__file__).parent / "firmware" / "zmk-left.uf2"
            usb = volume / "usb"
            usb.mkdir()
            keyboard = usb / "1-1"
            keyboard.mkdir()
            (keyboard / "idVendor").write_text("1d50")
            (keyboard / "idProduct").write_text("615e")
            (keyboard / "serial").write_text("other-device")
            error = OSError(errno.EIO, "bootloader disconnected")
            with (
                patch("update.os.fsync", side_effect=error),
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
            firmware = Path(__file__).parent / "firmware" / "zmk-left.uf2"
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
            firmware = Path(__file__).parent / "firmware" / "zmk-left.uf2"
            with (
                patch(
                    "update.os.fsync", side_effect=OSError(errno.ENOSPC, "disk full")
                ),
                patch("update.wait_for_keyboard", return_value=True),
            ):
                with self.assertRaises(OSError):
                    flash(volume, firmware, "target-device")


if __name__ == "__main__":
    unittest.main()
