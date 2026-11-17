#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""List the FlashPro adapters that are connected: serial number, USB ID, name, model and USB location.

    flashpros.py [--vendor ID] [--all]
    flashpros.py --model [--serial SERIAL] [--location LOCATION]
    flashpros.py --serials MODEL
    flashpros.py --adapters MODEL

Reads the USB devices from sysfs (Linux) and prints those of the Microchip (Actel) vendor ID 1514 as
"SERIAL  vendor:product  name  model  location". SERIAL is the serial number of the USB descriptor, for --flashpro of
hw/bootmode.py and FLASHPRO_SERIAL of lab.conf. A FlashPro whose descriptor has no serial number (iSerial not set) is listed
too, with "-" as its serial number: it cannot be chosen by serial number, only by its USB location, which is the name of its
directory in /sys/bus/usb/devices (such as 1-2.3: bus, then the ports of the hubs in between, as OpenOCD's "adapter usb
location" takes it) and is FLASHPRO_USB_LOCATION of lab.conf. The location changes if the adapter is plugged into another port.

The model is told by the product ID: 200b is an embedded FlashPro6 (efp6), 2008 is a FlashPro5 (fp5) if the product name is
"FlashPro5", which is what the OpenOCD configuration of the FlashPro5 asks for, else an embedded FlashPro5 (efp5), which has the
same ID; 2009 is a FlashPro6 (fp6); any other ID is "unknown". It only reads the descriptors the kernel has cached: it does not
open the adapter, so it is safe while OpenOCD or fpgenprog use it.

--all lists every USB device, not only those of the vendor (to find the vendor ID of an adapter that is not shown), --vendor ID
matches another vendor (hex). For hw/start_openocd.sh: --model prints only the models of the adapters (of those with that serial
number or at that location, if given), one per line; --serials MODEL prints the serial numbers of the adapters of that model
(efp6, fp6, efp5 or fp5), one per line, and none for an adapter without one; --adapters MODEL prints "SERIAL LOCATION" for each
adapter of that model, with "-" where there is no serial number.

That the serial number printed here is the one fpgenprog names its programmer by is not proven (it needs a
board); bootmode.py checks which programmer fpgenprog used and prints its serial after every run. FlashPro Express names a
programmer by yet another ID (see hw/program.py).

Exit status: 0 at least one adapter listed, 1 none found, 2 sysfs is not there or a bad option.
"""
import argparse
import os
import sys
from pathlib import Path

MICROCHIP_VENDOR = "1514"
MODELS = ("efp6", "fp6", "efp5", "fp5")   # the values of FLASHPRO_TYPE in lab.conf
SYSFS_USB = "/sys/bus/usb/devices"


def attribute(device: Path, name: str) -> str:
    try:
        return (device / name).read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return ""


def model_of(vid: str, pid: str, name: str) -> str:
    """The model of the FlashPro with this USB vendor and product ID (lower case hex) and product name, or "unknown"."""
    if vid != MICROCHIP_VENDOR:
        return "unknown"
    if pid == "200b":
        return "efp6"
    if pid == "2008":
        return "fp5" if name == "FlashPro5" else "efp5"
    if pid == "2009":
        return "fp6"
    return "unknown"


def list_devices(sysfs: Path, vendor: str | None) -> list[tuple[str, str, str, str, str]]:
    """(serial, "vendor:product", name, model, location) of the USB devices, of <vendor> only if given. The serial number is
    "" if the descriptor has none; the location is the name of the sysfs directory (1-2.3). Entries of sysfs that are not
    devices (the interfaces, which have no vendor ID) are left out."""
    found = []
    for device in sorted(sysfs.iterdir()):
        vid, pid = attribute(device, "idVendor"), attribute(device, "idProduct")
        if not vid or (vendor and vid.lower() != vendor):
            continue
        name = attribute(device, "product")
        found.append((attribute(device, "serial"), f"{vid}:{pid}", name or "(no name)",
                      model_of(vid.lower(), pid.lower(), name), device.name))
    return found


# The assumption, for now: the programming tools of Microchip (FlashPro Express, fpgenprog) name a FlashPro5 "S2" and the serial
# number that OpenOCD shows (S200BM0VJ was seen for an adapter that OpenOCD showed as 00BM80VJ: one character differs, so a
# name derived this way has to be checked against what the tool finds)
FP5_PREFIX = "S2"


def flashpro5_id(lab_conf: dict[str, str]) -> str | None:
    """The name the programming tools of Microchip are assumed to give the FlashPro5 that FLASHPRO_SERIAL names: FP5_PREFIX and
    the serial number (not again if it has the prefix). The model is FLASHPRO_TYPE (fp5 or efp5), else the one the USB
    descriptors of that serial number show (FLASHPRO_SYSFS names another sysfs, for the tests). None for another model, an
    unknown serial number or no serial number."""
    serial = lab_conf.get("FLASHPRO_SERIAL", "")
    if not serial:
        return None
    model = lab_conf.get("FLASHPRO_TYPE", "")
    if not model:
        sysfs = Path(os.environ.get("FLASHPRO_SYSFS", SYSFS_USB))
        found = list_devices(sysfs, MICROCHIP_VENDOR) if sysfs.is_dir() else []
        model = next((d[3] for d in found if d[0] == serial), "")
    if model not in ("fp5", "efp5"):
        return None
    return serial if serial.startswith(FP5_PREFIX) else FP5_PREFIX + serial


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="./x hw flashpros", description=__doc__.split("\n")[0])
    ap.add_argument("--vendor", metavar="ID", default=MICROCHIP_VENDOR, help="USB vendor ID in hex (default: %(default)s)")
    ap.add_argument("--all", action="store_true", help="list every USB device, not only those of the vendor")
    ap.add_argument("--model", action="store_true", help="print only the models of the FlashPro, one per line")
    ap.add_argument("--serials", metavar="MODEL", choices=MODELS,
                    help="print only the serial numbers of the FlashPro of this model, one per line (none for one without)")
    ap.add_argument("--adapters", metavar="MODEL", choices=MODELS,
                    help="print 'SERIAL LOCATION' for each FlashPro of this model, '-' where there is no serial number")
    ap.add_argument("--serial", metavar="SERIAL", help="with --model: only the FlashPro with this serial number")
    ap.add_argument("--location", metavar="LOCATION", help="with --model: only the FlashPro at this USB location (such as 1-2.3)")
    ap.add_argument("--sysfs", metavar="DIR", default=SYSFS_USB, help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    sysfs = Path(a.sysfs)
    if not sysfs.is_dir():
        print(f"flashpros: {sysfs} does not exist: this needs the USB sysfs of Linux (is the USB device passed "
              "into the container?)", file=sys.stderr)
        return 2
    vendor = None if a.all else a.vendor.lower().removeprefix("0x").zfill(4)
    found = list_devices(sysfs, vendor)
    if a.serials:
        found = [d for d in found if d[3] == a.serials]
        for d in found:
            if d[0]:
                print(d[0])
    elif a.adapters:
        found = [d for d in found if d[3] == a.adapters]
        for d in found:
            print(f"{d[0] or '-'} {d[4]}")
    elif a.model:
        found = [d for d in found if (not a.serial or d[0] == a.serial) and (not a.location or d[4] == a.location)]
        for m in sorted({d[3] for d in found}):
            print(m)
    else:
        for serial, ids, name, model, location in found:
            print(f"{serial or '-'}  {ids}  {name}  {model}  {location}")
    if not found:
        what = "USB device" if a.all else f"FlashPro (USB vendor {vendor})"
        print(f"flashpros: no {what} found; check the cable and the power of the board, or try --all",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
