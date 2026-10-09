"""轻量 czsc 装载:只挂 Rust 扩展 _native,绕过 fat 包入口。

czsc 1.0.1(native fork)的 __init__ 顶层硬拉 wbt/polars/pyarrow/plotly/scipy
等重依赖(打包多 ~380MB、内存多几百 MB),而看门狗只用 CZSC/RawBar/Freq
等 Rust 核心类型。启动时先用空壳顶替 sys.modules["czsc"],子模块
czsc._native 照常从真实包目录加载;之后全项目的 `from czsc import ...`
都命中壳属性,fat 部分永不执行——PyInstaller 阶段配合 spec excludes 剔除。
"""
import importlib
import importlib.util
import sys
import types

_EXPORTS = ("CZSC", "RawBar", "Freq", "Mark", "NewBar", "FX", "BI", "ZS",
            "Direction", "BarGenerator", "CzscSignals", "CzscTrader", "Event", "Operate")


def ensure_light_czsc():
    if "czsc" in sys.modules and hasattr(sys.modules["czsc"], "CZSC"):
        return
    spec = importlib.util.find_spec("czsc")   # 只定位真实包目录,不执行 __init__
    paths = list(spec.submodule_search_locations or [])
    shell = types.ModuleType("czsc")
    shell.__path__ = paths
    shell.__doc__ = "light shell(services/czsc_light.py:绕过 fat __init__)"
    sys.modules["czsc"] = shell
    nat = importlib.import_module("czsc._native")
    shell._native = nat
    for name in _EXPORTS:
        if hasattr(nat, name):
            setattr(shell, name, getattr(nat, name))
