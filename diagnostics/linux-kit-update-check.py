#!/usr/bin/env python3
"""Exercise the Linux kit updater with an isolated prefix and release fixture."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap


KIT = Path(__file__).resolve().parents[1]
RELEASES = 'https://github.com/lazy-jubei/altium-wine/releases'


def write_script(path, content):
    path.write_text(textwrap.dedent(content).lstrip())
    path.chmod(0o755)


def verify_update(temporary):
    root = temporary / 'prefix root'
    kits = root / 'kits'
    for tag in ('v1.5.9', 'v1.5.10'):
        kit = kits / tag
        (kit / 'tools').mkdir(parents=True)
        shutil.copy2(KIT / 'altium-wine.sh', kit)
        for name in ('altium-wine-linux.sh', 'altium-prefix.sh'):
            shutil.copy2(KIT / 'tools' / name, kit / 'tools')
        write_script(kit / 'tools/exe-icon.py', '''
            import sys
            from pathlib import Path

            output = Path(sys.argv[2] + '.png')
            output.write_bytes(b'test logo')
            print(output)
        ''')
        (kit / '.release-sha256').write_text('a' * 64)
    current = kits / 'current'
    current.symlink_to('v1.5.9')

    prefix = root / 'prefix'
    prefix.mkdir()
    kernel = prefix / 'drive_c/windows/system32/kernel32.dll'
    kernel.parent.mkdir(parents=True)
    kernel.touch()
    (prefix / '.altium-linux-setup').touch()
    exe = prefix / 'drive_c/Program Files/Altium/AD26/X2.EXE'
    exe.parent.mkdir(parents=True)
    exe.write_text('keep this executable')
    project = prefix / 'project.txt'
    project.write_text('keep this project')
    config = root / 'config.local.sh'
    config.write_text('keep this configuration')

    data = temporary / 'data'
    desktop = data / 'applications/altium-wine-linux.desktop'
    desktop.parent.mkdir(parents=True)
    old_command = f'/bin/bash "{kits}/v1.5.9/altium-wine.sh" run %F'
    new_command = f'/bin/bash "{current}/altium-wine.sh" run %F'
    desktop_content = (
        '[Desktop Entry]\nType=Application\nName=My Designer\nIcon=my-custom-icon\n'
        f'Exec=/usr/bin/env "ALTIUM_WINE_ROOT={root}" '
        f'"ALTIUM_WINE_RENDERER=dxvk" {old_command}\n'
    )
    desktop.write_text(desktop_content)

    bootstrap = temporary / 'install.sh'
    write_script(bootstrap, '''
        #!/bin/bash
        exec bash "$TEST_NEW_KIT/tools/altium-wine-linux.sh" kit-install "$@"
    ''')
    sha = hashlib.sha256(bootstrap.read_bytes()).hexdigest()
    sums = temporary / 'SHA256SUMS'
    curl = temporary / 'curl'
    write_script(curl, '''
        #!/bin/bash
        set -eu
        url="${!#}"
        case "$url" in
            "$TEST_RELEASES/latest?check="*) printf '%s/tag/v1.5.10' "$TEST_RELEASES"; exit ;;
            "$TEST_RELEASES"/download/v1.5.10/*) ;;
            *) exit 1 ;;
        esac
        while [[ $1 != -o ]]; do shift; done
        cp -- "$TEST_DOWNLOADS/${url##*/}" "$2"
    ''')
    write_script(temporary / 'wine', '#!/bin/bash\nexit 1\n')
    env = dict(os.environ, PATH=f'{temporary}:{os.environ["PATH"]}',
               XDG_DATA_HOME=str(data), ALTIUM_WINE_BIN=str(temporary / 'wine'),
               TEST_RELEASES=RELEASES, TEST_DOWNLOADS=str(temporary),
               TEST_NEW_KIT=str(kits / 'v1.5.10'))
    env.pop('ALTIUM_WINE_ROOT', None)
    env.pop('ALTIUM_WINE_EXE', None)

    def run(*args, kit=current, check=True, env_overrides=None):
        return subprocess.run(['bash', str(kit / 'altium-wine.sh'), *args],
                              env=dict(env, **(env_overrides or {})),
                              capture_output=True, text=True, check=check, timeout=15)

    def without_startup_class(launcher, expected_class):
        entry = f'StartupWMClass={expected_class}\n'
        assert launcher.count('StartupWMClass=') == 1 and entry in launcher
        return launcher.replace(entry, '')

    result = run('update', '--check')
    assert 'Installed kit: v1.5.9' in result.stdout and 'Latest kit:    v1.5.10' in result.stdout
    assert current.readlink() == Path('v1.5.9') and desktop.read_text() == desktop_content

    sums.write_text(f'{"0" * 64}  install.sh\n')
    result = run('update', check=False)
    assert result.returncode and 'Checksum mismatch' in result.stderr
    assert current.readlink() == Path('v1.5.9')

    sums.write_text(f'{sha}  install.sh\n')
    run('update', '--no-launcher')
    assert current.readlink() == Path('v1.5.10') and desktop.read_text() == desktop_content
    run('update')
    current_launcher = desktop_content.replace(old_command, new_command)
    assert without_startup_class(desktop.read_text(), 'x2.exe') == current_launcher

    desktop.write_text(current_launcher)
    run('update')
    assert without_startup_class(desktop.read_text(), 'x2.exe') == current_launcher

    custom_launcher = desktop.read_text().replace('StartupWMClass=x2.exe\n',
                                                 'StartupWMClass=CustomDesigner\n')
    desktop.write_text(custom_launcher)
    run('update')
    assert desktop.read_text() == custom_launcher

    dxp = exe.with_name('DXP.EXE')
    dxp.touch()
    legacy_launcher = current_launcher.replace(
        '"ALTIUM_WINE_RENDERER=dxvk"', f'"ALTIUM_WINE_EXE={dxp}" "ALTIUM_WINE_RENDERER=dxvk"')
    desktop.write_text(legacy_launcher)
    run('update')
    assert without_startup_class(desktop.read_text(), 'dxp.exe') == legacy_launcher

    fresh_data = temporary / 'fresh-launcher'
    fresh = fresh_data / 'applications/altium-wine-linux.desktop'
    launcher_env = {'ALTIUM_WINE_ROOT': str(root), 'ALTIUM_WINE_RENDERER': 'dxvk',
                    'XDG_DATA_HOME': str(fresh_data)}
    run('launcher', env_overrides=launcher_env)
    assert 'StartupWMClass=x2.exe\n' in fresh.read_text()
    logo = root / 'altium-wine-launcher.png'
    assert f'Icon={logo}\n' in fresh.read_text() and logo.read_bytes() == b'test logo'
    assert f'"ALTIUM_WINE_RENDERER=dxvk" {new_command}' in fresh.read_text()

    run('launcher', env_overrides=dict(launcher_env, ALTIUM_WINE_EXE=str(dxp)))
    assert 'StartupWMClass=dxp.exe\n' in fresh.read_text()

    run('kit-install', '--root', str(root), kit=kits / 'v1.5.9')
    assert current.readlink() == Path('v1.5.10')
    assert project.read_text() == 'keep this project'
    assert config.read_text() == 'keep this configuration'
    assert not (prefix / 'system.reg').exists()

    current.unlink()
    current.write_text('unrelated existing file')
    result = run('kit-install', '--update', '--root', str(root), kit=kits / 'v1.5.10', check=False)
    assert result.returncode and 'occupied' in result.stderr
    assert current.read_text() == 'unrelated existing file'


with tempfile.TemporaryDirectory(prefix='aw-kit-update-') as temp:
    verify_update(Path(temp))
print('PASS: the Linux updater checks versions and digests, preserves the prefix, and migrates the launcher.')
