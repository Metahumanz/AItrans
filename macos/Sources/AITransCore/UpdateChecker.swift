// UpdateChecker.swift - 通过 GitHub Releases 检查更新

import Foundation

public struct UpdateInfo: Sendable, Equatable {
    public let version: String
    public let notes: String
    public let downloadURL: URL
    public let pageURL: URL
}

public struct UpdateChecker: Sendable {
    public let repository: String
    /// 优先下载的资产后缀，按顺序匹配；都没有时回退到 .zip。
    public let preferredExtensions: [String]
    private let session: URLSession

    public init(
        repository: String = "Metahumanz/AItrans",
        preferredExtensions: [String] = [".dmg"],
        session: URLSession = .shared
    ) {
        self.repository = repository
        self.preferredExtensions = preferredExtensions
        self.session = session
    }

    public var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// 返回有新版本时的信息；已是最新返回 nil。
    public func check() async throws -> UpdateInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw AITransError("更新地址无效")
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AITransError(status == 404 ? "仓库还没有发布版本。" : "检查更新失败（HTTP \(status)）。")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AITransError("更新信息格式异常。")
        }

        let tag = (root["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let notes = root["body"] as? String ?? ""
        let assets = root["assets"] as? [[String: Any]] ?? []
        let named = assets.compactMap { asset -> (String, String)? in
            guard
                let name = asset["name"] as? String,
                let url = asset["browser_download_url"] as? String
            else { return nil }
            return (name, url)
        }
        let preferred = preferredExtensions.lazy
            .compactMap { ext in named.first { $0.0.lowercased().hasSuffix(ext.lowercased()) } }
            .first
        let asset = preferred ?? named.first { $0.0.lowercased().hasSuffix(".zip") }
        guard
            let download = asset.flatMap({ URL(string: $0.1) }),
            let page = (root["html_url"] as? String).flatMap(URL.init(string:))
        else {
            throw AITransError("该版本没有可下载的压缩包。")
        }

        guard Self.isNewer(tag, than: currentVersion) else { return nil }
        return UpdateInfo(version: tag, notes: notes, downloadURL: download, pageURL: page)
    }

    /// 语义化版本比较；非数字段按字符串比较。
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = candidate.split(separator: ".").map(String.init)
        let right = current.split(separator: ".").map(String.init)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : "0"
            let r = index < right.count ? right[index] : "0"
            if let ln = Int(l), let rn = Int(r) {
                if ln != rn { return ln > rn }
            } else if l != r {
                return l > r
            }
        }
        return false
    }
}

extension UpdateInfo: Identifiable {
    public var id: String { version }
}
