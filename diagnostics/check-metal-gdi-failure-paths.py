#!/usr/bin/env python3
"""Fault-inject the actual patched Wine readback header; no Wine prefix or GPU."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('wine_source', type=Path, help='Patched Wine source tree')
args = parser.parse_args()
header = (args.wine_source / 'dlls/winemac.drv/gdi_readback.h').read_text()
# Redirect only the two allocation sites; all state and cleanup use production code.
for original, injected in (
    ('[[NSData alloc] initWithBytes:', '[ReadbackAllocators pixelsWithBytes:'),
    ('[[NSMutableData alloc] initWithLength:', '[ReadbackAllocators cropWithLength:'),
):
    if header.count(original) != 1:
        raise SystemExit('Readback allocation site changed: review this fixture')
    header = header.replace(original, injected)
with tempfile.TemporaryDirectory(prefix='metal-gdi-check-') as temporary:
    directory = Path(temporary)
    (directory / 'gdi_readback.h').write_text(header)
    executable = directory / 'check'
    subprocess.run(['/usr/bin/clang', '-arch', 'x86_64', '-fobjc-weak', '-fblocks',
                    '-I', str(directory), str(Path(__file__).with_name('metal-gdi-failure-paths.m')),
                    '-framework', 'Foundation', '-framework', 'CoreGraphics', '-framework', 'Metal', '-framework', 'QuartzCore',
                    '-o', str(executable)], check=True)
    for stage in ('command', 'encoder', 'pixels', 'crop'):
        subprocess.run([str(executable), stage], check=True, timeout=10)
