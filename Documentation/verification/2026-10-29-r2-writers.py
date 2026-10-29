#!/usr/bin/env python3
"""Alternate two public-API release probes; archives are verified by the probe."""
import json
import fcntl
import pathlib
import statistics
import subprocess
import sys

before, after, root, case, mode, threads, label, destination = sys.argv[1:]
lock = open(pathlib.Path(root).parent / 'r2-measure.lock', 'w')
fcntl.flock(lock, fcntl.LOCK_EX)
rows = []
for run in range(7):
    for variant, binary in ([('before', before), ('after', after)] if run % 2 == 0
                            else [('after', after), ('before', before)]):
        disk = subprocess.check_output(['df', '-k', '/System/Volumes/Data'], text=True)
        if int(disk.splitlines()[-1].split()[3]) < 25 * 1024**2:
            raise SystemExit('STOP: less than 25 GiB free')
        row = json.loads(subprocess.check_output([binary, root, case, mode, threads], text=True))
        row.update(candidate=label, variant=variant, run=run)
        with open(destination, 'a') as out:
            out.write(json.dumps(row, sort_keys=True) + '\n')
        rows.append(row)
for variant in ['before', 'after']:
    group = [r for r in rows if r['variant'] == variant]
    print(label, variant, {key: statistics.median(r[key] for r in group)
                          for key in ['wall_s', 'cpu_s', 'bytes']}, flush=True)
    assert len({r['sha256'] for r in group}) == 1, 'nondeterministic archive'
print('byte_identical', len({r['sha256'] for r in rows}) == 1, flush=True)
