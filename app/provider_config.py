"""AItrans 模型提供商配置。

- providers.json：保存所有提供商配置（含 API Key，文件权限 600）。
- .env：保存当前启用的提供商，翻译脚本从这里读取运行时配置。
- aitrans.command / aitrans.bat：统一图形界面（翻译 + 提供商），通过本模块读写以上两个文件。
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlparse

BASE_DIR = Path(__file__).resolve().parent.parent
ENV_PATH = BASE_DIR / ".env"
PROFILES_PATH = BASE_DIR / "providers.json"

DEFAULT_PROVIDER_ID = "deepseek"
DEFAULT_PROVIDER_NAME = "DeepSeek"
DEFAULT_BASE_URL = "https://api.deepseek.com"
DEFAULT_MODEL = "deepseek-flash"

# 提示文案里引用的启动器：Windows 用 .bat，其他系统用 .command。
LAUNCHER_NAME = "aitrans.bat" if sys.platform.startswith("win") else "aitrans.command"

ENV_HEADER_PREFIX = "# ===== AItrans 模型提供商"
ENV_ACTIVE_PREFIX = "# 当前提供商："
ENV_EMPTY_PREFIX = "# 尚未选择模型提供商"
ENV_HEADER = f"{ENV_HEADER_PREFIX}（由 {LAUNCHER_NAME} 管理，请勿手工编辑本节）====="
ENV_EMPTY_LINE = f"{ENV_EMPTY_PREFIX}：请双击 {LAUNCHER_NAME} 配置"
MANAGED_ENV_KEYS = (
    "AI_PROVIDER",
    "AI_PROVIDER_NAME",
    "AI_API_KEY",
    "AI_BASE_URL",
    "AI_MODEL",
    "DEEPSEEK_API_KEY",
    "DEEPSEEK_BASE_URL",
)

# 预设只是填写起点，保存前可以修改任意字段。
PRESETS = (
    {
        "id": "deepseek",
        "name": "DeepSeek",
        "base_url": "https://api.deepseek.com",
        "model": "deepseek-flash",
        "requires_key": True,
    },
    {
        "id": "openai",
        "name": "OpenAI",
        "base_url": "https://api.openai.com/v1",
        "model": "gpt-4o-mini",
        "requires_key": True,
    },
    {
        "id": "moonshot",
        "name": "Moonshot 月之暗面",
        "base_url": "https://api.moonshot.cn/v1",
        "model": "moonshot-v1-8k",
        "requires_key": True,
    },
    {
        "id": "zhipu",
        "name": "智谱 GLM",
        "base_url": "https://open.bigmodel.cn/api/paas/v4",
        "model": "glm-4-flash",
        "requires_key": True,
    },
    {
        "id": "dashscope",
        "name": "阿里云百炼（通义千问）",
        "base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "model": "qwen-plus",
        "requires_key": True,
    },
    {
        "id": "siliconflow",
        "name": "硅基流动 SiliconFlow",
        "base_url": "https://api.siliconflow.cn/v1",
        "model": "deepseek-ai/DeepSeek-V3",
        "requires_key": True,
    },
    {
        "id": "openrouter",
        "name": "OpenRouter",
        "base_url": "https://openrouter.ai/api/v1",
        "model": "openai/gpt-4o-mini",
        "requires_key": True,
    },
    {
        "id": "ollama",
        "name": "Ollama（本地 OpenAI 兼容）",
        "base_url": "http://localhost:11434/v1",
        "model": "qwen2.5",
        "requires_key": False,
    },
    {
        "id": "custom",
        "name": "自定义 OpenAI 兼容服务",
        "base_url": "",
        "model": "",
        "requires_key": True,
    },
)


class ConfigError(Exception):
    """提供商配置或 .env 读写错误。"""


def get_presets():
    """返回可安全修改的预设副本。"""
    return [dict(preset) for preset in PRESETS]


def get_preset(provider_id):
    for preset in PRESETS:
        if preset["id"] == provider_id:
            return dict(preset)
    return None


def parse_env_text(text):
    """解析简单 .env 文本，返回有序字典。"""
    values = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key:
            values[key] = value
    return values


def read_env_file(path=ENV_PATH):
    if not path.exists():
        return {}
    try:
        return parse_env_text(path.read_text(encoding="utf-8-sig"))
    except OSError as error:
        raise ConfigError(f"无法读取 {path.name}：{error}") from error


def load_env_file(path=ENV_PATH, override=False):
    """把 .env 载入 os.environ；默认不覆盖已导出的环境变量。"""
    for key, value in read_env_file(path).items():
        if override:
            os.environ[key] = value
        else:
            os.environ.setdefault(key, value)


def _format_env_value(value):
    value = str(value)
    if value == "":
        return ""
    if any(character in value for character in ' \t#"\''):
        if '"' not in value:
            return f'"{value}"'
        if "'" not in value:
            return f"'{value}'"
    return value


def _atomic_write(path, text, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp"
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_name, mode)
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except OSError:
            pass
        raise


def make_provider_id(name, taken):
    """根据显示名称生成唯一的小写标识。"""
    base = re.sub(r"[^a-z0-9]+", "-", str(name).lower()).strip("-")[:40] or "provider"
    candidate = base
    index = 2
    while candidate in taken:
        candidate = f"{base}-{index}"
        index += 1
    return candidate


def _as_bool(value, default=True):
    if value is None:
        return default
    if isinstance(value, str):
        return value.strip().lower() not in {"0", "false", "no", "off", ""}
    return bool(value)


def _is_local_url(base_url):
    host = (urlparse(base_url).hostname or "").lower()
    return host in {"localhost", "127.0.0.1", "::1", "0.0.0.0"}


def normalize_provider(data, taken=None):
    """校验并规范化一个提供商配置。"""
    if not isinstance(data, dict):
        raise ConfigError("提供商配置格式不正确。")

    name = str(data.get("name") or "").strip()
    base_url = str(data.get("base_url") or "").strip().rstrip("/")
    model = str(data.get("model") or "").strip()
    api_key = str(data.get("api_key") or "").strip()
    requires_key = _as_bool(data.get("requires_key"), True)

    if not name:
        raise ConfigError("请填写提供商名称。")
    for label, value in (
        ("提供商名称", name),
        ("接口地址", base_url),
        ("模型名称", model),
        ("API Key", api_key),
    ):
        if any(ord(character) < 32 for character in value):
            raise ConfigError(f"{label}不能包含换行或控制字符。")
    if len(name) > 80:
        raise ConfigError("提供商名称不能超过 80 个字符。")
    if not base_url:
        raise ConfigError("请填写接口地址。")
    parsed = urlparse(base_url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ConfigError("接口地址必须以 http:// 或 https:// 开头。")
    if len(base_url) > 500:
        raise ConfigError("接口地址过长。")
    if not model:
        raise ConfigError("请填写模型名称。")
    if len(model) > 200:
        raise ConfigError("模型名称过长。")
    if len(api_key) > 1000:
        raise ConfigError("API Key 过长。")

    raw_id = str(data.get("id") or "").strip()
    if raw_id:
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", raw_id):
            raise ConfigError("提供商标识只能包含小写字母、数字、- 和 _。")
        provider_id = raw_id
    else:
        provider_id = make_provider_id(name, taken or set())

    return {
        "id": provider_id,
        "name": name,
        "base_url": base_url,
        "model": model,
        "api_key": api_key,
        "requires_key": requires_key,
    }


def _normalize_store(raw):
    if not isinstance(raw, dict):
        raise ConfigError("providers.json 内容格式不正确。")
    raw_providers = raw.get("providers")
    if not isinstance(raw_providers, list):
        raise ConfigError("providers.json 缺少 providers 列表。")

    providers = []
    taken = set()
    for item in raw_providers:
        if not isinstance(item, dict):
            continue
        try:
            provider = normalize_provider(item, taken=taken)
        except ConfigError:
            continue
        if provider["id"] in taken:
            continue
        taken.add(provider["id"])
        providers.append(provider)

    active = str(raw.get("active") or "").strip() or None
    if active not in taken:
        active = providers[0]["id"] if providers else None
    return {"version": 1, "active": active, "providers": providers}


def _bootstrap_store():
    env = read_env_file()
    raw_provider_id = (env.get("AI_PROVIDER") or "").strip() or DEFAULT_PROVIDER_ID
    provider_id = raw_provider_id
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", provider_id):
        provider_id = make_provider_id(provider_id, set())
    preset = get_preset(provider_id)

    name = (env.get("AI_PROVIDER_NAME") or "").strip()
    if not name:
        name = preset["name"] if preset else raw_provider_id
    legacy = provider_id == DEFAULT_PROVIDER_ID
    base_url = (
        (env.get("AI_BASE_URL") or "").strip()
        or ((env.get("DEEPSEEK_BASE_URL") or "").strip() if legacy else "")
        or (preset["base_url"] if preset else DEFAULT_BASE_URL)
    )
    model = (env.get("AI_MODEL") or "").strip() or (
        preset["model"] if preset else DEFAULT_MODEL
    )
    api_key = (
        (env.get("AI_API_KEY") or "").strip()
        or ((env.get("DEEPSEEK_API_KEY") or "").strip() if legacy else "")
    )
    requires_key = preset["requires_key"] if preset else True
    if not preset and _is_local_url(base_url):
        requires_key = False

    provider = {
        "id": provider_id,
        "name": name,
        "base_url": base_url,
        "model": model,
        "api_key": api_key,
        "requires_key": requires_key,
    }
    return {"version": 1, "active": provider_id, "providers": [provider]}


def load_store(path=PROFILES_PATH):
    """读取 providers.json；不存在时从当前 .env 生成初始配置。"""
    if not path.exists():
        return _bootstrap_store()
    try:
        raw = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as error:
        raise ConfigError(f"无法读取 {path.name}：{error}") from error
    return _normalize_store(raw)


def save_store(store, path=PROFILES_PATH):
    payload = {
        "version": 1,
        "active": store.get("active"),
        "providers": store.get("providers", []),
    }
    _atomic_write(
        path,
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        0o600,
    )


def harden_permissions():
    """包含 API Key 的文件只允许当前用户读写。"""
    for path in (ENV_PATH, PROFILES_PATH):
        if path.exists():
            try:
                os.chmod(path, 0o600)
            except OSError:
                pass


def find_provider(store, provider_id):
    for provider in store.get("providers", []):
        if provider.get("id") == provider_id:
            return provider
    return None


def active_provider(store):
    return find_provider(store, store.get("active"))


def upsert_provider(store, data, activate=False):
    """新增或更新提供商；若它是当前提供商，则同步 .env。"""
    providers = store.setdefault("providers", [])
    current_id = str(data.get("id") or "").strip()
    taken = {p["id"] for p in providers if p["id"] != current_id}
    normalized = normalize_provider(data, taken=taken)

    existing = find_provider(store, current_id) if current_id else None
    if existing is not None:
        existing.update(normalized)
        provider = existing
    else:
        providers.append(normalized)
        provider = normalized

    if activate or not store.get("active") or store.get("active") == provider["id"]:
        store["active"] = provider["id"]
    return provider


def write_env_file(store, path=ENV_PATH):
    """把当前启用的提供商写入 .env，保留其他手工配置项。"""
    active = active_provider(store)

    kept_lines = []
    if path.exists():
        try:
            original = path.read_text(encoding="utf-8-sig").splitlines()
        except OSError as error:
            raise ConfigError(f"无法读取 {path.name}：{error}") from error
        for raw_line in original:
            stripped = raw_line.strip()
            if (
                stripped.startswith(ENV_HEADER_PREFIX)
                or stripped.startswith(ENV_EMPTY_PREFIX)
                or stripped.startswith(ENV_ACTIVE_PREFIX)
            ):
                continue
            key = stripped.partition("=")[0].strip()
            if key.startswith("export "):
                key = key[7:].strip()
            if key in MANAGED_ENV_KEYS:
                continue
            kept_lines.append(raw_line)
    while kept_lines and not kept_lines[-1].strip():
        kept_lines.pop()

    block = [ENV_HEADER]
    if active is None:
        block.append("# 尚未选择模型提供商：请双击 aitrans.command 配置")
    else:
        block.append(f"# 当前提供商：{active['name']}")
        block.append(f"AI_PROVIDER={_format_env_value(active['id'])}")
        block.append(f"AI_PROVIDER_NAME={_format_env_value(active['name'])}")
        block.append(f"AI_API_KEY={_format_env_value(active['api_key'])}")
        block.append(f"AI_BASE_URL={_format_env_value(active['base_url'])}")
        block.append(f"AI_MODEL={_format_env_value(active['model'])}")

        host = (urlparse(active["base_url"]).hostname or "").lower()
        if active["id"] == DEFAULT_PROVIDER_ID or "deepseek" in host:
            # 兼容仍直接读取 DEEPSEEK_* 的旧脚本。
            block.append(f"DEEPSEEK_API_KEY={_format_env_value(active['api_key'])}")
            block.append(f"DEEPSEEK_BASE_URL={_format_env_value(active['base_url'])}")

    sections = []
    if kept_lines:
        sections.append("\n".join(kept_lines))
    sections.append("\n".join(block))
    content = "\n\n".join(sections) + "\n"
    _atomic_write(path, content, 0o600)
    # 让当前进程立即使用新配置；图形界面切换提供商后无需重启。
    load_env_file(path, override=True)


def set_active_api_key(api_key):
    """供启动脚本在缺少 Key 时保存输入值。"""
    store = load_store()
    provider = active_provider(store)
    if provider is None:
        if store.get("providers"):
            provider = store["providers"][0]
        else:
            provider = normalize_provider(
                {
                    "id": DEFAULT_PROVIDER_ID,
                    "name": DEFAULT_PROVIDER_NAME,
                    "base_url": DEFAULT_BASE_URL,
                    "model": DEFAULT_MODEL,
                }
            )
            store.setdefault("providers", []).append(provider)
        store["active"] = provider["id"]
    provider["api_key"] = str(api_key).strip()
    provider["requires_key"] = True
    save_store(store)
    write_env_file(store)
    return provider


def resolve_runtime_config():
    """解析翻译脚本应使用的提供商配置（.env 优先，配置文件兜底）。"""
    load_env_file()

    env = os.environ
    env_provider_id = (env.get("AI_PROVIDER") or "").strip()
    explicit = bool(env_provider_id)

    try:
        store = load_store()
    except ConfigError:
        store = {"version": 1, "active": None, "providers": []}

    if explicit:
        provider_id = env_provider_id
    else:
        provider_id = store.get("active") or DEFAULT_PROVIDER_ID

    profile = find_provider(store, provider_id)
    use_profile = profile is not None and (
        explicit or store.get("active") == provider_id
    )
    preset = get_preset(provider_id)
    legacy = provider_id == DEFAULT_PROVIDER_ID

    def env_value(key):
        """区分“未设置”和“显式留空”，显式留空不再回退到配置档案。"""
        return env[key].strip() if key in env else None

    api_key = env_value("AI_API_KEY")
    base_url = env_value("AI_BASE_URL")
    if legacy:
        if api_key is None:
            api_key = env_value("DEEPSEEK_API_KEY")
        if base_url is None:
            base_url = env_value("DEEPSEEK_BASE_URL")
    model = env_value("AI_MODEL")
    name = env_value("AI_PROVIDER_NAME")
    requires_key = True

    if use_profile:
        if api_key is None:
            api_key = profile["api_key"]
        if base_url is None:
            base_url = profile["base_url"]
        if model is None:
            model = profile["model"]
        if name is None:
            name = profile["name"]
        requires_key = profile["requires_key"]
    elif preset is not None:
        base_url = base_url or preset["base_url"]
        model = model or preset["model"]
        name = name or preset["name"]
        requires_key = preset["requires_key"]
    else:
        name = name or provider_id

    api_key = api_key or ""
    base_url = base_url or DEFAULT_BASE_URL
    model = model or DEFAULT_MODEL
    if not use_profile and not preset and _is_local_url(base_url):
        requires_key = False

    return {
        "provider_id": provider_id,
        "provider_name": name or provider_id,
        "api_key": api_key,
        "base_url": base_url,
        "model": model,
        "requires_key": requires_key,
    }


def get_api_key():
    """返回当前提供商的 API Key；需要密钥但未配置时给出可操作提示。"""
    config = resolve_runtime_config()
    if not config["api_key"] and config["requires_key"]:
        raise RuntimeError(
            f"未找到「{config['provider_name']}」的 API Key。"
            "请打开 aitrans 图形界面，在「提供商」标签页中配置，"
        )
    return config["api_key"]
