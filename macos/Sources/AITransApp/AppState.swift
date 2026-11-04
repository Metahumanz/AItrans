// AppState.swift - 界面状态与业务编排

import AppKit
import AITransCore
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var settings: AppSettings
    @Published var files: [URL] = []
    @Published var results: [String: FileResult] = [:]
    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var statusText = "拖入 .srt 文件或文件夹开始"
    @Published var alertMessage: String?
    @Published var providers: [Provider] = []
    @Published var activeProviderID: String?
    @Published var updateInfo: UpdateInfo?
    @Published var isCheckingUpdate = false
    @Published var isDownloadingUpdate = false
    @Published var downloadedUpdate: URL?
    @Published var isTestingProvider = false

    let settingsStore: SettingsStore
    let providerStore: ProviderStore
    private var task: Task<Void, Never>?

    init(
        settingsStore: SettingsStore = SettingsStore(),
        providerStore: ProviderStore = ProviderStore()
    ) {
        self.settingsStore = settingsStore
        self.providerStore = providerStore
        self.settings = settingsStore.settings
        reload()
    }

    var activeProvider: Provider? {
        guard let activeProviderID else { return nil }
        return providers.first { $0.id == activeProviderID }
    }

    var effectiveModel: String {
        let typed = settings.apiModel.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { return typed }
        return activeProvider?.model ?? ""
    }

    // MARK: - 载入

    func reload() {
        do {
            try AppPaths.prepare()
            try settingsStore.load(from: AppPaths.settingsFile)
            try providerStore.load(from: AppPaths.providersFile)
            settings = settingsStore.settings
            providers = providerStore.providers
            activeProviderID = providerStore.activeID
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - 文件

    func addFiles(_ urls: [URL]) {
        var expanded: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                expanded.append(contentsOf: contents.filter { $0.pathExtension.lowercased() == "srt" })
            } else if url.pathExtension.lowercased() == "srt" {
                expanded.append(url)
            }
        }

        var seen = Set(files.map(\.standardizedFileURL.path))
        for url in expanded {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            files.append(url)
        }

        if files.count > JobRunner.maxFiles {
            files = Array(files.prefix(JobRunner.maxFiles))
            alertMessage = "一次最多处理 \(JobRunner.maxFiles) 个文件，多出的已忽略。"
        }
        if !files.isEmpty {
            statusText = "已添加 \(files.count) 个文件"
        }
    }

    /// 从粘贴的路径添加（支持 ~ 展开与文件夹）。
    func addPath(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            alertMessage = "路径不存在：\(expanded)"
            return
        }
        addFiles([URL(fileURLWithPath: expanded)])
    }

    func removeFiles(at offsets: IndexSet) {
        files.remove(atOffsets: offsets)
    }

    func clearFiles() {
        guard !isRunning else { return }
        files.removeAll()
        results.removeAll()
        progress = 0
        statusText = "拖入 .srt 文件或文件夹开始"
    }

    // MARK: - 任务

    func start() {
        guard !isRunning else { return }
        guard !files.isEmpty else {
            alertMessage = "请先添加字幕文件。"
            return
        }
        let usesOllama = settings.backend == .ollama
        let provider = activeProvider
        if !usesOllama, provider == nil {
            alertMessage = "请先在「提供商」里添加并启用一个提供商。"
            return
        }

        let model = usesOllama
            ? settings.ollamaModel.trimmingCharacters(in: .whitespaces)
            : effectiveModel
        guard !model.isEmpty else {
            alertMessage = usesOllama ? "请填写 Ollama 模型名称。" : "请填写模型名称。"
            return
        }

        do {
            try settingsStore.save(to: AppPaths.settingsFile)
        } catch {
            alertMessage = "保存设置失败：\(error.localizedDescription)"
            return
        }

        let client: any ChatCompleting
        if usesOllama {
            client = OllamaClient(
                model: model,
                policy: RetryPolicy(retries: settings.ollamaRetries)
            )
        } else {
            client = ChatClient(
                baseURL: provider?.baseURL ?? "",
                apiKey: provider?.apiKey ?? "",
                model: model,
                policy: RetryPolicy(retries: settings.apiRetries)
            )
        }
        let runner = JobRunner(translator: Translator(client: client))
        let currentSettings = settings
        let pending = files
        let customDirectory = settings.customDir.isEmpty ? nil : URL(filePath: settings.customDir)

        isRunning = true
        progress = 0
        results.removeAll()
        statusText = "准备开始…"

        task = Task { [weak self] in
            guard let self else { return }
            do {
                if currentSettings.backend == .ollama {
                    self.statusText = "正在检查本地 Ollama…"
                    try await OllamaService.ensureRunning()
                    try await OllamaService.ensureModel(currentSettings.ollamaModel)
                }
                let output = try await runner.run(
                    files: pending,
                    settings: currentSettings,
                    outputDirectory: AppPaths.defaultOutputDirectory,
                    customDirectory: customDirectory,
                    onFileProgress: { update in
                        Task { @MainActor in
                            self.progress = update.total == 0 ? 0 : Double(update.completed) / Double(update.total)
                            self.statusText = update.currentName.isEmpty
                                ? "完成"
                                : "正在处理 \(update.currentName)"
                        }
                    }
                )
                await MainActor.run {
                    for result in output {
                        self.results[result.name] = result
                    }
                    self.progress = 1
                    self.isRunning = false
                    let ok = output.filter { $0.status == .success }.count
                    let skipped = output.filter { $0.status == .skipped }.count
                    let failed = output.filter { $0.status == .failed }.count
                    self.statusText = "完成：成功 \(ok)，跳过 \(skipped)，失败 \(failed)"
                    if failed > 0 {
                        self.alertMessage = "有 \(failed) 个文件失败，详情见列表。"
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isRunning = false
                    self.statusText = "已取消"
                }
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    self.statusText = "已停止"
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: - 提供商

    func saveProvider(_ provider: Provider, activate: Bool) {
        do {
            _ = try providerStore.upsert(provider, activate: activate)
            try providerStore.save(to: AppPaths.providersFile)
            providers = providerStore.providers
            activeProviderID = providerStore.activeID
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func deleteProvider(id: String) {
        do {
            try providerStore.delete(id: id)
            try providerStore.save(to: AppPaths.providersFile)
            providers = providerStore.providers
            activeProviderID = providerStore.activeID
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func setActiveProvider(id: String) {
        do {
            try providerStore.setActive(id: id)
            try providerStore.save(to: AppPaths.providersFile)
            activeProviderID = providerStore.activeID
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func importLegacyProviders(from url: URL) {
        do {
            let count = try providerStore.importLegacy(profiles: url, env: nil)
            try providerStore.save(to: AppPaths.providersFile)
            providers = providerStore.providers
            activeProviderID = providerStore.activeID
            alertMessage = count > 0 ? "已导入 \(count) 个提供商。" : "没有找到可导入的配置。"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// 用 /models 接口测试连通性。
    func testProvider(_ provider: Provider) async -> String {
        var base = provider.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/models") else { return "接口地址无效" }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !provider.apiKey.isEmpty {
            request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return "连接成功（HTTP 200）" }
            if status == 401 || status == 403 { return "鉴权失败（HTTP \(status)），请检查 API Key" }
            if status == 404 { return "可以访问，但没有 /models 接口（HTTP 404）" }
            let body = String(decoding: data.prefix(160), as: UTF8.self)
            return "HTTP \(status)\(body.isEmpty ? "" : "：\(body)")"
        } catch {
            return "连接失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 更新

    func checkForUpdates() {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        Task {
            defer { isCheckingUpdate = false }
            do {
                let info = try await UpdateChecker().check()
                await MainActor.run {
                    self.updateInfo = info
                    if info == nil {
                        self.alertMessage = "已是最新版本。"
                    }
                }
            } catch {
                await MainActor.run { self.alertMessage = error.localizedDescription }
            }
        }
    }

    /// 下载新版本并揭示到访达。
    func downloadUpdate(_ info: UpdateInfo) {
        guard !isDownloadingUpdate else { return }
        isDownloadingUpdate = true
        Task {
            defer { isDownloadingUpdate = false }
            do {
                let url = try await UpdateDownloader.download(info)
                await MainActor.run {
                    self.downloadedUpdate = url
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    self.alertMessage = UpdateDownloader.installHint
                }
            } catch {
                await MainActor.run { self.alertMessage = error.localizedDescription }
            }
        }
    }

    // MARK: - 杂项

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    func openOutputFolder() {
        NSWorkspace.shared.open(AppPaths.defaultOutputDirectory)
    }
}
