// OutputPaths.swift - 输入收集与输出路径规则
//
// 对应 legacy 的 translation_paths.py：后缀校验、三种输出位置、同名冲突检查。

import Foundation

public enum OutputPaths {
    /// Windows 文件名非法字符；所有平台统一拒绝，避免生成 ADS 等奇怪文件。
    static let invalidSuffixCharacters: Set<Character> = ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]

    public static func validateSuffix(_ suffix: String) throws -> String {
        let clean = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw AITransError("保存到源文件目录时必须提供文件名后缀。")
        }
        let bad = clean.filter { invalidSuffixCharacters.contains($0) || ($0.asciiValue.map { $0 < 32 } ?? false) }
        guard bad.isEmpty else {
            let shown = bad.map { "「\($0)」" }.joined(separator: " ")
            throw AITransError("文件名后缀不能包含这些字符：\(shown)。")
        }
        return clean
    }

    /// 收集 SRT：文件夹按修改时间升序，显式文件保持顺序，按真实路径去重。
    public static func collectSRTFiles(from inputs: [URL]) throws -> [URL] {
        var files: [URL] = []
        var seen = Set<String>()

        for input in inputs {
            let path = input.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
                throw AITransError("路径不存在：\(path.path)")
            }

            var candidates: [URL]
            if isDirectory.boolValue {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: path,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
                candidates = contents
                    .filter { $0.pathExtension.lowercased() == "srt" }
                    .sorted { lhs, rhs in
                        let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        return left < right
                    }
            } else {
                guard path.pathExtension.lowercased() == "srt" else {
                    throw AITransError("不是 SRT 文件：\(path.path)")
                }
                candidates = [path]
            }

            for candidate in candidates {
                let resolved = candidate.resolvingSymlinksInPath().path
                if seen.insert(resolved).inserted {
                    files.append(candidate)
                }
            }
        }
        return files
    }

    /// 单个源文件对应的输出位置。
    public static func outputURL(
        for source: URL,
        mode: OutputMode,
        suffix: String,
        outputDirectory: URL?,
        customDirectory: URL?
    ) throws -> URL {
        switch mode {
        case .source:
            let clean = try validateSuffix(suffix)
            let name = "\(source.deletingPathExtension().lastPathComponent)\(clean).srt"
            return source.deletingLastPathComponent().appendingPathComponent(name)
        case .output:
            guard let directory = outputDirectory else {
                throw AITransError("未指定输出目录。")
            }
            return directory.appendingPathComponent(source.lastPathComponent)
        case .custom:
            guard let directory = customDirectory else {
                throw AITransError("请选择自定义输出目录。")
            }
            return directory.appendingPathComponent(source.lastPathComponent)
        }
    }

    /// 批量生成输出位置，并检查两个源文件是否落到同一个输出。
    public static func prepareOutputs(
        sources: [URL],
        mode: OutputMode,
        suffix: String,
        outputDirectory: URL?,
        customDirectory: URL?
    ) throws -> [(source: URL, output: URL)] {
        var pairs: [(source: URL, output: URL)] = []
        var used: [String: URL] = [:]

        for source in sources {
            let output = try outputURL(
                for: source,
                mode: mode,
                suffix: suffix,
                outputDirectory: outputDirectory,
                customDirectory: customDirectory
            )
            if source.resolvingSymlinksInPath() == output.resolvingSymlinksInPath() {
                throw AITransError("输出路径与源文件相同，会覆盖原文件：\(output.path)")
            }
            let key = output.resolvingSymlinksInPath().path
            if let existing = used[key] {
                throw AITransError(
                    "多个源文件会写入同一个输出文件：\(output.lastPathComponent)\n"
                        + "  - \(existing.path)\n  - \(source.path)"
                )
            }
            used[key] = source
            pairs.append((source, output))
        }
        return pairs
    }
}
