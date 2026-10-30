# transopt.py - 翻译 + 润色一体化脚本 (Ollama)
import argparse
import os
import re
import time
from datetime import datetime

from pathlib import Path

import ollama
from tqdm import tqdm

from translation_paths import collect_srt_files, prepare_outputs, read_text_file


def translate_file(srt_path, model_name, lang="zh"):
    """第一阶段：翻译整个 SRT 文件，返回字幕块。"""
    srt_content = read_text_file(srt_path)

    blocks = re.split(r"\r?\n\r?\n", srt_content.strip()) if srt_content.strip() else []
    progress_bar = tqdm(
        total=len(blocks),
        desc=f"[翻译] {os.path.basename(srt_path)}",
        unit="段",
        bar_format="{l_bar}{bar}| {n_fmt}/{total_fmt} [{elapsed}<{remaining}, {rate_fmt}{postfix}]",
    )
    lang_display = {"zh": "中文", "en": "英文", "ja": "日文", "ko": "韩文"}.get(lang, "中文")

    parsed = []
    success = 0
    errors = 0
    start_time = time.time()

    for block in blocks:
        lines = block.splitlines()
        if len(lines) < 3:
            parsed.append({"raw": block, "valid": False})
            progress_bar.update(1)
            continue

        index_line = lines[0]
        time_line = lines[1]
        original_text = "\n".join(lines[2:])
        prompt = (
            f'"{original_text}" 翻译为{lang_display}，只给我翻译的结果，'
            "不要加入其他任何内容，按照最佳翻译输出"
        )

        try:
            response = ollama.chat(
                model=model_name,
                messages=[{"role": "user", "content": prompt}],
            )
            translated_text = re.sub(r'^"|"$', "", response["message"]["content"].strip())
            parsed.append(
                {
                    "valid": True,
                    "index": index_line,
                    "timeline": time_line,
                    "original": original_text,
                    "translated": translated_text,
                }
            )
            success += 1
            progress_bar.set_postfix({"成功": success, "错误": errors})
        except Exception:
            parsed.append(
                {
                    "valid": True,
                    "index": index_line,
                    "timeline": time_line,
                    "original": original_text,
                    "translated": original_text,
                }
            )
            errors += 1
            progress_bar.set_postfix({"成功": success, "错误": errors})

        progress_bar.update(1)

    progress_bar.close()
    print(f"  翻译完成: {success}成功 / {errors}失败, 耗时{time.time() - start_time:.1f}秒")
    return parsed


def parse_batch_result(result_text, batch_indices):
    """解析模型返回的批量润色结果。"""
    optimized_map = {}
    matches = re.findall(r"\[(\d+)\]\s*(.+?)(?=\n\[|\Z)", result_text, re.DOTALL)
    if matches:
        for num_str, text in matches:
            index = int(num_str)
            if index in batch_indices:
                optimized_map[index] = text.strip()

    if len(optimized_map) < len(batch_indices) // 2:
        matches = re.findall(
            r"(?:^|\n)(\d+)[.:：．]\s*(.+?)(?=\n\d+[.:：．]|\Z)",
            result_text,
            re.DOTALL,
        )
        if matches and len(matches) >= len(optimized_map):
            optimized_map.clear()
            for num_str, text in matches:
                index = int(num_str)
                if index in batch_indices:
                    optimized_map[index] = text.strip()

    if len(optimized_map) < len(batch_indices) // 2:
        lines = [line.strip() for line in result_text.strip().splitlines() if line.strip()]
        if len(lines) == len(batch_indices):
            optimized_map.clear()
            for index, line in zip(batch_indices, lines):
                text = re.sub(r"^\[?\d+\]?[.:\s]*", "", line).strip()
                if text:
                    optimized_map[index] = text

    return optimized_map


