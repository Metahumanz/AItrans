#!/usr/bin/env python3
"""AItrans 统一图形界面：翻译 + 模型提供商。

一个只监听 127.0.0.1 的本地网页，包含两个视图：

- 翻译：拖放/选择 SRT，调用四个原有翻译脚本；
- 提供商：管理 providers.json，并快速切换 .env 中的当前提供商。

翻译设置保存在 settings.json，下次打开自动恢复。仅使用 Python 标准库。
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import uuid
import webbrowser
from datetime import datetime
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse
from urllib.request import urlopen

import provider_config as pc
import provider_gui as pg
from translation_paths import PathError, collect_srt_files, output_path_for

HERE = Path(__file__).resolve().parent
HTML_PATH = HERE / "aitrans_gui.html"
SETTINGS_PATH = HERE / "settings.json"
OUTPUT_DIR = HERE / "output"
OLLAMA_URL = "http://127.0.0.1:11434/api/tags"
MAX_UPLOAD_BYTES = 50 * 1024 * 1024
MAX_FILES = 200
MAX_LOG_CHARS = 300_000
LANGS = {
    "zh": "中文",
    "en": "英文",
    "ja": "日文",
    "ko": "韩文",
}
SCRIPT_BY_MODE = {
    ("api", False): "transdeepseek.py",
    ("api", True): "transoptdeepseek.py",
    ("ollama", False): "trans.py",
    ("ollama", True): "transopt.py",
}
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")

DEFAULT_SETTINGS = {
    "version": 1,
    "backend": "api",
    "api_model": "",
    "ollama_model": "qwen2.5",
    "lang": "zh",
    "translate": True,
    "polish": True,
    "output_mode": "source",
    "suffix": "_translated",
    "custom_dir": "",
    "force": False,
}


GuiError = pg.GuiError


class JobCanceled(Exception):
    """任务被用户取消。"""


def _bool(value, default):
    return bool(value) if isinstance(value, bool) else default


def _clean_settings(raw, current=None):
    """合并并校验设置，避免坏值写入 settings.json。"""
    base = dict(current or DEFAULT_SETTINGS)
    if not isinstance(raw, dict):
        return base

    backend = raw.get("backend", base.get("backend"))
    if backend in {"api", "ollama"}:
        base["backend"] = backend

    for key in ("api_model", "ollama_model"):
        value = raw.get(key, base.get(key, ""))
        if isinstance(value, str):
            base[key] = value.strip()[:160]

    lang = raw.get("lang", base.get("lang"))
    if lang in LANGS:
        base["lang"] = lang

    for key in ("translate", "polish", "force"):
        base[key] = _bool(raw.get(key), base.get(key, False))

    output_mode = raw.get("output_mode", base.get("output_mode"))
    if output_mode in {"source", "output", "custom"}:
        base["output_mode"] = output_mode

    suffix = raw.get("suffix", base.get("suffix", "_translated"))
    if isinstance(suffix, str):
        suffix = suffix.strip()
        if not suffix or "/" in suffix or "\\" in suffix or len(suffix) > 40:
            suffix = base.get("suffix") or "_translated"
        base["suffix"] = suffix

    custom_dir = raw.get("custom_dir", base.get("custom_dir", ""))
    if isinstance(custom_dir, str):
        base["custom_dir"] = custom_dir.strip()[:1000]

    base["version"] = 1
    return base


def load_settings():
    settings = dict(DEFAULT_SETTINGS)
    try:
        raw = json.loads(SETTINGS_PATH.read_text(encoding="utf-8"))
        settings = _clean_settings(raw, settings)
    except FileNotFoundError:
        pass
    except (OSError, ValueError):
        pass

    try:
        runtime = pc.resolve_runtime_config()
        if not settings.get("api_model"):
            settings["api_model"] = runtime.get("model") or ""
    except Exception:
        pass
    return settings


def _atomic_write(path, text, mode=0o600):
    pc._atomic_write(path, text, mode)


def _format_time(timestamp):
    if not timestamp:
        return None
    return datetime.fromtimestamp(timestamp).strftime("%Y-%m-%d %H:%M:%S")


def _platform_name():
    """给前端用的平台标识，用于选择「在访达/资源管理器中显示」等文案。"""
    if sys.platform.startswith("win"):
        return "windows"
    if sys.platform == "darwin":
        return "macos"
    return "linux"


class App:
    def __init__(self):
        self.lock = threading.RLock()
        self.settings_from_file = SETTINGS_PATH.exists()
        try:
            if SETTINGS_PATH.exists():
                os.chmod(SETTINGS_PATH, 0o600)
        except OSError:
            pass
        self.settings = load_settings()
        self.files = []
        self.job = None
        self.job_thread = None
        self.upload_root = Path(tempfile.mkdtemp(prefix="aitrans-gui-"))
        self.downloads = {}
        self.quit_requested = False
        self.ollama_process = None
        self.ollama_log = None
        self.ollama_started = False
        self.ollama_cache_at = 0.0
        self.ollama_cache = {"running": False, "models": []}

    # ---------- 设置 ----------

    def settings_snapshot(self):
        with self.lock:
            return dict(self.settings)

    def update_settings(self, raw):
        with self.lock:
            self.settings = _clean_settings(raw, self.settings)
            settings = dict(self.settings)
        _atomic_write(
            SETTINGS_PATH,
            json.dumps(settings, ensure_ascii=False, indent=2) + "\n",
            0o600,
        )
        return settings

    # ---------- 文件队列 ----------

    def _snapshot_files(self):
        with self.lock:
            result = []
            for item in self.files:
                result.append(
                    {
                        "id": item["id"],
                        "name": item["name"],
                        "dir": item.get("dir", ""),
                        "size": item["size"],
                        "kind": item["kind"],
                        "batch_id": item.get("batch_id"),
                        "relative_name": item.get("relative_name") or item["name"],
                    }
                )
            return result

    def _check_can_edit_files(self):
        with self.lock:
            if self.job and self.job["status"] == "running":
                raise GuiError("任务进行中，请等待完成或先取消任务。")

    def add_paths(self, paths):
        self._check_can_edit_files()
        if not isinstance(paths, list) or not paths:
            raise GuiError("请选择至少一个 SRT 文件或文件夹。")

        candidates = []
        seen = set()
        for raw in paths:
            if not isinstance(raw, str) or not raw.strip():
                continue
            try:
                found = collect_srt_files([raw], HERE / "ori")
            except PathError as error:
                raise GuiError(str(error)) from error
            for path in found:
                try:
                    resolved = str(path.resolve())
                    size = path.stat().st_size
                except OSError as error:
                    raise GuiError(f"无法读取文件：{error}") from error
                if resolved in seen:
                    continue
                seen.add(resolved)
                candidates.append((path, resolved, size))

        if not candidates:
            raise GuiError("没有找到新的 SRT 文件（可能已在列表中）。")

        added = []
        with self.lock:
            existing = {item["path"] for item in self.files}
            fresh = [item for item in candidates if item[1] not in existing]
            if not fresh:
                raise GuiError("没有找到新的 SRT 文件（可能已在列表中）。")
            if len(self.files) + len(fresh) > MAX_FILES:
                raise GuiError(f"一次最多添加 {MAX_FILES} 个文件。")
            for path, resolved, size in fresh:
                entry = {
                    "id": uuid.uuid4().hex,
                    "name": path.name,
                    "path": resolved,
                    "dir": str(path.parent),
                    "size": size,
                    "kind": "path",
                    "batch_id": None,
                    "relative_name": path.name,
                }
                self.files.append(entry)
                added.append(entry)

        return added

    def add_upload(self, name, data, batch_id=None, relative_name=None):
        self._check_can_edit_files()
        if not data:
            raise GuiError("上传内容为空。")
        safe_name = Path(str(name or "subtitle.srt")).name
        safe_name = re.sub(r"[\x00-\x1f]", "", safe_name).strip()[:160]
        if not safe_name.lower().endswith(".srt"):
            raise GuiError("只支持 .srt 文件。")

        with self.lock:
            if len(self.files) >= MAX_FILES:
                raise GuiError(f"一次最多添加 {MAX_FILES} 个文件。")
            inbox = self.upload_root / "inbox" / uuid.uuid4().hex
            inbox.mkdir(parents=True, exist_ok=True)
            # 保留原始文件名，输出文件才能按原名命名并写回拖入的文件夹。
            path = inbox / safe_name
            path.write_bytes(data)
            entry = {
                "id": uuid.uuid4().hex,
                "name": safe_name,
                "path": str(path),
                "dir": "",
                "size": len(data),
                "kind": "upload",
                "batch_id": str(batch_id)[:80] if batch_id else None,
                "relative_name": str(relative_name or safe_name)[:500],
            }
            self.files.append(entry)
            return entry

    def remove_file(self, file_id):
        self._check_can_edit_files()
        with self.lock:
            target = next((item for item in self.files if item["id"] == file_id), None)
            if target is None:
                raise GuiError("找不到该文件。")
            self.files = [item for item in self.files if item["id"] != file_id]
        if target["kind"] == "upload":
            try:
                Path(target["path"]).unlink(missing_ok=True)
            except OSError:
                pass
        return target

    def clear_files(self):
        self._check_can_edit_files()
        with self.lock:
            uploads = [item for item in self.files if item["kind"] == "upload"]
            self.files = []
        for item in uploads:
            try:
                Path(item["path"]).unlink(missing_ok=True)
            except OSError:
                pass

    # ---------- Ollama ----------

    def ollama_status(self, force=False):
        now = time.time()
        if not force and now - self.ollama_cache_at < 2.0:
            return dict(self.ollama_cache)
        status = {"running": False, "models": []}
        try:
            with urlopen(OLLAMA_URL, timeout=1.5) as response:
                payload = json.load(response)
            models = []
            for item in payload.get("models", []) if isinstance(payload, dict) else []:
                if isinstance(item, dict) and item.get("name"):
                    models.append(str(item["name"]))
            status = {"running": True, "models": sorted(models)}
        except Exception as error:
            status = {
                "running": False,
                "models": [],
                "error": str(getattr(error, "reason", error))[:160],
            }
        self.ollama_cache_at = now
        self.ollama_cache = status
        return dict(status)

    def _find_ollama(self):
        candidates = [shutil.which("ollama")]
        if sys.platform == "darwin":
            candidates += [
                "/Applications/Ollama.app/Contents/Resources/ollama",
                "/opt/homebrew/bin/ollama",
                "/usr/local/bin/ollama",
            ]
        elif sys.platform.startswith("win"):
            # Windows 安装包默认放在 %LOCALAPPDATA%\Programs\Ollama。
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
                return candidate
        return None

    def ensure_ollama(self, job):
        status = self.ollama_status(force=True)
        if status.get("running"):
            return status

        executable = self._find_ollama()
        if not executable:
            raise GuiError(
                "未检测到 Ollama。请先安装/启动 Ollama，或在设置中切换到 API 提供商。"
            )

        log_path = HERE / ".ollama-gui.log"
        if self.ollama_log is not None:
            try:
                self.ollama_log.close()
            except OSError:
                pass
        self.ollama_log = open(log_path, "ab", buffering=0)
        popen_options = {
            "cwd": str(HERE),
            "stdout": self.ollama_log,
            "stderr": subprocess.STDOUT,
            "start_new_session": True,
        }
        if sys.platform.startswith("win"):
            # 不要让 Ollama 在 Windows 上额外弹出控制台窗口。
            popen_options["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        try:
            process = subprocess.Popen([executable, "serve"], **popen_options)
        except OSError as error:
            raise GuiError(f"无法启动 Ollama：{error}") from error

        self.ollama_process = process
        self.ollama_started = True
        self.append_log(job, "Ollama 未运行，正在启动本地服务…\n")

        for _ in range(60):
            if job["cancel_requested"]:
                self._signal_process(process)
                raise JobCanceled()
            if process.poll() is not None:
                status = self.ollama_status(force=True)
                if status.get("running"):
                    self.append_log(job, "Ollama 已由其他进程启动。\n")
                    return status
                tail = ""
                try:
                    tail = log_path.read_text(encoding="utf-8", errors="replace")[-800:].strip()
                except OSError:
                    pass
                raise GuiError(f"Ollama 启动失败。{(' ' + tail) if tail else ''}")
            time.sleep(0.5)
            status = self.ollama_status(force=True)
            if status.get("running"):
                self.append_log(job, "Ollama 已就绪。\n")
                return status

        self._signal_process(process)
        raise GuiError("Ollama 启动超时。请手动运行 `ollama serve` 后重试。")

    def stop_ollama(self):
        process = self.ollama_process
        self.ollama_process = None
        if process is not None and self.ollama_started:
            self._signal_process(process)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                try:
                    process.kill()
                except OSError:
                    pass
        self.ollama_started = False
        if self.ollama_log is not None:
            try:
                self.ollama_log.close()
            except OSError:
                pass
            self.ollama_log = None

    # ---------- 任务 ----------

    def _job_running(self):
        with self.lock:
            return bool(self.job and self.job["status"] == "running")

    def job_snapshot(self):
        with self.lock:
            job = self.job
            if job is None:
                return None
            return {
                "id": job["id"],
                "status": job["status"],
                "total": job["total"],
                "completed": job["completed"],
                "failed": job["failed"],
                "skipped": job["skipped"],
                "canceled": job.get("canceled", 0),
                "current": job["current"],
                "log": job["log"],
                "results": [dict(item) for item in job["results"]],
                "started_at": _format_time(job["started_at"]),
                "finished_at": _format_time(job["finished_at"]),
                "options": dict(job["options"]),
            }

    def append_log(self, job, text):
        if not text:
            return
        text = ANSI_RE.sub("", str(text)).replace("\r", "\n")
        text = re.sub(r"\n{3,}", "\n\n", text)
        with self.lock:
            job["log"] += text
            if len(job["log"]) > MAX_LOG_CHARS:
                job["log"] = job["log"][-MAX_LOG_CHARS:]

    def _build_items(self, settings):
        with self.lock:
            files = [dict(item) for item in self.files]
        if not files:
            raise GuiError("请先添加至少一个 SRT 文件。")

        if settings["output_mode"] == "custom":
            raw_custom_dir = settings["custom_dir"].strip()
            if not raw_custom_dir:
                raise GuiError("请选择自定义输出目录。")
            custom_dir = Path(raw_custom_dir).expanduser()
            if custom_dir.exists() and not custom_dir.is_dir():
                raise GuiError(f"自定义输出路径不是文件夹：{custom_dir}")
            try:
                custom_dir.mkdir(parents=True, exist_ok=True)
            except OSError as error:
                raise GuiError(f"无法创建输出目录：{error}") from error
        else:
            custom_dir = None

        suffix = settings["suffix"].strip()
        if settings["output_mode"] == "source" and not suffix:
            raise GuiError("保存到源文件目录时，文件名后缀不能为空。")

        items = []
        used_outputs = set()
        for entry in files:
            source = Path(entry["path"])
            if not source.exists():
                raise GuiError(f"源文件不存在：{source}")
            if entry["kind"] == "upload" and settings["output_mode"] == "source":
                # 浏览器上传的文件没有原始绝对路径，先输出到临时目录，
                # 由前端通过 File System Access API 写回拖入的文件夹。
                output = self.upload_root / "outputs" / uuid.uuid4().hex / source.name
                mode = "temp"
            elif settings["output_mode"] == "source":
                output = output_path_for(
                    source,
                    save_to_source=True,
                    suffix=suffix,
                )
                mode = "source"
            elif settings["output_mode"] == "custom":
                output = output_path_for(source, output_dir=custom_dir)
                mode = "output"
            else:
                output = output_path_for(source, output_dir=OUTPUT_DIR)
                mode = "output"

            key = output.resolve()
            if key in used_outputs:
                raise GuiError(
                    f"多个文件会写入同一个输出文件：{output}\n"
                    "请改用“源文件目录”，或让文件使用不同的输出目录。"
                )
            used_outputs.add(key)
            items.append(
                {
                    "file": entry,
                    "source": str(source),
                    "output": str(output),
                    "mode": mode,
                }
            )
        return items

    def start_job(self, raw_settings):
        if self._job_running():
            raise GuiError("已有任务在运行，请等待完成或先取消。")
        settings = self.update_settings(raw_settings)

        if not settings["translate"]:
            raise GuiError("“翻译”是必选步骤，请勾选后再开始。")
        if settings["backend"] not in {"api", "ollama"}:
            raise GuiError("未知的翻译引擎。")

        if importlib.util.find_spec("tqdm") is None:
            raise GuiError(
                pg.localize_launcher_text(
                    "缺少 tqdm 依赖，请通过 aitrans.command 启动以自动安装依赖。"
                )
            )
        if settings["backend"] == "ollama" and importlib.util.find_spec("ollama") is None:
            raise GuiError(
                pg.localize_launcher_text(
                    "缺少 ollama 依赖，请通过 aitrans.command 启动以自动安装依赖。"
                )
            )

        if settings["backend"] == "api":
            try:
                runtime = pc.resolve_runtime_config()
            except pc.ConfigError as error:
                raise GuiError(str(error)) from error
            if runtime.get("requires_key", True) and not runtime.get("api_key"):
                raise GuiError(
                    f"当前提供商「{runtime.get('provider_name') or runtime.get('provider_id')}」没有 API Key。"
                    "请先在“提供商”中配置，或切换到 Ollama。"
                )

        items = self._build_items(settings)
        job = {
            "id": uuid.uuid4().hex,
            "status": "running",
            "total": len(items),
            "completed": 0,
            "failed": 0,
            "skipped": 0,
            "canceled": 0,
            "current": "",
            "log": "",
            "results": [],
            "started_at": time.time(),
            "finished_at": None,
            "cancel_requested": False,
            "process": None,
            "options": dict(settings),
            "items": items,
        }
        with self.lock:
            self.job = job
        self.job_thread = threading.Thread(target=self._run_job, args=(job,), daemon=True)
        self.job_thread.start()
        return self.job_snapshot()

    def _run_job(self, job):
        settings = job["options"]
        items = job["items"]
        success = 0
        skipped = 0
        failed = 0
        canceled_count = 0

        try:
            if settings["backend"] == "ollama":
                self.ensure_ollama(job)
        except JobCanceled:
            self._finish_job(job, "canceled", success, skipped, failed, canceled_count)
            return
        except Exception as error:
            self.append_log(job, f"\n无法启动 Ollama：{error}\n")
            with self.lock:
                for item in items:
                    job["results"].append(
                        {
                            "source": item["source"],
                            "name": item["file"].get("name") or Path(item["source"]).name,
                            "output": item["output"],
                            "status": "failed",
                            "message": str(error),
                            "batch_id": item["file"].get("batch_id"),
                            "relative_name": item["file"].get("relative_name") or Path(item["source"]).name,
                            "output_name": Path(item["output"]).name,
                        }
                    )
                job["failed"] = len(items)
                job["completed"] = len(items)
            self._finish_job(job, "failed", success, skipped, len(items), canceled_count)
            return

        for item in items:
            if job["cancel_requested"]:
                break
            source = Path(item["source"])
            output = Path(item["output"])
            entry = item["file"]
            job["current"] = source.name
            self.append_log(job, f"\n{'=' * 60}\n▶ {source.name}\n{'=' * 60}\n")

            existed = output.exists() and output.stat().st_size > 0
            script = SCRIPT_BY_MODE[(settings["backend"], settings["polish"])]
            model = settings["api_model"] if settings["backend"] == "api" else settings["ollama_model"]
            command = [
                sys.executable,
                "-B",
                str(HERE / script),
                "--input",
                str(source),
                "--lang",
                settings["lang"],
            ]
            if model:
                command.extend(["--model", model])
            if settings["force"]:
                command.append("--force")
            if item["mode"] == "source":
                command.extend(["--save-to-source", "--suffix", settings["suffix"]])
            else:
                command.extend(["--output-dir", str(output.parent)])

            environment = os.environ.copy()
            environment["PYTHONUNBUFFERED"] = "1"
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            # 固定子进程输出编码，避免 Windows 控制台代码页导致日志乱码。
            environment["PYTHONIOENCODING"] = "utf-8"
            environment["PYTHONUTF8"] = "1"

            process = None
            try:
                process = subprocess.Popen(
                    command,
                    cwd=str(HERE),
                    env=environment,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    bufsize=1,
                    start_new_session=True,
                )
                with self.lock:
                    job["process"] = process
                if process.stdout is not None:
                    for line in process.stdout:
                        self.append_log(job, line)
                returncode = process.wait()
            except Exception as error:
                self.append_log(job, f"\n启动翻译脚本失败：{error}\n")
                self._signal_process(process)
                returncode = -1
            finally:
                with self.lock:
                    job["process"] = None

            canceled = bool(job["cancel_requested"])
            if canceled:
                status = "canceled"
                message = "已取消"
            elif returncode == 0 and output.exists() and output.stat().st_size > 0:
                status = "skipped" if existed and not settings["force"] else "success"
                message = "输出文件已存在，跳过" if status == "skipped" else "完成"
            else:
                status = "failed"
                message = f"翻译脚本退出码 {returncode}"

            result = {
                "source": str(source),
                "name": source.name,
                "output": str(output),
                "status": status,
                "message": message,
                "batch_id": entry.get("batch_id"),
                "relative_name": entry.get("relative_name") or output.name,
                "output_name": output.name,
            }
            if item["mode"] == "temp" and output.exists() and output.stat().st_size > 0:
                download_id = uuid.uuid4().hex
                with self.lock:
                    self.downloads[download_id] = {"path": output, "name": output.name}
                result["download_id"] = download_id

            with self.lock:
                job["results"].append(result)
                job["completed"] += 1
                if status == "success":
                    success += 1
                elif status == "skipped":
                    skipped += 1
                elif status == "canceled":
                    canceled_count += 1
                else:
                    failed += 1
                job["failed"] = failed
                job["skipped"] = skipped
                job["canceled"] = canceled_count

            icon = {"success": "✓", "skipped": "•", "failed": "✗", "canceled": "×"}.get(status, "·")
            self.append_log(job, f"\n{icon} {source.name}：{message}\n")
            if canceled:
                break

        status = "canceled" if job["cancel_requested"] else ("done" if (success + skipped) else "failed")
        self._finish_job(job, status, success, skipped, failed, canceled_count)

    def _finish_job(self, job, status, success, skipped, failed, canceled=0):
        with self.lock:
            job["status"] = status
            job["current"] = ""
            job["finished_at"] = time.time()
            job["process"] = None
        label = {
            "done": "全部完成",
            "failed": "任务失败",
            "canceled": "任务已取消",
        }.get(status, status)
        summary = f"成功 {success}，跳过 {skipped}，失败 {failed}"
        if canceled:
            summary += f"，取消 {canceled}"
        self.append_log(
            job,
            f"\n{'=' * 60}\n{label}：{summary}\n{'=' * 60}\n",
        )

    def cancel_job(self):
        with self.lock:
            job = self.job
            if not job or job["status"] != "running":
                return self.job_snapshot()
            job["cancel_requested"] = True
            process = job.get("process")
        self.append_log(job, "\n正在取消任务…\n")
        self._signal_process(process)
        return self.job_snapshot()

    @staticmethod
    def _signal_process(process):
        if process is None or process.poll() is not None:
            return
        if sys.platform.startswith("win"):
            # Windows 没有进程组信号，直接结束翻译子进程。
            try:
                process.terminate()
            except OSError:
                pass
            return
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGTERM)
        except (AttributeError, ProcessLookupError, PermissionError, OSError):
            try:
                process.terminate()
            except OSError:
                pass

    # ---------- 选择文件 / 结果 ----------

    def pick_paths(self, kind):
        if sys.platform == "darwin":
            return self._pick_macos(kind)
        if sys.platform.startswith("win"):
            return self._pick_windows(kind)
        raise GuiError("当前系统不支持原生文件选择，请拖入文件或手动输入路径。")

    @staticmethod
    def _pick_macos(kind):
        if kind == "folder":
            script = 'POSIX path of (choose folder with prompt "选择包含 SRT 字幕的文件夹")'
        else:
            script = """
