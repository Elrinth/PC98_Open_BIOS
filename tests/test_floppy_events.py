"""Real media notification ABI and DOS IRQ-chain compatibility regressions."""
import struct
from pathlib import Path
from pc98 import PC98, ROOT

PORT=0x7ed0
class EventPC98(PC98):
    def __init__(self, supported=True):
        self.supported=supported; self.event_status=0xa0; self.event_writes=[]
        super().__init__(ROOT/'build/boot.rom')
    def io_read(self, port, size):
        if port==PORT and self.supported:return self.event_status
        return super().io_read(port,size)
    def io_write(self, port, value, size):
        if port==PORT and self.supported:
            self.event_writes.append(value)
            if value==0xa5:self.event_status=0xa8
            elif value&0xfc==0x80:self.event_status &= ~(value&3)
            return
        return super().io_write(port,value,size)

def machine(supported=True):
    m=EventPC98(supported);m.run(seconds=3,until=lambda m:'No bootable' in m.text_screen());return m

def main():
    m=machine()
    assert m.event_writes==[0xa5],m.event_writes
    assert m.word(0x55c)==3
    for ax in (0x83f0,0x8470,0x7a70,0x5671):
        m.u.mem_write(0x55c,b'\x03\x00'); before=len(m.fdc.log)
        result=m.call_int(0x1b,ax=ax)
        assert result['cf'] and result['ax']>>8==0x40
        assert m.fdc.interface==1 and m.word(0x55c)==3 and len(m.fdc.log)==before
    # Explicit software selection still enables the alternate interface.
    m.u.mem_write(0x55c,struct.pack('<H',0x0ab3))
    m.io_write(0xbe,0,1)
    result=m.call_int(0x1b,ax=0x83f0)
    assert not result['cf'] and m.fdc.interface==0 and m.word(0x55c)==0x3ab0
    result=m.call_int(0x1b,ax=0x0390)
    assert result['cf'] and result['ax']>>8==0x40 and m.fdc.interface==0
    print('PASS inactive interface probes have no hardware/equipment side effects')
    # DOS-style hook: chain BIOS first, then sample drive 1 ST0.
    for vector,flag,mask in ((0x13,0x55e,0x0f),(0x12,0x55f,0xf0)):
        for native in (0,4):
            m=machine();old=m.mem(vector*4,4)
            record=0x56c if vector==0x13 else 0x5da
            code=b'\x9c\x9a'+old+bytes.fromhex('501e31c08ed8a0')+struct.pack('<H',record)+bytes.fromhex('a200901f58cf')
            m.u.mem_write(0x8000,code);m.u.mem_write(vector*4,struct.pack('<HH',0x8000,0))
            m.u.mem_write(0x564,bytes(range(16)))
            m.u.mem_write(flag,b'\x00');m.event_status=0xa8|native|2
            commands=len(m.fdc.log)
            result=m.call_int(vector,ax=0x1234,bx=0x2345,cx=0x3456,dx=0x4567,ds=0x1000)
            assert m.byte(0x9000)==0xc9,'DOS hook saw stale status'
            assert m.mem(0x564,8)==bytes(range(8)),'unaffected drive changed'
            assert m.mem(0x56d,7)==bytes(range(9,16)),'data result bytes clobbered'
            assert m.byte(flag)==(mask if native else 0),'media IRQ faked command completion'
            assert m.event_status&3==0 and m.event_writes[-1]==0x82
            assert len(m.fdc.log)==commands,'IRQ handler issued an FDC command'
            for name,value in dict(ax=0x1234,bx=0x2345,cx=0x3456,dx=0x4567,ds=0x1000).items():
                assert result[name]==value,(name,result)
    print('PASS DOS hook sees media change; native completion and registers preserved')
    m=machine(False);m.u.mem_write(0x55e,b'\x00');m.call_int(0x13)
    assert m.byte(0x55e)==0x0f and not m.event_writes
    print('PASS old core retains legacy IRQ behavior')
    return 0
if __name__=='__main__':raise SystemExit(main())
