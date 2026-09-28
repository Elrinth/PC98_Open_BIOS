"""Debug helper: run a PC98 machine with an instruction ring buffer."""
from collections import deque
from unicorn import UC_HOOK_CODE
from unicorn.x86_const import *


def attach_ring(m, size=60):
    ring = deque(maxlen=size)

    def code(u, addr, sz, _):
        ring.append((u.reg_read(UC_X86_REG_CS), u.reg_read(UC_X86_REG_EIP),
                     bytes(u.mem_read(addr, sz)).hex(), u.reg_read(UC_X86_REG_AX),
                     u.reg_read(UC_X86_REG_SP)))
    m.u.hook_add(UC_HOOK_CODE, code)
    return ring


def dump(ring):
    for cs, ip, b, ax, sp in ring:
        print(f'{cs:04x}:{ip:04x}  {b:<16} ax={ax:04x} sp={sp:04x}')


def crash_context(make, ring_size=60, margin=4000):
    """Run make() to its CPU error, then rerun and record the last
    instructions before it. Returns (machine, ring, error)."""
    m = make()
    try:
        m.run(seconds=600)
        return m, None, None
    except RuntimeError:
        n = m.instructions
    m = make()
    m.run(max_instructions=max(0, n - margin), seconds=600)
    ring = attach_ring(m, ring_size)
    err = None
    try:
        m.run(seconds=600)
    except RuntimeError as e:
        err = e
    return m, ring, err
