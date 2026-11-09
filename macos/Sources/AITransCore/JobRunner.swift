// JobRunner.swift - 把「文件列表 + 设置」跑成结果
//
// 对应 v1 的 process_ori_folder：跳过已存在输出、按设置决定翻译/润色、
// 输出 UTF-8 + LF。

import Foundation

public struct JobProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let currentName: String
}

public struct JobRunner: Sendable {
    public static let maxFiles = 200

    private let translator: Translator

    public init(translator: Translator) {
        self.translator = translator
    }

    /// 处理一批文件。单个文件失败不会中断整体。
    public func run(
        files: [URL],
        settings: AppSettings,
        outputDirectory: URL,
        customDirectory: URL?,
        pauseGate: PauseGate? = nil,
        onFileProgress: (@Sendable (JobProgress) -> Void)? = nil,
        onCueProgress: (@Sendable (CueProgress) -> Void)? = nil
    ) async throws -> [FileResult] {
        guard files.count <= Self.maxFiles else {
            throw AITransError("一次最多处理 \(Self.maxFiles) 个文件。")
        }

        let pairs = try OutputPaths.prepareOutputs(
            sources: files,
            mode: settings.outputMode,
            suffix: settings.suffix,
            outputDirectory: outputDirectory,
            customDirectory: customDirectory
        )

        var results: [FileResult] = []
        for (offset, pair) in pairs.enumerated() {
            try await pauseGate?.waitIfPaused()
            if Task.isCancelled { throw CancellationError() }
            onFileProgress?(JobProgress(
                completed: offset,
                total: pairs.count,
                currentName: pair.source.lastPathComponent
            ))

            let name = pair.source.lastPathComponent
            let reportCueProgress: @Sendable (CueProgress) -> Void = { update in
                onCueProgress?(CueProgress(
                    fileName: name,
                    stage: update.stage,
                    completed: update.completed,
                    total: update.total,
                    successCount: update.successCount,
                    errorCount: update.errorCount
                ))
            }
            if !settings.force, let size = try? pair.output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                results.append(FileResult(
                    name: name,
                    relativeName: name,
                    status: .skipped,
                    outputPath: pair.output.path
                ))
                continue
            }

            do {
                let text = try TextDecoding.decode(contentsOf: pair.source)
                let blocks = SRT.splitBlocks(text)
                guard !blocks.isEmpty else {
                    results.append(FileResult(name: name, relativeName: name, status: .skipped))
                    continue
                }

                // 本地 Ollama 默认并发更低，避免显存吃紧。
                let workers = settings.backend == .api ? settings.apiWorkers : settings.ollamaWorkers
                let translated = try await translator.translate(
                    blocks: blocks,
                    language: settings.lang,
                    workers: workers,
                    pauseGate: pauseGate,
                    onProgress: reportCueProgress
                )

                var translations = translated.translations
                if settings.polish {
                    // v1 的 Ollama 润色按批次串行。
                    let polishWorkers = settings.backend == .api ? Spec.defaultPolishWorkers : 1
                    let polished = try await translator.polish(
                        blocks: blocks,
                        translations: translations,
                        batchSize: Spec.defaultPolishBatchSize,
                        workers: polishWorkers,
                        pauseGate: pauseGate,
                        onProgress: reportCueProgress
                    )
                    translations = polished.translations
                }

                let output = SRT.assemble(blocks, translations: translations)
                try FileManager.default.createDirectory(
                    at: pair.output.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try output.write(to: pair.output, atomically: true, encoding: .utf8)

                results.append(FileResult(
                    name: name,
                    relativeName: name,
                    status: .success,
                    outputPath: pair.output.path,
                    translatedCount: translated.successCount,
                    errorCount: translated.errorCount
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                results.append(FileResult(
                    name: name,
                    relativeName: name,
                    status: .failed,
                    error: error.localizedDescription
                ))
            }
        }

        onFileProgress?(JobProgress(completed: pairs.count, total: pairs.count, currentName: ""))
        return results
    }
}
