#!/usr/bin/env python3
"""A small PC-98 machine model on Unicorn for exercising the open BIOS.

It is deliberately behavioural, not cycle accurate: enough 8259/8253/8251/
uPD7220/ATA/uPD4990 behaviour for POST, the BIOS services and a DOS boot.
Time advances with executed instructions (IPS instructions per second).
"""
import struct
import time as _time
from pathlib import Path
import capstone
from unicorn import (Uc, UcError, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INSN, UC_HOOK_INTR, UC_HOOK_BLOCK,
                     UC_PROT_READ, UC_PROT_EXEC, UC_PROT_ALL, UC_HOOK_MEM_UNMAPPED)
from unicorn.x86_const import *
from fdd import DMA, FDC, DiskImage
import gdc_draw

ROOT = Path(__file__).resolve().parent.parent
IPS = 10_000_000           # modelled instructions per second
CHUNK = 2000               # instructions between interrupt checks
PIT_HZ = 2_457_600         # 5/10 MHz lineage; 1_996_800 for the 8 MHz lineage


class PIC:
    """8259A in the PC-98 configuration (edge triggered, cascade on IR7)."""

    def __init__(self, name):
        self.name = name
        self.irr = self.isr = 0
        self.imr = 0xff
        self.base = 0
        self.icw = 0            # remaining ICW bytes: 2,3,4
        self.icw4 = False
        self.single = False
        self.read_isr = False
        self.auto_eoi = False
        self.special_mask = False

    def write(self, a0, value):
        if a0 == 0:
            if value & 0x10:                       # ICW1
                self.icw4 = bool(value & 1)
                self.single = bool(value & 2)
                self.imr = self.isr = self.irr = 0
                self.icw = 2
                self.read_isr = False
            elif value & 0x08:                     # OCW3
                if value & 2:
                    self.read_isr = bool(value & 1)
                if value & 0x40:
                    self.special_mask = bool(value & 0x20)
            else:                                  # OCW2
                cmd = value >> 5
                if cmd == 1:                       # non-specific EOI
                    for i in range(8):
                        if self.isr & (1 << i):
                            self.isr &= ~(1 << i)
                            break
                elif cmd == 3:                     # specific EOI
                    self.isr &= ~(1 << (value & 7))
        else:
            if self.icw == 2:
                self.base = value & 0xf8
                self.icw = 3 if not self.single else (4 if self.icw4 else 0)
            elif self.icw == 3:
                self.icw = 4 if self.icw4 else 0
            elif self.icw == 4:
                self.auto_eoi = bool(value & 2)
                self.icw = 0
            else:
                self.imr = value

    def read(self, a0):
        if a0:
            return self.imr
        # the core's 8259 shows IRR only for unmasked lines
        return self.isr if self.read_isr else self.irr & ~self.imr & 0xff

    def pending(self):
        """Highest-priority requested, unmasked, not-in-service IR or None."""
        req = self.irr & ~self.imr & 0xff
        for i in range(8):
            if self.isr & (1 << i) and not self.special_mask:
                return None
            if req & (1 << i):
                return i
        return None


class PITChannel:
    def __init__(self):
        self.mode = 3
        self.rw = 3
        self.bcd = False
        self.reload = 0x10000
        self.count = 0x10000
        self.latched = None
        self.write_lsb = None
        self.read_msb = False
        self.running = False
        self.out = False
        self.phase = 0.0

    def period(self):
        return self.reload if self.reload else 0x10000


class PIT:
    def __init__(self, machine):
        self.m = machine
        self.ch = [PITChannel() for _ in range(3)]
        self.ticks = 0.0

    def advance(self, ticks):
        c = self.ch[0]
        if not c.running:
            return
        c.phase += ticks
        period = c.period()
        if c.mode in (2, 3):
            while c.phase >= period:
                c.phase -= period
                self.m.raise_irq(0)
        elif c.mode == 0:
            if c.phase >= c.count and not c.out:
                c.out = True
                self.m.raise_irq(0)

    def current(self, c):
        period = c.period()
        if c.mode in (2, 3):
            v = period - int(c.phase) % period
        elif c.mode == 0:
            v = max(0, c.count - int(c.phase))
        else:
            v = period
        if c.mode == 3:
            v = (v * 2) % 0x10000
        return v & 0xffff

    def write(self, index, value):
        if index == 3:
            sel = value >> 6
            if sel == 3:
                return
            c = self.ch[sel]
            rw = (value >> 4) & 3
            if rw == 0:
                c.latched = self.current(c)
                return
            c.rw, c.mode, c.bcd = rw, (value >> 1) & 7, bool(value & 1)
            if c.mode > 5:
                c.mode -= 4
            c.write_lsb = None
            c.read_msb = False
            c.running = False
            c.out = c.mode != 0
            return
        c = self.ch[index]
        if c.rw == 1:
            c.reload = value
        elif c.rw == 2:
            c.reload = value << 8
        elif c.write_lsb is None:
            c.write_lsb = value
            return
        else:
            c.reload = c.write_lsb | (value << 8)
            c.write_lsb = None
        c.count = c.reload if c.reload else 0x10000
        c.phase = 0.0
        c.running = True
        c.out = c.mode != 0

    def read(self, index):
        c = self.ch[index]
        v = c.latched if c.latched is not None else self.current(c)
        if c.rw == 1:
            c.latched = None
            return v & 0xff
        if c.rw == 2:
            c.latched = None
            return v >> 8
        if not c.read_msb:
            c.read_msb = True
            return v & 0xff
        c.read_msb = False
        c.latched = None
        return v >> 8


