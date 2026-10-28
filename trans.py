# trans.py - 使用 Ollama 批量翻译 SRT 字幕
import argparse
import os
import re
import time
from datetime import datetime

from pathlib import Path

import ollama
from tqdm import tqdm

from translation_paths import collect_srt_files, prepare_outputs


def translate_srt_file(srt_path, model_name, lang="zh"):
    """翻译单个 SRT 文件，将译文放在原文上方。"""
    with open(srt_path, "r", encoding="utf-8") as file:
        srt_content = file.read()

    blocks = srt_content.strip().split("\n\n")
    progress_bar = tqdm(
        total=len(blocks),
        desc=f"翻译字幕: {os.path.basename(srt_path)}",
        unit="段",
        bar_format="{l_bar}{bar}| {n_fmt}/{total_fmt} [{elapsed}<{remaining}, {rate_fmt}{postfix}]",
    )

    translated_blocks = []
    translated_count = 0
    error_count = 0
    start_time = time.time()

    for block in blocks:
        lines = block.split("\n")
        if len(lines) < 3:
            translated_blocks.append(block)
            progress_bar.update(1)
            continue

        index_line = lines[0]
        time_line = lines[1]
        original_text = "\n".join(lines[2:])
        lang_display = {
            "zh": "中文",
            "en": "英文",
            "ja": "日文",
            "ko": "韩文",
        }.get(lang, "中文")
        prompt = (
            f'"{original_text}" 翻译为{lang_display}，只给我翻译的结果，'
            "不要加入其他任何内容，按照最佳翻译输出"
        )

        try:
            response = ollama.chat(
                model=model_name,
                messages=[{"role": "user", "content": prompt}],
            )
            translated_text = re.sub(r'^"|"$', "", response["message"]["content"])
            translated_blocks.append(
                f"{index_line}\n{time_line}\n{translated_text}\n{original_text}"
            )
            translated_count += 1
            progress_bar.set_postfix(
                {"状态": "成功", "已翻译": translated_count, "错误": error_count}
            )
        except Exception as error:
            error_count += 1
            translated_blocks.append(block)
            progress_bar.set_postfix(
                {"状态": f"失败({str(error)[:10]})", "已翻译": translated_count, "错误": error_count}
            )

        progress_bar.update(1)

    progress_bar.close()
    elapsed = time.time() - start_time
    speed = len(blocks) / elapsed if elapsed > 0 else 0

    print("\n翻译摘要:")
    print(f"  - 总字幕块: {len(blocks)}")
    print(f"  - 成功翻译: {translated_count} ({translated_count / len(blocks) * 100:.1f}%)")
    print(f"  - 翻译错误: {error_count} ({error_count / len(blocks) * 100:.1f}%)")
    print(f"  - 处理时间: {elapsed:.1f}秒")
    print(f"  - 平均速度: {speed:.1f} 块/秒")

    return "\n\n".join(translated_blocks)


def process_ori_folder(
    model_name,
    lang="zh",
    force=False,
    inputs=None,
    output_dir=None,
    save_to_source=False,
    suffix="_translated",
):
    """处理指定文件/文件夹中的所有 SRT 文件（默认 ori 文件夹）。"""
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

    print(f"找到 {len(source_files)} 个 SRT 文件 (待处理: {len(to_process)}, 已跳过: {len(skipped_files)})，按修改时间升序处理...")
    for source, output_path in skipped_files:
        print(f"[跳过] {source.name} (输出文件已存在: {output_path}, 大小: {output_path.stat().st_size / 1024:.1f} KB)")

    if not to_process and len(source_files) > 0:
        print("\n所有字幕文件均已存在翻译结果，无需重复翻译。")
        print("如需重新翻译，请删除对应的输出文件，或添加 --force 参数重新运行。")
        return 0, len(skipped_files)

    processed_files = 0

    for source, output_path in to_process:
        start_time = datetime.now()

        print(f"\n{'=' * 60}")
        print(f"开始处理文件: {source.name}")
        print(f"修改时间: {datetime.fromtimestamp(source.stat().st_mtime)}")
        print(f"大小: {source.stat().st_size / 1024:.1f} KB")
        print(f"输出到: {output_path}")
        print(f"{'=' * 60}")

        translated_content = translate_srt_file(source, model_name, lang)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(translated_content, encoding="utf-8")

        processed_files += 1
        duration = (datetime.now() - start_time).total_seconds()
        print(f"文件处理完成! 耗时: {duration:.1f}秒")

    return processed_files, len(skipped_files)


def main():
    parser = argparse.ArgumentParser(description="批量翻译 SRT 字幕文件")
    parser.add_argument("--model", default="qwen2.5", help="Ollama 模型名称")
    parser.add_argument(
        "--lang",
        default="zh",
        choices=["zh", "en", "ja", "ko"],
        help="翻译目标语言 (zh: 中文, en: 英文, ja: 日文, ko: 韩文)",
    )
    parser.add_argument("--force", "-f", action="store_true", help="强制重新翻译，即使输出文件已存在")
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
    print("开始批量翻译字幕")
    print(f"使用模型: {args.model}")
    print(f"目标语言: {args.lang}")
    print(f"强制重译: {'是' if args.force else '否 (已存在结果自动跳过)'}")
    print(f"源文件: {source_display}")
    print(f"输出位置: {output_display}")
    print(f"{'=' * 60}\n")

    start_time = datetime.now()
    skipped_count = 0
    try:
        processed_count, skipped_count = process_ori_folder(
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
        processed_count = 0

    total_duration = (datetime.now() - start_time).total_seconds()
    print(f"\n{'=' * 60}")
    print("翻译任务摘要:")
    print(f"  - 开始时间: {start_time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  - 结束时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  - 总耗时: {total_duration:.1f}秒")
    print(f"  - 成功翻译: {processed_count} 个文件")
    if skipped_count:
        print(f"  - 跳过已存在: {skipped_count} 个文件")
    print(f"{'=' * 60}\n")


if __name__ == "__main__":
    main()
