"""Local, synthetic-only fixtures for native UI verification (port 18081)."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from urllib.parse import urlsplit
from test_prototype_subscription import CONFIG, LINK

VARIANT = 'normal'


def document(variant):
    def external(url): return {'type': 'openExternalUrl', 'url': url}
    def button(identifier, title, action): return {'id': identifier, 'title': title, 'action': action}
    choices = [
        {'id': 'option01', 'title': 'Обычный ВПН', 'text': 'Подключение через обычные VPN-серверы подписки. Подходит для повседневного использования, когда сеть не ограничена белыми списками.',
         'state': 'available', 'buttons': [], 'detailsPageId': 'page01'},
        {'id': 'option02', 'title': 'Обход БС', 'text': 'Альтернативное подключение для сетей с белыми списками. Выберите этот режим, если обычный ВПН недоступен.',
         'state': 'restricted' if variant == 'restricted' else 'available',
         'stateText': 'Нет в тарифе' if variant == 'restricted' else None,
         'detailsPageId': 'page02', 'buttons': [button('button05', 'Сменить тариф', external('https://example.org/plans'))] if variant == 'restricted' else []},
        {'id': 'option03', 'title': 'Авто', 'text': 'При запуске проверяет доступность обычного ВПН. Если он недоступен, выбирает обход БС. Повторяет проверку при новом подключении.', 'state': 'available', 'buttons': []}]
    if variant == 'restricted': choices[1]['text'] = 'Для сетей с белыми списками.\nНедоступно на вашем тарифе.'
    if variant == 'ban-current': choices[0]['state'] = 'restricted'
    blocks = [
        {'id': 'block01', 'type': 'card', 'title': 'Обновлённый тариф' if variant == 'changed' else 'Основной',
         'subtitle': 'ID: 12345678', 'text': 'Осталось 24 дня',
         'buttons': [button('button01', 'Изменить тариф', external('https://example.org/plans'))]},
        {'id': 'block02', 'type': 'valueRow', 'title': '900 ₽', 'subtitle': 'Баланс',
         'buttons': [button('button02', 'Пополнить', external('https://example.org/top-up'))]},
        {'id': 'block03', 'type': 'actionSheet', 'title': 'Личный кабинет', 'text': 'Выберите, где открыть личный кабинет',
         'buttons': [button('button03', 'Открыть личный кабинет в Telegram', external('https://t.me/example')),
                     button('button04', 'Открыть личный кабинет на сайте', external('https://example.org/account'))]},
        {'id': 'block04', 'type': 'selectionList', 'items': choices},
        {'id': 'block05', 'type': 'menu', 'visible': variant != 'hidden', 'items': [
            button('item01', 'Изменить ссылку подписки', {'type': 'openScreen', 'targetId': 'screen01'}),
            button('item02', 'Перейти в личный кабинет', {'type': 'openBlock', 'targetId': 'block03'}),
            button('item03', 'Поддержка', external('https://example.org/support'))]},
        {'id': 'block06', 'type': 'progress', 'value': 0, 'maximum': 2000000000, 'unit': 'bytes', 'period': 'day',
         'text': 'Осталось 2000000000 байт'}]
    if variant == 'long-dialog':
        blocks[2]['title'] = 'Личный кабинет ' * 6
        blocks[2]['text'] = 'Выберите, где открыть личный кабинет. ' * 18
    if variant == 'empty-lists':
        blocks[0]['buttons'] = []
        blocks[3]['items'] = []
        blocks[4]['items'] = []
    if variant == 'long':
        blocks[0]['title'] = 'Длинное название подписки ' * 5
        choices[0]['text'] *= 25
    return {'schemaVersion': 1, 'blocks': blocks, 'pages': [
        {'id': 'page01', 'title': 'Обычный ВПН', 'text': 'Подробное описание режима.\n' * 30}, {'id': 'page02', 'title': 'Обход БС', 'text': 'Альтернативное подключение для сетей с белыми списками.'}]}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        global VARIANT
        path = urlsplit(self.path).path
        name = path.rsplit('/', 1)[-1]
        status = 200
        if path.startswith('/control/'):
            VARIANT = name
            payload = {'ok': True}
        elif path == '/config':
            payload = CONFIG
        elif path.startswith('/ui/'):
            if self.headers.get('Authorization') != 'Bearer synthetic_ui_token_123':
                status, payload = 401, {'error': 'unauthorized'}
            else:
                variant = VARIANT if name == 'both' else name
                payload = document(variant)
                if variant == 'invalid': payload['schemaVersion'] = 2
        elif path.startswith('/subscription/') and name != 'error':
            base = f'http://localhost:{self.server.server_port}'
            payload = {'sing_box_url': None if name in ('empty', 'vk') else base + ('/unavailable' if name == 'config-error' else '/config'),
                       'vk_turn_link': None if name in ('empty', 'vless') else LINK,
                       'ui_url': base + '/ui/' + name, 'ui_token': 'synthetic_ui_token_123'}
        else:
            status, payload = 404, {'error': 'not_found'}
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_): pass


if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', 18081), Handler).serve_forever()
