from PyInstaller.utils import hooks as pyi_hooks
# -*- mode: python ; coding: utf-8 -*-


a = Analysis(
    ['main.py'],
    pathex=[],
    datas=[],
    binaries=pyi_hooks.collect_dynamic_libs('czsc') + pyi_hooks.collect_data_files('czsc'),
    hiddenimports=['czsc', 'czsc._native', 'uvicorn.logging', 'uvicorn.loops', 'uvicorn.loops.auto', 'uvicorn.protocols', 'uvicorn.protocols.http', 'uvicorn.protocols.http.auto', 'uvicorn.protocols.websockets', 'uvicorn.protocols.websockets.auto', 'uvicorn.lifespan', 'uvicorn.lifespan.on'],
    # czsc_light 壳让 fat 依赖(wbt/polars/pyarrow/plotly)永不执行,这里从包里剔除;
    # pandas 保留:_native 的 FX.dt 等 Rust getter 运行时要 import pandas(fx.rs:237)
    excludes=['polars', 'pyarrow', 'plotly', 'matplotlib', 'scipy', 'statsmodels',
              'PIL', 'lxml', 'jedi', 'IPython', 'zmq', 'cramjam',
              'notebook', 'jupyterlab', 'tkinter', 'akshare', 'tushare', 'talib'],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name='watchdog-server',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