def optimize_translations(parsed_blocks, model_name, batch_size=8):
    """第二阶段：批量润色译文，带上下文感知。"""
    valid_indices = [index for index, block in enumerate(parsed_blocks) if block["valid"]]
    if not valid_indices:
        return parsed_blocks

    batches = [
        valid_indices[start : start + batch_size]
        for start in range(0, len(valid_indices), batch_size)
    ]
    progress_bar = tqdm(
        total=len(valid_indices),
        desc="[润色]",
        unit="段",
        bar_format="{l_bar}{bar}| {n_fmt}/{total_fmt} [{elapsed}<{remaining}, {rate_fmt}{postfix}]",
    )
    system_prompt = (
        "你是一位专业的字幕文本润色助手。你的任务是优化字幕译文的表达质量。\n"
        "规则：\n"
        "1. 保持原文的核心含义不变\n"
        "2. 结合上下文语境进行润色，确保前后连贯\n"
        "3. 修正语法错误、不自然的表达\n"
        "4. 输出格式：每行对应一条字幕，用 [序号] 标记\n"
        "5. 不要添加任何解释或说明，只输出润色结果\n"
        "6. 如果译文已经很好，可以保持不变"
    )

    optimized_count = 0
    error_count = 0
    start_time = time.time()
    recent_context = ""

    for batch_idx, batch_indices in enumerate(batches):
        numbered_text = "\n".join(
            f"[{index}] {parsed_blocks[index]['translated']}" for index in batch_indices
        )
        if recent_context:
            user_prompt = (
                "请对以下字幕译文进行润色优化，使其更通顺自然、表达更流畅，同时保持原意不变。\n\n"
                f"【前文参考（已润色完成）】\n{recent_context}\n\n"
                f"【本批次需要润色的译文】\n{numbered_text}\n\n"
                "请按 [序号] 格式逐条输出润色结果，每条占一行："
            )
        else:
            user_prompt = (
                "请对以下字幕译文进行润色优化，使其更通顺自然、表达更流畅，同时保持原意不变。\n\n"
                f"【需要润色的译文】\n{numbered_text}\n\n"
                "请按 [序号] 格式逐条输出润色结果，每条占一行："
            )

        try:
            response = ollama.chat(
                model=model_name,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt},
                ],
            )
            optimized_map = parse_batch_result(response["message"]["content"], batch_indices)
            batch_ok = 0
            for index in batch_indices:
                if index in optimized_map:
                    text = re.sub(r'^["“]|["”]$', "", optimized_map[index].strip())
                    if text:
                        parsed_blocks[index]["translated"] = text
                        batch_ok += 1
            optimized_count += batch_ok
            error_count += len(batch_indices) - batch_ok
        except Exception as error:
            error_count += len(batch_indices)
            progress_bar.set_postfix({"错误": str(error)[:12]})

        recent_lines = []
        for previous_batch in batches[max(0, batch_idx - 1) : batch_idx + 1]:
            for index in previous_batch:
                recent_lines.append(f"[{index}] {parsed_blocks[index]['translated']}")
        recent_context = "\n".join(recent_lines[-batch_size * 2 :])
        progress_bar.set_postfix(
            {"成功": optimized_count, "错误": error_count, "批": f"{batch_idx + 1}/{len(batches)}"}
        )
        progress_bar.update(len(batch_indices))

    progress_bar.close()
    print(f"  润色完成: {optimized_count}成功 / {error_count}失败, 耗时{time.time() - start_time:.1f}秒")
    return parsed_blocks


def assemble_srt(parsed_blocks):
    """将解析后的字幕块重新组装为 SRT 内容。"""
    result = []
    for block in parsed_blocks:
        if block["valid"]:
            result.append(
                f"{block['index']}\n{block['timeline']}\n"
                f"{block['translated']}\n{block['original']}"
            )
        else:
            result.append(block["raw"])
    return "\n\n".join(result)


