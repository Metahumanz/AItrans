// SRT.swift - SRT 分块、解析与组装
//
// 行为必须与 legacy Python 实现（app/transdeepseek.py）一致：
// 以空行切块；不足 3 行的块原样保留；译文在上、原文在下。

import Foundation

public struct SRTBlock: Equatable, Sendable {
    /// 切分后的原始文本（保留原始换行符，用于回退输出）。
    public let raw: String
    public let isValid: Bool
    public let index: String
    public let timeline: String
    public let original: String

    public init(raw: String, isValid: Bool, index: String = "", timeline: String = "", original: String = "") {
        self.raw = raw
        self.isValid = isValid
        self.index = index
        self.timeline = timeline
        self.original = original
    }
}

public enum SRT {
    private static let separatorRegex = try! NSRegularExpression(pattern: Spec.blockSplitPattern)

    /// 按空行切块并解析。
    public static func splitBlocks(_ text: String) -> [SRTBlock] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return rawBlocks(trimmed).map(parseBlock)
    }

    /// 按空行切分，保留每块的原始文本。
    static func rawBlocks(_ text: String) -> [String] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = separatorRegex.matches(in: text, range: full)
        guard !matches.isEmpty else { return [text] }

        var blocks: [String] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                blocks.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            blocks.append(ns.substring(from: cursor))
        }
        return blocks
    }

    /// 解析单个块。少于 3 行视为无效块，原样保留。
    static func parseBlock(_ block: String) -> SRTBlock {
        // Swift 把 CRLF 视作单个 Character，与 Python 的 splitlines 行为一致。
        let lines = block.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= Spec.minLinesForValidBlock else {
            return SRTBlock(raw: block, isValid: false)
        }
        return SRTBlock(
            raw: block,
            isValid: true,
            index: lines[0],
            timeline: lines[1],
            original: lines[2...].joined(separator: "\n")
        )
    }

    /// 组装为最终 SRT：译文在上、原文在下；无效块原样输出。
    public static func assemble(_ blocks: [SRTBlock], translations: [String?]) -> String {
        var output: [String] = []
        output.reserveCapacity(blocks.count)
        for (offset, block) in blocks.enumerated() {
            guard block.isValid,
                  offset < translations.count,
                  let translated = translations[offset]
            else {
                output.append(block.raw)
                continue
            }
            output.append("\(block.index)\n\(block.timeline)\n\(translated)\n\(block.original)")
        }
        return output.joined(separator: Spec.blockSeparator)
    }

    /// 去掉译文首尾的中英文引号（模型偶尔会加）。
    public static func stripQuotes(_ text: String) -> String {
        var result = text
        if let first = result.first, first == "\"" || first == "“" {
            result.removeFirst()
        }
        if let last = result.last, last == "\"" || last == "”" {
            result.removeLast()
        }
        return result
    }
}
