import http.server
import json
import os
import re
from pathlib import Path
import shutil
import socket
import subprocess
import threading
import time

root = Path(os.environ['TEMP']) / ('restream-refill-' + str(int(time.time())))
root.mkdir()
repo = Path(__file__).resolve().parents[3]
children = []
down = threading.Event()
progress = {}
events = []
began = time.monotonic()
def event(message, **fields):
    row = dict(t=round(time.monotonic()-began,2), message=message, **fields)
    events.append(row)
    print(json.dumps(row), flush=True)

def spawn(args, name, progress_output=False):
    log = (root/(name+'.log')).open('wb')
    proc = subprocess.Popen(args, stdout=subprocess.PIPE if progress_output else log, stderr=log,
                            creationflags=subprocess.CREATE_NO_WINDOW)
    children.append(proc)
    return proc

def until(condition, seconds):
    end = time.monotonic()+seconds
    while not condition():
        if time.monotonic() >= end:
            raise RuntimeError('Condition timed out')
        time.sleep(.25)

def logs():
    p = root/'publisher-media.log'
    return p.read_text(errors='replace') if p.exists() else ''

def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

server = None
try:
    event('Generating local HLS test source', artifacts=str(root))
    generate = subprocess.run([shutil.which('ffmpeg'), '-nostdin', '-hide_banner', '-v','error',
        '-f','lavfi','-i','testsrc2=size=320x180:rate=15', '-f','lavfi','-i','sine=frequency=440:sample_rate=48000',
        '-t','240','-c:v','libx264','-preset','ultrafast','-g','15','-sc_threshold','0',
        '-c:a','aac','-b:a','64k','-f','hls','-hls_time','1','-hls_list_size','0',
        '-hls_segment_filename',str(root/'seg%04d.ts'),str(root/'generated.m3u8')],
        capture_output=True,timeout=60,creationflags=subprocess.CREATE_NO_WINDOW)
    if generate.returncode:
        raise RuntimeError(generate.stderr.decode(errors='replace'))
    timeline = time.monotonic()
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            if down.is_set():
                self.send_response(503)
                self.end_headers()
                return
            if self.path == '/live.m3u8':
                count = min(239, max(1, int(time.monotonic()-timeline)))
                body = '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n'
                for i in range(count):
                    body += f'#EXTINF:1.000,\nseg{i:04d}.ts\n'
                data = body.encode()
                mime = 'application/vnd.apple.mpegurl'
            elif self.path.startswith('/seg') and self.path.endswith('.ts'):
                path = root/Path(self.path).name
                if not path.is_file():
                    self.send_error(404)
                    return
                data = path.read_bytes()
                mime = 'video/mp2t'
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type',mime)
            self.send_header('Content-Length',str(len(data)))
            self.end_headers()
            try: self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    rtsp_port = free_port()
    config = root/'mediamtx.yml'
    config.write_text(f'logLevel: info\nreadTimeout: 300s\nrtspAddress: 127.0.0.1:{rtsp_port}\nrtspTransports: [tcp]\nrtmp: false\nhls: false\nwebrtc: false\nsrt: false\nmoq: false\npaths:\n  all_others:\n')
    mtx = spawn([shutil.which('mediamtx'),str(config)],'mediamtx')
    slconfig = root/'streamlink.conf'
    slconfig.write_text('http-ignore-env\nhls-live-edge=1\nhls-start-offset=0\nringbuffer-size=16M\nstream-segment-attempts=100\nstream-segment-timeout=2\nhls-playlist-reload-time=1\nhls-playlist-reload-attempts=100\nstream-timeout=300\nhttp-timeout=2\nstream-segmented-queue-deadline=0\n')
    url = f'rtsp://127.0.0.1:{rtsp_port}/refill-test'
    publisher = spawn([shutil.which('pwsh'),'-NoProfile','-File',
        str(repo/'.chezmoitemplates/powershell/RestreamPublisher.ps1'),
        f'hls://http://127.0.0.1:{server.server_port}/live.m3u8','best',str(slconfig),'youtube',
        url,str(root/'publisher-media.log')], 'publisher')
    until(lambda: 'Publishing at 1x speed.' in logs(),60)
    event('Publisher started after default 30-second prefill')
    mpv = spawn([shutil.which('mpv'), '--no-config', '--vo=null', '--ao=null', '--cache=no',
        '--rtsp-transport=tcp', '--loop-playlist=force', '--term-status-msg=POS:${time-pos}', url], 'mpv')
    mpv_state = {'played':0.0, 'position':None}
    def observe_mpv():
        while mpv.poll() is None:
            positions = re.findall(r'POS:(\d+):(\d+):(\d+)', (root/'mpv.log').read_text(errors='replace'))
            if positions:
                hours, minutes, seconds = map(int, positions[-1])
                pos = hours*3600 + minutes*60 + seconds
                previous = mpv_state['position']
                if previous is not None and 0 < pos-previous < 2:
                    mpv_state['played'] += pos-previous
                mpv_state['position'] = pos
            time.sleep(.2)
    threading.Thread(target=observe_mpv,daemon=True).start()
    reader = spawn([shutil.which('ffmpeg'),'-nostdin','-hide_banner','-v','warning',
        '-rtsp_transport','tcp','-i',url,'-map','0:v:0','-map','0:a:0',
        '-stats_period','1','-progress','pipe:1','-f','null','-'], 'reader',True)
    def read_progress():
        for raw in iter(reader.stdout.readline,b''):
            line = raw.decode(errors='replace').strip()
            if '=' in line:
                key,value = line.split('=',1)
                progress[key] = value
                if key == 'progress':
                    with (root/'progress.jsonl').open('a') as f:
                        f.write(json.dumps(dict(t=time.monotonic()-began, **progress))+'\n')
    threading.Thread(target=read_progress,daemon=True).start()
    until(lambda: int(progress.get('frame',0)) >= 120 and mpv_state['played'] >= 5,20)
    down.set()
    event('Source outage started',frames=progress.get('frame'))
    until(lambda: 'Input stalled' in logs(),65)
    event('Controller detected starvation')
    time.sleep(3)
    down.clear()
    event('Source restored')
    until(lambda: 'Media returned; refilling' in logs(),30)
    refill_start = time.monotonic()
    event('Refill hold started')
    time.sleep(10)
    before = mpv_state['played']
    time.sleep(5)
    after = mpv_state['played']
    if after-before > 0.2:
        raise RuntimeError(f'Playback continued through refill: {before} -> {after}')
    until(lambda: 'Refill complete' in logs(),25)
    refill_seconds = time.monotonic()-refill_start
    event('Refill completed',seconds=round(refill_seconds,2))
    until(lambda: mpv_state['played'] >= after+8,30)
    if 'Restarting downloader' in logs():
        raise RuntimeError('Unexpected publisher restart')
    if mpv.poll() is not None:
        raise RuntimeError('MPV exited')
    event('PASS: MPV resumed after refill; no publisher restart',played_seconds=round(mpv_state['played'],2),
          raw_ffmpeg_reader_exited=reader.poll() is not None)
finally:
    for child in reversed(children):
        if child.poll() is None:
            subprocess.run(['taskkill','/PID',str(child.pid),'/T','/F'],capture_output=True,
                           creationflags=subprocess.CREATE_NO_WINDOW)
    if server:
        server.shutdown()
    (root/'events.json').write_text(json.dumps(events,indent=2))
    event('Test processes cleaned up',artifacts=str(root))
