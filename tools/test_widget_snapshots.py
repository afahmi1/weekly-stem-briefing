#!/usr/bin/env python3
"""Exercise the compiled widget without opening a window or touching live data."""
import hashlib
import os
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'build/WeeklyStemBriefing.app/Contents/MacOS/WeeklyStemBriefing'


def run(*args, expected=0, size=''):
    env = os.environ.copy()
    env.pop('WIDGET_RENDER_SIZE', None)
    if size:
        env['WIDGET_RENDER_SIZE'] = size
    result = subprocess.run([APP, *args], env=env, capture_output=True, text=True, timeout=30)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout + result.stderr


def png(path, dims):
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n' and data[12:16] == b'IHDR', path
    assert struct.unpack('>II', data[16:24]) == dims, path
    return hashlib.sha256(data).digest()


def main():
    assert APP.is_file(), 'Build the worktree app first: bash build-app.sh'
    assert 'appearance-test: PASS' in run('--appearance-test')
    print('PASS persisted appearance, defaults, and invalid-value recovery')
    with tempfile.TemporaryDirectory() as directory:
        out = Path(directory)
        variants = {
            'light': ('--mode', 'light'),
            'dark': ('--mode', 'dark'),
            'classic': ('--theme', 'classic', '--mode', 'dark'),
            'classic-light': ('--theme', 'classic', '--mode', 'light'),
            'gold': ('--mode', 'dark', '--accent', 'gold'),
            'plum': ('--mode', 'dark', '--accent', 'plum'),
            'wing': ('--mode', 'dark', '--accent', 'wing'),
        }
        digests = set()
        for name, args in variants.items():
            path = out / f'{name}.png'
            run('--render-appearance', path, *args, size='420x420')
            digests.add(png(path, (840, 840)))
        assert len(digests) == len(variants), 'Appearance variants should produce distinct pixels'
        path = out / 'dark-again.png'
        run('--render-appearance', path, '--mode', 'dark', size='420x420')
        assert png(path, (840, 840)) == png(out / 'dark.png', (840, 840))
        print('PASS widget renders (light/dark, Classic pair, Gold, Plum, Wing) and repeatability')

        for mode in ('light', 'dark'):
            path = out / f'settings-{mode}.png'
            run('--render-settings', path, '--mode', mode)
            png(path, (712, 880))
        path = out / 'chat.png'
        run('--render', path, '--fixture', '--chat', size='420x420')
        png(path, (840, 840))
        print('PASS settings in both modes and chat')

        path = out / 'bad.png'
        for args, message in [(('--theme', 'typo'), 'unknown --theme'),
                              (('--mode', 'typo'), 'unknown --mode'),
                              (('--accent', 'typo'), 'unknown --accent'),
                              (('--mode',), 'requires a value')]:
            assert message in run('--render-appearance', path, *args, expected=2)
            assert not path.exists()
        assert 'requires a value' in run('--render-settings', expected=2)
        assert 'require' in run('--theme', 'thermocline', expected=2)
        assert 'could not write' in run('--render-settings', out / 'missing/x.png', expected=1)
        print('PASS error paths do not write output')


if __name__ == '__main__':
    main()
