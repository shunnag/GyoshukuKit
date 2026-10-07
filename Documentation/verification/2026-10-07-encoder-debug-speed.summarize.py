#!/usr/bin/env python3
"""XCTest と ENCODER_PHASE の log を集計する（工程の入れ子を二重計上しない）。"""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import re

CASE = re.compile(r"Test Case '-\[GyoshukuKitTests\.(\w+) (\w+)\]' (passed|failed|skipped) \(([0-9.]+) seconds\)")
START = re.compile(r"Test Case '-\[GyoshukuKitTests\.(\w+) (\w+)\]' started")
SUITE = re.compile(r"Test Suite '(\w+Tests)' (passed|failed) at")
COUNT = re.compile(r"Executed (\d+) tests?, (?:with (\d+) tests? skipped and |with )(\d+) failures?.* in ([0-9.]+)")


def parse(path):
    result = dict(path=str(path), cases={}, classes={}, phases={}, counts=None)
    current = None
    last_suite = None
    for line in path.read_text().splitlines():
        m = START.search(line)
        if m:
            current = '.'.join(m.groups())
            result['phases'][current] = []
        if line.startswith('ENCODER_PHASE\t') and current:
            parts = line.split('\t')
            result['phases'][current].append(dict(label=parts[1], seconds=float(parts[2]),
                                                   input=int(parts[3]), output=int(parts[4])))
        m = CASE.search(line)
        if m:
            cls, name, status, seconds = m.groups()
            result['cases'][cls + '.' + name] = dict(seconds=float(seconds), status=status)
            current = None
        m = SUITE.search(line)
        if m:
            last_suite = m[1]
        m = COUNT.search(line)
        if m:
            count, skipped, failures, seconds = m.groups()
            row = dict(count=int(count), skipped=int(skipped or 0), failures=int(failures), seconds=float(seconds))
            if last_suite:
                result['classes'][last_suite] = row
                last_suite = None
            else:
                result['counts'] = row
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, default=Path('.build/verification/encoder-debug-speed'))
    args = ap.parse_args()
    results = {}
    for group in ['paired', 'remaining', 'full-release', 'reference-release']:
        results[group] = {variant: [parse(p) for p in sorted((args.root / group).glob(variant + '-*.log'))]
                          for variant in ['baseline', 'new']}
    metrics = dict(runs=results, classes={}, cases={})
    for group in ['paired', 'remaining']:
        for variant, runs in results[group].items():
            for run in runs:
                for name, row in run['classes'].items():
                    dest = metrics['classes'].setdefault(name, {}).setdefault(variant, [])
                    dest.append(row)
                for name, row in run['cases'].items():
                    metrics['cases'].setdefault(name, {}).setdefault(variant, []).append(row)
    for scope in ['classes', 'cases']:
        for name, variants in metrics[scope].items():
            for variant, rows in variants.items():
                variants[variant] = dict(best_seconds=min(r['seconds'] for r in rows),
                                         samples=len(rows), failures=sum(r.get('failures', r.get('status') == 'failed') for r in rows), rows=rows)
    totals = {v: sum(c[v]['best_seconds'] for c in metrics['classes'].values() if v in c)
              for v in ['baseline', 'new']}
    metrics['totals'] = totals
    (args.root / 'metrics.json').write_text(json.dumps(metrics, indent=2) + '\n')
    lines = ['class\tbaseline_s\tnew_s\tbaseline_runs\tnew_runs']
    for name, c in sorted(metrics['classes'].items()):
        b, n = c.get('baseline', {}), c.get('new', {})
        lines.append(f"{name}\t{b.get('best_seconds', '')}\t{n.get('best_seconds', '')}\t{b.get('samples', 0)}\t{n.get('samples', 0)}")
    (args.root / 'class-times.tsv').write_text('\n'.join(lines) + '\n')
    lines = ['test\tbaseline_s\tnew_s\tbaseline_runs\tnew_runs']
    for name, c in sorted(metrics['cases'].items()):
        if name.endswith('FullSize'): continue
        b, n = c.get('baseline', {}), c.get('new', {})
        lines.append(f"{name}\t{b.get('best_seconds', '')}\t{n.get('best_seconds', '')}\t{b.get('samples', 0)}\t{n.get('samples', 0)}")
    (args.root / 'test-times.tsv').write_text('\n'.join(lines) + '\n')
    print(json.dumps(dict(totals=totals, classes=len(metrics['classes']), cases=len(metrics['cases'])), indent=2))


if __name__ == '__main__':
    main()
