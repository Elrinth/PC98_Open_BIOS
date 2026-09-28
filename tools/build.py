#!/usr/bin/env python3
"""Assemble the open PC-98 system BIOS and package a core-compatible boot.rom.

boot.rom layout expected by the Zet98 core (see docs/ROM_LAYOUT.md):

  0x00000  96 KiB  system BIOS, mapped at E8000h-FFFFFh
  0x18000  32 KiB  ITF bank, mapped at F8000h while ITF is enabled
  0x20000 128 KiB  zero
  0x40000 288,768  character generator (NP2 FONT.ROM layout)

NASM is used from PATH when present, otherwise from the project's
zet98-dos-tools Docker image.
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIOS_SIZE = 0x18000
ITF_SIZE = 0x8000
FONT_OFFSET = 0x40000
FONT_SIZE = 288768
BOOTROM_SIZE = FONT_OFFSET + FONT_SIZE
DOCKER_IMAGE = 'zet98-dos-tools'


def nasm(source, output, defines=(), listing=None):
    args = ['-f', 'bin', '-w+all', '-I', 'src/']
    args += [f'-D{d}' for d in defines]
    if listing:
        args += ['-l', listing.relative_to(ROOT).as_posix()]
    args += ['-o', output.relative_to(ROOT).as_posix(), source.relative_to(ROOT).as_posix()]
    local = shutil.which('nasm')
    if local:
        cmd = [local] + args
    else:
        env = dict(os.environ, MSYS_NO_PATHCONV='1')
        cmd = ['docker', 'run', '--rm', '-v', f'{ROOT}:/project', '-w', '/project',
               DOCKER_IMAGE, 'nasm'] + args
        subprocess.run(cmd, check=True, cwd=ROOT, env=env)
        return
    subprocess.run(cmd, check=True, cwd=ROOT)


def package(bios, font, itf=None):
    assert len(bios) == BIOS_SIZE, f'BIOS image is {len(bios):#x} bytes'
    if itf is None:
        itf = bios[BIOS_SIZE - ITF_SIZE:]
    assert len(itf) == ITF_SIZE
    assert len(font) == FONT_SIZE, f'font is {len(font)} bytes, expected {FONT_SIZE}'
    rom = bytearray(BOOTROM_SIZE)
    rom[0:BIOS_SIZE] = bios
    rom[BIOS_SIZE:BIOS_SIZE + ITF_SIZE] = itf
    rom[FONT_OFFSET:] = font
    return bytes(rom)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--font', type=Path, help='288,768-byte FONT.ROM-layout file; '
                   'default font/pc98font.rom (free font), else blank')
    p.add_argument('--font-from-bootrom', type=Path,
                   help='take the character generator from an existing boot.rom (local testing only)')
    p.add_argument('-D', dest='defines', action='append', default=[], help='extra NASM define')
    args = p.parse_args()

    build = ROOT / 'build'
    build.mkdir(exist_ok=True)
    bios_path = build / 'bios.bin'
    nasm(ROOT / 'src' / 'bios.asm', bios_path, args.defines, build / 'bios.lst')
    bios = bios_path.read_bytes()

    if args.font_from_bootrom:
        font = args.font_from_bootrom.read_bytes()[FONT_OFFSET:FONT_OFFSET + FONT_SIZE]
        note = f'font from {args.font_from_bootrom} (NOT redistributable)'
    elif args.font or (ROOT / 'font' / 'pc98font.rom').exists():
        font_path = args.font or ROOT / 'font' / 'pc98font.rom'
        font = font_path.read_bytes()
        note = f'font from {font_path}'
    else:
        font = bytes(FONT_SIZE)
        note = 'blank font (text will be invisible on hardware)'

    rom = package(bios, font)
    (build / 'boot.rom').write_bytes(rom)
    print(f'build/bios.bin  {len(bios)} bytes  sha256 {hashlib.sha256(bios).hexdigest()[:16]}')
    print(f'build/boot.rom  {len(rom)} bytes  sha256 {hashlib.sha256(rom).hexdigest()[:16]}  ({note})')


if __name__ == '__main__':
    sys.exit(main())