set chosen to choose file with prompt "选择 SRT 字幕文件" with multiple selections allowed
set output to ""
if class of chosen is list then
  repeat with f in chosen
    set output to output & POSIX path of f & linefeed
  end repeat
else
  set output to POSIX path of chosen
end if
return output
"""
        try:
            result = subprocess.run(
                ["osascript", "-e", script],
                capture_output=True,
                text=True,
                timeout=600,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise GuiError(f"无法打开文件选择器：{error}") from error

        if result.returncode != 0:
            message = (result.stderr or "").strip()
            if "User canceled" in message or "-128" in message:
                return {"canceled": True}
            raise GuiError(f"文件选择器出错：{message or '未知错误'}")
        paths = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if not paths:
            return {"canceled": True}
        return {"paths": paths}

    @staticmethod
    def _pick_windows(kind):
        """用子进程调用 Windows 原生文件/文件夹选择器。"""
        environment = os.environ.copy()
        # 路径可能包含中文，固定子进程输出编码后再解析 JSON。
        environment["PYTHONIOENCODING"] = "utf-8"
        try:
            result = subprocess.run(
                [sys.executable, "-B", str(HERE / "windows_picker.py"), kind],
                capture_output=True,
                env=environment,
                timeout=600,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise GuiError(f"无法打开文件选择器：{error}") from error

        if result.returncode != 0:
            message = result.stderr.decode("utf-8", errors="replace").strip()
            if "ModuleNotFoundError" in message and "tkinter" in message:
                raise GuiError(
                    "当前 Python 没有安装 tkinter，无法打开文件选择器。"
                    "可以拖入文件，或直接粘贴文件/文件夹路径。"
                )
            raise GuiError(f"文件选择器出错：{message or '未知错误'}")

        try:
            payload = json.loads(result.stdout.decode("utf-8", errors="replace") or "{}")
        except ValueError as error:
            raise GuiError("文件选择器返回了无法识别的结果。") from error

        paths = [
            str(item).strip()
            for item in payload.get("paths") or []
            if str(item).strip()
        ]
        if not paths:
            return {"canceled": True}
        return {"paths": paths}

    def get_download(self, download_id):
        with self.lock:
            entry = self.downloads.get(download_id)
        if not entry:
            raise GuiError("下载链接无效或已过期。")
        path = Path(entry["path"]).resolve()
        try:
            path.relative_to(self.upload_root.resolve())
        except ValueError as error:
            raise GuiError("下载路径无效。") from error
        if not path.exists():
            raise GuiError("文件不存在或已被删除。")
        return path

    def reveal(self, raw_path):
        if not isinstance(raw_path, str) or not raw_path.strip():
            raise GuiError("缺少文件路径。")
        target = Path(raw_path).expanduser().resolve()
        with self.lock:
            job = self.job
            allowed = {
                Path(result["output"]).resolve()
                for result in (job["results"] if job else [])
                if result.get("output")
            }
        if target not in allowed:
            raise GuiError("只能打开本次任务的输出文件。")
        if not target.exists():
            raise GuiError("输出文件不存在。")
        try:
            if sys.platform == "darwin":
                subprocess.Popen(["open", "-R", str(target)])
            elif sys.platform.startswith("win"):
                subprocess.Popen(["explorer", "/select,", str(target)])
            else:
                subprocess.Popen(["xdg-open", str(target.parent)])
        except OSError as error:
            raise GuiError(f"无法打开文件管理器：{error}") from error

    # ---------- 状态 / 退出 ----------

    def build_combined_state(self):
        state = pg.build_state()
        settings = self.settings_snapshot()
        try:
            runtime = pc.resolve_runtime_config()
            provider = {
                "id": runtime.get("provider_id"),
                "name": runtime.get("provider_name"),
                "model": runtime.get("model"),
                "base_url": runtime.get("base_url"),
                "requires_key": bool(runtime.get("requires_key", True)),
                "has_key": bool(runtime.get("api_key")),
            }
        except Exception as error:
            provider = {
                "id": None,
                "name": "读取失败",
                "model": "",
                "base_url": "",
                "requires_key": True,
                "has_key": False,
                "error": str(error),
            }

        state["settings"] = settings
        state["translate"] = {
            "settings": settings,
            "settings_from_file": self.settings_from_file,
            "platform": _platform_name(),
            "provider": provider,
            "ollama": self.ollama_status(),
            "files": self._snapshot_files(),
            "job": self.job_snapshot(),
            "langs": [{"id": key, "name": value} for key, value in LANGS.items()],
            "paths": {
                "home": str(HERE),
                "output": str(OUTPUT_DIR),
                "settings": str(SETTINGS_PATH),
            },
        }
        return state

    def request_quit(self):
        with self.lock:
            self.quit_requested = True
        self.cancel_job()

    def cleanup(self):
        self.request_quit()
        thread = self.job_thread
        if thread is not None and thread.is_alive():
            thread.join(timeout=5)
        self.stop_ollama()
        shutil.rmtree(self.upload_root, ignore_errors=True)


class Handler(pg.Handler):
    server_version = "AItransGUI/1.0"

    def _app(self):
        return self.server.app

    def _send_html_file(self, path):
        try:
            html = path.read_text(encoding="utf-8")
        except OSError as error:
            self._send_text(500, f"找不到界面文件 {path.name}：{error}")
            return
        html = html.replace("__AITRANS_TOKEN__", self.server.token)
        html = pg.localize_launcher_text(html)
        self._send_html(200, html)

    def do_GET(self):  # noqa: N802 - 匹配基类命名
        if not self._host_ok():
            self._send_text(403, "Host 校验失败。")
            return
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/":
            if not self._token_ok():
                self._send_text(
                    403,
                    "链接无效或已过期。请重新双击 aitrans.command 启动。",
                )
                return
            self._send_html_file(HTML_PATH)
            return

        if path == "/provider":
            if not self._token_ok():
                self._send_text(
                    403,
                    "链接无效或已过期。请重新双击 aitrans.command 启动。",
                )
                return
            self._send_html_file(pg.HTML_PATH)
            return

        if path == "/favicon.ico":
            self._send_bytes(204, "image/x-icon", b"")
            return

        if path in {"/api/state", "/api/job", "/api/download"} and not self._token_ok():
            self._send_json(403, {"ok": False, "error": "访问令牌无效。"})
            return

        if path == "/api/state":
            try:
                self._send_json(200, {"ok": True, "state": self._app().build_combined_state()})
            except (pc.ConfigError, OSError, PathError) as error:
                self._send_json(400, {"ok": False, "error": str(error)})
            except Exception as error:  # pragma: no cover - 兜底
                traceback.print_exc()
                self._send_json(500, {"ok": False, "error": f"内部错误：{error}"})
            return

        if path == "/api/job":
            self._send_json(200, {"ok": True, "job": self._app().job_snapshot()})
            return

        if path == "/api/download":
            query = parse_qs(parsed.query)
            download_id = (query.get("id") or [""])[0]
            try:
                file_path = self._app().get_download(download_id)
                body = file_path.read_bytes()
            except GuiError as error:
                self._send_json(404, {"ok": False, "error": str(error)})
                return
            except OSError as error:
                self._send_json(500, {"ok": False, "error": f"读取文件失败：{error}"})
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/x-subrip; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header(
                "Content-Disposition",
                f"attachment; filename*=UTF-8''{quote(file_path.name)}",
            )
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)
            return

        self._send_text(404, "未找到该页面。")

    def do_POST(self):  # noqa: N802 - 匹配基类命名
        if not self._host_ok() or not self._origin_ok():
            self._send_json(403, {"ok": False, "error": "来源校验失败。"})
            return
        if not self._token_ok():
            self._send_json(403, {"ok": False, "error": "访问令牌无效。"})
            return

        parsed = urlparse(self.path)
        path = parsed.path
        app = self._app()

        try:
            if path == "/api/upload":
                query = parse_qs(parsed.query)
                name = (query.get("name") or ["subtitle.srt"])[0]
                batch_id = (query.get("batch_id") or [None])[0]
                relative_name = (query.get("relative_name") or [None])[0]
                body = self._read_raw(MAX_UPLOAD_BYTES)
                entry = app.add_upload(name, body, batch_id, relative_name)
                self._send_json(
                    200,
                    {"ok": True, "file": entry, "state": app.build_combined_state()},
                )
                return

            payload = self._read_json()

            if path == "/api/providers":
                result = pg.save_provider(payload)
                result["state"] = app.build_combined_state()
            elif path == "/api/activate":
                result = pg.activate_provider(payload)
                result["state"] = app.build_combined_state()
            elif path == "/api/delete":
                result = pg.delete_provider(payload)
                result["state"] = app.build_combined_state()
            elif path == "/api/test":
                result = {"test": pg.test_provider(payload.get("provider") or {})}
            elif path == "/api/files":
                app.add_paths(payload.get("paths"))
                result = {"state": app.build_combined_state()}
            elif path == "/api/remove":
                app.remove_file(str(payload.get("id") or ""))
                result = {"state": app.build_combined_state()}
            elif path == "/api/clear":
                app.clear_files()
                result = {"state": app.build_combined_state()}
            elif path == "/api/settings":
                settings = app.update_settings(payload.get("settings") or payload)
                result = {"settings": settings, "state": app.build_combined_state()}
            elif path == "/api/start":
                job = app.start_job(payload.get("settings") or payload)
                result = {"job": job, "state": app.build_combined_state()}
            elif path == "/api/cancel":
                result = {"job": app.cancel_job()}
            elif path == "/api/pick":
                result = app.pick_paths(str(payload.get("kind") or "files"))
            elif path == "/api/reveal":
                app.reveal(payload.get("path"))
                result = {}
            elif path == "/api/quit":
                app.request_quit()
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                result = {"state": None}
            else:
                self._send_json(404, {"ok": False, "error": "未知接口。"})
                return

            self._send_json(200, {"ok": True, **result})
        except (GuiError, pc.ConfigError, PathError, OSError) as error:
            self._send_json(400, {"ok": False, "error": str(error)})
        except Exception as error:  # pragma: no cover - 兜底
            traceback.print_exc()
            self._send_json(500, {"ok": False, "error": f"内部错误：{error}"})

    def _read_raw(self, limit):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError as error:
            raise GuiError("请求长度无效。") from error
        if length <= 0:
            raise GuiError("上传内容为空。")
        if length > limit:
            raise GuiError(f"文件过大，最大允许 {limit // (1024 * 1024)} MB。")
        return self.rfile.read(length)


def main(argv=None):
    parser = argparse.ArgumentParser(description="AItrans 统一图形界面（翻译 + 提供商）")
    parser.add_argument("--port", type=int, default=0, help="监听端口，默认自动选择空闲端口")
    parser.add_argument("--no-browser", action="store_true", help="启动后不自动打开浏览器")
    parser.add_argument(
        "--tab",
        choices=["translate", "provider"],
        default="translate",
        help="打开哪个视图（默认翻译）",
    )
    args = parser.parse_args(argv)
    if not 0 <= args.port <= 65535:
        parser.error("--port 必须在 0 到 65535 之间")

    try:
        # 输出被重定向时也立即打印访问地址。
        sys.stdout.reconfigure(line_buffering=True)
    except (AttributeError, OSError):
        pass

    pc.harden_permissions()
    app = App()

    try:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError as error:
        print(f"无法启动 AItrans 图形界面：{error}", file=sys.stderr)
        return 1

    server.daemon_threads = True
    server.token = secrets.token_urlsafe(24)
    server.app = app
    route = "/provider" if args.tab == "provider" else "/"
    url = f"http://127.0.0.1:{server.server_port}{route}?token={server.token}"

    print("AItrans 统一图形界面")
    print(f"打开地址：{url}")
    print(f"设置文件：{SETTINGS_PATH}")
    print(f"配置档案：{pc.PROFILES_PATH}")
    print("关闭本窗口或按 Ctrl+C 退出。")

    if not args.no_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已退出。")
    finally:
        app.cleanup()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
