#!/usr/bin/env python3
"""Serve a single managed VPN subscription from a local .env file."""

import argparse
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import shlex
from urllib.parse import urlsplit


def read_env(path):
    values = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        key, separator, value = line.partition('=')
        if not separator or not re.fullmatch(r'[A-Z][A-Z0-9_]*', key.strip()):
            raise ValueError('Invalid .env entry')
        parts = shlex.split(value, comments=True, posix=True)
        if len(parts) > 1:
            raise ValueError('Quote values containing spaces')
        values[key.strip()] = parts[0] if parts else ''
    return values


def subscription(values, config_url):
    ui_url = values.get('UI_DOCUMENT_URL', '').strip()
    ui_token = values.get('UI_DOCUMENT_TOKEN', '').strip() or None
    try:
        parsed = urlsplit(ui_url)
        if (parsed.scheme not in ('http', 'https') or not parsed.hostname
                or parsed.username is not None or parsed.password is not None
                or parsed.fragment or (parsed.port is not None and not 1 <= parsed.port <= 65535)
                or any(character.isspace() or ord(character) < 32 or character == '\\' for character in ui_url)):
            raise ValueError('Invalid UI URL')
    except ValueError:
        raise ValueError('Invalid UI settings') from None
    if ui_token is not None and not re.fullmatch(r'[A-Za-z0-9_-]{16,256}', ui_token):
        raise ValueError('Invalid UI settings')
    return {
        'sing_box_url': config_url if values.get('SING_BOX_CONFIG_PATH', '').strip() else None,
        'vk_turn_link': values.get('VK_TURN_LINK', '').strip() or None,
        'ui_url': ui_url,
        'ui_token': ui_token,
    }


def read_config(values, env_path):
    config_source = values.get('SING_BOX_CONFIG_PATH', '').strip()
    if config_source:
        config_path = Path(config_source).expanduser()
        if not config_path.is_absolute():
            config_path = env_path.parent / config_path

        def reject_constant(_):
            raise ValueError('Non-finite JSON number')

        config = json.loads(config_path.read_text(encoding='utf-8'), parse_constant=reject_constant)
        if not isinstance(config, dict):
            raise ValueError('Configuration must be a JSON object')
        return config
    raise ValueError('Configuration is disabled')


def create_server(env_path, host=None, port=None):
    env_path = Path(env_path).resolve()
    startup = read_env(env_path)
    token = startup.get('SUBSCRIPTION_TOKEN', '')
    if not re.fullmatch(r'[A-Za-z0-9_-]+', token):
        raise ValueError('SUBSCRIPTION_TOKEN must contain URL-safe characters')

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            try:
                values = read_env(env_path)
                token = values.get('SUBSCRIPTION_TOKEN', '')
                expected = '/subscription/' + token
                path = urlsplit(self.path).path
                if not re.fullmatch(r'[A-Za-z0-9_-]+', token):
                    raise ValueError('Invalid token')
                if hmac.compare_digest(path.encode(), (expected + '/config').encode()):
                    if not values.get('SING_BOX_CONFIG_PATH', '').strip():
                        self.respond(404, {'error': 'Not found'})
                        return
                    self.respond(200, read_config(values, env_path))
                    return
                if not hmac.compare_digest(path.encode(), expected.encode()):
                    self.respond(404, {'error': 'Not found'})
                    return
                host = self.headers.get('Host', '')
                authority = urlsplit('http://' + host)
                if (not authority.hostname or authority.username is not None or authority.password is not None
                        or authority.path or authority.query or authority.fragment):
                    raise ValueError('Invalid Host header')
                self.respond(200, subscription(values, 'http://' + host + expected + '/config'))
            except (OSError, ValueError, KeyError):
                self.respond(503, {'error': 'Subscription unavailable'})

        def respond(self, status, payload):
            body = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode('utf-8')
            self.send_response(status)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format, *args):
            # The request path contains the subscription credential.
            pass

    return ThreadingHTTPServer((host if host is not None else startup.get('HOST', '0.0.0.0'),
                                port if port is not None else int(startup.get('PORT', '8080'))), Handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--env', type=Path, default=Path(__file__).with_name('.env'))
    args = parser.parse_args()
    try:
        httpd = create_server(args.env)
    except (OSError, ValueError, KeyError):
        parser.exit(1, 'Cannot start server: check .env and listen address.\n')
    print(f'Subscription server listening on port {httpd.server_port}. Press Ctrl+C to stop.')
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == '__main__':
    main()
