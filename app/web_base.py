# web_base.py - 本地 Web 服务的公共基础（错误类型、启动器文案、HTTP 基类）
"""AItrans 各个本地网页服务共用的基础设施。

只监听 127.0.0.1，通过查询参数里的随机 token 和 `X-AItrans-Token`
请求头校验访问权限，并限制 Host / Origin，避免其他网页调用本地接口。
"""

from __future__ import annotations

import json
import secrets
import sys
from http.server import BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

MAX_BODY_BYTES = 1_000_000
LAUNCHER_EXTENSION = ".bat" if sys.platform.startswith("win") else ".command"
_LAUNCHER_NAMES = (
    "transoptdeepseek",
    "transdeepseek",
    "transopt",
    "trans",
    "aitrans",
    "provider",
)


class GuiError(Exception):
    """可以直接展示给用户的错误。"""


def localize_launcher_text(text):
    """把界面文案里的 .command 启动器换成当前系统的实际文件名。"""
    if not text or LAUNCHER_EXTENSION == ".command":
        return text
    for name in _LAUNCHER_NAMES:
        text = text.replace(f"{name}.command", f"{name}{LAUNCHER_EXTENSION}")
    return text


class Handler(BaseHTTPRequestHandler):
    """带 token / Host / Origin 校验的请求处理基类。"""

    server_version = "AItransGUI/2.0"
    sys_version = ""

    def log_message(self, format, *args):  # noqa: A002 - 匹配基类签名
        pass

    # ---------- 校验 ----------

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

    # ---------- 响应 ----------

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
        if isinstance(payload, dict) and isinstance(payload.get("error"), str):
            payload = {**payload, "error": localize_launcher_text(payload["error"])}
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._send_bytes(status, "application/json; charset=utf-8", body)

    def _send_text(self, status, text):
        self._send_bytes(
            status,
            "text/plain; charset=utf-8",
            localize_launcher_text(text).encode("utf-8"),
        )

    def _send_html(self, status, html):
        self._send_bytes(
            status,
            "text/html; charset=utf-8",
            localize_launcher_text(html).encode("utf-8"),
        )

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

    # ---------- 默认路由 ----------

    def do_GET(self):  # noqa: N802 - 匹配基类命名
        self._send_text(404, "未找到该页面。")

    def do_POST(self):  # noqa: N802 - 匹配基类命名
        self._send_json(404, {"ok": False, "error": "未知接口。"})
