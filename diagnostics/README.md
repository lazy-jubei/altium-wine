# AD17 diagnostics

## Model-server pipe writes

`model-pipe-write.c` isolates the AD17 model server's I/O pattern without Altium files. It starts a duplex pipe with `FILE_FLAG_OVERLAPPED`, submits a read, then writes 61,440-byte blocks with a NULL `OVERLAPPED`. The peer completes the read before consuming the write. The probe verifies all 3,932,160 transferred bytes and checks that the first write waits for its consumer.

```sh
i686-w64-mingw32-gcc model-pipe-write.c -O2 -Wall -Wextra -o AltiumMS.exe
```

Run in a disposable directory in the AD17 prefix; **do not replace Altium's own executable**. The filename exercises the process-specific workaround in `patches/0010`.

```sh
ALTIUM_WINE_ROOT="$HOME/AltiumWine17" bash ../altium-wine.sh wine 'Z:\path\to\probe\AltiumMS.exe'
ALTIUM_WINE_ROOT="$HOME/AltiumWine17" bash ../altium-wine.sh wine 'Z:\path\to\probe\AltiumMS.exe' --overlapped
```

On October 5, 2026, the original Wine DLL failed the first test with `ERROR_IO_PENDING` (997), matching the live AltiumMS crash. With `0010`, the NULL-overlapped test passed (318 ms first write), as did ordinary overlapped writes (314 ms). Both checked the full payload and the duplex read. Renaming the probe to `pipe-control.exe` still reproduces the original failure for NULL-overlapped writes, confirming the workaround's scope; proper overlapped writes pass under either filename.

## Buffer uploads

`d3d9-buffer-bench.c` reproduces the small dynamic-buffer upload pattern seen in AD17: 2,600 discard locks and draws per frame, with a 420-byte vertex buffer. It warms up for two frames, measures eight, and checks the triangle and background pixels through GPU readback. It requires no Altium SDK or project files.

Build a 32-bit Windows executable with MinGW:

```sh
i686-w64-mingw32-gcc d3d9-buffer-bench.c -O2 -o buffer-bench.exe -ld3d9 -luser32 -lgdi32
```

Run the executable in the AD17 Wine prefix with each setting, using the same patched Wine bundle:

```sh
WINE_D3D_CONFIG='SampleCount=0,csmt=1' ALTIUM_WINE_ROOT="$HOME/AltiumWine17" bash ../altium-wine.sh wine 'Z:\path\to\buffer-bench.exe'
WINE_D3D_CONFIG='SampleCount=0,csmt=0' ALTIUM_WINE_ROOT="$HOME/AltiumWine17" bash ../altium-wine.sh wine 'Z:\path\to\buffer-bench.exe'
```

On October 5, 2026, the readback-verified comparison measured 5.35 fps / 67.1 µs per lock+unlock with CSMT enabled, versus 10.19 fps / 24.9 µs with it disabled. Two earlier comparisons showed the same direction. A final repeat with AD17 open measured 2.98 versus 9.07 fps, showing run-to-run variability. These are synthetic results, not AD17 board frame rates. The pipe-write fix above subsequently allowed the Music and LimeSDR boards to load and render in 3D.

`WINE_D3D_CONFIG='SampleCount=0,csmt=0'` is a per-launch experiment; it is not enabled by the kit. Altium's full rendering behavior and stability still need validation before changing the default.

A matched Music-board rotation test after the pipe fix used the same 12-second mouse drag, viewport, original d3d9 and `SampleCount=0`. Wine's present counter measured median **2.18 fps with CSMT enabled** and **2.28 fps with it disabled** (eight samples each). Both rendered correctly. The small difference does not establish a useful board-level improvement, so CSMT and antialiasing defaults remain unchanged.

## Window coordinates

`window-coordinates.c` creates hidden windows with negative, mixed and positive
coordinates. A foreign process at 96 DPI verifies their rectangles against signed
`MulDiv` results. Build with `-D_WIN32_WINNT=0x0a00` using either the i686 or
x86_64 compiler. The original server fails four of five cases; `0013` passes all
five in both architectures. It requires no Altium files.

## Upload ordering

`d3d9-upload-order.c` uses 2 MiB dynamic vertex and index buffers, changing colours
and positions between queued draws. GPU readback checks 64 tiles after ring reuse,
partial writes, ordinary maps and a zero-size lock. With the fast path enabled it
also checks disjoint nested locks and rejection of draws with locked buffers.
Both modes pass. Wine's legacy nested-map path has separate rendering failures,
so nested-lock checks run only against the new upload path.
It also checks partial discards at the end of both buffers followed by disjoint
NOOVERWRITE writes. The old index range is explicitly recreated after discard.

```sh
i686-w64-mingw32-gcc d3d9-upload-order.c -O2 -ld3d9 -lgdi32 -o upload-order.exe
ALTIUM_D3D9_UPLOADS=0 WINE_D3D_CONFIG=SampleCount=0 wine upload-order.exe
ALTIUM_D3D9_UPLOADS=1 WINE_D3D_CONFIG=SampleCount=0 wine upload-order.exe
ALTIUM_D3D9_UPLOADS=1 ALTIUM_D3D9_UPLOAD_HINTS=1 WINE_D3D_CONFIG=SampleCount=0,csmt=1 wine upload-order.exe
ALTIUM_D3D9_UPLOADS=1 ALTIUM_D3D9_UPLOAD_HINTS=1 WINE_D3D_CONFIG=SampleCount=0,csmt=0 wine upload-order.exe
```

These probes use their own test windows. They do not modify project files.

## Immediate draw ordering

