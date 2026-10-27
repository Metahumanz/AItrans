#!/usr/bin/env python3
"""AItrans 模型提供商图形化配置工具。

启动一个只监听 127.0.0.1 的本地网页，用浏览器管理 providers.json，
并把选中的提供商写入 .env。仅使用 Python 标准库，无需安装依赖。
"""

from __future__ import annotations

import argparse
import json
import secrets
import sys
import threading
import traceback
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen

import provider_config as pc

HERE = Path(__file__).resolve().parent
HTML_PATH = HERE / "provider_gui.html"
MAX_BODY_BYTES = 1_000_000


class GuiError(Exception):
    """可以直接展示给用户的错误。"""


def _extract_api_message(body):
    try:
        payload = json.loads(body)
    except ValueError:
        return " ".join(body.strip().split())[:300]
    if isinstance(payload, dict):
        error = payload.get("error")
        if isinstance(error, dict) and error.get("message"):
            return str(error["message"])[:300]
        if isinstance(error, str) and error:
            return error[:300]
        if payload.get("message"):
            return str(payload["message"])[:300]
    return " ".join(body.strip().split())[:300]


def test_provider(data):
    """用 /models 接口测试提供商是否可访问。"""
    try:
        provider = pc.normalize_provider(data, taken=set())
    except pc.ConfigError as error:
        raise GuiError(str(error)) from error

    url = f"{provider['base_url'].rstrip('/')}/models"
    headers = {
        "Accept": "application/json",
        "User-Agent": "AItrans-ProviderGUI/1.0",
    }
    if provider["api_key"]:
        headers["Authorization"] = f"Bearer {provider['api_key']}"

    request = Request(url, headers=headers, method="GET")
    try:
        with urlopen(request, timeout=12) as response:
            body = response.read(200_000).decode("utf-8", errors="replace")
            status = response.status
    except HTTPError as error:
        body = error.read(20_000).decode("utf-8", errors="replace")
        detail = _extract_api_message(body)
        if error.code in {401, 403}:
            return {
                "success": False,
                "level": "error",
                "message": f"鉴权失败（HTTP {error.code}）。请检查 API Key 是否正确。"
                + (f" 服务返回：{detail}" if detail else ""),
            }
        if error.code == 404:
            return {
                "success": True,
                "level": "warning",
                "message": "服务可以访问，但没有 /models 接口（HTTP 404）。"
                "请确认接口地址是否完整（有些服务需要以 /v1 结尾），然后保存并试翻译。",
            }
        return {
            "success": False,
            "level": "error",
            "message": f"连接失败（HTTP {error.code}）。"
            + (f" 服务返回：{detail}" if detail else ""),
        }
    except (URLError, TimeoutError, OSError) as error:
        reason = getattr(error, "reason", error)
        return {
            "success": False,
            "level": "error",
            "message": f"无法连接 {provider['base_url']}：{reason}",
        }

    model_names = []
    try:
        payload = json.loads(body)
        items = payload.get("data") if isinstance(payload, dict) else None
        if isinstance(items, list):
            model_names = [
                str(item.get("id"))
                for item in items
                if isinstance(item, dict) and item.get("id")
            ]
    except ValueError:
        pass

    message = f"连接成功（HTTP {status}）"
    if model_names:
        message += f"，发现 {len(model_names)} 个可用模型"
        if provider["model"] not in model_names:
            message += f"；注意：列表中未找到「{provider['model']}」"
    return {"success": True, "level": "success", "message": message}


