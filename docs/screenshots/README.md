# Screenshot project and attribution

These are real captures of Altium Designer 26.10.1 running under Wine on an
Apple Silicon M4 Mac with macOS 15.7.9. They were captured on October 3, 2026.
The macOS menu bar shows the active Wine application. The images show the
3D PCB editor, the 2D PCB editor with the top layer emphasized, and the FPGA
banks 1–4 schematic.

The example is **LimeSDR-USB**, an open-hardware software-defined radio board
built around an Altera Cyclone IV EP4CE40 FPGA. The hardware design is by
**Lime Microsystems / Myriad-RF** and is licensed under
[Creative Commons Attribution 3.0 Unported](https://creativecommons.org/licenses/by/3.0/).

- [Upstream repository and licensing statement](https://github.com/myriadrf/LimeSDR-USB)
- [Exact source revision: c6ea7cea27b90e94625b8e49b71ee2a10a5345bb](https://github.com/myriadrf/LimeSDR-USB/tree/c6ea7cea27b90e94625b8e49b71ee2a10a5345bb)
- [Altium project: hardware/plug/1v4/LimeSDR-USB_1v4.PrjPcb](https://github.com/myriadrf/LimeSDR-USB/blob/c6ea7cea27b90e94625b8e49b71ee2a10a5345bb/hardware/plug/1v4/LimeSDR-USB_1v4.PrjPcb)

The underlying hardware design was not modified. The repository includes
screenshots; the Altium project files remain in their upstream repository.

To reproduce the views, download or clone the upstream design, open the
project above in Altium, and open `PCB/LimeSDR-USB_1v4.PcbDoc` or
`Schematics/08_FPGA_banks_1_2_3_4.SchDoc` from the Projects panel.
For the 3D view, choose View → 3D Layout Mode, then
View → 3D View Control → Isometric View.
The screenshots demonstrate document loading and rendering; they do not
constitute electrical, manufacturing or full Altium feature validation.