class GDC:
    """uPD7220 command capture: parameters are recorded, not rendered."""

    def __init__(self, name):
        self.name = name
        self.cmd = None
        self.params = []
        self.log = []
        self.started = False
        self.pram = bytearray(16)
        self.pram_index = 0
        self.csr = 0
        self.fifo = []
        self.vectw = bytearray(11)
        self.csrw = bytearray(3)
        self.wmode = 0
        self.on_draw = None

    def write(self, a1, value, now):
        if a1:
            self.flush()
            self.cmd = value
            self.params = []
            if value in (0x0d, 0x6b):
                self.started = True
            elif value in (0x0c, 0x05):
                self.started = False
            elif 0x70 <= value <= 0x7f:
                self.pram_index = value & 15
            elif value in (0x20, 0x21, 0x22, 0x23):
                self.wmode = value & 3
            elif value in (0x6c, 0x68) and self.on_draw:
                self.on_draw(self, value)
        else:
            self.params.append(value)
            if self.cmd is not None and 0x70 <= self.cmd <= 0x7f and self.pram_index < 16:
                self.pram[self.pram_index] = value
                self.pram_index += 1
            if self.cmd == 0x4c and len(self.params) <= 11:
                self.vectw[len(self.params) - 1] = value
            if self.cmd == 0x49 and len(self.params) <= 3:
                self.csrw[len(self.params) - 1] = value
                shift = 8 * (len(self.params) - 1)
                self.csr = (self.csr & ~(0xff << shift)) | (value << shift)

    def flush(self):
        if self.cmd is not None:
            self.log.append((self.cmd, bytes(self.params)))
        self.cmd = None

    def status(self, now):
        vsync = (now * 59.5) % 1.0 > 0.92        # core video: ~59.5 Hz
        hblank = (now * 24830) % 1.0 > 0.8
        return 0x04 | (0x20 if vsync else 0) | (0x40 if hblank else 0)


