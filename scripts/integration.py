#!/usr/bin/env python3
"""CLI integration with an independent struct-based image builder and reader.
All images are sparse, disposable files. No device is opened by this script.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile


def make_image(path, endian, width):
    cluster = 4096
    size = 2 * 1024**2 if width == 2 else 256 * 1024**2
    fat_size = (((size // cluster + 1) * width + 4095) // 4096) * 4096
    start = 4096 + fat_size
    with path.open('wb') as f:
        f.truncate(size)
        f.seek(0)
        f.write(struct.pack(endian + '4sIII', b'FATX' if endian == '<' else b'XTAF', 0x12345678, 8, 1))
        f.seek(4096)
        fmt = endian + ('H' if width == 2 else 'I')
        last = 0xFFFF if width == 2 else 0xFFFFFFFF
        f.write(struct.pack(fmt, last - 7))
        f.write(struct.pack(fmt, last))
        f.seek(start)
        f.write(b'\xff' * cluster)
    return start


def read_file(path, endian, width, start, name):
    with path.open('rb') as f:
        f.seek(start)
        directory = f.read(4096)
        for offset in range(0, 4096, 64):
            e = directory[offset:offset + 64]
            if e[0] in (0, 255):
                break
            if e[0] == 229:
                continue
            if e[2:2 + e[0]] == name.encode('ascii'):
                first, size = struct.unpack_from(endian + 'II', e, 44)
                remaining, current, result, seen = size, first, bytearray(), set()
                while remaining:
                    assert current not in seen
                    seen.add(current)
                    f.seek(start + (current - 1) * 4096)
                    n = min(remaining, 4096)
                    result.extend(f.read(n))
                    remaining -= n
                    f.seek(4096 + current * width)
                    current = struct.unpack(endian + ('H' if width == 2 else 'I'), f.read(width))[0]
                return bytes(result)
    raise AssertionError(f'{name} missing')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    args = parser.parse_args()
    binary = str(args.binary.resolve())
    steps = 0
    with tempfile.TemporaryDirectory(prefix='fatx-integration-') as temp:
        root = Path(temp)
        def run(*words, success=True):
            nonlocal steps
            steps += 1
            result = subprocess.run([binary, *map(str, words)], capture_output=True, timeout=30)
            assert (result.returncode == 0) == success, (words, result.returncode, result.stderr.decode(errors='replace'))
            assert result.returncode >= 0, f'crash on {words}'
            return result.stdout
        for endian in ('<', '>'):
            for width in (2, 4):
                image = root / f'{endian == ">"}-{width}.img'
                start = make_image(image, endian, width)
                assert json.loads(run('info', image))['fatEntryBytes'] == width
                run('check', image)
                data = bytes((i * 29) % 256 for i in range(150003))
                local = root / 'input.bin'
                local.write_bytes(data)
                def write(command, *words, **kwargs):
                    return run(command, image, *words, '--journal', root / f'j{steps}.undo', **kwargs)
                write('put', local, '/test.bin')
                assert read_file(image, endian, width, start, 'test.bin') == data
                extracted = root / f'out{steps}.bin'
                run('get', image, '/TEST.BIN', extracted)
                assert extracted.read_bytes() == data
                run('get', image, '/test.bin', extracted, success=False)
                assert run('cat', image, '/test.bin') == data
                # Ensure complete FATX file replacement works, including empty files.
                write('put', local, '/test.bin', success=False)
                local.write_bytes(b'changed')
                write('put', local, '/test.bin', '--replace')
                assert read_file(image, endian, width, start, 'test.bin') == b'changed'
                write('mkdir', '/folder')
                write('mv', '/test.bin', '/folder/moved.bin')
                assert run('cat', image, '/folder/moved.bin') == b'changed'
                write('rm', '/folder', success=False)
                write('mv', '/folder', '/folder/descendant', success=False)
                write('rm', '/folder/moved.bin')
                write('rm', '/folder')
                run('check', image)
                assert run('ls', image) == b''
                # Parser errors must return a controlled error and leave media unchanged.
                digest = hashlib.sha256(image.read_bytes()).digest()
                run('mkdir', image, '/no-journal', success=False)
                run('info', image, '--offset', '0', success=False)
                run('info', image, '--offset', str(2**64 - 1), '--length', '512', success=False)
                run('info', image, '--sector-size', str(2**64 - 1), success=False)
                run('info', image, '--unknown', 'x', success=False)
                assert hashlib.sha256(image.read_bytes()).digest() == digest
        # Invalid binary geometry must never crash, even with extreme integers.
        image = root / 'malformed.img'
        make_image(image, '<', 2)
        for value in [0, 3, 0x80000000, 0xFFFFFFFF]:
            with image.open('r+b') as f:
                f.seek(8)
                f.write(struct.pack('<I', value))
            run('info', image, success=False)
    print(f'PASS: {steps} CLI checks across FATX/XTAF and FAT16/FAT32; independent extraction matched.')


if __name__ == '__main__':
    main()
