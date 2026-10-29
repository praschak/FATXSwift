#!/usr/bin/env python3
"""Exercise the browser's actual JSON subprocess transport against disposable images."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import argparse

spec = importlib.util.spec_from_file_location('fixture', Path(__file__).with_name('integration.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bridge', type=Path)
    args = parser.parse_args()
    bridge = str(args.bridge.resolve())
    checks = 0
    with tempfile.TemporaryDirectory(prefix='fatx-browser-') as temp:
        root = Path(temp)
        image = root / 'volume.img'
        fixture.make_image(image, '<', 2)
        def send(command, expect=True, **extra):
            nonlocal checks
            checks += 1
            exchange = root / f'exchange-{checks}'
            exchange.mkdir(mode=0o700)
            request = dict(command=command, source=str(image), offset=0, sectorSize=512, directory='/', paths=[], localPaths=[], destination='', replace=False, unmount=False, ownerUID=os.getuid(), ownerGID=os.getgid())
            request.update(extra)
            (exchange / 'request.json').write_text(json.dumps(request))
            response = exchange / 'response.json'
            response.touch(mode=0o600)
            result = subprocess.run([bridge, str(exchange / 'request.json'), str(response)], capture_output=True, timeout=30)
            assert result.returncode == 0, result.stderr.decode()
            reply = json.loads(response.read_bytes())
            assert reply['success'] == expect, reply
            return reply
        assert send('probe')['candidates']
        send('browse')
        local = root / 'My Game'
        (local / 'Saves').mkdir(parents=True)
        (local / 'default.xbe').write_bytes(b'payload\0' * 10003)
        (local / 'Saves' / 'save.bin').write_bytes(b'game save')
        p = send('importPreview', localPaths=[str(local)])
        assert p['importPreview']['files'] == 2
        send('importItems', localPaths=[str(local)], journal=str(root / 'import.undo'))
        assert send('browse', directory='/My Game')['items']
        assert send('preview', paths=['/My Game/Saves/save.bin'])['preview'] == 'game save'
        send('importItems', expect=False, localPaths=[str(local)], journal=str(root / 'conflict.undo'))
        send('move', paths=['/My Game'], destination='/Renamed', journal=str(root / 'move.undo'))
        destination = root / 'Exported Game'
        send('exportItems', paths=['/Renamed'], destination=str(destination))
        assert (destination / 'default.xbe').read_bytes() == (local / 'default.xbe').read_bytes()
        assert (destination / 'Saves/save.bin').read_bytes() == b'game save'
        send('exportItems', expect=False, paths=['/Renamed'], destination=str(destination))
        send('delete', paths=['/Renamed'], journal=str(root / 'delete.undo'))
        assert send('check')['check']['files'] == 0
        # Correctly formed JSON cannot turn a bad destination into silent success.
        send('mkdir', expect=False, destination='/bad+name', journal=str(root / 'bad.undo'))
        assert send('browse')['items'] == []
    print(f'PASS: {checks} browser bridge checks; recursive file bytes matched after JSON transport.')


if __name__ == '__main__':
    main()
