// AppPaths.swift - 应用数据目录

import Foundation

public enum AppPaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "AITrans", directoryHint: .isDirectory)
    }

    public static var settingsFile: URL { supportDirectory.appending(path: "settings.json") }
    public static var providersFile: URL { supportDirectory.appending(path: "providers.json") }
    public static var secretsFile: URL { supportDirectory.appending(path: "secrets.json") }
    public static var defaultOutputDirectory: URL {
        supportDirectory.appending(path: "output", directoryHint: .isDirectory)
    }
    public static var logDirectory: URL {
        supportDirectory.appending(path: "logs", directoryHint: .isDirectory)
    }

    public static func prepare() throws {
        for directory in [supportDirectory, defaultOutputDirectory, logDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
