"""Loopback HTTPS fixture for real URLSession/XCUITest. Never calls any AI."""
import argparse
import hashlib
import io
import json
import ssl
import threading
import wave
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs, unquote

LOCK = threading.Lock()
STATE = {'offline': False, 'jobs': {}, 'uploads': [], 'events': []}
TRANSCRIPT = '今日は図書館で金融資本について勉強しました。教科書の資料を次回までに用意します。'


class TLSHTTPServer(ThreadingHTTPServer):
    def finish_request(self, request, address):
        # TLS negotiation must happen in the request thread. NSURLSession can
        # preconnect without completing a handshake; it must not block accept().
        request.settimeout(10)
        try:
            with self.ssl_context.wrap_socket(request, server_side=True) as secure:
                self.RequestHandlerClass(secure, address, self)
        except (TimeoutError, ConnectionError, ssl.SSLError):
            pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def reply(self, value, status=200, raw=False):
        data = value.encode('utf-8') if raw else json.dumps(value, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'text/plain; charset=utf-8' if raw else 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = unquote(urlsplit(self.path).path)
        if path == '/__state':
            with LOCK: self.reply(STATE)
            return
        if STATE['offline']:
            self.reply({'detail': 'Test connection unavailable'}, 503)
            return
        if path.endswith('/api/jobs'):
            self.reply({'jobs': list(STATE['jobs'].values())})
            return
        job_id = path.split('/jobs/')[-1].split('/')[0]
        job = next((v for v in STATE['jobs'].values() if v['id'] == job_id), None)
        if not job:
            self.reply({'detail': 'Unknown job'}, 404)
            return
        if path.endswith('/transcript'):
            self.reply({'status': 'completed', 'progress': '完了', 'error': '', 'text': TRANSCRIPT, 'empty': False, 'message': ''})
        elif path.endswith('/files'):
            files = [{'name': '音声/原文.md', 'kind': 'original'}]
            for kind in job.get('generated', []):
                name = {'polish': '丁寧化/丁寧版.md', 'brief': '要約/3行要約.md', 'detailed': '要約/詳しい要約.md'}[kind]
                files.append({'name': name, 'kind': 'polished' if kind == 'polish' else 'summary'})
            self.reply({'files': files})
        elif '/download/' in path:
            if '丁寧化/' in path: text = '読みやすく整えた本文です。' + TRANSCRIPT
            elif '3行' in path: text = '- 図書館で勉強した。\n- 金融資本を学んだ。\n- 次回までに資料を用意する。'
            else: text = '# 詳しい要約\n## 内容\n図書館で金融資本について学習しました。\n## 次の行動\n教科書の資料を用意します。'
            self.reply(text, raw=True)
        elif path.endswith('/summary'): self.reply({'summary': []})
        elif path.endswith('/polish'): self.reply({'polish': []})
        else: self.reply({'detail': 'Unknown route'}, 404)

    def do_POST(self):
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query)
        length = int(self.headers.get('Content-Length', '0'))
        if length > 16 * 1024 * 1024:
            self.reply({'detail': 'Fixture body too large'}, 413)
            return
        data = self.rfile.read(length)
        if parsed.path == '/__control':
            control = json.loads(data or b'{}')
            with LOCK:
                if control.get('reset'): STATE.update(offline=False, jobs={}, uploads=[], events=[])
                if 'offline' in control: STATE['offline'] = bool(control['offline'])
            self.reply({'ok': True})
            return
        if STATE['offline']:
            self.reply({'detail': 'Test connection unavailable'}, 503)
            return
        backend_key = 'stt_backend' if parsed.path.endswith('/uploads') else 'backend'
        if query.get(backend_key) != ['local']:
            self.reply({'detail': 'Only local engine is allowed in tests'}, 400)
            return
        with LOCK:
            STATE['events'].append({'path': parsed.path, 'backend': 'local'})
            if parsed.path.endswith('/uploads'):
                message = BytesParser(policy=default).parsebytes(('Content-Type: '+self.headers['Content-Type']+'\r\nMIME-Version: 1.0\r\n\r\n').encode()+data)
                part = next(p for p in message.iter_parts() if p.get_filename())
                content = part.get_payload(decode=True)
                with wave.open(io.BytesIO(content)) as audio:
                    assert audio.getframerate() == 16000 and audio.getnchannels() == 1 and audio.getsampwidth() == 2
                    seconds = audio.getnframes() / audio.getframerate()
                identity = part.get_filename() + hashlib.sha256(content).hexdigest()
                if identity not in STATE['jobs']:
                    STATE['jobs'][identity] = {'id': 'ui-job-'+str(len(STATE['jobs'])+1), 'original_name': query.get('display_name', ['録音'])[0], 'status': 'completed', 'progress': '完了', 'generated': []}
                STATE['uploads'].append({'filename': part.get_filename(), 'seconds': seconds, 'identity': identity})
                self.reply({'jobs': [STATE['jobs'][identity]]})
            else:
                job_id = parsed.path.split('/jobs/')[-1].split('/')[0]
                job = next(v for v in STATE['jobs'].values() if v['id'] == job_id)
                kind = 'polish' if parsed.path.endswith('/polish') else query.get('mode', ['brief'])[0]
                if kind not in job['generated']: job['generated'].append(kind)
                self.reply({'ok': True})


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--cert', required=True)
    parser.add_argument('--key', required=True)
    args = parser.parse_args()
    server = TLSHTTPServer(('127.0.0.1', 18865), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    server.ssl_context = context
    print('Local-only HTTPS fixture ready', flush=True)
    server.serve_forever()
