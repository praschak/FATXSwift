#!/usr/bin/env python3
"""Byte-level verification on disposable sparse images; never opens a device."""
import json, struct, subprocess, sys, tempfile
from pathlib import Path
binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='fatx-format-') as temp:
    root = Path(temp)
    def run(*args, ok=True):
        p = subprocess.run([binary, *map(str, args)], capture_output=True, timeout=90)
        assert p.returncode >= 0 and (p.returncode == 0) == ok, (args, p.stderr.decode(errors='replace'))
        return p.stdout
    for profile in ['retail', 'lba48-f', 'lba48-fg']:
        disk = root / (profile + '.img')
        with disk.open('wb') as f:
            f.truncate(16 * 1024**3); f.write(b'ORIGINAL HEADER')
        plan = json.loads(run('format-plan', disk, '--profile', profile))
        expected = [('C',1,0x8ca80000,0x1f400000),('E',0,0xabe80000,0x1312d6000),('X',2,0x80000,0x2ee00000),('Y',3,0x2ee80000,0x2ee00000),('Z',4,0x5dc80000,0x2ee00000)]
        extra = disk.stat().st_size - 0x1dd156000
        if profile == 'lba48-f': expected += [('F',5,0x1dd156000,extra)]
        if profile == 'lba48-fg':
            half = extra // 2 // 4096 * 4096
            expected += [('F',5,0x1dd156000,half),('G',6,0x1dd156000+half,extra-half)]
        assert [(v['name'],v['tableIndex'],v['offset'],v['length']) for v in plan['volumes']] == expected
        planfile, journal = root/'plan.json', root/(profile+'.undo')
        planfile.write_text(json.dumps(plan))
        run('format',disk,'--plan',planfile,'--journal',journal,ok=False)
        assert not journal.exists()
        with disk.open('rb') as f: assert f.read(15) == b'ORIGINAL HEADER'
        run('format',disk,'--plan',planfile,'--journal',journal,'--confirm',disk)
        assert len(json.loads(run('scan',disk))) == len(expected)
        with disk.open('rb') as f:
            table = f.read(512)
            assert (table[:16] == b'****PARTINFO****') == (profile != 'retail')
            for name,index,offset,length in expected:
                cluster = 16384 if name in 'CEXYZ' else 65536
                width = 2 if length//cluster+1 < 0xfff0 else 4
                fat = ((length//cluster+1)*width+4095)//4096*4096
                if profile != 'retail': assert struct.unpack_from('<III',table,48+index*32+16) == (0x80000000,offset//512,length//512)
                f.seek(offset); magic,_,spc,first = struct.unpack('<4sIII',f.read(16))
                assert (magic,spc,first) == (b'FATX',cluster//512,1)
                f.seek(offset+4096); assert struct.unpack('<HH' if width==2 else '<II',f.read(width*2)) == ((0xfff8,0xffff) if width==2 else (0xfffffff8,0xffffffff))
                f.seek(offset+4096+fat); assert f.read(cluster) == b'\xff'*cluster
                report = json.loads(run('check',disk,'--partition','fatx-'+name.lower()))
                assert report['directories']==1 and report['files']==0 and report['usedClusters']==1
        payload = root/'data.bin'; payload.write_bytes(bytes(range(256))*901)
        for name in ['c']+(['f'] if profile != 'retail' else []):
            run('put',disk,payload,'/test.bin','--partition','fatx-'+name,'--journal',root/(profile+name+'.undo'))
            output = root/(profile+name+'.bin')
            run('get',disk,'/test.bin',output,'--partition','fatx-'+name)
            assert output.read_bytes() == payload.read_bytes()
        run('recover',disk,'--journal',journal,ok=False)
print('PASS: format layouts, byte structures, transfer round trips,')
