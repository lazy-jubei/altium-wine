#!/usr/bin/env python3

import fcntl
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile


IMAGE = "ram://4194304"
VOLUME_NAME = "AltiumWineRAM"
VOLUME_PATH = Path("/Volumes") / VOLUME_NAME
MAPPINGS_PATH = VOLUME_PATH / "mappings"
HDIUTIL = "/usr/bin/hdiutil"


def image_at_mount():
    images = plistlib.loads(subprocess.check_output([HDIUTIL, "info", "-plist"]))
    for image in images.get("images", []):
        entities = image.get("system-entities", [])
        if any(entity.get("mount-point") == str(VOLUME_PATH) for entity in entities):
            return image
    return None


def ensure_ram_volume():
    image = image_at_mount()
    if image is not None and image.get("image-path") == IMAGE:
        return
    if image is not None or os.path.lexists(VOLUME_PATH):
        raise RuntimeError(f"{VOLUME_PATH} is already in use")

    attached = plistlib.loads(subprocess.check_output([HDIUTIL, "attach", "-nomount", "-plist", IMAGE]))
    devices = [entity.get("dev-entry", "") for entity in attached["system-entities"]]
    whole_disks = [device for device in devices if re.fullmatch(r"/dev/disk[0-9]+", device)]
    if len(whole_disks) != 1:
        raise RuntimeError("could not identify the new RAM disk")
    device = whole_disks[0]
    try:
        subprocess.run(
            ["/usr/sbin/diskutil", "eraseDisk", "APFS", VOLUME_NAME, "GPT", device],
            stdout=subprocess.DEVNULL,
            check=True,
        )
        image = image_at_mount()
        if image is None or image.get("image-path") != IMAGE or not any(
            entity.get("dev-entry") == device for entity in image["system-entities"]
        ):
            raise RuntimeError("the new RAM disk did not mount at the expected path")
    except BaseException:
        subprocess.run([HDIUTIL, "detach", device], stdout=subprocess.DEVNULL, check=False)
        raise


def private_path(metadata, file_type):
    return file_type(metadata.st_mode) and metadata.st_uid == os.getuid() and not (metadata.st_mode & 0o077)


def main():
    lock_path = Path(tempfile.gettempdir()) / f"altium-wine-ram-{os.getuid()}.lock"
    lock_mode = os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW
    with os.fdopen(os.open(lock_path, lock_mode, 0o600), "rb") as lock:
        if not private_path(os.fstat(lock.fileno()), stat.S_ISREG):
            raise RuntimeError("the RAM mapping lock must be a private file owned by the current user")
        fcntl.flock(lock, fcntl.LOCK_EX)
        ensure_ram_volume()
        MAPPINGS_PATH.mkdir(mode=0o700, exist_ok=True)
        if not private_path(MAPPINGS_PATH.lstat(), stat.S_ISDIR):
            raise RuntimeError("the RAM mapping directory must be private and owned by the current user")
        print(MAPPINGS_PATH)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"RAM mappings: {error}", file=sys.stderr)
        sys.exit(1)
