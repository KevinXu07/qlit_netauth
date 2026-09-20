#!/usr/bin/env python3
"""
从浏览器导出的 HAR 抓包里还原 Dr.COM 门户的登录协议。

这个脚本就是当初得出 qlit-netauth 里那套算法/参数的过程的可复现版本。
如果哪天学校改了门户，再用同样的方式抓一次包，跑这个脚本就能看出新协议
和现在有什么不同。

用法:
    python3 tooling/har_login_dump.py <抓包.har>

输出包括:
  * 登录请求的完整 URL、请求头、请求体
  * 各表单参数的拆解
  * 用 auth_tag 作 RC4 密钥解密 pwd 得到的明文密码
  * 门户返回体
  * 同一会话里出现的其它门户接口
"""
import sys
import json
import datetime


def rc4(key: str, data: bytes) -> bytes:
    """标准 RC4；与门户页面 rc4.js 的 do_encrypt_rc4 等价（后者输出 hex）"""
    key_b = key.encode()
    sbox = list(range(256))
    j = 0
    for i in range(256):
        j = (j + sbox[i] + key_b[i % len(key_b)]) % 256
        sbox[i], sbox[j] = sbox[j], sbox[i]
    out = bytearray()
    a = b = 0
    for ch in data:
        a = (a + 1) % 256
        b = (b + sbox[a]) % 256
        sbox[a], sbox[b] = sbox[b], sbox[a]
        out.append(ch ^ sbox[(sbox[a] + sbox[b]) % 256])
    return bytes(out)


def load_har(path):
    with open(path, encoding='utf-8') as fh:
        return json.load(fh)['log']['entries']


def parse_form(text):
    from urllib.parse import parse_qs
    return {k: v[0] for k, v in parse_qs(text or '', keep_blank_values=True).items()}


def find_login(entries):
    for e in entries:
        req = e['request']
        if 'login.php' in req['url'] and req['method'] == 'POST':
            form = parse_form((req.get('postData') or {}).get('text'))
            if form.get('opr') == 'pwdLogin':
                return e, form
    return None, None


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    path = sys.argv[1]
    entries = load_har(path)

    print('=' * 72)
    print('HAR: %s' % path)
    print('请求总数: %d' % len(entries))
    print('=' * 72)

    entry, form = find_login(entries)
    if not entry:
        print('\n没有找到 opr=pwdLogin 的登录请求。')
        print('可能这次抓包里没有登录动作 —— 请先注销，再在浏览器里重新登录一次并抓包。')
        sys.exit(1)

    req, resp = entry['request'], entry['response']

    print('\n--- 登录请求 ---')
    print('%s %s' % (req['method'], req['url']))
    for h in req['headers']:
        if h['name'].lower() in ('content-type', 'origin', 'referer', 'x-requested-with'):
            print('  %s: %s' % (h['name'], h['value']))

    print('\n--- 表单参数 ---')
    for k, v in form.items():
        print('  %-12s = %s' % (k, v))

    print('\n--- 密码解密 ---')
    tag = form.get('auth_tag', '')
    enc = form.get('pwd', '')
    if not enc:
        print('  请求里没有 pwd 字段，可能不是账号密码登录。')
    else:
        try:
            ct = bytes.fromhex(enc)
        except ValueError:
            print('  pwd 不是十六进制串：%r' % enc)
            ct = None
        if ct is not None:
            if not tag:
                print('  没有 auth_tag，无法确定 RC4 密钥。')
            else:
                plain = rc4(tag, ct)
                print('  auth_tag (RC4 密钥) = %s' % tag)
                print('  pwd 密文 (%d 字节)   = %s' % (len(ct), enc))
                print('  解密结果             = %r' % plain)
                try:
                    print('  作为文本             = %s' % plain.decode())
                except UnicodeDecodeError:
                    print('  （不是合法 UTF-8，密钥可能不对）')
                if tag.isdigit() and len(tag) == 13:
                    ts = datetime.datetime.fromtimestamp(
                        int(tag) / 1000, datetime.timezone.utc)
                    print('  auth_tag 时间        = %s UTC' % ts)
                    print('  说明: auth_tag 就是个毫秒时间戳，同时也是 RC4 密钥。')
                    print('        门户页面 JS 里写作 rckey = +(new Date()) + \'\';')

    print('\n--- 门户响应 ---')
    print('  HTTP %s' % resp['status'])
    for h in resp['headers']:
        if h['name'].lower() in ('set-cookie', 'content-type'):
            print('  %s: %s' % (h['name'], h['value']))
    print('  %s' % (resp['content'].get('text') or '<空>'))

    print('\n--- 同一会话中的其它门户接口 ---')
    seen = set()
    for e in entries:
        url = e['request']['url']
        if '10.2.2.82' not in url and '/ac_portal/' not in url and '/homepage/' not in url:
            continue
        key = (e['request']['method'], url.split('?')[0])
        if key in seen:
            continue
        seen.add(key)
        body = ((e['request'].get('postData') or {}).get('text') or '').strip()
        print('  %-5s %-42s %s' % (e['request']['method'], url.split('?')[0],
                                   ('body: ' + body) if body else ''))


if __name__ == '__main__':
    main()
