#!/usr/bin/env python3
"""Windows 原生文件/文件夹选择器。

由 `aitrans_gui.py` 以子进程方式调用：Tk 只在这个短命进程的主线程里
创建和销毁，避免在 Web 服务的请求线程里反复初始化 Tcl 造成不稳定。

输出一行 JSON：{"paths": [...]}；取消选择时为空列表。
"""

from __future__ import annotations

import json
import sys


def pick(kind="files"):
    """弹出系统对话框，返回选中的路径列表（取消时为空列表）。"""
    import tkinter
    from tkinter import filedialog

    root = tkinter.Tk()
    root.withdraw()
    root.attributes("-topmost", True)
    root.update()
    try:
        if kind == "folder":
            selected = filedialog.askdirectory(
                parent=root,
                title="选择包含 SRT 字幕的文件夹",
                mustexist=True,
            )
            return [selected] if selected else []
        selected = filedialog.askopenfilenames(
            parent=root,
            title="选择 SRT 字幕文件",
            filetypes=(("SRT 字幕", "*.srt"), ("所有文件", "*.*")),
        )
        return [str(item) for item in selected or ()]
    finally:
        root.destroy()


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    kind = argv[0] if argv else "files"
    try:
        paths = pick(kind)
    except Exception as error:  # pragma: no cover - 依赖具体系统环境
        print(f"{type(error).__name__}: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"paths": paths}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
