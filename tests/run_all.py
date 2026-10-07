#!/usr/bin/env python3
"""Build the BIOS and run every test; exit non-zero on any failure."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TESTS = ['test_post.py', 'test_services.py', 'test_fdd_bios.py', 'test_floppy_events.py', 'test_floppy_boot.py', 'test_graphics.py', 'test_lio.py', 'test_dos_boot.py', 'test_basic.py']


def main():
    subprocess.run([sys.executable, 'tools/build.py'] + sys.argv[1:], cwd=ROOT, check=True)
    import sys as _s
    _s.path.insert(0, str(ROOT / 'tests'))
    from core_rom import disk_rom_bytes
    (ROOT / 'build/diskrom.bin').write_bytes(disk_rom_bytes())
    failed = []
    for t in TESTS:
        r = subprocess.run([sys.executable, f'tests/{t}'], cwd=ROOT, capture_output=True, text=True,
                           encoding='utf-8', errors='replace', env={**__import__('os').environ, 'PYTHONIOENCODING': 'utf-8'})
        status = 'PASS' if r.returncode == 0 else 'FAIL'
        print(f'{status} {t}')
        if r.returncode:
            failed.append(t)
            print(r.stdout[-2000:], r.stderr[-2000:])
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
