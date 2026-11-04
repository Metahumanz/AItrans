#!/usr/bin/env python3
"""生成 fixtures/ 黄金样本。

设计原则：不复制解析逻辑，而是给现有 Python 实现注入确定性的假翻译器/假润色器，
让真实代码产出期望结果。这样 fixtures 描述的是「当前实现的真实行为」，
而不是「我以为的行为」。

用法：
    .venv/bin/python tools/gen_fixtures.py
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

os.environ.setdefault("TQDM_DISABLE", "1")

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "app"
sys.path.insert(0, str(APP))

import transdeepseek  # noqa: E402
import transoptdeepseek  # noqa: E402
from translation_paths import read_text_file  # noqa: E402

FIXTURE_DIR = ROOT / "fixtures" / "srt"
EXPECTED_DIR = ROOT / "fixtures" / "expected"

TRANSLATE_PREFIX = "〔译〕"
POLISH_PREFIX = "〔润〕"
FAKE_BASE_URL = "https://example.invalid"


# --------------------------------------------------------------------------
# 1. 生成输入样本（覆盖编码与结构边界）
# --------------------------------------------------------------------------

def srt(cues: list[tuple[str, str, list[str]]]) -> str:
    blocks = ["\n".join([index, timeline, *lines]) for index, timeline, lines in cues]
    return "\n\n".join(blocks) + "\n"


BASE_CUES = [
    ("1", "00:00:01,000 --> 00:00:03,000", ["Good morning, everyone."]),
    ("2", "00:00:03,500 --> 00:00:06,000", ["Let's begin the meeting."]),
    ("3", "00:00:06,500 --> 00:00:09,000", ["Thanks for coming."]),
]

MULTILINE_CUES = [
    ("1", "00:00:01,000 --> 00:00:03,000", ["Good morning, everyone."]),
    ("2", "00:00:03,500 --> 00:00:07,000", ["This is a long line", "that wraps."]),
    ("3", "00:00:07,500 --> 00:00:09,000", ["Thanks for coming."]),
]

CHINESE_CUES = [
    ("1", "00:00:01,000 --> 00:00:03,000", ["早上好，各位。"]),
    ("2", "00:00:03,500 --> 00:00:06,000", ["我们开始会议吧。"]),
]

MALFORMED_TEXT = (
    "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n"
    "2\n00:00:03,000 --> 00:00:04,000\n"
)

SAMPLES: dict[str, bytes] = {
    "basic-utf8.srt": srt(BASE_CUES).encode("utf-8"),
    "crlf.srt": srt(BASE_CUES).replace("\n", "\r\n").encode("utf-8"),
    "utf8-bom.srt": b"\xef\xbb\xbf" + srt(BASE_CUES).encode("utf-8"),
    "utf16le-bom.srt": b"\xff\xfe" + srt(BASE_CUES).encode("utf-16-le"),
    "gbk.srt": srt(CHINESE_CUES).encode("gbk"),
    "multiline.srt": srt(MULTILINE_CUES).encode("utf-8"),
    "malformed.srt": MALFORMED_TEXT.encode("utf-8"),
}


# --------------------------------------------------------------------------
# 2. 解析结构（与 app/transdeepseek.py 的分块规则一致，仅用于生成期望值）
# --------------------------------------------------------------------------

def parse_blocks(text: str) -> list[dict]:
    stripped = text.strip()
    blocks = re.split(r"\r?\n\r?\n", stripped) if stripped else []
    parsed = []
    for block in blocks:
        lines = block.splitlines()
        if len(lines) < 3:
            parsed.append({"raw": block, "valid": False})
            continue
        parsed.append(
            {
                "valid": True,
                "raw": block,
                "index": lines[0],
                "timeline": lines[1],
                "original": "\n".join(lines[2:]),
            }
        )
    return parsed


# --------------------------------------------------------------------------
# 3. 假模型：确定性、可验证
# --------------------------------------------------------------------------

def fake_chat_completion(api_key, base_url, model_name, messages, timeout, retries):
    """翻译请求返回带中文引号的译文（用于验证引号剥离）；润色请求返回编号列表。"""
    system = messages[0]["content"]
    user = messages[1]["content"]
    if "润色" in system:
        in_batch = user.split("【本批次译文】", 1)[-1].split("\n\n请按", 1)[0]
        # 用 DOTALL 捕获，保证多行译文完整回显，贴近真实模型的输出。
        numbered = re.findall(r"^\[(\d+)\] (.*?)(?=\n\[\d+\] |\Z)", in_batch, re.DOTALL | re.MULTILINE)
        return "\n".join(f"[{num}] {POLISH_PREFIX}{text}" for num, text in numbered)
    return f"“{TRANSLATE_PREFIX}{user}”"


def fake_translate(api_key, base_url, model_name, original_text, lang_display, timeout, retries):
    """复刻 request_translation 的引号剥离，返回剥掉引号后的译文。"""
    raw = fake_chat_completion(
        api_key,
        base_url,
        model_name,
        [{"role": "system", "content": "翻译"}, {"role": "user", "content": original_text}],
        timeout,
        retries,
    )
    return re.sub(r'^["“]|["”]$', "", raw)


def install_fakes() -> None:
    # transoptdeepseek 在导入时已绑定名字，两处都要替换。
    for module in (transdeepseek, transoptdeepseek):
        module.request_chat_completion = fake_chat_completion
        module.request_translation = fake_translate


# --------------------------------------------------------------------------
# 4. 用真实实现生成期望输出
# --------------------------------------------------------------------------

def run_translate(path: Path) -> str:
    return transdeepseek.translate_srt_file(
        path, "key", FAKE_BASE_URL, "model", "zh", 30, 0, 1
    )


def run_translate_polish(path: Path) -> str:
    blocks = transoptdeepseek.translate_file(
        path, "key", FAKE_BASE_URL, "model", "zh", 30, 0, 1
    )
    blocks = transoptdeepseek.optimize_translations(
        blocks, "key", FAKE_BASE_URL, "model", 8, 30, 0, 2
    )
    return transoptdeepseek.assemble_srt(blocks)


def main() -> int:
    FIXTURE_DIR.mkdir(parents=True, exist_ok=True)
    EXPECTED_DIR.mkdir(parents=True, exist_ok=True)

    for name, payload in SAMPLES.items():
        (FIXTURE_DIR / name).write_bytes(payload)

    install_fakes()

    cases = {}
    for name in SAMPLES:
        path = FIXTURE_DIR / name
        text = read_text_file(path)
        cases[name] = {
            "blocks": parse_blocks(text),
            "translateOutput": run_translate(path),
            "polishOutput": run_translate_polish(path),
        }
        print(f"generated {name}: {len(cases[name]['blocks'])} blocks")

    document = {
        "generatedBy": "tools/gen_fixtures.py",
        "translatePrefix": TRANSLATE_PREFIX,
        "polishPrefix": POLISH_PREFIX,
        "cases": cases,
    }
    out = EXPECTED_DIR / "srt.json"
    out.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
