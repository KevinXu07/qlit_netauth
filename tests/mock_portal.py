#!/usr/bin/env python3
"""
模拟 QLIT 校园网 Dr.COM 门户，用于端到端验证 qlit-netauth，无需接触真实网络。

它按抓包还原出的真实行为工作：
  * 用接收到的 auth_tag 作为 RC4 密钥解密 pwd，再和期望密码比对
    —— 这与真实门户的校验方式一致，因此能真正验证客户端的加密是否正确
  * 未认证时，探测地址返回门户页面（模拟运营商劫持），认证后返回正常内容
  * 记录每一次登录请求，供测试断言

用法: mock_portal.py <port> <expected_password> <logfile> [expected_username]
"""
import sys
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


def rc4(key: str, data: bytes) -> bytes:
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


# 未认证时门户劫持返回的页面（真实门户会返回它自己的登录页）
PORTAL_PAGE = (
    "<html><head><title>校园网认证</title></head><body>"
    "<script>var opr='pwdLogin';function success(){};</script>"
    "请先登录校园网</body></html>"
)

# 各探测端点认证后返回的内容。connecttest.txt 的内容带空格，用于覆盖
# 「MARKER 中含空格」这一解析场景（默认探测串里就有一条是这样）。
PROBE_BODIES = {
    "/success.txt": "success",
    "/hotspot-detect.html": "<HTML><HEAD><TITLE>Success</TITLE></HEAD>"
                            "<BODY>Success</BODY></HTML>",
    "/connecttest.txt": "Microsoft Connect Test",
}

STATE = {
    "authenticated": False,
    "logins": [],       # 每次登录请求的记录
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass  # 静音 access log，保持测试输出干净

    def _send(self, body: str, code: int = 200, ctype: str = "text/html"):
        raw = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    # ---- 探测地址：认证前后返回不同内容，模拟运营商劫持 ----
    def _probe(self, path):
        if STATE["authenticated"]:
            body = PROBE_BODIES.get(path, "success")
            ctype = "text/html" if body.startswith("<") else "text/plain"
            self._send(body, 200, ctype)
        else:
            self._send(PORTAL_PAGE, 200, "text/html")

    def do_GET(self):
        path = urlparse(self.path).path
        if path in PROBE_BODIES:
            self._probe(path)
        elif path == "/homepage/logout":
            STATE["authenticated"] = False
            self._send("{'success':true, 'msg':'logout success'}")
        elif path == "/homepage/info.php":
            self._send(json.dumps({"success": STATE["authenticated"]}), 200,
                       "application/json")
        elif path == "/__state":
            self._send(json.dumps({
                "authenticated": STATE["authenticated"],
                "login_count": len(STATE["logins"]),
                "logins": STATE["logins"],
            }), 200, "application/json")
        else:
            self._send(PORTAL_PAGE)

    def do_POST(self):
        path = urlparse(self.path).path
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace")
        form = {k: v[0] for k, v in parse_qs(body, keep_blank_values=True).items()}

        if path == "/ac_portal/login.php" and form.get("opr") == "pwdLogin":
            record = self._handle_login(form)
            if record["ok"]:
                STATE["authenticated"] = True
                self._send(
                    "{'success':true, 'msg':'logon success','action':'location',"
                    "'pop':0,'userName':'%s','location':'http://x/homepage/index.html'}"
                    % record["userName"]
                )
            else:
                self._send("{'success':false, 'msg':'%s'}" % record["reason"])
        else:
            self._send("{'success':false, 'msg':'unknown endpoint'}", 404)

    def _handle_login(self, form):
        """像真实门户那样用 auth_tag 解密 pwd 并校验"""
        user = form.get("userName", "")
        tag = form.get("auth_tag", "")
        enc = form.get("pwd", "")
        rec = {
            "userName": user,
            "auth_tag": tag,
            "pwd_cipher": enc,
            "ok": False,
            "reason": "",
        }

        if form.get("opr") != "pwdLogin":
            rec["reason"] = "bad opr"
        elif not tag.isdigit() or len(tag) != 13:
            rec["reason"] = "auth_tag 不是 13 位毫秒时间戳: %r" % tag
        else:
            try:
                plain = rc4(tag, bytes.fromhex(enc)).decode("utf-8")
            except Exception as exc:
                rec["reason"] = "pwd 解密失败: %s" % exc
                plain = None
            if plain is not None:
                rec["pwd_plain"] = plain
                rec["pwd_hexlen_ok"] = (len(enc) == 2 * len(plain))
                if user != EXPECTED_USER:
                    rec["reason"] = "用户名不匹配: %r" % user
                elif plain != EXPECTED_PASSWORD:
                    rec["reason"] = "密码不匹配"
                else:
                    rec["ok"] = True
                    rec["reason"] = "ok"

        STATE["logins"].append(rec)
        with open(LOGFILE, "a") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
        return rec


def main():
    global EXPECTED_PASSWORD, EXPECTED_USER, LOGFILE
    port = int(sys.argv[1])
    EXPECTED_PASSWORD = sys.argv[2]
    LOGFILE = sys.argv[3]
    EXPECTED_USER = sys.argv[4] if len(sys.argv) > 4 else ""

    open(LOGFILE, "w").close()
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    srv.daemon_threads = True
    thread = threading.Thread(target=srv.serve_forever, daemon=True)
    thread.start()
    print("mock portal listening on 127.0.0.1:%d" % port, flush=True)
    thread.join()


if __name__ == "__main__":
    main()
