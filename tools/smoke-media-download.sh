#!/usr/bin/env bash
# Range playback and authenticated ZIP downloads, including encoded names and isolation.
set -euo pipefail
export BIN="${BIN:-.build/debug/LocalShare}"
python3 - <<'PY'
import io, json, os, socket, subprocess, tempfile, time, urllib.error, urllib.parse, urllib.request, zipfile
from pathlib import Path
with tempfile.TemporaryDirectory(prefix='ls-media-test-') as temp:
    root = Path(temp) / 'share'
    root.mkdir()
    (root / 'folder').mkdir()
    (root / 'clip.mp4').write_bytes(b'0123456789')
    special = '中文 100% #?.txt'
    (root / special).write_text('selected')
    (root / 'private.txt').write_text('unselected')
    payload = bytes(range(256)) * 600
    (root / 'large.bin').write_bytes(payload)
    (root / 'empty.txt').write_bytes(b'')
    (Path(temp) / 'secret.txt').write_text('outside')
    (root / 'link.txt').symlink_to(Path(temp) / 'secret.txt')
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    env = dict(os.environ, LS_HEADLESS='1', LS_FOLDER=str(root), LS_TOKEN='mediatest', LS_PORT=str(port))
    server = subprocess.Popen([os.environ['BIN']], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    base = f'http://127.0.0.1:{port}'
    def request(path, data=None, headers=None):
        req = urllib.request.Request(base+path, data=data, headers=headers or {})
        try:
            with urllib.request.urlopen(req) as res: return res.status, res.headers, res.read()
        except urllib.error.HTTPError as res: return res.code, res.headers, res.read()
    def archive(paths, authenticated=True):
        body = urllib.parse.urlencode({'paths':json.dumps(paths)}).encode()
        return request('/ls/download'+('?t=mediatest' if authenticated else ''), body)
    try:
        for _ in range(100):
            try:
                if request('/?t=mediatest')[0] == 200: break
            except urllib.error.URLError: pass
            time.sleep(.1)
        else: raise AssertionError('server did not start')
        for value, expected, content_range in [('bytes=0-1',b'01','bytes 0-1/10'),('bytes=5-',b'56789','bytes 5-9/10'),('bytes=-3',b'789','bytes 7-9/10')]:
            status, headers, body = request('/clip.mp4?t=mediatest', headers={'Range':value})
            assert (status,body,headers['Content-Range'],headers['Content-Length']) == (206,expected,content_range,str(len(expected)))
        status, headers, body = request('/clip.mp4?t=mediatest', headers={'Range':'bytes=10-'})
        assert status == 416 and headers['Content-Range'] == 'bytes */10' and body == b''
        assert request('/clip.mp4', headers={'Range':'bytes=0-1'})[0] == 403
        paths = ['/clip.mp4','/'+urllib.parse.quote(special),'/large.bin','/empty.txt']
        status, headers, body = archive(paths)
        assert status == 200 and headers['Content-Type'] == 'application/zip'
        assert int(headers['Content-Length']) == len(body)
        with zipfile.ZipFile(io.BytesIO(body)) as z:
            assert set(z.namelist()) == {'clip.mp4', special, 'large.bin', 'empty.txt'}
            assert z.testzip() is None
            assert z.read('clip.mp4') == b'0123456789'
            assert z.read(special) == b'selected'
            assert z.read('large.bin') == payload
            assert z.read('empty.txt') == b''
        assert archive(paths, False)[0] == 403
        for bad in ['/../secret.txt','/%2e%2e/secret.txt','/..%2fsecret.txt','/link.txt','/folder','/missing.txt']:
            assert archive([bad])[0] == 400, bad
        assert archive([])[0] == 400
        assert archive(['/clip.mp4','/clip.mp4'])[0] == 400
        assert archive(['/clip.mp4','/missing.txt'])[0] == 400
        print('PASS: ranges, ZIP contents, authentication, encoded names, traversal, symlinks, directories and invalid selections')
    finally:
        server.terminate()
        server.wait(timeout=5)
PY
