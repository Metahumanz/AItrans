# trans.py - 使用 Ollama 批量翻译 SRT 字幕
import argparse
import os
import re
import time
from datetime import datetime

import ollama
from tqdm import tqdm


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


def process_ori_folder(model_name, lang="zh", force=False):
    """处理 ori 文件夹中的所有 SRT 文件。"""
    os.makedirs("output", exist_ok=True)
    if not os.path.exists("ori"):
        raise RuntimeError("源文件夹不存在: ori")
    srt_files = [
        filename
        for filename in os.listdir("ori")
        if filename.endswith(".srt") and os.path.isfile(os.path.join("ori", filename))
    ]
    srt_files.sort(key=lambda filename: os.path.getmtime(os.path.join("ori", filename)))

    skipped_files = []
    to_process = []
    for filename in srt_files:
        output_path = os.path.join("output", filename)
        if not force and os.path.exists(output_path) and os.path.getsize(output_path) > 0:
            skipped_files.append((filename, output_path))
        else:
            to_process.append(filename)

    print(f"找到 {len(srt_files)} 个 SRT 文件 (待处理: {len(to_process)}, 已跳过: {len(skipped_files)})，按修改时间升序处理...")
    for filename, output_path in skipped_files:
        print(f"[跳过] {filename} (输出文件已存在: {output_path}, 大小: {os.path.getsize(output_path) / 1024:.1f} KB)")

    if not to_process and len(srt_files) > 0:
        print("\n所有字幕文件在 output 中均已存在翻译结果，无需重复翻译。")
        print("如需重新翻译，请删除 output 目录中对应的文件，或添加 --force 参数重新运行。")
        return 0, len(skipped_files)

    processed_files = 0

    for filename in to_process:
        start_time = datetime.now()
        file_path = os.path.join("ori", filename)
        output_path = os.path.join("output", filename)

        print(f"\n{'=' * 60}")
        print(f"开始处理文件: {filename}")
        print(f"修改时间: {datetime.fromtimestamp(os.path.getmtime(file_path))}")
        print(f"大小: {os.path.getsize(file_path) / 1024:.1f} KB")
        print(f"输出到: {output_path}")
        print(f"{'=' * 60}")

        translated_content = translate_srt_file(file_path, model_name, lang)
        with open(output_path, "w", encoding="utf-8") as file:
            file.write(translated_content)

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
    parser.add_argument("--force", "-f", action="store_true", help="强制重新翻译，即使 output 目录已存在同名结果")
    args = parser.parse_args()

    print(f"{'=' * 60}")
    print("开始批量翻译字幕")
    print(f"使用模型: {args.model}")
    print(f"目标语言: {args.lang}")
    print(f"强制重译: {'是' if args.force else '否 (已存在结果自动跳过)'}")
    print("源文件夹: ori")
    print("输出文件夹: output")
    print(f"{'=' * 60}\n")

    start_time = datetime.now()
    skipped_count = 0
    try:
        processed_count, skipped_count = process_ori_folder(args.model, args.lang, args.force)
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
