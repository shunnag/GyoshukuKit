import pathlib, subprocess, tempfile
root = pathlib.Path.cwd()
corpus = pathlib.Path('/private/tmp/claude-501/-Users-nagash-Github-KaitoFinder/3d80b8d3-15ce-4c2d-bf52-2944c9d6e58c/scratchpad/corpus')
bench = root / '.build/p6g-layout/GyoshukuKit/Benchmarks/.build/out/Products/Debug/gyoshuku-bench'
verify = root / '.build/p6g-layout/VerifyBench/.build/out/Products/Debug/VerifyBench'
formats = {'zip': 'zip', 'tar': 'tar', 'tgz': 'tar.gz', 'tbz': 'tar.bz2', 'txz': 'tar.xz', '7z': '7z', 'lha': 'lha'}
sources = ['text256.txt', 'random256.bin', 'headers', 'small']
print('format\tcorpus\tprogress\tentry_order', flush=True)
with tempfile.TemporaryDirectory(prefix='p6g-bench-', dir=root / '.build') as work:
    for fmt, suffix in formats.items():
        for source in sources:
            for progress in [False, True]:
                paths = []
                for mode in ['recursive', 'items']:
                    output = pathlib.Path(work) / (mode + '.' + suffix)
                    command = [str(bench), fmt, str(output), str(corpus / source), '--mode', mode]
                    if progress: command.append('--progress')
                    subprocess.run(command, check=True, capture_output=True, text=True)
                    paths.append(str(output))
                result = subprocess.run([str(verify)] + paths, check=True, capture_output=True, text=True)
                print('\t'.join([fmt, source, str(progress).lower(), result.stdout.strip()]), flush=True)
                for path in paths: pathlib.Path(path).unlink()
