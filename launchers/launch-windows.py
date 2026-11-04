#!/usr/bin/env python3
"""Windows 启动器（对应 macOS 的 launch-mac.sh）。

双击 `aitrans.bat`（或 legacy/ 中的旧启动器）后，由本脚本完成准备工作：

1. 创建或复用项目内的 `.venv`（macOS 复制过来的旧环境会自动重建）；
2. 按需安装 `tqdm`、`ollama` 依赖；
3. 使用 API 提供商时确认 API Key，使用 Ollama 时确认本地服务与模型；
4. 运行对应的翻译脚本，或启动统一图形界面。

只有 Python 标准库，不依赖 PowerShell。
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import URLError
from urllib.request import urlopen

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
APP_DIR = ROOT / "app"
VENV_DIR = ROOT / ".venv"
VENV_PYTHON = VENV_DIR / "Scripts" / "python.exe"
OLLAMA_URL = "http://127.0.0.1:11434/api/tags"
OLLAMA_LOG = ROOT / ".ollama-win.log"
MIN_PYTHON = (3, 10)
_VERSION_CHECK = (
    "import sys; raise SystemExit(0 if sys.version_info >= "
    f"{MIN_PYTHON!r} else 1)"
)

MODES = {
    "trans": {
        "script": "trans.py",
        "dependencies": ("ollama", "tqdm"),
        "backend": "ollama",
    },
    "transopt": {
        "script": "transopt.py",
        "dependencies": ("ollama", "tqdm"),
        "backend": "ollama",
    },
    "transdeepseek": {
        "script": "transdeepseek.py",
        "dependencies": ("tqdm",),
        "backend": "api",
    },
    "transoptdeepseek": {
        "script": "transoptdeepseek.py",
        "dependencies": ("tqdm",),
        "backend": "api",
    },
    "provider": {
        "script": "aitrans_gui.py",
        "dependencies": ("ollama", "tqdm"),
        "backend": "gui",
        "arguments": ("--tab", "provider"),
    },
    "aitrans": {
        "script": "aitrans_gui.py",
        "dependencies": ("ollama", "tqdm"),
        "backend": "gui",
        "arguments": (),
    },
}


class LauncherError(Exception):
    """可以直接展示给用户的启动错误。"""


def _version_ok(executable):
    try:
        result = subprocess.run(
            [str(executable), "-c", _VERSION_CHECK],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return False
    return result.returncode == 0


def ensure_venv():
    """返回可用的虚拟环境 Python；必要时创建或重建 .venv。"""
    if VENV_PYTHON.exists() and _version_ok(VENV_PYTHON):
        return VENV_PYTHON

    command = [sys.executable, "-m", "venv"]
    if VENV_DIR.exists():
        # 从 macOS 复制过来的 .venv 只有 bin/，在 Windows 上无法使用。
        print("检测到不可用的 .venv（可能来自其他系统），正在重建…")
        command.append("--clear")
    command.append(str(VENV_DIR))

    print("首次运行：正在创建 Python 虚拟环境…")
    result = subprocess.run(command)
    if result.returncode != 0 or not VENV_PYTHON.exists():
        raise LauncherError(
            "创建虚拟环境失败。请确认 Python 安装完整，"
            "或手动删除本目录的 .venv 后重新双击启动。"
        )
    if not _version_ok(VENV_PYTHON):
        raise LauncherError(".venv 中的 Python 版本过旧，请删除 .venv 后重新启动。")
    return VENV_PYTHON


def missing_modules(python, names):
    """返回尚未安装的模块名。"""
    if not names:
        return ()
    code = (
        "import importlib.util, sys\n"
        "print('\\n'.join(n for n in sys.argv[1:] if importlib.util.find_spec(n) is None))\n"
    )
    try:
        result = subprocess.run(
            [str(python), "-B", "-c", code, *names],
            capture_output=True,
            text=True,
        )
    except OSError:
        return tuple(names)
    if result.returncode != 0:
        return tuple(names)
    return tuple(line.strip() for line in result.stdout.splitlines() if line.strip())


def ensure_dependencies(python, names):
    missing = missing_modules(python, names)
    if not missing:
        return
    print("正在安装所需依赖（首次运行需要联网）：" + "、".join(missing))
    result = subprocess.run(
        [str(python), "-m", "pip", "install", "--disable-pip-version-check", *missing]
    )
    if result.returncode != 0 or missing_modules(python, missing):
        raise LauncherError(
            "依赖安装失败。请检查网络，或手动运行：\n"
            f'  "{python}" -m pip install {" ".join(missing)}'
        )


def ollama_models():
    """返回本地 Ollama 的模型名列表；服务未运行时返回 None。"""
    try:
        with urlopen(OLLAMA_URL, timeout=1.5) as response:
            payload = json.load(response)
    except (URLError, OSError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    models = []
    for item in payload.get("models") or []:
        if isinstance(item, dict):
            name = item.get("name") or item.get("model")
            if name:
                models.append(str(name))
    return models


def find_ollama():
    candidates = [shutil.which("ollama")]
    for root in (
        os.environ.get("LOCALAPPDATA"),
        os.environ.get("PROGRAMFILES"),
        os.environ.get("PROGRAMFILES(X86)"),
    ):
        if not root:
            continue
        candidates.append(str(Path(root) / "Programs" / "Ollama" / "ollama.exe"))
        candidates.append(str(Path(root) / "Ollama" / "ollama.exe"))
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return Path(candidate)
    return None


def model_available(models, model):
    if not model:
        return True
    for name in models or []:
        if name == model or name == f"{model}:latest":
            return True
        if name.split(":")[0] == model:
            return True
    return False


def start_ollama():
    executable = find_ollama()
    if executable is None:
        print("未检测到 Ollama。请先安装并打开 Ollama，然后重新启动：")
        print("  https://ollama.com/download/windows")
        return None, None
    try:
        log = open(OLLAMA_LOG, "ab", buffering=0)
    except OSError as error:
        print(f"无法写入 {OLLAMA_LOG.name}：{error}")
        return None, None
    print("正在启动 Ollama 服务…")
    try:
        process = subprocess.Popen(
            [str(executable), "serve"],
            cwd=str(ROOT),
            stdout=log,
            stderr=subprocess.STDOUT,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except OSError as error:
        log.close()
        print(f"无法启动 Ollama：{error}")
        return None, None
    return process, log


def ensure_ollama(model):
    """确保 Ollama 服务和模型可用；返回 (进程, 日志, 是否就绪)。"""
    models = ollama_models()
    process = None
    log = None

    if models is None:
        process, log = start_ollama()
        if process is None:
            return None, None, False
        deadline = time.time() + 30
        while time.time() < deadline:
            models = ollama_models()
            if models is not None:
                break
            if process.poll() is not None:
                break
            time.sleep(0.5)
        if models is None:
            print(f"Ollama 启动失败，详情见 {OLLAMA_LOG.name}。")
            return process, log, False
        print("Ollama 已就绪。")
    else:
        print("Ollama 服务已在运行。")

    if not model_available(models, model):
        print(f"尚未安装模型 {model}。请在命令行运行：ollama pull {model}")
        return process, log, False
    return process, log, True


def stop_ollama(process, log):
    if process is not None:
        try:
            process.terminate()
            process.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            try:
                process.kill()
            except OSError:
                pass
    if log is not None:
        try:
            log.close()
        except OSError:
            pass


def ensure_api_key():
    """确认当前提供商已配置 API Key，必要时提示输入并保存。"""
    if str(APP_DIR) not in sys.path:
        sys.path.insert(0, str(APP_DIR))
    try:
        from provider_config import get_api_key, resolve_runtime_config, set_active_api_key
    except Exception as error:  # pragma: no cover - 配置模块损坏时
        print(f"无法读取提供商配置：{error}")
        return False

    # 空的环境变量不应覆盖 .env 中已保存的 Key。
    for name in ("AI_API_KEY", "DEEPSEEK_API_KEY"):
        if name in os.environ and not os.environ[name].strip():
            del os.environ[name]

    try:
        get_api_key()
        return True
    except RuntimeError as error:
        message = str(error)

    if not sys.stdin.isatty():
        print(message)
        return False

    try:
        config = resolve_runtime_config()
    except Exception:
        config = {}
    provider_name = config.get("provider_name") or "当前提供商"
    print(f"首次运行：请输入「{provider_name}」的 API Key，将保存到本目录的 .env。")
    key = getpass.getpass("API Key（输入不显示）: ").strip()
    if not key:
        print("API Key 不能为空。")
        return False
    try:
        set_active_api_key(key)
    except Exception as error:
        print(f"保存 API Key 失败：{error}")
        return False
    print("API Key 已保存。")
    return True


def model_from_arguments(arguments):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--model", default="qwen2.5")
    known, _ = parser.parse_known_args(arguments)
    return known.model


def run_script(python, script, arguments):
    return subprocess.call(
        [str(python), "-B", str(APP_DIR / script), *arguments],
        cwd=str(ROOT),
    )


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--mode", default="")
    known, passthrough = parser.parse_known_args(argv)

    try:
        # 输出被重定向时也保持与子进程一致的顺序。
        sys.stdout.reconfigure(line_buffering=True)
    except (AttributeError, OSError):
        pass

    mode = known.mode.strip()
    spec = MODES.get(mode)
    if spec is None:
        print("错误：未知的启动模式。请通过 aitrans.bat 启动。")
        return 2

    os.chdir(ROOT)
    try:
        python = ensure_venv()
        ensure_dependencies(python, spec["dependencies"])
    except LauncherError as error:
        print(f"\n{error}")
        return 1

    script = spec["script"]
    prefix = list(spec.get("arguments") or ())

    # --help 不需要 API Key 或 Ollama。
    if any(argument in {"-h", "--help"} for argument in passthrough):
        return run_script(python, script, prefix + passthrough)

    if spec["backend"] == "gui":
        return run_script(python, script, prefix + passthrough)

    (ROOT / "ori").mkdir(exist_ok=True)
    (ROOT / "output").mkdir(exist_ok=True)

    process = None
    log = None
    try:
        if spec["backend"] == "api":
            if not ensure_api_key():
                return 1
        else:
            process, log, ready = ensure_ollama(model_from_arguments(passthrough))
            if not ready:
                return 1

        if any(
            argument == "--input" or argument.startswith("--input=")
            for argument in passthrough
        ):
            print("\n开始处理指定的字幕文件…\n")
        else:
            print("\n开始处理 ori 文件夹中的 .srt 字幕…\n")
        code = run_script(python, script, passthrough)
        print(
            "\n脚本运行结束，结果请查看上方的「输出位置」；"
            "翻译失败数量请查看上方摘要。"
        )
        return code
    finally:
        stop_ollama(process, log)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\n已退出。")
        raise SystemExit(130)
