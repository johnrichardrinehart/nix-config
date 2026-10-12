import errno
import fcntl
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time


BOARD_ID = "nRF52833-slicemk-ergodox-202207-green"
# The ZMK keyboard the bootloader turns back into after a successful update.
KEYBOARD_VENDOR = 0x1D50
KEYBOARD_PRODUCT = 0x615E


def bootloader_device(devices):
    matches = []

    def visit(device, transport=None):
        transport = device.get("tran") or transport
        if device.get("label") == "SliceMK":
            if transport != "usb" or device.get("fstype") != "vfat":
                raise ValueError("The SliceMK volume must be a USB FAT filesystem.")
            matches.append(device)
        for child in device.get("children", []):
            visit(child, transport)

    for device in devices:
        visit(device)
    if len(matches) != 1:
        raise ValueError("Connect exactly one SliceMK bootloader drive: the left half.")
    return matches[0]


def device_serial(name):
    device = (Path("/sys/class/block") / Path(name).name).resolve()
    for parent in (device, *device.parents):
        if (parent / "idVendor").exists() and (parent / "serial").exists():
            return (parent / "serial").read_text().strip()
    raise ValueError("Cannot identify the bootloader USB serial number.")


def keyboard_returned(serial, usb_devices=Path("/sys/bus/usb/devices")):
    for device in usb_devices.iterdir():
        try:
            if (
                (device / "serial").read_text().strip() == serial
                and (device / "idVendor").read_text().strip() == "1d50"
                and (device / "idProduct").read_text().strip() == "615e"
            ):
                return True
        except FileNotFoundError:
            continue
    return False


def darwin_bootloader_volume(volumes):
    """Pick the SliceMK bootloader volume from `diskutil info -plist` records."""
    matches = [volume for volume in volumes if volume.get("VolumeName") == "SliceMK"]
    if len(matches) != 1:
        raise ValueError("Connect exactly one SliceMK bootloader drive: the left half.")
    volume = matches[0]
    if volume.get("BusProtocol") != "USB" or volume.get("FilesystemType") != "msdos":
        raise ValueError("The SliceMK volume must be a USB FAT filesystem.")
    return volume


def darwin_usb_devices():
    """Every USB device with its I/O Registry subtree, as `ioreg` reports them."""
    output = subprocess.run(
        ["/usr/sbin/ioreg", "-a", "-l", "-r", "-c", "IOUSBHostDevice"],
        check=True,
        capture_output=True,
    ).stdout
    return plistlib.loads(output) if output.strip() else []


def _darwin_holds_disk(entry, disk):
    for child in entry.get("IORegistryEntryChildren", []):
        # A USB device below a hub is listed on its own; do not credit the hub.
        if "idVendor" in child:
            continue
        if child.get("BSD Name") == disk or _darwin_holds_disk(child, disk):
            return True
    return False


def darwin_device_serial(devices, disk):
    for device in devices:
        if _darwin_holds_disk(device, disk):
            serial = device.get("USB Serial Number") or device.get(
                "kUSBSerialNumberString"
            )
            if serial:
                return serial
    raise ValueError("Cannot identify the bootloader USB serial number.")


def darwin_keyboard_returned(serial, devices=None):
    devices = darwin_usb_devices() if devices is None else devices
    return any(
        device.get("idVendor") == KEYBOARD_VENDOR
        and device.get("idProduct") == KEYBOARD_PRODUCT
        and serial
        in (device.get("USB Serial Number"), device.get("kUSBSerialNumberString"))
        for device in devices
    )


def sync_to_device(fd):
    if sys.platform == "darwin":
        # fsync on macOS stops at the drive's cache; F_FULLFSYNC pushes every
        # block through to the bootloader.
        fcntl.fcntl(fd, fcntl.F_FULLFSYNC)
    else:
        os.fsync(fd)


def wait_for_keyboard(serial):
    returned = (
        darwin_keyboard_returned if sys.platform == "darwin" else keyboard_returned
    )
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if returned(serial):
            return True
        time.sleep(0.1)
    return False


def flash(volume, firmware, serial=None):
    info = (volume / "INFO_UF2.TXT").read_text()
    board_ids = [
        line.removeprefix("Board-ID:").strip()
        for line in info.splitlines()
        if line.startswith("Board-ID:")
    ]
    if board_ids != [BOARD_ID]:
        raise ValueError(f"Incorrect board ID. Expected {BOARD_ID}; found {board_ids}.")
    # Both halves report the same board ID. The operator must connect only the left half.
    with firmware.open("rb") as source:
        destination = (volume / "zmk-left.uf2").open("wb")
        try:
            shutil.copyfileobj(source, destination)
        except BaseException:
            try:
                destination.close()
            except OSError:
                pass
            raise
        # UF2 bootloaders reboot after receiving the last block, before FAT metadata sync.
        try:
            try:
                destination.flush()
                sync_to_device(destination.fileno())
            finally:
                destination.close()
        except OSError as error:
            if (
                error.errno not in (errno.EIO, errno.ENODEV, errno.ENXIO)
                or not serial
                or not wait_for_keyboard(serial)
            ):
                raise
            print(
                "The bootloader disconnected after transfer; the same keyboard returned over USB."
            )


