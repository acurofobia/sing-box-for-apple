#!/usr/bin/env python3
"""Generate the public policy site from the same documents bundled in the app."""
import argparse
from html import escape
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
SOURCE_URL = 'https://github.com/acurofobia/sing-box-for-apple/releases/tag/vipin-1.14.6-2'


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    policy = (ROOT / 'PrototypeApp/Legal/PrivacyPolicy.txt').read_text(encoding='utf-8')
    assert policy.startswith('ПОЛИТИКА КОНФИДЕНЦИАЛЬНОСТИ VIPIN')
    paragraphs = policy.strip().split('\n\n')
    content = '\n'.join('<p>' + escape(p).replace('\n', '<br>') + '</p>' for p in paragraphs)
    page = '''<!doctype html>
<html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>vipin — конфиденциальность и поддержка</title>
<meta name="description" content="Политика конфиденциальности, поддержка и исходники клиента vipin.">
<link rel="icon" href="icon.png"><style>
:root{font-family:system-ui,-apple-system,sans-serif;color:#262028;background:#faf8f9;color-scheme:light}
body{margin:0}main{max-width:760px;margin:auto;padding:48px 24px 72px}header{display:flex;gap:18px;align-items:center}
header img{width:68px;height:68px;border-radius:16px}h1{margin:0;font-size:40px;letter-spacing:-1px}header p{margin:4px 0;color:#665d63}
nav{display:flex;flex-wrap:wrap;gap:12px 24px;margin:28px 0 36px;padding-bottom:24px;border-bottom:1px solid #e1d8de}
a{color:#a61643;text-underline-offset:3px}article{font-size:17px;line-height:1.65;overflow-wrap:anywhere}p{margin:0 0 24px}
footer{border-top:1px solid #e1d8de;margin-top:40px;padding-top:24px;font-size:15px;color:#665d63}
@media(max-width:480px){main{padding:28px 20px 48px}article{font-size:16px}}
</style><main><header><img src="icon.png" alt=""><div><h1>vipin</h1><p>Клиент для ваших серверов</p></div></header>
<nav aria-label="Документы и поддержка"><a href="#privacy">Конфиденциальность</a><a href="mailto:fusedased@gmail.com">Поддержка</a>
<a href="SOURCE_URL">Исходники выпуска</a><a href="privacy.txt">Текст политики</a><a href="licenses.txt">Лицензии</a></nav>
<article id="privacy">CONTENT</article><footer>Sergey Mikhailov · <a href="mailto:fusedased@gmail.com">fusedased@gmail.com</a><br>
По вопросам конфиденциальности и удаления отправленных в поддержку данных напишите на этот адрес.</footer></main></html>
'''.replace('SOURCE_URL', SOURCE_URL).replace('CONTENT', content)
    (output / 'index.html').write_text(page, encoding='utf-8')
    shutil.copyfile(ROOT / 'PrototypeApp/Legal/PrivacyPolicy.txt', output / 'privacy.txt')
    shutil.copyfile(ROOT / 'PrototypeApp/Legal/Licenses.txt', output / 'licenses.txt')
    shutil.copyfile(ROOT / 'PrototypeApp/Assets.xcassets/AppIcon.appiconset/1024.png', output / 'icon.png')
    print(output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/vipin-policy-site/dist')
    generate(parser.parse_args().output.resolve())
