"""Locate artefacts from the Zet98-486 core checkout."""
from pathlib import Path

CORE = Path(__file__).resolve().parents[2] / 'Zet98_Improved_Core' / 'PC98_MiSTer'
ROMS = Path(__file__).resolve().parents[2] / 'zet98_roms_for_dev'


def disk_rom_bytes():
    """The disk extension ROM exactly as embedded in the RBF (D0000h)."""
    words = (CORE / 'rtl/storage/pc98_ide_bootrom.mem').read_text().split()
    return b''.join(int(w, 16).to_bytes(2, 'little') for w in words)
