// UpdateDownloader.swift - 下载新版本到本地
//
// 不做静默自替换：未签名分发下自动替换安装目录风险过高，
// 这里下载并交给用户完成替换，同时给出明确步骤。

import Foundation

public enum UpdateDownloader {
    public static var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// 下载更新包，返回落盘位置。
    public static func download(_ info: UpdateInfo, into directory: URL = downloadsDirectory) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: info.downloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AITransError("下载失败，请稍后重试或打开下载页。")
        }

        let name = info.downloadURL.lastPathComponent.isEmpty
            ? "AITrans-\(info.version).zip"
            : info.downloadURL.lastPathComponent
        let destination = directory.appending(path: name)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// 替换步骤，展示给用户；按实际下载到的文件类型区分 dmg 与 zip。
    public static func installHint(for file: URL) -> String {
        let directory = file.deletingLastPathComponent().path
        if file.pathExtension.lowercased() == "dmg" {
            return "已下载到「\(directory)」。退出 AITrans，打开 dmg，把 AITrans.app 拖到「应用程序」覆盖旧版本即可。"
        }
        return "已下载到「\(directory)」。退出 AITrans，解压后把 AITrans.app 拖到「应用程序」覆盖旧版本即可。"
    }
}
