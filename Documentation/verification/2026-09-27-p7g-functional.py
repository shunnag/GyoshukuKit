from pathlib import Path
import os, subprocess, sys
root=Path.cwd()/'.build/p7g-functional'
root.mkdir(exist_ok=True)
source=root/'input'
source.mkdir(exist_ok=True)
for i in range(120):
    parent=source/f'd{i//30}'
    parent.mkdir(exist_ok=True)
    path=parent/f'f{i}.txt'
    size=[0,1,4002,65536,1048577][i%5]
    path.write_bytes((b'Gyoshuku batch verification\n'*(size//27+1))[:size])
    os.utime(path,(1700000001,1700000001))
bench=Path.cwd()/'.build/p7g-layout/GyoshukuKit/Benchmarks/.build/release/gyoshuku-bench'
seven='/opt/homebrew/bin/7zz'
print('format\tmode\tprogress\tentries\tintegrity\torder_and_sizes')
for fmt in ['zip','tar','tgz','tbz','txz','7z','lha']:
    reference=None
    for mode in ['recursive','items','batch']:
        for progress in [False,True]:
            out=root/f'{fmt}-{mode}-{progress}'
            out.unlink(missing_ok=True)
            command=[str(bench),fmt,str(out),str(source),'--threads','8','--mode',mode]
            if progress: command.append('--progress')
            subprocess.run(command,check=True,stdout=subprocess.DEVNULL)
            subprocess.run([seven,'t','-bd','-bso0','-bsp0',str(out)],check=True,stdout=subprocess.DEVNULL)
            inspected=out
            if fmt in ['tgz','tbz','txz']:
                inspected=root/'inner.tar'
                inspected.write_bytes(subprocess.check_output([seven,'x','-so',str(out)]))
                subprocess.run([seven,'t','-bd','-bso0','-bsp0',str(inspected)],check=True,stdout=subprocess.DEVNULL)
            listing=subprocess.check_output([seven,'l','-slt',str(inspected)],text=True)
            rows=[]
            for block in listing.split('----------\n',1)[1].split('\n\n'):
                fields=dict(line.split(' = ',1) for line in block.splitlines() if ' = ' in line)
                if 'Path' in fields: rows.append((fields['Path'],fields.get('Size')))
            if reference is None: reference=rows
            assert rows==reference,(fmt,mode,progress,'entry order/sizes differ')
            print(f'{fmt}\t{mode}\t{progress}\t{len(rows)}\tpass\tpass',flush=True)
            out.unlink()
invalid=subprocess.run([str(bench),'zip',str(root/'invalid'),str(source),'--mode','bogus'],capture_output=True,text=True)
assert invalid.returncode==1 and not (root/'invalid').exists()
(root/'invalid-mode.log').write_text(invalid.stderr)
