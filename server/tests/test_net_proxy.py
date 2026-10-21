"""出网纪律回归:全进程绕过系统/环境代理。

2026-10-21 实盘事故:urllib 默认 opener 在首次调用时固化系统代理(启动时 Clash
开着),Clash 一挂,App 长活进程内所有出网 ECONNREFUSED——行情/选股/飞书全哑,
外部 curl 却正常。本测试锁死三件事:
  1) net.OPENER 不挂任何代理;
  2) install() 后 urllib 默认 opener 就是它——即使环境里有死代理也直连;
  3) requests 统一入口 trust_env=False。

跑法:cd server && /Users/chenhong/github/czsc-repo/.venv/bin/python -m unittest tests.test_net_proxy -v
"""
import os
import sys
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest import mock

SERVER_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SERVER_ROOT))

from services import net  # noqa: E402


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        body = b"wd-net-ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):  # 静音
        pass


class NetProxyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.httpd = HTTPServer(("127.0.0.1", 0), _Handler)
        cls.port = cls.httpd.server_address[1]
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()

    def test_opener_has_empty_proxy(self):
        # ProxyHandler({}) 本身不注册任何 handler(空代理=直连),这里锁“没有挂代理”
        proxies = {}
        for h in net.OPENER.handlers:
            if isinstance(h, urllib.request.ProxyHandler):
                proxies.update(h.proxies)
        self.assertEqual(proxies, {}, "OPENER 不允许挂任何代理")

    def test_install_ignores_dead_env_proxy(self):
        """环境里塞一个死代理,install() 后仍必须直连成功。"""
        dead = "http://127.0.0.1:9"
        with mock.patch.dict(os.environ, {"http_proxy": dead, "HTTP_PROXY": dead,
                                          "https_proxy": dead, "HTTPS_PROXY": dead,
                                          "all_proxy": dead, "ALL_PROXY": dead}):
            net.install()
            self.assertIs(urllib.request._opener, net.OPENER)
            with urllib.request.urlopen(
                    f"http://127.0.0.1:{self.port}/", timeout=5) as r:
                self.assertEqual(r.status, 200)
                self.assertEqual(r.read(), b"wd-net-ok")

    def test_requests_session_trust_env_off(self):
        sess = net.session()
        self.assertFalse(sess.trust_env)
        self.assertEqual(sess.proxies, {})
        sess.close()

    def test_main_installs_before_startup(self):
        """main.py 必须在外网模块启动前安装空代理 opener。"""
        src = (SERVER_ROOT / "main.py").read_text(encoding="utf-8")
        self.assertIn("net.install()", src)
        self.assertLess(src.index("net.install()"),
                        src.index("ensure_light_czsc()"))


if __name__ == "__main__":
    unittest.main()
