"""Floppy side of the PC-98 test machine: disk images, uPD765 and 8237.

The FDC model follows the uPD765A data sheet in the configuration the core
uses (two drives, DMA channel 2 on the 1 MB interface, channel 3 on the
640 KB interface). It is behavioural: commands complete immediately and the
interrupt is raised a little later.
"""
import struct
from pathlib import Path


# ---------------------------------------------------------------- images
class Sector:
    __slots__ = ('c', 'h', 'r', 'n', 'data', 'fm', 'deleted', 'status')

    def __init__(self, c, h, r, n, data, fm=False, deleted=False, status=0):
        self.c, self.h, self.r, self.n = c, h, r, n
        self.data = bytearray(data)
        self.fm, self.deleted, self.status = fm, deleted, status


class DiskImage:
    """tracks[(cyl, head)] -> list of Sector (in rotational order)."""

    def __init__(self, path):
        self.path = Path(path)
        self.tracks = {}
        self.write_protected = False
        self.media = '2HD'
        raw = self.path.read_bytes()
        ext = self.path.suffix.lower()
        if ext == '.d88' or ext == '.d98' or ext == '.88d':
            self._d88(raw)
        elif ext == '.fdi':
            self._fdi(raw)
        elif ext in ('.hdm', '.tfd', '.xdf', '.dup', '.2hd'):
            self._raw(raw, 1024, 8, 2, 77)
        else:
            raise ValueError(f'unsupported image {path}')

    def _d88(self, raw):
        self.write_protected = raw[0x1a] != 0
        self.media = {0x00: '2D', 0x10: '2DD', 0x20: '2HD'}.get(raw[0x1b], '2HD')
        offsets = struct.unpack_from('<164I', raw, 0x20)
        for index, off in enumerate(offsets):
            if not off or off >= len(raw):
                continue
            sectors = []
            count = struct.unpack_from('<H', raw, off + 4)[0]
            pos = off
            for _ in range(count):
                c, h, r, n = raw[pos:pos + 4]
                density, deleted, status = raw[pos + 6], raw[pos + 7], raw[pos + 8]
                size = struct.unpack_from('<H', raw, pos + 14)[0]
                sectors.append(Sector(c, h, r, n, raw[pos + 16:pos + 16 + size],
                                      fm=density == 0x40, deleted=deleted != 0, status=status))
                pos += 16 + size
            self.tracks[(index // 2, index % 2)] = sectors

    def _fdi(self, raw):
        _, fddtype, header, secsize, sectors, heads, cyls = struct.unpack_from('<7I', raw, 0)
        n = {128: 0, 256: 1, 512: 2, 1024: 3}[secsize]
        self.media = '2HD' if fddtype & 0xf0 == 0x90 else '2DD'
        self._raw(raw[header:], secsize, sectors, heads, cyls)

    def _raw(self, raw, secsize, spt, heads, cyls):
        n = {128: 0, 256: 1, 512: 2, 1024: 3}[secsize]
        pos = 0
        for c in range(cyls):
            for h in range(heads):
                self.tracks[(c, h)] = [Sector(c, h, r, n, raw[pos + (r - 1) * secsize:pos + r * secsize])
                                       for r in range(1, spt + 1)]
                pos += spt * secsize


# ---------------------------------------------------------------- 8237
class DMAChannel:
    def __init__(self):
        self.base_addr = self.addr = 0
        self.base_count = self.count = 0
        self.mode = 0
        self.masked = True
        self.flip = False
        self.bank = 0
        self.tc = False


class DMA:
    """PC-98 8237: channel n address at 01h+4n, count at 03h+4n; 11h command,
    13h request, 15h single mask, 17h mode, 19h clear flip-flop, 1Bh master
    clear, 1Dh clear mask, 1Fh all mask; bank registers 27h/21h/23h/25h."""
    BANK_PORT = {0x27: 0, 0x21: 1, 0x23: 2, 0x25: 3}

    def __init__(self, machine):
        self.m = machine
        self.ch = [DMAChannel() for _ in range(4)]
        self.command = 0
        self.log = []

    def handles(self, port):
        return (1 <= port <= 0x1f and port & 1) or port in self.BANK_PORT or port == 0x29

    def write(self, port, value):
        if port in self.BANK_PORT:
            self.ch[self.BANK_PORT[port]].bank = value & 0x0f
            return
        if port == 0x29:
            return
        reg = (port - 1) >> 1
        if reg < 8:
            c = self.ch[reg >> 1]
            is_count = reg & 1
            if self.command & 0x04:
                c.flip = False
            if is_count:
                if not c.flip:
                    c.base_count = (c.base_count & 0xff00) | value
                else:
                    c.base_count = (c.base_count & 0x00ff) | (value << 8)
                c.count = c.base_count
            else:
                if not c.flip:
                    c.base_addr = (c.base_addr & 0xff00) | value
                else:
                    c.base_addr = (c.base_addr & 0x00ff) | (value << 8)
                c.addr = c.base_addr
            c.tc = False
            if not self.command & 0x04:
                c.flip = not c.flip
            return
        if port == 0x11:
            self.command = value
            if value & 0x04:
                for c in self.ch:
                    c.flip = False
        elif port == 0x15:
            self.ch[value & 3].masked = bool(value & 4)
        elif port == 0x17:
            self.ch[value & 3].mode = value
        elif port == 0x19:
            for c in self.ch:
                c.flip = False
        elif port == 0x1b:
            for c in self.ch:
                c.masked = True
                c.flip = False
        elif port == 0x1d:
            for c in self.ch:
                c.masked = False
        elif port == 0x1f:
            for i, c in enumerate(self.ch):
                c.masked = bool(value & (1 << i))

    def read(self, port):
        if port == 0x11:
            v = 0
            for i, c in enumerate(self.ch):
                if c.tc:
                    v |= 1 << i
                    c.tc = False
            return v
        reg = (port - 1) >> 1
        if reg < 8:
            c = self.ch[reg >> 1]
            v = c.count if reg & 1 else c.addr
            r = (v >> 8) if c.flip else (v & 0xff)
            c.flip = not c.flip
            return r
        return 0xff

    def transfer(self, channel, data=None, length=0):
        """Device <-> memory. For writes-to-memory pass `data`; for reads
        from memory pass `length`. Returns (bytes transferred / data read,
        tc_reached)."""
        c = self.ch[channel]
        if c.masked:
            return (0 if data is not None else b''), False
        out = bytearray()
        n = len(data) if data is not None else length
        done = 0
        tc = False
        while done < n:
            phys = (c.bank << 16) | c.addr
            if data is not None:
                if (c.mode >> 2) & 3 == 1:              # write to memory
                    self.m.dma_write(phys, data[done])
            else:
                out.append(self.m.dma_read(phys))
            done += 1
            c.addr = (c.addr - 1 if c.mode & 0x20 else c.addr + 1) & 0xffff
            c.count = (c.count - 1) & 0xffff
            if c.count == 0xffff:
                tc = True
                c.tc = True
                if c.mode & 0x10:
                    c.addr, c.count = c.base_addr, c.base_count
                break
        self.log.append((channel, c.mode, done, tc))
        return (done if data is not None else bytes(out)), tc


# ---------------------------------------------------------------- uPD765
CMD_LEN = {0x02: 9, 0x03: 3, 0x04: 2, 0x05: 9, 0x06: 9, 0x07: 2, 0x08: 1, 0x09: 9,
           0x0a: 2, 0x0c: 9, 0x0d: 6, 0x0f: 3, 0x11: 9, 0x19: 9, 0x1d: 9}


class FDC:
    def __init__(self, machine, dma):
        self.m = machine
        self.dma = dma
        self.drives = [None, None, None, None]
        self.cyl = [127, 127, 127, 127]  # unknown until recalibrated
        self.sis = None                  # pending SENSE INTERRUPT status
        self.interface = 0            # BEh bit 0: 1 = 1 MB interface
        self.hd = False
        self.control = 0              # last write to 94h/CCh
        self.cmd = []
        self.result = []
        self.pending_irq = []          # (time, seek result tuples)
        self.int_status = []           # queued (ST0, PCN) for SENSE INTERRUPT
        self.irq_at = None
        self.log = []
        self.nd = False

    # ports: data 92h/CAh, status 90h/C8h, control 94h/CCh
    def active(self, port):
        if port in (0x90, 0x92, 0x94):
            return self.interface == 1
        if port in (0xc8, 0xca, 0xcc):
            return self.interface == 0
        return False

    def irq_line(self):
        return 11 if self.interface else 10

    def dma_channel(self):
        return 2 if self.interface else 3

    def ready(self, unit):
        # core: FRY (bit 6) = 1 passes the drive's ready; 0 forces ready
        if not self.control & 0x40:
            return unit < 3
        return unit < 2 and self.drives[unit] is not None and bool(self.control & 0x08)

    def density_ok(self, disk):
        # the core's drive plays the image at its own bit rate: a 2DD/2D disk
        # cannot be read with BEh bit 1 (2HD mode) set, nor a 2HD disk without it
        return (disk.media == '2HD') == self.hd

    def broken(self):
        # without DMA command bit 6 the core's FDC sees a permanent DACK
        return not self.dma.command & 0x40

    def status(self):
        if self.broken():
            return 0x00
        if self.result:
            return 0xd0                  # RQM | DIO | CB
        busy = 0x10 if self.cmd else 0
        return 0x80 | busy

    def write_data(self, value):
        if self.result or self.broken():
            return
        self.cmd.append(value)
        op = self.cmd[0] & 0x1f
        need = CMD_LEN.get(op, 1)
        if len(self.cmd) >= need:
            cmd, self.cmd = self.cmd, []
            self.log.append(bytes(cmd))
            self.execute(cmd)

    def read_data(self):
        if not self.result:
            return 0xff
        v = self.result.pop(0)
        return v

    def write_control(self, value):
        prev = self.control
        self.control = value
        # bit 7 only resets the core's FDC timing tick: no FDC reset

    def schedule_irq(self, delay=0.0005):
        self.irq_at = self.m.now + delay

    def poll(self, now):
        if self.irq_at is not None and now >= self.irq_at:
            self.irq_at = None
            self.m.raise_irq(self.irq_line())

    # -------------------------------------------------------- commands
    def execute(self, cmd):
        op = cmd[0] & 0x1f
        mt, mf, sk = cmd[0] & 0x80, cmd[0] & 0x40, cmd[0] & 0x20
        if op == 0x03:                                   # SPECIFY
            self.nd = bool(cmd[2] & 1)
            return
        if op == 0x04:                                   # SENSE DRIVE STATUS
            u = cmd[1] & 3
            st3 = u | (cmd[1] & 4)
            if self.drives[u]:
                st3 |= 0x20 if self.ready(u) else 0
                st3 |= 0x40 if self.drives[u].write_protected else 0
                st3 |= 0x08                              # two-sided
            if self.cyl[u] == 0:
                st3 |= 0x10
            self.result = [st3]
            return
        if op == 0x07:                                   # RECALIBRATE
            u = cmd[1] & 3
            if u < 2:
                self.cyl[u] = 0
                self.sis = (0x20 | u, 0)
            else:
                self.sis = (0x70 | u, 0)                 # EC
            self.schedule_irq(0.01)
            return
        if op == 0x0f:                                   # SEEK
            u = cmd[1] & 3
            if not self.ready(u):
                self.sis = (0xc8 | u, self.cyl[u])
            else:
                self.cyl[u] = cmd[2]
                self.sis = (0x20 | u, cmd[2])
            self.schedule_irq(0.005)
            return
        if op == 0x08:                                   # SENSE INTERRUPT
            if self.sis:
                self.result = list(self.sis)
                self.sis = None
            else:
                self.result = [0x80]
            return
        if op in (0x06, 0x0c, 0x02, 0x05, 0x09):
            self.read_write(cmd, op, mt, mf, sk)
            return
        if op == 0x0a:                                   # READ ID
            u, h = cmd[1] & 3, (cmd[1] >> 2) & 1
            st0 = u | (h << 2)
            d = self.drives[u]
            if not self.ready(u):
                self.finish([0x48 | st0, 0, 0, 0, 0, 0, 0])
                return
            track = d.tracks.get((self.cyl[u], h), []) if self.density_ok(d) else []
            match = [s for s in track if s.fm == (not mf)]
            if not match:
                self.finish([0x40 | st0, 0x01, 0, 0, 0, 0, 0])
                return
            # the disk turns at 360 rpm: return the next ID under the head
            turn = (self.m.now * 6.0) % 1.0
            s = match[int(turn * len(match)) % len(match)]
            self.finish([st0, 0, 0, s.c, s.h, s.r, s.n])
            return
        if op == 0x0d:                                   # FORMAT (not modelled)
            u = cmd[1] & 3
            self.finish([0x40 | u, 0x02, 0, 0, 0, 0, cmd[2]])
            return
        self.result = [0x80]                             # invalid

    def finish(self, result):
        self.result = result
        self.sis = (result[0], self.cyl[result[0] & 3])
        self.schedule_irq(0.0002)

    def read_write(self, cmd, op, mt, mf, sk):
        u, h = cmd[1] & 3, (cmd[1] >> 2) & 1
        c, hh, r, n, eot = cmd[2], cmd[3], cmd[4], cmd[5], cmd[6]
        st0 = u | (h << 2)
        d = self.drives[u]
        if not self.ready(u):
            self.finish([0x48 | st0, 0, 0, c, hh, r, n])
            return
        writing = op in (0x05, 0x09)
        if writing and d.write_protected:
            self.finish([0x40 | st0, 0x02, 0, c, hh, r, n])
            return
        chan = self.dma_channel()
        while True:
            track = d.tracks.get((self.cyl[u], h), []) if self.density_ok(d) else []
            sec = next((s for s in track if s.c == c and s.h == hh and s.r == r and s.n == n
                        and s.fm == (not mf)), None)
            if sec is None:
                st1 = 0x04 if track else 0x01              # ND / MA
                st2 = 0
                if track and any(s.r == r for s in track) and not any(s.c == c for s in track):
                    st2 = 0x10                              # WC
                self.finish([0x40 | st0, st1, st2, c, hh, r, n])
                return
            size = 128 << min(n, 7)
            if writing:
                data, tc = self.dma.transfer(chan, length=size)
                sec.data[:len(data)] = data
            else:
                done, tc = self.dma.transfer(chan, data=bytes(sec.data[:size]).ljust(size, b'\0'))
            if tc:
                r += 1
                if r > eot and mt and not h:
                    pass
                self.finish([st0, 0, 0, c, hh, r, n])
                return
            if r == eot:
                if mt and h == 0:
                    h, hh, r = 1, hh ^ 1, 1
                    st0 = u | 4
                    continue
                self.finish([0x40 | st0, 0x80, 0, c + 1, hh, 1, n])   # EN
                return
            r += 1
