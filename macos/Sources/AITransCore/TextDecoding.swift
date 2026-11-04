// TextDecoding.swift - 字幕文件编码探测
//
// 与 legacy 的 translation_paths.read_text_file 保持一致：
// 带 BOM 的 UTF-16 → UTF-8（含 BOM）→ GB18030 → 有损 UTF-8。

import CoreFoundation
import Foundation

public enum TextDecoding {
    static let gb18030: String.Encoding = {
        let cf = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        return String.Encoding(rawValue: cf)
    }()

    public static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(2))

        if bytes.count == 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            let body = data.dropFirst(2)
            if let text = String(data: body, encoding: .utf16LittleEndian) { return text }
        }
        if bytes.count == 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            let body = data.dropFirst(2)
            if let text = String(data: body, encoding: .utf16BigEndian) { return text }
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            if let text = String(data: data.dropFirst(3), encoding: .utf8) { return text }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: gb18030) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(contentsOf url: URL) throws -> String {
        do {
            return decode(try Data(contentsOf: url))
        } catch {
            throw AITransError("无法读取文件：\(url.lastPathComponent)")
        }
    }
}
