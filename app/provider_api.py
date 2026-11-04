# provider_api.py - 提供商的读写、切换与连通性测试
"""图形界面和翻译脚本共用的提供商管理逻辑。

- 读取 `providers.json` 与 `.env`，生成界面所需的状态；
- 新增/修改/删除/启用提供商，并同步 `.env`；
- 通过 `/models` 接口测试提供商是否可访问。
"""

from __future__ import annotations

import json
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import provider_config as pc
from web_base import GuiError


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
    """返回提供商列表、当前启用项以及 .env 的同步状态。"""
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
