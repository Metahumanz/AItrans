# translation_paths.py - 四个翻译脚本共用的输入/输出路径处理
"""收集 SRT 输入文件，并决定每个文件的输出位置。

四个翻译脚本原本只处理 `ori/` 和 `output/`。图形界面和命令行现在
可以通过 `--input` / `--output-dir` / `--save-to-source` 处理任意路径，
这里集中处理这些规则，避免四份脚本各写一套。
"""

from __future__ import annotations

from pathlib import Path

SRT_SUFFIX = ".srt"


class PathError(ValueError):
    """输入或输出路径不合法。"""


def collect_srt_files(inputs, default_dir):
    """展开文件/文件夹参数，返回去重后的 SRT 路径列表。

    `inputs` 为 None 时使用 `default_dir`（保持原有 ori 默认行为）。
    显式传入的文件按参数顺序保留；文件夹内的文件按修改时间升序。
    """
    raw_inputs = list(inputs) if inputs else [str(default_dir)]
    files = []
    seen = set()

    for raw in raw_inputs:
        path = Path(raw).expanduser()
        if not path.exists():
            raise PathError(f"路径不存在: {path}")
        if path.is_dir():
            candidates = [
                item
                for item in path.iterdir()
                if item.is_file() and item.suffix.lower() == SRT_SUFFIX
            ]
            candidates.sort(key=lambda item: item.stat().st_mtime)
        elif path.is_file():
            if path.suffix.lower() != SRT_SUFFIX:
                raise PathError(f"不是 SRT 文件: {path}")
            candidates = [path]
        else:
            raise PathError(f"不是普通文件或文件夹: {path}")

        for candidate in candidates:
            resolved = candidate.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            files.append(candidate)

    return files


def output_path_for(source, output_dir=None, save_to_source=False, suffix="_translated"):
    """返回一个源文件对应的输出路径。

    - save_to_source=True：放在源文件旁边，文件名加后缀，避免覆盖原文件；
    - 否则放在 output_dir 中，文件名保持不变。
    """
    source = Path(source)

    if save_to_source:
        clean_suffix = (suffix or "").strip()
        if not clean_suffix:
            raise PathError("保存到源文件目录时必须提供文件名后缀。")
        if "/" in clean_suffix or "\\" in clean_suffix:
            raise PathError("文件名后缀不能包含路径分隔符。")
        output = source.with_name(f"{source.stem}{clean_suffix}{source.suffix}")
    else:
        if output_dir is None:
            raise PathError("未指定输出目录。")
        output = Path(output_dir).expanduser() / source.name

    if source.resolve() == output.resolve():
        raise PathError(f"输出路径与源文件相同，会覆盖原文件: {output}")
    return output


def prepare_outputs(source_files, output_dir=None, save_to_source=False, suffix="_translated"):
    """为一批源文件生成 (source, output) 列表，并检查同名冲突。"""
    pairs = []
    used = {}
    for source in source_files:
        output = output_path_for(
            source,
            output_dir=output_dir,
            save_to_source=save_to_source,
            suffix=suffix,
        )
        key = output.resolve()
        if key in used:
            raise PathError(
                f"多个源文件会写入同一个输出文件: {output}\n"
                f"  - {used[key]}\n  - {source}\n"
                "请改用 --save-to-source，或让每个文件使用不同的输出目录。"
            )
        used[key] = source
        pairs.append((source, output))
    return pairs
