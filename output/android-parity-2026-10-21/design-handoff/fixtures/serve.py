"""Serve synthetic design fixtures with Python standard library only."""
import argparse
import json
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

FIXTURES = Path(__file__).resolve().parent
SYNTHETIC_TOKEN = "synthetic_ui_token_123"

class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if path.startswith('/ui-') or path == '/config-vless.json':
            if self.headers.get('Authorization') != 'Bearer ' + SYNTHETIC_TOKEN:
                self.send_error(401, 'Synthetic fixture bearer token required')
                return
        if not path.endswith('.json') or '..' in path.split('/') or not (FIXTURES / path.lstrip('/')).is_file():
            self.send_error(404, 'Fixture not found')
            return
        if path.startswith('/subscription-'):
            payload = json.loads((FIXTURES / path.lstrip('/')).read_text(encoding='utf-8'))
            origin = 'http://localhost:%d/' % self.server.server_port
            payload = {key: value.replace('http://localhost:18081/', origin) if isinstance(value, str) else value for key, value in payload.items()}
            body = json.dumps(payload, ensure_ascii=False).encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

    def end_headers(self):
        self.send_header('X-Subscription-Format', 'vipin-v1')
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

    def log_message(self, format, *args):
        pass

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=18081)
    args = parser.parse_args()
    handler = partial(Handler, directory=str(FIXTURES))
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler)
    print('Synthetic fixture server: http://localhost:%d/subscription-normal.json' % args.port, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == '__main__':
    main()