def main():
    prepared = len(sys.argv) == 3 and sys.argv[2] == "--prepared"
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and not prepared):
        raise ValueError("Usage: slicemk-update")
    firmware = Path(sys.argv[1])
    if not prepared:
        print(
            "Connect only the LEFT half by USB; leave the right half and dongle unplugged from USB."
        )
        print(
            "With keys up and USB-C facing you, press the RIGHT/reset button twice within 500 ms; LEDs turn green."
        )
        if sys.stdin.isatty():
            input("Press Enter when the SliceMK bootloader drive is ready: ")
    if sys.platform == "darwin":
        darwin_update(firmware)
    else:
        linux_update(firmware)
    print(
        "Firmware transfer completed. The left half reboots automatically; test Tab and Bluetooth typing."
    )


def darwin_update(firmware):
    listing = plistlib.loads(
        subprocess.run(
            ["/usr/sbin/diskutil", "list", "-plist", "external"],
            check=True,
            capture_output=True,
        ).stdout
    )
    identifiers = []
    for disk in listing.get("AllDisksAndPartitions", []):
        identifiers.append(disk["DeviceIdentifier"])
        identifiers.extend(
            part["DeviceIdentifier"] for part in disk.get("Partitions", [])
        )

    def info(identifier):
        return plistlib.loads(
            subprocess.run(
                ["/usr/sbin/diskutil", "info", "-plist", identifier],
                check=True,
                capture_output=True,
            ).stdout
        )

    volume = darwin_bootloader_volume([info(identifier) for identifier in identifiers])
    if not volume.get("MountPoint"):
        subprocess.run(
            ["/usr/sbin/diskutil", "mount", volume["DeviceIdentifier"]],
            check=True,
            capture_output=True,
        )
        volume = info(volume["DeviceIdentifier"])
    mountpoint = Path(volume["MountPoint"])
    if not os.access(mountpoint, os.W_OK):
        raise ValueError(f"{mountpoint} is not writable.")
    serial = darwin_device_serial(darwin_usb_devices(), volume["ParentWholeDisk"])
    flash(mountpoint, firmware, serial)


def linux_update(firmware):
    result = subprocess.run(
        [
            "@utilLinux@/bin/lsblk",
            "--json",
            "--paths",
            "--output",
            "NAME,LABEL,FSTYPE,MOUNTPOINTS,TRAN",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    device = bootloader_device(json.loads(result.stdout)["blockdevices"])
    mountpoints = [point for point in device.get("mountpoints", []) if point]
    if len(mountpoints) > 1:
        raise ValueError(
            "The SliceMK volume has multiple mountpoints. Unmount extra mounts before updating."
        )
    volume = Path(mountpoints[0]) if mountpoints else None
    if os.geteuid() != 0 and (volume is None or not os.access(volume, os.W_OK)):
        sudo = Path("/run/wrappers/bin/sudo")
        if not sudo.exists():
            sudo = Path(shutil.which("sudo") or "")
        if not sudo.is_file():
            raise ValueError("Root access is required, but sudo is unavailable.")
        os.execv(
            str(sudo),
            [
                str(sudo),
                sys.executable,
                str(Path(__file__).resolve()),
                str(firmware),
                "--prepared",
            ],
        )
    serial = device_serial(device["name"])
    if volume is not None:
        flash(volume, firmware, serial)
    else:
        with tempfile.TemporaryDirectory(prefix="slicemk-update-") as directory:
            subprocess.run(
                [
                    "@utilLinux@/bin/mount",
                    "-o",
                    "nodev,nosuid,noexec",
                    "--",
                    device["name"],
                    directory,
                ],
                check=True,
            )
            try:
                flash(Path(directory), firmware, serial)
            finally:
                cleanup = subprocess.run(
                    ["@utilLinux@/bin/umount", "--", directory],
                    capture_output=True,
                    text=True,
                )
                if cleanup.returncode:
                    mounted = subprocess.run(
                        ["@utilLinux@/bin/findmnt", "--mountpoint", directory],
                        capture_output=True,
                    )
                    if mounted.returncode != 1:
                        raise OSError(
                            f"Cannot unmount the bootloader drive: {cleanup.stderr.strip()}"
                        )


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"slicemk-update: {error}", file=sys.stderr)
        print(
            "If the drive disappeared during transfer, the update is unverified. Check keyboard operation before retrying.",
            file=sys.stderr,
        )
        sys.exit(1)
