"""出网纪律:全进程绕过系统/环境代理(AGENTS §5)。

背景(2026-10-21 实盘事故):urllib 的模块级 opener 在**首次 urlopen 时固化**
当时的系统代理。App 进程长活,启动时若 Clash 开着且系统代理指向 127.0.0.1:7897,
Clash 一挂,进程内所有 urllib 请求全部 ECONNREFUSED——行情/选股/飞书推送一起哑,
而外部 curl 一切正常,极难排查。所以启动即安装空代理 opener,永不走代理。

requests 侧对应纪律:sess.trust_env = False(见 food.py / selection.py)。
"""
import urllib.request

# 显式空代理:ProxyHandler({}) 不读系统/环境代理
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def install() -> None:
    """把空代理 opener 设为 urllib 全进程默认(main.py 启动时调用)。"""
    urllib.request.install_opener(OPENER)


def urlopen(req, timeout: int = 10):
    """需要显式 opener 的场景用这个;普通代码直接 urllib.request.urlopen 即可(已装默认)。"""
    return OPENER.open(req, timeout=timeout)


def session():
    """requests 统一入口:trust_env=False,不读环境/系统代理。"""
    import requests
    s = requests.Session()
    s.trust_env = False
    return s
