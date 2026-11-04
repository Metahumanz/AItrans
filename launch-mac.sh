#!/bin/bash
# Shared launcher for the macOS Finder entry points (Bash 3.2 compatible).
set -e
cd "$(dirname "$0")"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/Applications/Ollama.app/Contents/Resources"
export PYTHONPATH="$PWD/app${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1

ollama_pid=""
finish() {
    status=$?
    trap - EXIT
    if [ -n "$ollama_pid" ]; then
        kill "$ollama_pid" 2>/dev/null || true
        wait "$ollama_pid" 2>/dev/null || true
    fi
    if [ "$status" -ne 0 ]; then
        printf '\n启动或处理失败，请查看上方提示。\n'
    fi
    if [ -t 0 ] && [ "${AITRANS_NO_PAUSE:-0}" != "1" ]; then
        read -r -p "按回车键关闭窗口…" unused || true
    fi
    exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mode="${1:-}"
case "$mode" in
    trans|transopt) dependencies=(ollama tqdm); backend=ollama ;;
    transdeepseek|transoptdeepseek) dependencies=(tqdm); backend=deepseek ;;
    provider) dependencies=(); backend=gui ;;
    aitrans) dependencies=(ollama tqdm); backend=gui ;;
    *) echo "错误：未知的启动模式。"; exit 1 ;;
esac
shift

if [ "$mode" = "provider" ] || [ "$mode" = "aitrans" ]; then
    script="app/aitrans_gui.py"
    if [ "$mode" = "provider" ]; then
        gui_args=(--tab provider)
    else
        gui_args=()
    fi
else
    script="app/$mode.py"
    gui_args=()
fi

# Finder's PATH often does not include Homebrew. Keep dependencies local.
python=".venv/bin/python"
if [ ! -x "$python" ]; then
    if ! command -v python3 >/dev/null 2>&1; then
        echo "请先安装 Python 3.10 或更新版本，然后重新双击启动。"
        exit 1
    fi
    if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
        echo "需要 Python 3.10 或更新版本。"
        exit 1
    fi
    echo "首次运行：正在创建 Python 虚拟环境…"
    python3 -m venv .venv
fi
if ! "$python" -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
    echo ".venv 中的 Python 版本过旧，请移走 .venv 后重新启动。"
    exit 1
fi
if ! "$python" -c 'import importlib, sys; [importlib.import_module(name) for name in sys.argv[1:]]' "${dependencies[@]}" >/dev/null 2>&1; then
    echo "首次运行：正在安装所需依赖（需要联网）…"
    "$python" -m pip install "${dependencies[@]}"
fi

# Help must work without an API key or a running Ollama service.
for argument in "$@"; do
    case "$argument" in
        -h|--help) "$python" -B "$script" "${gui_args[@]}" "$@"; exit $? ;;
    esac
done

# The unified GUI is self-contained; it only needs the local Python.
if [ "$mode" = "provider" ] || [ "$mode" = "aitrans" ]; then
    "$python" -B "$script" "${gui_args[@]}" "$@"
    exit $?
fi

mkdir -p ori output

if [ "$backend" = "deepseek" ]; then
    # An empty exported key should not override a valid key in .env.
    if [[ ! ${DEEPSEEK_API_KEY:-} =~ [^[:space:]] ]]; then
        unset DEEPSEEK_API_KEY
    fi
    if [[ ! ${AI_API_KEY:-} =~ [^[:space:]] ]]; then
        unset AI_API_KEY
    fi
    # Keep stdin attached to Terminal so getpass can also use it as a fallback.
    key_setup_code=$(cat <<'PY'
import getpass
import sys

from provider_config import get_api_key, resolve_runtime_config, set_active_api_key

try:
    get_api_key()
except RuntimeError:
    if not sys.stdin.isatty() and not sys.stderr.isatty():
        raise SystemExit("未配置 API Key。请双击 provider.command 配置，或设置 AI_API_KEY。")
    config = resolve_runtime_config()
    print(f"首次运行：请输入「{config['provider_name']}」的 API Key，将保存到本目录的 .env。")
    key = getpass.getpass("API Key（输入不显示）: ").strip()
    if not key:
        raise SystemExit("API Key 不能为空。")
    set_active_api_key(key)
    print("API Key 已保存。")
PY
    )
    "$python" -B -c "$key_setup_code"
else
    ollama_ready() {
        "$python" -c 'import ollama; ollama.Client(timeout=2).list()' >/dev/null 2>&1
    }
    if ollama_ready; then
        echo "Ollama 服务已在运行。"
    else
        if ! command -v ollama >/dev/null 2>&1; then
            echo "请先安装并打开 Ollama，然后重新双击启动。"
            echo "下载地址：https://ollama.com/download/mac"
            exit 1
        fi
        echo "正在启动 Ollama 服务…"
        ollama serve >.ollama-mac.log 2>&1 &
        ollama_pid=$!
        ready=0
        for ((attempt=0; attempt<30; attempt++)); do
            if ollama_ready; then ready=1; break; fi
            if ! kill -0 "$ollama_pid" 2>/dev/null; then break; fi
            sleep 1
        done
        if [ "$ready" -ne 1 ]; then
            echo "Ollama 启动失败，详情见 .ollama-mac.log。"
            exit 1
        fi
    fi
    "$python" - "$@" <<'PY'
import argparse
import ollama

parser = argparse.ArgumentParser(add_help=False)
parser.add_argument("--model", default="qwen2.5")
args, _ = parser.parse_known_args()
try:
    ollama.Client(timeout=5).show(args.model)
except ollama.ResponseError as error:
    if error.status_code == 404:
        raise SystemExit(f"尚未安装模型 {args.model}。请在终端运行 ollama pull {args.model}，完成后重新启动。")
    raise
PY
fi

printf '\n开始处理 ori 文件夹中的 .srt 字幕…\n\n'
"$python" -B "$script" "$@"
printf '\n脚本运行结束，结果请查看 output 文件夹；翻译失败数量请查看上方摘要。\n'