`d3d9-up-order.c` verifies queued `DrawPrimitiveUP` and
`DrawIndexedPrimitiveUP` uploads using GPU pixel readback. It overwrites or frees
caller data immediately, varies strides, uses both index formats and a nonzero
minimum vertex, crosses and grows both rings, and checks stream/index cleanup
and device Reset.

```sh
i686-w64-mingw32-gcc d3d9-up-order.c -O2 -ld3d9 -lgdi32 -o up-order.exe
ALTIUM_D3D9_QUEUED_UP=0 wine up-order.exe
ALTIUM_D3D9_QUEUED_UP=1 wine up-order.exe
ALTIUM_D3D9_QUEUED_UP=1 WINE_D3D_CONFIG=csmt=0 wine up-order.exe
```
## GDI bitmap check

`gdi-copy-check.c` checks bitmap fills, row padding, single-pixel and clipped
copies, raster operations, top-down/bottom-up storage, large overlapping copies
in nine directions, and font rendering. It reads back and verifies the pixels.
Its copy timings are microbenchmarks; they do not measure CAD panning fps.

Build with the kit's compiler, then run in the AD17 prefix:

```bash
~/AltiumWine/tools/llvm-mingw/bin/i686-w64-mingw32-gcc -O2 \
  diagnostics/gdi-copy-check.c -o /tmp/gdi-copy-check.exe -lgdi32 -luser32
ALTIUM_WINE_ROOT=~/AltiumWine17 bash altium-wine.sh wine /tmp/gdi-copy-check.exe
```

The native viewport-copy path is controlled by `AD17_NATIVE_GDI` (default `1`)
and `AD17_NATIVE_GDI_WORKERS` (default `2`). Set `AD17_SMOOTH_SCHEMATIC_PAN=0`
when measuring completed CAD redraws. With direct diagnostic launches, use the
corresponding `ALTIUM_NATIVE_GDI` and `ALTIUM_SMOOTH_SCHEMATIC_PAN` variables.
Confirm `native viewport=1` and `ARM_COPY native worker` in the log; a passing
pixel check with the feature disabled is insufficient. A missing worker must
log startup failure and still pass `gdi-copy-check` through Wine's fallback.

## Schematic interaction check

Use a disposable AD17 schematic with both acceleration options enabled. Edit a
component, undo/redo, place a wire and net label, select/copy/paste/move objects,
and save/reopen the document. Verify the reopened values and connections.

With component properties open, left-click and right-drag the disabled canvas.
The dialog must stay in front and the canvas must not show a translated preview.
Repeat with Component Pin Editor → Pin Properties, then cancel without edits.
Check normal panning and resize during a pan; releasing or refreshing must not
shift the drawing or leave an overlay. Confirm no held buttons/modifiers remain.

Hover over a component until its hint appears. Focus must remain in the
schematic, and a right-button pan starting inside the hint's rectangle must
reach the underlying canvas.


Zoom into a populated sheet, then pan quickly in a figure-eight and inspect all
four edges, reversals, and the image after release. Repeat with
`AD17_SMOOTH_SCHEMATIC_PAN=0` as the real-redraw control.

The macOS helper checks the foreground schematic window before posting input:

```bash
cc diagnostics/schematic-figure-eight.m -framework AppKit \
  -framework ApplicationServices -o /tmp/schematic-figure-eight
# Supply the current native window ID and coordinates inside the canvas.
/tmp/schematic-figure-eight WINDOW_ID 1450 850 600 300 1.8 3.6
```

Use `ALTIUM_PAN_STATS=1` on the AD17 launcher for per-gesture compositor counts.
A static capture caused by another app covering the gesture is not a pass.

## Native mapping regression

Build against the source tree produced by the kit, then use its exported worker:

```bash
cc -arch x86_64 -O2 -Wno-deprecated-declarations \
  -I ~/AltiumWine/build/src-wine-11.16/dlls/winemac.drv \
  diagnostics/native-copy-check.c -o /tmp/native-copy-check
/tmp/native-copy-check ~/AltiumWine/build/modules-export/altium-gdi-copy-arm64
```

Checks complete pixels and row padding in both orientations, reverses cached
source/destination roles, then replaces an allocation at the same address.

## ADO startup properties

`ado-properties.c` checks CommandTimeout, Prepared, parameter precision, and
lookup by name, null BSTR and index. Build using either the i686 or x86_64
compiler with `-I ~/AltiumWine/build/obj-wine-11.16/include -lole32 -loleaut32`,
then run in the tested Wine prefix. Both architectures pass.

## Schematic pan rate

`pan-frames.swift` counts changed content in a ScreenCaptureKit window capture.
Use a region which stays populated for the entire pan, away from the cursor,
crosshair and status bars. A small region that becomes blank undercounts frames.
The optional `linear` gesture follows the same horizontal path every four seconds.

```bash
swiftc -parse-as-library -O diagnostics/pan-frames.swift -o /tmp/pan-frames
# Capture in one terminal; start the gesture after “capture ready” and refocus Altium.
/tmp/pan-frames WINDOW_ID 23 450 100 680 250 120
/tmp/schematic-figure-eight WINDOW_ID 1450 850 500 1 4 20 linear
```

Coordinates above assume the tested 2560-point window; captures are scaled to
1280 pixels wide. Count `change` timestamps from 1.5 to 19.5 seconds and divide
by 18. Report completed CAD frames separately from compositor interpolation
and from MoltenVK's GPU presentation statistics.

## Cocoa main-thread dispatch

On macOS with Rosetta, test `0029` against the actual Wine helper:

```bash
python3 diagnostics/main-thread-reentry.py /path/to/patched/dlls/winemac.drv/cocoa_event.m \
  --baseline /path/to/unpatched/dlls/winemac.drv/cocoa_event.m
```

The baseline must deadlock. The patched helper must finish direct, nested, semaphore-worker and kqueue-worker calls.
