import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import urlopen

spec = importlib.util.spec_from_file_location('subscription_server', Path(__file__).parents[1] / 'server.py')
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.config = self.root / 'config.json'
        self.config.write_text('{"outbounds":[{"type":"direct"}]}')
        self.env = self.root / '.env'
        self.write_env()
        self.httpd = server.create_server(self.env, host='127.0.0.1', port=0)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.httpd.server_port}'

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join()
        self.directory.cleanup()

    def write_env(self, vk='wdtt://example.com:443:a:b:password:call', token='test-token'):
        self.env.write_text(f'SUBSCRIPTION_TOKEN={token}\nSING_BOX_CONFIG_PATH=config.json\nVK_TURN_LINK="{vk}"\n')

    def get(self, path='/subscription/test-token'):
        try:
            response = urlopen(self.url + path, timeout=2)
        except HTTPError as error:
            self.addCleanup(error.close)
            raise
        with response:
            self.assertEqual(response.headers['Cache-Control'], 'no-store')
            return json.load(response)

    def test_subscription_contains_only_two_links(self):
        result = self.get()
        self.assertEqual(result, {
            'sing_box_url': self.url + '/subscription/test-token/config',
            'vk_turn_link': 'wdtt://example.com:443:a:b:password:call',
        })
        self.assertEqual(self.get('/subscription/test-token/config'),
                         {'outbounds': [{'type': 'direct'}]})

    def test_optional_vk_turn(self):
        self.write_env(vk='')
        self.assertIsNone(self.get()['vk_turn_link'])

    def test_optional_sing_box_without_loading_a_file(self):
        self.env.write_text(self.env.read_text().replace('SING_BOX_CONFIG_PATH=config.json', 'SING_BOX_CONFIG_PATH='))
        self.config.unlink()
        result = self.get()
        self.assertIsNone(result['sing_box_url'])
        self.assertTrue(result['vk_turn_link'].startswith('wdtt://'))

    def test_env_and_config_reloaded_without_restart(self):
        self.get()
        self.write_env(vk='')
        self.config.write_text('{"outbounds":[]}')
        result = self.get()
        self.assertIsNone(result['vk_turn_link'])
        self.assertEqual(self.get('/subscription/test-token/config')['outbounds'], [])

    def test_wrong_token_and_private_files_are_not_served(self):
        for path in ['/subscription/wrong', '/subscription/wrong/config', '/.env', '/config.json', '/subscription/test-token/../.env']:
            with self.subTest(path=path), self.assertRaises(HTTPError) as error:
                self.get(path)
            self.assertEqual(error.exception.code, 404)

    def test_missing_or_invalid_config(self):
        self.config.unlink()
        with self.assertRaises(HTTPError) as error:
            self.get('/subscription/test-token/config')
        self.assertEqual(error.exception.code, 503)
        for text in ['broken', '[]', '{"value":NaN}']:
            self.config.write_text(text)
            with self.subTest(text=text), self.assertRaises(HTTPError) as error:
                self.get('/subscription/test-token/config')
            self.assertEqual(error.exception.code, 503)

    def test_metadata_is_not_required_or_returned(self):
        with self.env.open('a') as file:
            file.write('PLAN_NAME=""\nREMAINING_DAYS=invalid\n')
        self.assertEqual(set(self.get()), {'sing_box_url', 'vk_turn_link'})

    def test_config_link_is_disabled_and_token_is_reloaded(self):
        self.write_env(token='replacement')
        with self.assertRaises(HTTPError) as error:
            self.get('/subscription/test-token/config')
        self.assertEqual(error.exception.code, 404)
        self.assertEqual(self.get('/subscription/replacement')['sing_box_url'],
                         self.url + '/subscription/replacement/config')
        self.env.write_text(self.env.read_text().replace('SING_BOX_CONFIG_PATH=config.json', 'SING_BOX_CONFIG_PATH='))
        with self.assertRaises(HTTPError) as error:
            self.get('/subscription/replacement/config')
        self.assertEqual(error.exception.code, 404)

    def test_credentials_are_not_logged_or_echoed_in_errors(self):
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.get()
            self.config.write_text('secret-invalid-json')
            with self.assertRaises(HTTPError) as error:
                self.get('/subscription/test-token/config')
            body = error.exception.read().decode()
        self.assertNotIn('test-token', stderr.getvalue() + body)
        self.assertNotIn('secret-invalid-json', stderr.getvalue() + body)


if __name__ == '__main__':
    unittest.main()