def build_state():
    store = pc.load_store()
    env = pc.read_env_file()
    active = pc.active_provider(store)

    explicit_id = (env.get("AI_PROVIDER") or "").strip()
    legacy_active = (
        active is not None
        and active["id"] == pc.DEFAULT_PROVIDER_ID
        and bool(env.get("DEEPSEEK_API_KEY") or env.get("DEEPSEEK_BASE_URL"))
    )
    env_provider_id = explicit_id or (
        pc.DEFAULT_PROVIDER_ID if legacy_active else None
    )

    env_key = None
    env_base = None
    env_model = None
    if "AI_API_KEY" in env:
        env_key = env["AI_API_KEY"]
    elif legacy_active:
        env_key = env.get("DEEPSEEK_API_KEY")
    if "AI_BASE_URL" in env:
        env_base = env["AI_BASE_URL"]
    elif legacy_active:
        env_base = env.get("DEEPSEEK_BASE_URL")
    if "AI_MODEL" in env:
        env_model = env["AI_MODEL"]

    synced = False
    if active is not None and env_provider_id == active["id"]:
        checks = []
        if env_key is not None:
            checks.append(env_key == active["api_key"])
        if env_base is not None:
            checks.append(env_base == active["base_url"])
        if env_model is not None:
            checks.append(env_model == active["model"])
        synced = all(checks)

    return {
        "active": store.get("active"),
        "providers": store.get("providers", []),
        "presets": pc.get_presets(),
        "paths": {
            "home": str(pc.BASE_DIR),
            "env": str(pc.ENV_PATH),
            "profiles": str(pc.PROFILES_PATH),
        },
        "env": {
            "provider_id": env_provider_id,
            "synced": synced,
            "has_key": bool(env_key),
        },
    }


def save_provider(payload):
    provider_data = payload.get("provider")
    if not isinstance(provider_data, dict):
        raise GuiError("缺少提供商配置。")
    activate = bool(payload.get("activate"))
    store = pc.load_store()
    try:
        provider = pc.upsert_provider(store, provider_data, activate=activate)
    except pc.ConfigError as error:
        raise GuiError(str(error)) from error
    pc.save_store(store)
    if store.get("active") == provider["id"]:
        pc.write_env_file(store)
    return {"saved_id": provider["id"], "state": build_state()}


def activate_provider(payload):
    provider_id = str(payload.get("id") or "").strip()
    store = pc.load_store()
    provider = pc.find_provider(store, provider_id)
    if provider is None:
        raise GuiError("找不到该提供商，请刷新后重试。")
    store["active"] = provider["id"]
    pc.save_store(store)
    pc.write_env_file(store)
    return {"state": build_state()}


def delete_provider(payload):
    provider_id = str(payload.get("id") or "").strip()
    store = pc.load_store()
    providers = store.get("providers", [])
    remaining = [provider for provider in providers if provider["id"] != provider_id]
    if len(remaining) == len(providers):
        raise GuiError("找不到该提供商，请刷新后重试。")

    active_changed = store.get("active") == provider_id
    store["providers"] = remaining
    if active_changed:
        store["active"] = remaining[0]["id"] if remaining else None
    pc.save_store(store)
    if active_changed:
        pc.write_env_file(store)
    return {"state": build_state()}


def quit_app(server):
    threading.Thread(target=server.shutdown, daemon=True).start()
    return {"state": None}


