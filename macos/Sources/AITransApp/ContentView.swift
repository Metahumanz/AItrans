// ContentView.swift - 主窗口

import AITransCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    @State private var showFileImporter = false
    @State private var showFolderImporter = false
    @State private var showProviders = false
    @State private var isTargeted = false
    @State private var pathInput = ""

    private var srtType: UTType {
        UTType(filenameExtension: "srt") ?? .plainText
    }

    var body: some View {
        HSplitView {
            fileColumn
                .frame(minWidth: 460)
            settingsColumn
                .frame(minWidth: 300, idealWidth: 330, maxWidth: 400)
        }
        .frame(minWidth: 900, minHeight: 560)
        .toolbar { toolbar }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [srtType],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { state.addFiles(urls) }
        }
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result { state.addFiles(urls) }
        }
        .sheet(isPresented: $showProviders) {
            ProviderSheet()
                .environmentObject(state)
        }
        .sheet(item: $state.updateInfo) { info in
            UpdateSheet(info: info)
                .environmentObject(state)
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { state.alertMessage != nil },
                set: { if !$0 { state.alertMessage = nil } }
            )
        ) {
            Button("好") { state.alertMessage = nil }
        } message: {
            Text(state.alertMessage ?? "")
        }
        .onChange(of: state.settings) { _, _ in
            state.persistSettings()
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                showFileImporter = true
            } label: {
                Label("添加文件", systemImage: "plus")
            }
            .help("添加 SRT 文件")

            Button {
                showFolderImporter = true
            } label: {
                Label("添加文件夹", systemImage: "folder.badge.plus")
            }
            .help("添加包含 SRT 的文件夹")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(state.providers) { provider in
                    Button {
                        state.setActiveProvider(id: provider.id)
                    } label: {
                        if provider.id == state.activeProviderID {
                            Label(provider.name, systemImage: "checkmark")
                        } else {
                            Text(provider.name)
                        }
                    }
                }
                if state.providers.isEmpty {
                    Text("尚未配置提供商")
                }
                Divider()
                Button("管理提供商…") { showProviders = true }
            } label: {
                Label(state.activeProvider?.name ?? "选择提供商", systemImage: "cpu")
            }
        }
    }

    // MARK: - 文件列

    private var fileColumn: some View {
        VStack(spacing: 0) {
            if let update = state.backgroundUpdate {
                updateBanner(update)
                Divider()
            }

            HStack(spacing: 8) {
                TextField("粘贴文件或文件夹路径", text: $pathInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitPath() }
                Button("添加") { submitPath() }
                    .disabled(pathInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if state.files.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(Array(state.files.enumerated()), id: \.offset) { _, url in
                        FileRow(url: url, result: state.results[url.lastPathComponent]) {
                            state.revealInFinder(url.path)
                        }
                    }
                    .onDelete { state.removeFiles(at: $0) }
                }
                .listStyle(.inset)
            }

            Divider()
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            state.addFiles(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    private func updateBanner(_ update: UpdateInfo) -> some View {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        return HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("发现新版本 \(update.version)")
                    .font(.callout.weight(.semibold))
                Text("当前版本 \(current)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("查看更新") {
                state.backgroundUpdate = nil
                state.updateInfo = update
            }
            Button {
                state.backgroundUpdate = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("这次不提示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tertiary)
            Text("把 .srt 文件或文件夹拖到这里")
                .font(.title3)
            Text("也可以点左上角「添加文件」，再点左下角「开始」")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            progressRows

            // 主操作固定在左下角：开始 / 暂停（继续）/ 取消。
            HStack(spacing: 8) {
                Button {
                    state.start()
                } label: {
                    Label("开始", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(state.isRunning || state.files.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .help("开始翻译（⌘↩）")

                if state.isRunning {
                    Button {
                        if state.isPaused {
                            state.resume()
                        } else {
                            state.pause()
                        }
                    } label: {
                        Label(
                            state.isPaused ? "继续" : "暂停",
                            systemImage: state.isPaused ? "play.fill" : "pause.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help(state.isPaused ? "继续任务" : "暂停（当前批次完成后停止）")

                    Button(role: .destructive) {
                        state.cancel()
                    } label: {
                        Label("取消", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("取消任务")
                }

                Spacer()

                if !state.files.isEmpty {
                    Button("清空") { state.clearFiles() }
                        .buttonStyle(.link)
                        .disabled(state.isRunning)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var progressRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("文件")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)
                ProgressView(value: state.progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 220)
                Text(state.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }

            // 对应 legacy 的 tqdm：翻译和润色各自按段推进，并显示成功/失败计数。
            if state.isRunning, let cue = state.activeCueProgress, cue.total > 0 {
                HStack(spacing: 8) {
                    Text(cue.stage.displayName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .leading)
                    ProgressView(value: cue.fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                    Text("\(cue.completed)/\(cue.total) 段")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("成功 \(cue.successCount) · 失败 \(cue.errorCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(cue.errorCount > 0 ? Color.red : Color.secondary)
                }
            }
        }
    }

    // MARK: - 设置列

    private var settingsColumn: some View {
        Form {
            Section("翻译") {
                Picker("引擎", selection: $state.settings.backend) {
                    Text("API 提供商").tag(Engine.api)
                    Text("本地 Ollama").tag(Engine.ollama)
                }
                .pickerStyle(.menu)

                TextField("模型", text: modelBinding, prompt: Text(modelPrompt))

                if state.settings.backend == .ollama {
                    Text("需要先安装 Ollama 并准备好模型，例如 qwen2.5。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("目标语言", selection: $state.settings.lang) {
                    ForEach(Language.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)

                Toggle("翻译", isOn: $state.settings.translate)
                    .disabled(true)
                Toggle("润色", isOn: $state.settings.polish)
            }

            Section("输出") {
                Picker("位置", selection: $state.settings.outputMode) {
                    Text("源文件目录").tag(OutputMode.source)
                    Text("应用输出目录").tag(OutputMode.output)
                    Text("自定义目录").tag(OutputMode.custom)
                }
                .pickerStyle(.menu)

                if state.settings.outputMode == .source {
                    TextField("文件名后缀", text: $state.settings.suffix)
                }
                if state.settings.outputMode == .custom {
                    HStack {
                        TextField("目录", text: $state.settings.customDir)
                        Button("选择…") { chooseCustomDirectory() }
                    }
                }
                if state.settings.outputMode == .output {
                    Button("打开输出目录") { state.openOutputFolder() }
                        .buttonStyle(.link)
                }
                Toggle("强制重新处理", isOn: $state.settings.force)
            }

            Section("并发与重试") {
                NumberRow(title: "并发", value: $state.settings.apiWorkers, range: 1...64)
                NumberRow(title: "重试", value: $state.settings.apiRetries, range: 0...5)
                Text("可直接输入，也可以点右侧箭头微调。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("关于") {
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                Toggle("启动时自动检查更新", isOn: $state.settings.autoCheckUpdates)
                Button("检查更新…") { state.checkForUpdates() }
                    .disabled(state.isCheckingUpdate)
                Button("管理提供商…") { showProviders = true }
            }
        }
        .formStyle(.grouped)
    }

    private func submitPath() {
        state.addPath(pathInput)
        pathInput = ""
    }

    private var modelBinding: Binding<String> {
        state.settings.backend == .api
            ? $state.settings.apiModel
            : $state.settings.ollamaModel
    }

    private var modelPrompt: String {
        state.settings.backend == .api
            ? (state.activeProvider?.model ?? "deepseek-flash")
            : "qwen2.5"
    }

    private func chooseCustomDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.settings.customDir = url.path
        }
    }
}

private struct FileRow: View {
    let url: URL
    let result: FileResult?
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if result?.outputPath != nil {
                Button("显示", action: reveal)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch result?.status {
        case .success: return "checkmark.circle.fill"
        case .skipped: return "arrow.uturn.right.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case nil: return "doc.text"
        }
    }

    private var tint: Color {
        switch result?.status {
        case .success: return .green
        case .skipped: return .secondary
        case .failed: return .red
        case nil: return .secondary
        }
    }

    private var subtitle: String {
        guard let result else { return url.deletingLastPathComponent().path }
        switch result.status {
        case .success: return "成功 \(result.translatedCount) 段\(result.errorCount > 0 ? "，失败 \(result.errorCount) 段" : "")"
        case .skipped: return "已存在，跳过"
        case .failed: return result.error ?? "失败"
        }
    }
}


/// 可输入也可步进的数字行。
private struct NumberRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            TextField("", value: $value, format: .number)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .onSubmit(clamp)
            Stepper("", value: $value, in: range)
                .labelsHidden()
                .onChange(of: value) { _, _ in clamp() }
        }
    }

    private func clamp() {
        value = min(range.upperBound, max(range.lowerBound, value))
    }
}
