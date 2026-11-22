#!/usr/bin/env python3
"""Verify setup can run again while its original wineserver remains alive.

Linux only. Reuses an installed runner; creates and removes its own test prefix.
Requires xvfb-run. No Altium installer, project or production prefix is opened.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('runner', type=Path, help='Installed Wine runner directory containing bin/wine')
args = parser.parse_args()
if not sys.platform.startswith('linux'):
    raise SystemExit('Linux only')
runner = args.runner.resolve()
if not (runner / 'bin/wineserver').is_file():
    raise SystemExit('Runner has no bin/wineserver')
kit = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='aw-setup-repeat-') as temporary:
    root = Path(temporary)
    (root / 'runners').mkdir()
    (root / 'runners' / runner.name).symlink_to(runner, target_is_directory=True)
    prefix = root / 'prefix'
    env = os.environ.copy()
    env.update(ALTIUM_WINE_ROOT=str(root), WINEPREFIX=str(prefix), WINEDEBUG='-all')
    command = ['xvfb-run', '-a', 'bash', str(kit / 'install.sh'), '--root', str(root),
               '--skip-altium', '--no-launcher', '--yes']
    server = [str(runner / 'bin/wineserver')]
    try:
        subprocess.run(command, env=env, check=True, timeout=120)
        if not (prefix / '.altium-linux-setup').exists():
            raise RuntimeError('Initial setup did not finish')
        expected = os.fsencode('WINEPREFIX=' + str(prefix))
        found = []
        for process in Path('/proc').iterdir():
            if not process.name.isdecimal():
                continue
            try:
                if process.joinpath('comm').read_text().strip() != 'wineserver':
                    continue
                if expected not in process.joinpath('environ').read_bytes().split(b'\0'):
                    continue
                found.append(process)
                for descriptor in process.joinpath('fd').iterdir():
                    if descriptor.resolve() == root / '.setup.lock':
                        raise RuntimeError('wineserver retained the setup lock')
            except (FileNotFoundError, PermissionError):
                continue
        if not found:
            raise RuntimeError('No surviving wineserver: test would not cover the regression')
        subprocess.run(command, env=env, check=True, timeout=10)
        print('PASS: repeated setup completed with the original wineserver alive')
    finally:
        subprocess.run(server + ['-k'], env=env, check=False)
        subprocess.run(server + ['-w'], env=env, check=True, timeout=20)