class Handler(BaseHTTPRequestHandler):
    server_version = "AItransProviderGUI/1.0"
    sys_version = ""

    def log_message(self, format, *args):  # noqa: A002 - 匹配基类签名
        pass

    # ---------- 基础响应 ----------

    def _allowed_hosts(self):
        port = self.server.server_port
        return {f"127.0.0.1:{port}", f"localhost:{port}"}

    def _host_ok(self):
        return self.headers.get("Host", "") in self._allowed_hosts()

    def _origin_ok(self):
        origin = self.headers.get("Origin")
        if not origin:
            return True
        port = self.server.server_port
        return origin in {
            f"http://127.0.0.1:{port}",
            f"http://localhost:{port}",
        }

    def _token_ok(self):
        supplied = self.headers.get("X-AItrans-Token", "")
        if not supplied:
            query = parse_qs(urlparse(self.path).query)
            supplied = (query.get("token") or [""])[0]
        return secrets.compare_digest(supplied, self.server.token)

    def _send_bytes(self, status, content_type, body):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; script-src 'unsafe-inline'; "
            "style-src 'unsafe-inline'; connect-src 'self'; "
            "img-src data:; base-uri 'none'; form-action 'none'",
        )
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._send_bytes(status, "application/json; charset=utf-8", body)

    def _send_text(self, status, text):
        self._send_bytes(
            status,
            "text/plain; charset=utf-8",
            text.encode("utf-8"),
        )

    def _send_html(self, status, html):
        self._send_bytes(status, "text/html; charset=utf-8", html.encode("utf-8"))

    def _read_json(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError as error:
            raise GuiError("请求长度无效。") from error
        if length <= 0:
            return {}
        if length > MAX_BODY_BYTES:
            raise GuiError("请求内容过大。")
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as error:
            raise GuiError("请求格式不正确。") from error
        if not isinstance(payload, dict):
            raise GuiError("请求格式不正确。")
        return payload

    # ---------- 路由 ----------

    def do_GET(self):  # noqa: N802 - 匹配基类命名
        if not self._host_ok():
            self._send_text(403, "Host 校验失败。")
            return
        path = urlparse(self.path).path

        if path == "/":
            if not self._token_ok():
                self._send_text(
                    403,
                    "链接无效或已过期。请重新双击 provider.command 启动配置工具。",
                )
                return
            try:
                html = HTML_PATH.read_text(encoding="utf-8")
            except OSError as error:
                self._send_text(500, f"找不到界面文件 provider_gui.html：{error}")
                return
            html = html.replace("__AITRANS_TOKEN__", self.server.token)
            self._send_html(200, html)
            return

        if path == "/api/state":
            if not self._token_ok():
                self._send_json(403, {"ok": False, "error": "访问令牌无效。"})
                return
            try:
                self._send_json(200, {"ok": True, "state": build_state()})
            except (pc.ConfigError, OSError) as error:
                self._send_json(400, {"ok": False, "error": str(error)})
            except Exception as error:  # pragma: no cover - 兜底
                traceback.print_exc()
                self._send_json(500, {"ok": False, "error": f"内部错误：{error}"})
            return

        if path == "/favicon.ico":
            self._send_bytes(204, "image/x-icon", b"")
            return

        self._send_text(404, "未找到该页面。")

    def do_POST(self):  # noqa: N802 - 匹配基类命名
        if not self._host_ok() or not self._origin_ok():
            self._send_json(403, {"ok": False, "error": "来源校验失败。"})
            return
        if not self._token_ok():
            self._send_json(403, {"ok": False, "error": "访问令牌无效。"})
            return

        path = urlparse(self.path).path
        try:
            payload = self._read_json()
            if path == "/api/providers":
                result = save_provider(payload)
            elif path == "/api/activate":
                result = activate_provider(payload)
            elif path == "/api/delete":
                result = delete_provider(payload)
            elif path == "/api/test":
                result = {"test": test_provider(payload.get("provider") or {})}
            elif path == "/api/quit":
                result = quit_app(self.server)
            else:
                self._send_json(404, {"ok": False, "error": "未知接口。"})
                return
            self._send_json(200, {"ok": True, **result})
        except GuiError as error:
            self._send_json(400, {"ok": False, "error": str(error)})
        except (pc.ConfigError, OSError) as error:
            self._send_json(400, {"ok": False, "error": str(error)})
        except Exception as error:  # pragma: no cover - 兜底
            traceback.print_exc()
            self._send_json(500, {"ok": False, "error": f"内部错误：{error}"})


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="AItrans 模型提供商图形化配置工具（本地网页）"
    )
    parser.add_argument(
        "--port",
        type=int,
        default=0,
        help="监听端口，默认自动选择空闲端口（仅绑定 127.0.0.1）",
    )
    parser.add_argument(
        "--no-browser",
        action="store_true",
        help="启动后不自动打开浏览器",
    )
    args = parser.parse_args(argv)
    if not 0 <= args.port <= 65535:
        parser.error("--port 必须在 0 到 65535 之间")

    pc.harden_permissions()

    try:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError as error:
        print(f"无法启动配置工具：{error}", file=sys.stderr)
        return 1

    server.daemon_threads = True
    server.token = secrets.token_urlsafe(24)
    url = f"http://127.0.0.1:{server.server_port}/?token={server.token}"

    print("AItrans 模型提供商配置工具")
    print(f"打开地址：{url}")
    print(f"配置文件：{pc.ENV_PATH}")
    print(f"配置档案：{pc.PROFILES_PATH}")
    print("在网页中保存并启用后，翻译脚本会立即使用新的提供商。")
    print("关闭本窗口或按 Ctrl+C 退出。")

    if not args.no_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已退出。")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
