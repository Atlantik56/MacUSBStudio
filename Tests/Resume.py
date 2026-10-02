"""Integration test: pause real curl, retain prefix, resume exact Range, compare complete bytes.
Uses native app's exact curl argument factory via the --download-arguments diagnostic.
Only localhost and a temporary file are touched. No Apple downloads or disks.
"""
import http.server, threading, subprocess, tempfile, pathlib, time, json, sys
payload = bytes(range(256)) * 16384
ranges = []
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        value = self.headers.get('Range', 'bytes=0-')
        start = int(value.split('=')[1].split('-')[0]); ranges.append(start)
        self.send_response(206 if start else 200)
        self.send_header('Content-Length', len(payload)-start)
        if start: self.send_header('Content-Range', f'bytes {start}-{len(payload)-1}/{len(payload)}')
        self.end_headers()
        try:
            for i in range(start, len(payload), 8192):
                self.wfile.write(payload[i:i+8192]); self.wfile.flush(); time.sleep(.002)
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
with tempfile.TemporaryDirectory(prefix='mac-usb-resume-') as task_dir:
    path = str(pathlib.Path(task_dir)/'pkg')
    url = f'http://127.0.0.1:{server.server_port}/pkg'
    args = json.loads(subprocess.check_output([sys.argv[1],'--download-arguments',url,path]))
    # Fixture is local HTTP; retain every other production download argument.
    args[args.index('--proto')+1] = '=http'; args[args.index('--proto-redir')+1] = '=http'
    proc = subprocess.Popen(['/usr/bin/curl',*args],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    deadline = time.monotonic()+10
    while (not pathlib.Path(path).exists() or pathlib.Path(path).stat().st_size<131072) and time.monotonic()<deadline: time.sleep(.03)
    proc.terminate(); proc.wait(timeout=5)
    saved = pathlib.Path(path).read_bytes()
    assert 0 < len(saved) < len(payload) and saved == payload[:len(saved)]
    subprocess.run(['/usr/bin/curl',*args],check=True,timeout=20)
    assert pathlib.Path(path).read_bytes()==payload
    assert ranges[-1]==len(saved), (ranges,len(saved))
    print(f'PASS: pause saved {len(saved)} bytes; resume requested exact offset; full bytes match')
server.shutdown()
