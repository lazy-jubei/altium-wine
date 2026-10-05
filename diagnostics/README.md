# AD17 buffer upload probe

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

On October 5, 2026, the readback-verified comparison measured 5.35 fps / 67.1 µs per lock+unlock with CSMT enabled, versus 10.19 fps / 24.9 µs with it disabled. Two earlier comparisons showed the same direction. A final repeat with AD17 open measured 2.98 versus 9.07 fps, showing run-to-run variability. These are synthetic results, not AD17 board frame rates. The full-board comparison remains blocked by AD17's STEP model-server errors and loading stalls.

`WINE_D3D_CONFIG='SampleCount=0,csmt=0'` is a per-launch experiment; it is not enabled by the kit. Altium's full rendering behavior and stability still need validation before changing the default.
