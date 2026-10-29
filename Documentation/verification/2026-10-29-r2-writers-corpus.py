#!/usr/bin/env python3
"""Deterministic small files, actual JPEG/PNG pages, renamed compressed files, Unicode names."""
import os
from pathlib import Path
import random
import struct
import subprocess
import sys
import zlib

root = Path(sys.argv[1])
disk = subprocess.check_output(['df', '-k', '/System/Volumes/Data'], text=True)
if int(disk.splitlines()[-1].split()[3]) < 25 * 1024**2:
    raise SystemExit('STOP: less than 25 GiB free')
rng = random.Random(20261029)
small = root / 'small'
small.mkdir()
for directory in range(20):
    folder = small / f'd{directory:02}'
    folder.mkdir()
    for index in range(1000):
        size = 1024 + (index * 37 + directory * 113) % 3073
        line = f'public struct Entry{directory}_{index} {{ let value: Int = {index} }}\n'.encode()
        (folder / f'file-{index:04}.txt').write_bytes((line * ((size + len(line) - 1) // len(line)))[:size])

def png(path, width, height, rgb=False):
    channels = 3 if rgb else 1
    raw = b''.join(b'\0' + rng.randbytes(width * channels) for _ in range(height))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    path.write_bytes(b'\x89PNG\r\n\x1a\n'
                     + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2 if rgb else 0, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))

png(root / 'rgb.png', 1400, 1400, True)
png(root / 'gray.png', 1300, 1300)
subprocess.run(['/usr/bin/sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '85',
                str(root / 'rgb.png'), '--out', str(root / 'page.jpg')], check=True)
(root / 'rgb.png').unlink()
media = root / 'media'
media.mkdir()
for index in range(160):
    extension = 'jpg' if index < 120 else 'png'
    rng = random.Random(20261029 + index)
    page = media / f'{index:03}.{extension}'
    if index < 120:
        source = root / 'page-input.ppm'
        source.write_bytes(b'P6\n1400 1400\n255\n' + rng.randbytes(1400 * 1400 * 3))
        subprocess.run(['/usr/bin/sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '85',
                        str(source), '--out', str(page)], check=True, stdout=subprocess.DEVNULL)
    else:
        png(page, 1300, 1300)
(root / 'page-input.ppm').unlink()
missing = root / 'missing'
missing.mkdir()
for index, extension in enumerate(['avif', 'jxl', 'heif', 'jp2', 'cbz', 'epub', 'zst', 'm4a', 'webm', 'docx']):
    os.link(root / 'page.jpg', missing / f'{index:03}.{extension}')
unicode = root / 'unicode'
unicode.mkdir()
for name in ['a1', 'A2', 'Z1', 'z2', 'が', 'か\u3099別', 'ガ', 'カ\u3099別', 'é', 'e\u0301別', '日本語', '😀']:
    (unicode / name).write_text(name)
lha = root / 'unicode-lha'
lha.mkdir()
for path in unicode.iterdir():
    if path.name not in ['é', 'e\u0301別', '😀']:
        (lha / path.name).write_bytes(path.read_bytes())
for path in [small, media, missing, unicode] + list(small.rglob('*')) + list(media.iterdir()) + list(unicode.iterdir()):
    path.chmod(0o755 if path.is_dir() else 0o644)
(root / 'gray.png').chmod(0o644)
(root / 'page.jpg').chmod(0o644)
print('media_bytes', sum(path.stat().st_size for path in media.iterdir()))