def process_folder(
    model_name,
    lang="zh",
    force=False,
    inputs=None,
    output_dir=None,
    save_to_source=False,
    suffix="_translated",
):
    """处理指定文件/文件夹中的所有 SRT 文件：先翻译再润色。"""
    source_files = collect_srt_files(inputs, "ori")
    output_root = Path(output_dir) if output_dir else Path("output")
    if not save_to_source:
        output_root.mkdir(parents=True, exist_ok=True)
    pairs = prepare_outputs(
        source_files,
        output_dir=output_root,
        save_to_source=save_to_source,
        suffix=suffix,
    )

    skipped_files = []
    to_process = []
    for source, output_path in pairs:
        if not force and output_path.exists() and output_path.stat().st_size > 0:
            skipped_files.append((source, output_path))
        else:
            to_process.append((source, output_path))

    print(f"找到 {len(source_files)} 个 SRT 文件 (待处理: {len(to_process)}, 已跳过: {len(skipped_files)})\n")
    for source, output_path in skipped_files:
        print(f"[跳过] {source.name} (输出文件已存在: {output_path}, 大小: {output_path.stat().st_size / 1024:.1f} KB)")

    if not to_process and len(source_files) > 0:
        print("\n所有字幕文件均已存在翻译与润色结果，无需重复处理。")
        print("如需重新处理，请删除对应的输出文件，或添加 --force 参数重新运行。")
        return 0, len(skipped_files)

    processed = 0
    for source, output_path in to_process:
        file_start = datetime.now()

        print(f"{'=' * 60}")
        print(f"处理文件: {source.name} ({source.stat().st_size / 1024:.1f} KB)")
        print(f"输出到: {output_path}")
        print(f"{'=' * 60}")
        parsed = translate_file(source, model_name, lang)
        parsed = optimize_translations(parsed, model_name)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(assemble_srt(parsed), encoding="utf-8", newline="\n")

        print(f"  文件完成! 总耗时: {(datetime.now() - file_start).total_seconds():.1f}秒\n")
        processed += 1

    return processed, len(skipped_files)


def main():
    parser = argparse.ArgumentParser(description="SRT 字幕翻译+润色一体化工具 (Ollama)")
    parser.add_argument("--model", default="qwen2.5", help="Ollama 模型名称")
    parser.add_argument(
        "--lang",
        default="zh",
        choices=["zh", "en", "ja", "ko"],
        help="翻译目标语言",
    )
    parser.add_argument("--force", "-f", action="store_true", help="强制重新翻译与润色，即使输出文件已存在")
    parser.add_argument(
        "--input",
        action="append",
        metavar="PATH",
        help="SRT 文件或文件夹，可重复指定；默认 ori 文件夹",
    )
    parser.add_argument("--output-dir", metavar="DIR", help="输出文件夹（默认 output）")
    parser.add_argument(
        "--save-to-source",
        action="store_true",
        help="保存到每个源文件所在目录，文件名加后缀，不覆盖原文件",
    )
    parser.add_argument("--suffix", default="_translated", help="配合 --save-to-source 使用的文件名后缀（默认 _translated）")
    args = parser.parse_args()

    source_display = ", ".join(args.input) if args.input else "ori"
    output_display = (
        f"源文件目录（后缀 {args.suffix}）" if args.save_to_source else (args.output_dir or "output")
    )
    print(f"{'=' * 60}")
    print("字幕翻译+润色一体化工具")
    print(f"模型: {args.model}  目标语言: {args.lang}")
    print(f"强制重译: {'是' if args.force else '否 (已存在结果自动跳过)'}")
    print(f"源文件: {source_display}")
    print(f"输出位置: {output_display}")
    print(f"{'=' * 60}\n")

    start_time = datetime.now()
    skipped_count = 0
    try:
        count, skipped_count = process_folder(
            args.model,
            args.lang,
            args.force,
            inputs=args.input,
            output_dir=args.output_dir,
            save_to_source=args.save_to_source,
            suffix=args.suffix,
        )
    except Exception as error:
        print(f"\n发生错误: {error}")
        count = 0

    print(f"{'=' * 60}")
    print(f"全部完成! 处理{count}个文件" + (f", 跳过{skipped_count}个已存在文件" if skipped_count else "") + f", 总耗时{(datetime.now() - start_time).total_seconds():.1f}秒")
    print(f"{'=' * 60}\n")


if __name__ == "__main__":
    main()