class UPD4990:
    """Calendar clock: port 20h (bits 0-2 command, 3 STB, 4 CLK, 5 DIN),
    serial data out on port 33h bit 0. Time = start + simulated seconds."""

    def __init__(self, machine, start=(2026, 9, 26, 12, 0, 0)):
        self.m = machine
        import datetime
        self.base = datetime.datetime(*start)
        self.last = 0
        self.cmd = 0
        self.shift = False
        self.reg = [0] * 48           # bit i shifts out i-th
        self.pos = 0
        self.offset = 0.0

    def _now(self):
        import datetime
        return self.base + datetime.timedelta(seconds=self.m.now + self.offset)

    def _load_time(self):
        t = self._now()
        bcd = lambda v: ((v // 10) << 4) | (v % 10)
        week = (t.weekday() + 1) % 7
        data = [bcd(t.second), bcd(t.minute), bcd(t.hour), bcd(t.day),
                (t.month << 4) | week, bcd(t.year % 100)]
        self.reg = [(data[i // 8] >> (i % 8)) & 1 for i in range(48)]
        self.pos = 0

    def write(self, value):
        changed = value ^ self.last
        self.last = value
        if value & 0x08 and changed & 0x08:          # strobe
            cmd = self.cmd
            if cmd == 0:
                self.shift = False
            elif cmd == 1:
                self.shift = True
                self.pos = 0
            elif cmd == 2:
                self.shift = False
                self._set_time()
            elif cmd == 3:
                self.shift = False
                self._load_time()
        elif value & 0x10:
            if changed & 0x10 and self.shift:          # clock: shift one bit
                self.reg.pop(0)
                self.reg.append((self.last >> 5) & 1)
        else:
            self.cmd = value & 7

    def _set_time(self):
        pass                                           # tests keep the model clock

    def data_bit(self):
        return self.reg[0] if self.reg else 0


class Keyboard:
    """8251 USART at 41h/43h fed by a key-code queue (IRQ1 per byte)."""

    def __init__(self, machine):
        self.m = machine
        self.queue = []
        self.data = 0
        self.ready = False
        self.next_time = 0.0

    def poll(self, now):
        if not self.ready and self.queue and now >= self.next_time:
            self.data = self.queue.pop(0)
            self.ready = True
            self.m.raise_irq(1)

    def read_data(self):
        self.ready = False
        self.next_time = self.m.now + 0.002
        return self.data

    def status(self):
        return 0x85 | (0x02 if self.ready else 0)


class ATA:
    """Raw ATA master at 640h-64Eh/74Ch, as used by the core's disk ROM."""

    def __init__(self, image=None):
        # Read-only image with an in-memory copy-on-write overlay: tests
        # never modify the user's disk images.
        self.f = open(image, 'rb') if image else None
        self.overlay = {}
        self.capacity = (Path(image).stat().st_size // 512) if image else 0
        self.regs = {}
        self.status = 0x50 if image else 0
        self.buffer = bytearray()
        self.pos = 0
        self.command = None
        self.lba = 0
        self.count = 0
        self.writes = []

    def _lba(self):
        r = self.regs
        return (r.get(0x646, 0) | r.get(0x648, 0) << 8 | r.get(0x64a, 0) << 16 |
                (r.get(0x64c, 0) & 15) << 24)

    def _load(self):
        if self.lba in self.overlay:
            self.buffer = bytearray(self.overlay[self.lba])
        else:
            self.f.seek(self.lba * 512)
            self.buffer = bytearray(self.f.read(512))
        self.pos = 0
        self.status = 0x58

    def write(self, port, value, size):
        if not self.f:
            return
        if port == 0x640:
            if self.command == 0x30:
                self.buffer[self.pos:self.pos + size] = value.to_bytes(size, 'little')
                self.pos += size
                if self.pos >= 512:
                    self.writes.append(self.lba)
                    self.overlay[self.lba] = bytes(self.buffer[:512])
                    self.lba += 1
                    self.count -= 1
                    self.pos = 0
                    self.status = 0x58 if self.count > 0 else 0x50
            return
        self.regs[port] = value
        if port == 0x64e:
            self.command = value
            self.lba = self._lba()
            self.count = self.regs.get(0x644, 1) or 256
            if value == 0xec:
                self.buffer = bytearray(512)
                struct.pack_into('<I', self.buffer, 120, self.capacity)
                self.pos = 0
                self.status = 0x58
            elif value in (0x20, 0x21):
                self._load()
            elif value in (0x30, 0x31):
                self.buffer = bytearray(512)
                self.pos = 0
                self.status = 0x58
            else:
                self.status = 0x50

    def read(self, port, size):
        if not self.f:
            return 0xff if port != 0x640 else 0xffff
        if port in (0x64e, 0x74c):
            return self.status
        if port == 0x640 and self.status & 0x08:
            v = int.from_bytes(self.buffer[self.pos:self.pos + size], 'little')
            self.pos += size
            if self.pos >= 512:
                self.count -= 1
                if self.count > 0 and self.command in (0x20, 0x21):
                    self.lba += 1
                    self._load()
                else:
                    self.status = 0x50
            return v
        return self.regs.get(port, 0)


class PC98:
    def __init__(self, bootrom, disk_rom=None, vhd=None, total_mb=64, pit_hz=PIT_HZ, has_31k=False):
        self.u = u = Uc(UC_ARCH_X86, UC_MODE_16)
        self.pit_hz = pit_hz
        rom = Path(bootrom).read_bytes()
        self.font = rom[0x40000:0x40000 + 288768]
        # Conventional RAM, text VRAM (A0000-A3FFF incl. memory switches),
        # CG window page (A4000-A4FFF), graphics VRAM A8000-BFFFF,
        # extension ROM D0000-D7FFF, reserved RAM D8000-DFFFF, E0000-E7FFF VRAM,
        # BIOS E8000-FFFFF (read only). Extended RAM from 1 MB, hole at 15 MB.
        u.mem_map(0, 0xa0000)
        u.mem_map(0xa0000, 0x4000)
        u.mmio_map(0xa4000, 0x1000, self._cg_read, None, self._cg_write, None)
        u.mem_map(0xa5000, 0x3000)
        u.mem_map(0xa8000, 0x18000)
        u.mem_map(0xc0000, 0x10000)
        u.mem_map(0xd0000, 0x8000, UC_PROT_READ | UC_PROT_EXEC)
        u.mem_map(0xd8000, 0x8000)
        u.mem_map(0xe0000, 0x8000)
        u.mem_map(0xe8000, 0x18000, UC_PROT_READ | UC_PROT_EXEC)
        # boot.rom is writable SDRAM on the core; the BIOS keeps its INT 1Bh
        # stack in this page (FD700h-FD7FFh).
        u.mem_protect(0xfd000, 0x1000, UC_PROT_ALL)
        u.mem_write(0xe8000, rom[:0x18000])
        if disk_rom:
            u.mem_write(0xd0000, Path(disk_rom).read_bytes()[:0x8000])
        else:
            u.mem_write(0xd0000, b'\xff' * 0x8000)
        # total_mb as in the core: 16 MB = 1-15 MB extended, 64 MB adds
        # 16-64 MB. The 15-16 MB aperture is modelled as open bus.
        if total_mb > 1:
            u.mem_map(0x100000, (min(total_mb, 15) - 1) * 0x100000)
        if total_mb > 16:
            u.mem_map(0x1000000, (total_mb - 16) * 0x100000)
        # Open bus (reads FFh, writes ignored) at the 15-16 MB aperture and
        # from the top of RAM to 128 MB, so memory probes terminate.
        ff = lambda *a: 0xffffffff
        nop = lambda *a: None
        u.mmio_map(0xf00000, 0x100000, ff, None, nop, None)
        top = max(total_mb, 16) * 0x100000
        u.mmio_map(top, 0x100000, ff, None, nop, None)
        # Unmapped high reads (A20 off wrap is handled by the CPU model).
        self.pic = [PIC('master'), PIC('slave')]
        self.pit = PIT(self)
        self.kbd = Keyboard(self)
        self.rtc = UPD4990(self)
        self.dma = DMA(self)
        self.fdc = FDC(self, self.dma)
        self.gdc = [GDC('text'), GDC('graphics')]
        self.gdc[1].on_draw = self._gdc_draw
        self.draw_log = []
        self.ata = ATA(vhd)
        self.ports_out = []
        self.unknown_ports = set()
        self.instructions = 0
        self.now = 0.0
        self.halted = False
        self.int_log = []
        self.trace_ints = False
        self.mode_ff1 = {}
        self.analog = False
        self.pal_index = 0
        self.digital_pal = [0x37, 0x15, 0x26, 0x04]   # A8h AAh ACh AEh
        self.analog_pal = [[0, 0, 0] for _ in range(16)]
        self.disp_page = 0
        self.draw_page = 0
        self.vram_banks = [None, None]                 # saved inactive bank
        self.grcg_mode = 0
        self.grcg_tile = [0, 0, 0, 0]
        self.grcg_seq = 0
        self.grcg_planes = None                        # bytearrays while MMIO
        self.pending_remap = False
        self.pending_reset = False
        self.cg_code = 0
        self.cg_line = 0
        self.a20 = False
        self.port_c = 0xff             # system 8255 port C (reset: FFh)
        self.has_31k = has_31k         # core with the 480-line extension
        self.port_9a8 = 0
        self.cpu_resets = 0
        self.beep = False
        self.port_31 = 0x80          # DIP switch 2 as the core reports it (GDC 2.5 MHz)
        self.port_33 = 0x08
        self.itf = True
        self.stopped = None
        self.pm_cs_base = None
        self.int_hook = None
        self.frame = 0
        u.hook_add(UC_HOOK_INSN, self._in, None, 1, 0, UC_X86_INS_IN)
        u.hook_add(UC_HOOK_INSN, self._out, None, 1, 0, UC_X86_INS_OUT)
        u.hook_add(UC_HOOK_INTR, self._intr)
        u.hook_add(UC_HOOK_MEM_UNMAPPED, self._unmapped)
        # Unicorn stops after HLT without telling why. HLT always ends a
        # translation block, so remember where the last block started and
        # decode forward from it to confirm a real HLT.
        self.last_block = None
        u.hook_add(UC_HOOK_BLOCK, self._block)
        self._cs16 = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_16)
        self.unmapped = []
        self.reset()

    # ---- CPU helpers
    def reg(self, name):
        return self.u.reg_read(getattr(unicorn_x86, 'UC_X86_REG_' + name.upper()))

    def regs(self, *names):
        return {n: self.reg(n) for n in names}

    def reset(self):
        u = self.u
        for r in (UC_X86_REG_DS, UC_X86_REG_ES, UC_X86_REG_SS, UC_X86_REG_FS, UC_X86_REG_GS):
            u.reg_write(r, 0)
        u.reg_write(UC_X86_REG_EFLAGS, 0x0002)
        u.reg_write(UC_X86_REG_CS, 0xf000)
        u.reg_write(UC_X86_REG_EIP, 0xfff0)
        self.halted = False

    def linear_pc(self):
        u = self.u
        cr0 = u.reg_read(UC_X86_REG_CR0)
        cs, ip = u.reg_read(UC_X86_REG_CS), u.reg_read(UC_X86_REG_EIP)
        if not cr0 & 1 or u.reg_read(UC_X86_REG_EFLAGS) & 0x20000:
            return (cs << 4) + (ip & 0xffff)
        if self.pm_cs_base is not None:
            return self.pm_cs_base + ip
        return self._desc_base(cs) + ip

    def _desc_base(self, sel):
        gdtr = self.u.reg_read(UC_X86_REG_GDTR)
        d = bytes(self.u.mem_read(gdtr[1] + (sel & ~7), 8))
        return d[2] | d[3] << 8 | d[4] << 16 | d[7] << 24

    def push16(self, value):
        u = self.u
        ss, sp = u.reg_read(UC_X86_REG_SS), (u.reg_read(UC_X86_REG_SP) - 2) & 0xffff
        u.mem_write((ss << 4) + sp, struct.pack('<H', value & 0xffff))
        u.reg_write(UC_X86_REG_SP, sp)

    def real_interrupt(self, vector):
        u = self.u
        flags = u.reg_read(UC_X86_REG_EFLAGS)
        self.push16(flags)
        self.push16(u.reg_read(UC_X86_REG_CS))
        self.push16(u.reg_read(UC_X86_REG_EIP))
        u.reg_write(UC_X86_REG_EFLAGS, flags & ~0x300)
        ip, cs = struct.unpack('<HH', u.mem_read(vector * 4, 4))
        u.reg_write(UC_X86_REG_CS, cs)
        u.reg_write(UC_X86_REG_EIP, ip)

    def _intr(self, u, vector, _):
        if u.reg_read(UC_X86_REG_CR0) & 1:
            raise RuntimeError(f'interrupt {vector:#x} in protected mode at {self.linear_pc():#x}')
        if self.trace_ints:
            self.int_log.append((vector, u.reg_read(UC_X86_REG_AX), self.linear_pc()))
        if self.int_hook:
            self.int_hook(self, vector)
        self.real_interrupt(vector)

    def _block(self, u, address, size, _):
        self.last_block = (address, size)

    def _stopped_on_hlt(self, pc):
        if self.last_block is None or bytes(self.u.mem_read(pc - 1, 1)) != b'\xf4':
            return False
        start, size = self.last_block
        if not start < pc <= start + size:
            return False
        code = bytes(self.u.mem_read(start, pc - start))
        end = None
        for insn in self._cs16.disasm(code, start):
            end = insn
        return end is not None and end.mnemonic == 'hlt' and end.address + end.size == pc

    def _unmapped(self, u, access, address, size, value, _):
        self.unmapped.append((access, address, size, self.linear_pc()))
        return False

    # ---- interrupts
    def raise_irq(self, line):
        if line < 8:
            self.pic[0].irr |= 1 << line
        else:
            self.pic[1].irr |= 1 << (line - 8)
            self.pic[0].irr |= 0x80

    def _pending_vector(self):
        m, s = self.pic
        ir = m.pending()
        if ir is None:
            return None
        if ir == 7:
            sir = s.pending()
            if sir is None:
                m.irr &= ~0x80
                return None
            s.irr &= ~(1 << sir)
            if not s.irr & ~s.imr:
                m.irr &= ~0x80
            s.isr |= 1 << sir
            m.isr |= 0x80
            return s.base + sir
        m.irr &= ~(1 << ir)
        if not m.auto_eoi:
            m.isr |= 1 << ir
        return m.base + ir

    # ---- I/O
    def _in(self, u, port, size, _):
        v = self.io_read(port, size)
        return v & (0xff if size == 1 else 0xffff if size == 2 else 0xffffffff)

    def _out(self, u, port, size, value, _):
        self.io_write(port, value, size)

    def mount(self, unit, path):
        self.fdc.drives[unit] = DiskImage(path) if path else None

    def dma_write(self, phys, value):
        self.u.mem_write(phys, bytes([value]))

    def dma_read(self, phys):
        return self.u.mem_read(phys, 1)[0]

    def io_read(self, port, size):
        if self.dma.handles(port):
            return self.dma.read(port)
        if self.fdc.active(port):
            if port in (0x90, 0xc8):
                return self.fdc.status()
            if port in (0x92, 0xca):
                return self.fdc.read_data()
            return 0x44
        if port == 0xbe:
            return 0x08 | (2 if self.fdc.hd else 0) | self.fdc.interface
        if port in (0x00, 0x02):
            return self.pic[0].read(port >> 1)
        if port in (0x08, 0x0a):
            return self.pic[1].read((port >> 1) & 1)
        if port in (0x71, 0x73, 0x75):
            return self.pit.read((port - 0x71) >> 1)
        if port == 0x41:
            return self.kbd.read_data()
        if port == 0x43:
            return self.kbd.status()
        if port == 0x60:
            return self.gdc[0].status(self.now)
        if port == 0xa0:
            return self.gdc[1].status(self.now)
        if port == 0x9a8:
            return self.port_9a8 if self.has_31k else 0xff
        if port in (0x5c, 0x5e):
            ticks = int(self.now / 3.26e-6)
            return (ticks if port == 0x5c else ticks >> 8) & 0xffff
        if port == 0x31:
            return self.port_31
        if port == 0x33:
            return (self.port_33 & ~1) | self.rtc.data_bit()
        if port == 0x35:
            return self.port_c
        if port == 0x42:
            return 0x94                 # core: 1 0 0 DIP1-3 DIP1-8 1 0 0
        if port == 0xa9:
            return self._cg_byte(self.cg_line & 0x3f)
        if port == 0xf2:
            return 0x00 if self.a20 else 0x01
        if port in (0x640, 0x642, 0x644, 0x646, 0x648, 0x64a, 0x64c, 0x64e, 0x74c):
            return self.ata.read(port, size)
        self.unknown_ports.add(('in', port))
        return 0xff

    def io_write(self, port, value, size):
        self.ports_out.append((port, value))
        if len(self.ports_out) > 4096:
            del self.ports_out[:2048]
        if self.dma.handles(port) and port != 0x20:
            self.dma.write(port, value & 0xff)
        elif self.fdc.active(port):
            if port in (0x92, 0xca):
                self.fdc.write_data(value & 0xff)
            elif port in (0x94, 0xcc):
                self.fdc.write_control(value & 0xff)
        elif port == 0xbe:
            self.fdc.interface = value & 1
            self.fdc.hd = bool(value & 2)
        elif port in (0x90, 0x92, 0x94, 0xc8, 0xca, 0xcc, 0x4be):
            pass
        elif port in (0x00, 0x02):
            self.pic[0].write(port >> 1, value & 0xff)
        elif port in (0x08, 0x0a):
            self.pic[1].write((port >> 1) & 1, value & 0xff)
        elif port in (0x71, 0x73, 0x75, 0x77):
            self.pit.write((port - 0x71) >> 1, value & 0xff)
        elif port in (0x41, 0x43):
            pass
        elif port in (0x60, 0x62):
            self.gdc[0].write(port == 0x62, value & 0xff, self.now)
        elif port in (0xa0, 0xa2):
            self.gdc[1].write(port == 0xa2, value & 0xff, self.now)
        elif port == 0x20:
            self.rtc.write(value & 0xff)
        elif port in (0xa8, 0xaa, 0xac, 0xae):
            v = value & 0xff
            if self.analog:
                if port == 0xa8:
                    self.pal_index = v & 15
                else:
                    self.analog_pal[self.pal_index][{0xaa: 1, 0xac: 0, 0xae: 2}[port]] = v & 15
            else:
                self.digital_pal[(port - 0xa8) >> 1] = v
        elif port == 0x6a:
            if (value & 0xfe) == 0:
                self.analog = bool(value & 1)
        elif port == 0x9a8:
            self.port_9a8 = value & 1
        elif port == 0x7c:
            self._grcg_mode(value & 0xff)
        elif port == 0x7e:
            enabled = [p for p in range(4) if not self.grcg_mode & (1 << p)] or [0]
            self.grcg_tile[enabled[self.grcg_seq % len(enabled)]] = value & 0xff
            self.grcg_seq += 1
        elif port == 0xa4:
            self.disp_page = value & 1
        elif port == 0xa6:
            self._select_draw_page(value & 1)
        elif port == 0x68:
            self.mode_ff1[(value >> 1) & 7] = value & 1
        elif port == 0x37:
            if value & 0x80 == 0:
                bit, state = (value >> 1) & 7, value & 1
                self.port_c = (self.port_c | (1 << bit)) if state else (self.port_c & ~(1 << bit))
                if bit == 3:
                    self.beep = not state
            else:
                self.port_c = 0            # core: a mode word clears port C
        elif port == 0xa1:
            self.cg_code = (self.cg_code & 0x00ff) | ((value & 0xff) << 8)
        elif port == 0xa3:
            self.cg_code = (self.cg_code & 0xff00) | (value & 0xff)
        elif port == 0xa5:
            self.cg_line = value & 0xff
        elif port == 0xf2:
            self.a20 = True
        elif port == 0xf6:
            self.a20 = (value & 0xff) == 2
        elif port == 0xf0:
            # core: CPU-only reset (PICs, PIT, 8255, RAM survive; A20 off)
            self.pending_reset = True
            self.u.emu_stop()
        elif port == 0x7ff0 or port == 0x5f:
            pass
        elif port in (0x640, 0x642, 0x644, 0x646, 0x648, 0x64a, 0x64c, 0x64e, 0x74c):
            self.ata.write(port, value, size)
        else:
            self.unknown_ports.add(('out', port))

    # ---- graphics GDC drawing into the current draw page
    def _gdc_draw(self, gdc, cmd):
        c = gdc.csrw
        csrw = c[0] | c[1] << 8 | (c[2] & 3) << 16
        dot = c[2] >> 4
        pattern = gdc.pram[8] | gdc.pram[9] << 8
        painter = gdc_draw.Painter(self._gdc_pixel, csrw, dot, pattern, gdc.wmode)
        self.draw_log.append((cmd, bytes(gdc.vectw), csrw, dot, gdc.wmode))
        if cmd == 0x6c:
            gdc_draw.draw_vect(painter, gdc.vectw)
        else:
            gdc_draw.draw_text(painter, gdc.vectw, bytes(gdc.pram[8:16]))

    def _gdc_pixel(self, plane, x, y, bit, mode):
        # plane: word address bits 15-14: 1 blue, 2 red, 3 green, 0 E
        index = (plane - 1) & 3
        off = y * 80 + (x >> 3)
        mask = 0x80 >> (x & 7)
        if self.grcg_planes:
            buf = self.grcg_planes[index]
            old = buf[off]
        else:
            addr = self.PLANE_BASES[index] + off
            old = self.u.mem_read(addr, 1)[0]
        if mode == 0:
            new = (old | mask) if bit else (old & ~mask)
        elif mode == 1:
            new = old ^ mask if bit else old
        elif mode == 2:
            new = old & ~mask if bit else old
        else:
            new = old | mask if bit else old
        new &= 0xff
        if self.grcg_planes:
            buf[off] = new
        else:
            self.u.mem_write(addr, bytes([new]))

    # ---- graphics VRAM banks and rendering
    VRAM_RANGES = ((0xa8000, 0x18000), (0xe0000, 0x8000))


    def _select_draw_page(self, page):
        self.want_page = page
        if page != self.draw_page:
            self.pending_remap = True
            self.u.emu_stop()

    def _apply_page(self, page):
        if page == self.draw_page:
            return
        mode = self.grcg_mode
        if self.grcg_planes is not None:
            self.grcg_mode = 0
            self._apply_remap()
        current = self._bank_bytes()
        other = self.vram_banks[page] or bytes(0x20000)
        self.vram_banks[self.draw_page] = current
        pos = 0
        for a, n in self.VRAM_RANGES:
            self.u.mem_write(a, other[pos:pos + n])
            pos += n
        self.draw_page = page
        self.grcg_mode = mode
        if mode & 0x80:
            self._apply_remap()

    # GRCG: while enabled, the planes are MMIO so that CPU accesses can be
    # turned into tile writes (TDW), read-modify-writes (RMW) or compares.
    PLANE_BASES = (0xa8000, 0xb0000, 0xb8000, 0xe0000)

    def _grcg_mode(self, value):
        self.grcg_mode = value
        self.grcg_seq = 0
        want = bool(value & 0x80)
        if want != (self.grcg_planes is not None):
            self.pending_remap = True
            self.u.emu_stop()

    def _apply_remap(self):
        self.pending_remap = False
        now = self.grcg_mode & 0x80
        was = self.grcg_planes is not None
        if now and not was:
            self.grcg_planes = [bytearray(self.mem(b, 0x8000)) for b in self.PLANE_BASES]
            for a, n in self.VRAM_RANGES:
                self.u.mem_unmap(a, n)
            for i, b in enumerate(self.PLANE_BASES):
                self.u.mmio_map(b, 0x8000, self._grcg_read, i, self._grcg_write, i)
        elif was and not now:
            planes = self.grcg_planes
            self.grcg_planes = None
            for b in self.PLANE_BASES:
                self.u.mem_unmap(b, 0x8000)
            for a, n in self.VRAM_RANGES:
                self.u.mem_map(a, n)
            for b, data in zip(self.PLANE_BASES, planes):
                self.u.mem_write(b, bytes(data))

    def _grcg_write(self, u, offset, size, value, plane):
        for k in range(size):
            off = (offset + k) & 0x7fff
            data = (value >> (8 * k)) & 0xff
            for p in range(4):
                if self.grcg_mode & (1 << p):
                    continue
                pl = self.grcg_planes[p]
                if self.grcg_mode & 0x40:
                    pl[off] = (pl[off] & ~data & 0xff) | (self.grcg_tile[p] & data)
                else:
                    pl[off] = self.grcg_tile[p]

    def _grcg_read(self, u, offset, size, plane):
        v = 0
        for k in range(size):
            off = (offset + k) & 0x7fff
            if self.grcg_mode & 0x40:
                b = self.grcg_planes[plane][off]
            else:
                b = 0xff
                for p in range(4):
                    if not self.grcg_mode & (1 << p):
                        b &= ~(self.grcg_planes[p][off] ^ self.grcg_tile[p]) & 0xff
            v |= b << (8 * k)
        return v

    def _bank_bytes(self):
        if self.grcg_planes:
            return b''.join(bytes(p) for p in self.grcg_planes)
        return b''.join(self.mem(a, n) for a, n in self.VRAM_RANGES)

    def planes(self, page=None):
        page = self.disp_page if page is None else page
        data = self._bank_bytes() if page == self.draw_page else (self.vram_banks[page] or bytes(0x20000))
        return [data[0:0x8000], data[0x8000:0x10000], data[0x10000:0x18000], data[0x18000:0x20000]]

    def screenshot(self, path, text=True):
        import numpy as np
        from PIL import Image
        b, r, g, e = (np.unpackbits(np.frombuffer(pl, dtype=np.uint8)[:32000]).reshape(400, 640)
                      for pl in self.planes())
        index = b | (r << 1) | (g << 2) | (e << 3)
        if self.analog:
            pal = np.array([[c[0] * 17, c[1] * 17, c[2] * 17] for c in self.analog_pal], dtype=np.uint8)
        else:
            order = {3: 0, 7: 0, 1: 1, 5: 1, 2: 2, 6: 2, 0: 3, 4: 3}
            pal = []
            for i in range(16):
                reg = self.digital_pal[order[i & 7]]
                v = (reg >> 4) & 7 if (i & 7) < 4 else reg & 7
                pal.append([(v >> 1 & 1) * 255, (v >> 2 & 1) * 255, (v & 1) * 255])
            pal = np.array(pal, dtype=np.uint8)
        img = pal[index] if self.gdc[1].started else np.zeros((400, 640, 3), np.uint8)
        if text and self.gdc[0].started:
            self._draw_text(img)
        Image.fromarray(img).resize((640, 400)).save(path)

    def _draw_text(self, img):
        vram = self.mem(0xa0000, 0x4000)
        pram = self.gdc[0].pram
        start = ((pram[0] | pram[1] << 8) & 0x1fff) * 2
        colours = [(0, 0, 0), (0, 0, 255), (255, 0, 0), (255, 0, 255),
                   (0, 255, 0), (0, 255, 255), (255, 255, 0), (255, 255, 255)]
        c = 0
        for row in range(25):
            col = 0
            while col < 80:
                off = (start + (row * 80 + col) * 2) & 0x1fff
                code, hi = vram[off], vram[off + 1]
                attr = vram[0x2000 + off]
                width = 1
                if hi and not hi & 0x80:
                    base = 0x1800 + 0xc00 * ((code & 0x7f) - 1) + ((hi & 0x7f) - 0x20) * 32
                    glyph = [self.font[base + i] if 0 <= base + i < len(self.font) else 0 for i in range(32)]
                    width = 2
                elif not hi:
                    glyph = list(self.font[0x800 + code * 16:0x800 + code * 16 + 16])
                else:
                    col += 1
                    continue
                if attr & 1 and code:
                    colour = colours[(attr >> 5) & 7]
                    for half in range(width):
                        for y in range(16):
                            bits = glyph[y + 16 * half] if width == 2 else glyph[y]
                            if attr & 4:
                                bits ^= 0xff
                            for x in range(8):
                                if bits & (0x80 >> x):
                                    py, px = row * 16 + y, (col + half) * 8 + x
                                    if py < 400 and px < 640:
                                        img[py, px] = colour
                col += width

    # ---- character generator (FONT.ROM layout)
    def _cg_byte(self, line):
        # A1h holds the second JIS byte, A3h the first byte minus 20h;
        # A5h bit 5 selects the left (1) or right (0) half.
        ten, ku = self.cg_code >> 8, self.cg_code & 0x7f
        right = not (line & 0x20)
        line &= 0x0f
        if ten == 0:                                 # ANK 8x16
            return self.font[0x800 + (self.cg_code & 0xff) * 16 + line]
        ten &= 0x7f
        if not (1 <= ku <= 0x5c) or not (0x20 <= ten < 0x80):
            return 0
        base = 0x1800 + 0xc00 * (ku - 1) + (ten - 0x20) * 32
        return self.font[base + line + (16 if right else 0)]

    def _cg_read(self, u, offset, size, _):
        line = (offset >> 1) & 0x0f
        return self._cg_byte(line | (0x20 if offset & 1 else 0))

    def _cg_write(self, u, offset, size, value, _):
        pass

    # ---- execution
    def step(self, instructions=CHUNK):
        u = self.u
        if self.halted:
            self.advance(instructions)
            vec = self._take_irq()
            if vec is None:
                return
            self.halted = False
        # Unicorn (16-bit mode) sets EIP = begin - CS*16 even in protected
        # mode, so resume with that encoding rather than the linear address.
        begin = (u.reg_read(UC_X86_REG_CS) << 4) + u.reg_read(UC_X86_REG_EIP)
        try:
            u.emu_start(begin, 0xffffffffffff, count=instructions)
        except UcError as e:
            raise RuntimeError(f'CPU error {e} at {self.linear_pc():#x} '
                               f'(CS:IP {self.reg_cs():04x}:{u.reg_read(UC_X86_REG_EIP):04x})')
        executed = instructions
        self.instructions += executed
        if self.pending_reset:
            self.pending_reset = False
            self.cpu_resets += 1
            self.a20 = False
            self.reset()
            return
        if self.pending_remap:
            page = getattr(self, 'want_page', self.draw_page)
            self._apply_page(page)
            if (self.grcg_mode & 0x80) != (self.grcg_planes is not None and 0x80 or 0):
                self._apply_remap()
            self.pending_remap = False
        self.advance(executed)
        pc = self.linear_pc()
        if self.stopped is None and self._stopped_on_hlt(pc):
            self.halted = True
        self._take_irq()

    def reg_cs(self):
        return self.u.reg_read(UC_X86_REG_CS)

    def _take_irq(self):
        if not self.u.reg_read(UC_X86_REG_EFLAGS) & 0x200:
            return None
        if self.u.reg_read(UC_X86_REG_CR0) & 1:
            return None
        vec = self._pending_vector()
        if vec is not None:
            self.halted = False
            self.real_interrupt(vec)
        return vec

    def advance(self, instructions):
        dt = instructions / IPS
        self.now += dt
        self.pit.advance(dt * self.pit_hz)
        self.kbd.poll(self.now)
        self.fdc.poll(self.now)
        frame = int(self.now * 59.5)                   # core video: ~59.5 Hz
        if frame != self.frame:
            self.frame = frame
            self.raise_irq(2)

    def run(self, seconds=None, until=None, max_instructions=200_000_000):
        """Run until `until(self)` is true or the time/instruction limit."""
        deadline = self.now + seconds if seconds else None
        start = self.instructions
        while True:
            if until and until(self):
                return True
            if deadline and self.now >= deadline:
                return False
            if self.instructions - start > max_instructions:
                return False
            if self.stopped:
                return False
            self.step()

    # ---- inspection
    def text_screen(self, rows=25, cols=80):
        """Text screen as displayed: starts at the text GDC's SAD0 and
        decodes JIS cells (left half: low = first byte - 20h, high = second)."""
        vram = bytes(self.u.mem_read(0xa0000, 0x2000))
        pram = self.gdc[0].pram
        start = ((pram[0] | pram[1] << 8) & 0x1fff) * 2
        lines = []
        for r in range(rows):
            chars = []
            c = 0
            while c < cols:
                off = (start + (r * 80 + c) * 2) & 0x1fff
                code, hi = vram[off], vram[off + 1]
                if hi and not hi & 0x80:
                    try:
                        chars.append(bytes([0x1b, 0x24, 0x42, code + 0x20, hi, 0x1b, 0x28, 0x42])
                                     .decode('iso2022_jp'))
                    except UnicodeDecodeError:
                        chars.append('?')
                    c += 2
                    continue
                chars.append(chr(code) if 0x20 <= code < 0x7f else ' ')
                c += 1
            lines.append(''.join(chars).rstrip())
        while lines and not lines[-1]:
            lines.pop()
        return chr(10).join(lines)

    def mem(self, address, size):
        return bytes(self.u.mem_read(address, size))

    def byte(self, address):
        return self.u.mem_read(address, 1)[0]

    def word(self, address):
        return struct.unpack('<H', self.u.mem_read(address, 2))[0]

    def call_int(self, vector, max_instructions=5_000_000, **regs):
        """Execute INT vector from a scratch stub at 0000:7000 with the given
        registers; returns the register file afterwards (CF in 'cf')."""
        u = self.u
        u.mem_write(0x7000, bytes([0xcd, vector, 0xeb, 0xfe]))   # INT n; JMP $
        u.ctl_remove_cache(0x7000, 0x7004)                        # stub changed
        defaults = dict(cs=0, eip=0x7000, ss=0, sp=0x6ff0, ds=0, es=0)
        defaults.update(regs)
        for name, value in defaults.items():
            u.reg_write(getattr(unicorn_x86, 'UC_X86_REG_' + name.upper()), value)
        u.reg_write(UC_X86_REG_EFLAGS, 0x202)
        self.halted = False
        self.stopped = None
        start = self.instructions
        while self.linear_pc() != 0x7002:
            if self.instructions - start > max_instructions:
                raise TimeoutError(f'INT {vector:02x}h did not return')
            self.step(500)
        self.halted = False
        out = self.regs('ax', 'bx', 'cx', 'dx', 'si', 'di', 'bp', 'es', 'ds')
        out['cf'] = bool(u.reg_read(UC_X86_REG_EFLAGS) & 1)
        return out

    def type_keys(self, codes):
        """Queue raw PC-98 key make/break codes."""
        self.kbd.queue.extend(codes)


import unicorn.x86_const as unicorn_x86  # noqa: E402  (used by PC98.reg)
