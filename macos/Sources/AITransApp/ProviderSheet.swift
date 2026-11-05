// ProviderSheet.swift - 提供商管理

import AITransCore
import SwiftUI

struct ProviderSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String?
    @State private var draft = Provider(id: "", name: "", baseURL: "", model: "", apiKey: "", requiresKey: true)
    @State private var isNew = false
    @State private var testMessage: String?
    @State private var isTesting = false
    @State private var showLegacyImporter = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("提供商")
                    .font(.title3.bold())
                Spacer()
                Button("从旧版导入…") { showLegacyImporter = true }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            HSplitView {
                sidebar
                    .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
                editor
                    .frame(minWidth: 420)
            }
        }
        .frame(width: 860, height: 540)
        .fileImporter(
            isPresented: $showLegacyImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                state.importLegacyProviders(from: url)
                syncSelection()
            }
        }
        .onAppear(perform: syncSelection)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(state.providers) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name)
                            Text(provider.model)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if provider.id == state.activeProviderID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .tag(provider.id)
                }
            }
            .onChange(of: selection) { _, _ in loadDraft() }

            Divider()
            HStack {
                Button {
                    startNew()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                Button {
                    deleteSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil)
                Spacer()
                Menu {
                    ForEach(Spec.presets) { preset in
                        Button(preset.name) { applyPreset(preset) }
                    }
                } label: {
                    Label("从预设新建", systemImage: "square.grid.2x2")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(10)
        }
    }

    private var editor: some View {
        Form {
            Section("基本信息") {
                TextField("名称", text: $draft.name)
                TextField("接口地址", text: $draft.baseURL, prompt: Text("https://api.deepseek.com"))
                TextField("模型", text: $draft.model, prompt: Text("deepseek-flash"))
                SecureField("API Key", text: $draft.apiKey)
                Toggle("需要 API Key", isOn: $draft.requiresKey)
            }

            Section {
                HStack {
                    Button("保存") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                    Button("保存并启用") { save(activate: true) }
                    Spacer()
                    Button("测试连接") { test() }
                        .disabled(isTesting || draft.baseURL.isEmpty)
                }
                if let testMessage {
                    Text(testMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(selection == nil && !isNew)
        .overlay {
            if selection == nil && !isNew {
                ContentUnavailableView(
                    "选择或新建提供商",
                    systemImage: "cpu",
                    description: Text("左侧列表选择，或用底部「从预设新建」快速开始。")
                )
            }
        }
    }

    // MARK: - 操作

    private func syncSelection() {
        if selection == nil {
            selection = state.activeProviderID ?? state.providers.first?.id
        }
        loadDraft()
    }

    private func loadDraft() {
        isNew = false
        testMessage = nil
        if let id = selection, let provider = state.providers.first(where: { $0.id == id }) {
            draft = state.providerForEditing(provider)
        }
    }

    private func startNew() {
        selection = nil
        isNew = true
        testMessage = nil
        draft = Provider(id: "", name: "", baseURL: "", model: "", apiKey: "", requiresKey: true)
    }

    private func applyPreset(_ preset: ProviderPreset) {
        isNew = true
        selection = nil
        testMessage = nil
        draft = Provider(
            id: preset.id,
            name: preset.name,
            baseURL: preset.baseURL,
            model: preset.model,
            apiKey: "",
            requiresKey: preset.requiresKey
        )
    }

    private func save(activate: Bool = false) {
        let candidate = Provider(
            id: isNew ? "" : draft.id,
            name: draft.name,
            baseURL: draft.baseURL,
            model: draft.model,
            apiKey: draft.apiKey,
            requiresKey: draft.requiresKey
        )
        guard let saved = state.saveProvider(candidate, activate: activate) else { return }
        // 新建后即使没有“保存并启用”，也应停在刚保存的提供商上，而不是跳回当前 active。
        selection = saved.id
        isNew = false
        loadDraft()
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        state.deleteProvider(id: id)
        selection = state.activeProviderID ?? state.providers.first?.id
        if selection == nil { startNew() } else { loadDraft() }
    }

    private func test() {
        isTesting = true
        testMessage = "正在测试…"
        Task {
            let message = await state.testProvider(draft)
            await MainActor.run {
                testMessage = message
                isTesting = false
            }
        }
    }
}
