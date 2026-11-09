// UpdateSheet.swift - 更新详情与下载

import AITransCore
import SwiftUI

struct UpdateSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let info: UpdateInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("发现新版本 \(info.version)")
                        .font(.title3.bold())
                    Text("当前版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            if info.notes.isEmpty {
                Text("该版本没有填写更新说明。")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(info.notes)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }

            if let downloaded = state.downloadedUpdate {
                Label("已下载：\(downloaded.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                Text(UpdateDownloader.installHint(for: downloaded))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Link("打开下载页", destination: info.pageURL)
                Spacer()
                Button("稍后") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    state.downloadUpdate(info)
                } label: {
                    if state.isDownloadingUpdate {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("下载更新")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.isDownloadingUpdate)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
