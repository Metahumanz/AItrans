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
    /// 启动时静默检查到的新版本，只显示顶部提示条，不弹窗。
    @Published var backgroundUpdate: UpdateInfo?
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
        checkForUpdatesQuietly()
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
            return
        }

        // 旧版 providers.json 里的明文 key 在载入后立刻迁移，避免只翻译不改配置的用户一直留着明文。
        // 迁移失败不阻塞启动：明文仍留在内存里可用，下次启动再试。
        do {
            try providerStore.migratePlaintextKeys(to: AppPaths.providersFile)
            providers = providerStore.providers
        } catch {
            alertMessage = "迁移旧版明文 API Key 失败：\(error.localizedDescription)"
        }
    }

    /// 把界面上的设置写回存储；顺带把越界值收敛后再回填界面。
    func persistSettings() {
        settingsStore.replace(with: settings)
        do {
            try settingsStore.save(to: AppPaths.settingsFile)
        } catch {
            alertMessage = "保存设置失败：\(error.localizedDescription)"
            return
        }
        // save() 内部会做取值收敛，把结果同步回界面。
        if settings != settingsStore.settings {
            settings = settingsStore.settings
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
        var provider = activeProvider
        if !usesOllama {
            guard let selected = provider else {
                alertMessage = "请先在「提供商」里添加并启用一个提供商。"
                return
            }
            do {
                provider = try providerStore.hydrate(selected)
            } catch {
                alertMessage = "读取 API Key 失败：\(error.localizedDescription)"
                return
            }
        }
        if !usesOllama, let provider, provider.requiresKey, provider.apiKey.isEmpty {
            alertMessage = "该提供商还没有 API Key。密钥现在保存在本地文件，请在「提供商」里填写。"
            return
        }

        let model = usesOllama
            ? settings.ollamaModel.trimmingCharacters(in: .whitespaces)
            : effectiveModel
        guard !model.isEmpty else {
            alertMessage = usesOllama ? "请填写 Ollama 模型名称。" : "请填写模型名称。"
            return
        }

        persistSettings()
        if alertMessage != nil { return }

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

    /// 编辑前按需补齐密钥；打开提供商面板时才会读本地密钥文件。
    func providerForEditing(_ provider: Provider) -> Provider {
        do {
            return try providerStore.hydrate(provider)
        } catch {
            alertMessage = "读取 API Key 失败：\(error.localizedDescription)"
            return provider
        }
    }

    @discardableResult
    func saveProvider(_ provider: Provider, activate: Bool) -> Provider? {
        do {
            let saved = try providerStore.upsert(provider, activate: activate)
            try providerStore.save(to: AppPaths.providersFile)
            providers = providerStore.providers
            activeProviderID = providerStore.activeID
            return saved
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    func deleteProvider(id: String) {
        do {
            try providerStore.delete(id: id)
            try providerStore.save(to: AppPaths.providersFile)
            providers = providerStore.providers
            activeProviderID = providerStore.activeID
        } catch {
            alertMessage = "删除提供商失败：\(error.localizedDescription)\n"
                + "如果密钥文件已损坏，可手动删除 \(AppPaths.secretsFile.path) 后重试。"
        }
    }

    /// 清除某个提供商已保存的密钥，提供商本身保留。
    @discardableResult
    func clearProviderKey(id: String) -> Bool {
        do {
            try providerStore.clearSecret(for: id)
            providers = providerStore.providers
            statusText = "已清除该提供商的 API Key"
            return true
        } catch {
            alertMessage = "清除 API Key 失败：\(error.localizedDescription)\n"
                + "如果密钥文件已损坏，可手动删除 \(AppPaths.secretsFile.path) 后重试。"
            return false
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
        let hydrated: Provider
        do {
            hydrated = try providerStore.hydrate(provider)
        } catch {
            return "读取 API Key 失败：\(error.localizedDescription)"
        }

        var base = hydrated.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/models") else { return "接口地址无效" }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !hydrated.apiKey.isEmpty {
            request.setValue("Bearer \(hydrated.apiKey)", forHTTPHeaderField: "Authorization")
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

    /// 启动后静默查一次。没网、被限流、已是最新都不打扰用户；
    /// 只有确实有新版本时才在文件列顶部亮一条提示。
    func checkForUpdatesQuietly() {
        guard settings.autoCheckUpdates else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.settings.autoCheckUpdates, self.updateInfo == nil else { return }
            do {
                if let info = try await UpdateChecker().check() {
                    await MainActor.run { self.backgroundUpdate = info }
                }
            } catch {
                // 后台检查失败保持静默。
            }
        }
    }

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
