#!/usr/bin/env python3
"""Measure visible schematic redraws during wheel scrolling on an X11 desktop."""

import argparse
import concurrent.futures
import ctypes
import time
import zlib

import gi

gi.require_version("Gdk", "3.0")
from gi.repository import Gdk


def navigate(x, y, start, duration, rate, pan, wheel_burst):
    x11 = ctypes.CDLL("libX11.so.6")
    xtest = ctypes.CDLL("libXtst.so.6")
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    x11.XFlush.argtypes = [ctypes.c_void_p]
    xtest.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
                                          ctypes.c_int, ctypes.c_ulong]
    xtest.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int,
                                          ctypes.c_ulong]
    xtest.XTestFakeRelativeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                                  ctypes.c_int, ctypes.c_ulong]
    display = x11.XOpenDisplay(None)
    if not display:
        raise RuntimeError("Cannot open the X11 display.")
    try:
        xtest.XTestFakeMotionEvent(display, -1, x, y, 0)
        x11.XFlush(display)
        if pan:
            time.sleep(max(0, start - time.monotonic()))
            xtest.XTestFakeButtonEvent(display, 3, 1, 0)
        for event in range(int(duration * rate)):
            time.sleep(max(0, start + event / rate - time.monotonic()))
            if pan:
                step = 8 if event // 24 % 2 == 0 else -8
                xtest.XTestFakeRelativeMotionEvent(display, step, 0, 0)
            else:
                # Alternate before reaching a scroll or zoom limit.
                button = 4 if event // wheel_burst % 2 == 0 else 5
                xtest.XTestFakeButtonEvent(display, button, 1, 0)
                xtest.XTestFakeButtonEvent(display, button, 0, 0)
            x11.XFlush(display)
    finally:
        if pan:
            xtest.XTestFakeButtonEvent(display, 3, 0, 0)
        x11.XCloseDisplay(display)


def measure(root, area, start, duration, rate):
    previous = None
    changes = samples = 0
    time.sleep(max(0, start - time.monotonic()))
    deadline = start + duration
    while time.monotonic() < deadline:
        image = Gdk.pixbuf_get_from_window(root, *area)
        if image is None:
            raise RuntimeError("Could not capture the schematic region.")
        checksum = zlib.crc32(image.get_pixels())
        if previous is not None and checksum != previous:
            changes += 1
        previous = checksum
        samples += 1
        time.sleep(max(0, min(deadline, start + samples / rate) - time.monotonic()))
    return changes, samples, time.monotonic() - start


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("region", nargs=4, type=int, metavar="PIXELS",
                        help="capture region as X Y WIDTH HEIGHT")
    parser.add_argument("--seconds", type=float, default=6)
    parser.add_argument("--wheel-rate", type=int, default=60)
    parser.add_argument("--wheel-burst", type=int, default=8,
                        help="wheel notches in each direction before reversing")
    parser.add_argument("--sample-rate", type=int, default=144)
    parser.add_argument("--pan", action="store_true", help="measure right-drag panning instead of wheel scrolling")
    args = parser.parse_args()
    root = Gdk.get_default_root_window()
    if root is None or "X11" not in type(root).__name__:
        parser.error("An active X11 desktop is required.")
    x, y, width, height = args.region
    if min(x, y) < 0 or min(width, height) <= 0 or x + width > root.get_width() or y + height > root.get_height():
        parser.error("The capture region must fit within the desktop.")
    if min(args.seconds, args.wheel_rate, args.sample_rate, args.wheel_burst) <= 0:
        parser.error("The duration, rates and wheel burst must be positive.")

    start = time.monotonic() + 0.5
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
        scroll = executor.submit(navigate, x + width // 2, y + height // 2, start,
                                 args.seconds, args.wheel_rate, args.pan, args.wheel_burst)
        changes, samples, elapsed = measure(root, args.region, start, args.seconds, args.sample_rate)
        scroll.result()
    print(f"{changes / elapsed:.1f} visible redraws/sec "
          f"({changes} changed frames, {samples} samples, {elapsed:.2f} s)")


if __name__ == "__main__":
    main()
