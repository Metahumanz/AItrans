// Translator.swift - 并发翻译与分批润色
//
// 对齐 legacy 行为：
// - 翻译：逐块并发，失败保留原文；
// - 润色：每批 8 条，取前两批作为上下文，按波次并发；
// - 取消：在波次之间检查，已完成的块保留。

import Foundation

public struct TranslateFailure: Sendable, Equatable {
    public let index: Int
    public let message: String
}

public struct TranslateOutcome: Sendable {
    public var translations: [String?]
    public var successCount: Int
    public var errorCount: Int
    public var failures: [TranslateFailure]
}

public struct PolishOutcome: Sendable {
    public var translations: [String?]
    public var polishedCount: Int
    public var errorCount: Int
}

public struct Translator: Sendable {
    public let client: ChatCompleting
    public let timeout: TimeInterval

    public init(client: ChatCompleting, timeout: TimeInterval = TimeInterval(Spec.defaultTimeoutSeconds)) {
        self.client = client
        self.timeout = timeout
    }

    // MARK: - 翻译

    public func translate(
        blocks: [SRTBlock],
        language: Language,
        workers: Int = Spec.defaultTranslateWorkers,
        pauseGate: PauseGate? = nil,
        onProgress: (@Sendable (CueProgress) -> Void)? = nil
    ) async throws -> TranslateOutcome {
        let indices = blocks.indices.filter { blocks[$0].isValid }
        var translations = [String?](repeating: nil, count: blocks.count)
        var failures: [TranslateFailure] = []
        let system = Spec.translateSystemPrompt.replacingOccurrences(of: "{{lang}}", with: language.displayName)
        let width = max(1, workers)
        var finished = 0
        var success = 0

        try await pauseGate?.waitIfPaused()

        // 与 legacy 的 tqdm 一致：任务一开始就显示 0/N，而不是等第一批完成才出现。
        onProgress?(CueProgress(
            stage: .translating,
            completed: 0,
            total: indices.count,
            successCount: 0,
            errorCount: 0
        ))

        for start in stride(from: 0, to: indices.count, by: width) {
            try await pauseGate?.waitIfPaused()
            if Task.isCancelled { throw CancellationError() }
            let wave = Array(indices[start..<min(start + width, indices.count)])

            let results = await withTaskGroup(of: (Int, Result<String, Error>).self) { group -> [(Int, Result<String, Error>)] in
                for index in wave {
                    let text = blocks[index].original
                    group.addTask { [client] in
                        do {
                            let answer = try await client.complete(messages: [
                                .system(system),
                                .user(Spec.translateUserTemplate.replacingOccurrences(of: "{{text}}", with: text)),
                            ])
                            return (index, .success(SRT.stripQuotes(answer)))
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                }
                var collected: [(Int, Result<String, Error>)] = []
                for await item in group { collected.append(item) }
                return collected
            }

            for (index, result) in results {
                switch result {
                case .success(let text):
                    translations[index] = text
                    success += 1
                case .failure(let error):
                    failures.append(TranslateFailure(index: index, message: Self.message(for: error)))
                }
            }
            finished += wave.count
            onProgress?(CueProgress(
                stage: .translating,
                completed: finished,
                total: indices.count,
                successCount: success,
                errorCount: failures.count
            ))
        }

        return TranslateOutcome(
            translations: translations,
            successCount: translations.filter { $0 != nil }.count,
            errorCount: failures.count,
            failures: failures
        )
    }

    // MARK: - 润色

    public func polish(
        blocks: [SRTBlock],
        translations: [String?],
        batchSize: Int = Spec.defaultPolishBatchSize,
        workers: Int = Spec.defaultPolishWorkers,
        pauseGate: PauseGate? = nil,
        onProgress: (@Sendable (CueProgress) -> Void)? = nil
    ) async throws -> PolishOutcome {
        var working = translations
        let indices = blocks.indices.filter { blocks[$0].isValid && translations[$0] != nil }
        guard !indices.isEmpty else {
            return PolishOutcome(translations: working, polishedCount: 0, errorCount: 0)
        }

        let size = max(1, batchSize)
        let batches: [[Int]] = stride(from: 0, to: indices.count, by: size).map {
            Array(indices[$0..<min($0 + size, indices.count)])
        }
        let width = max(1, workers)
        var polished = 0
        var errors = 0
        var finishedCues = 0

        try await pauseGate?.waitIfPaused()

        onProgress?(CueProgress(
            stage: .polishing,
            completed: 0,
            total: indices.count,
            successCount: 0,
            errorCount: 0
        ))

        for start in stride(from: 0, to: batches.count, by: width) {
            try await pauseGate?.waitIfPaused()
            if Task.isCancelled { throw CancellationError() }
            let wave = Array(start..<min(start + width, batches.count))

            // 提示词在并发前算好：上下文依赖上一波已润色的结果。
            let prepared: [(batchNumber: Int, batch: [Int], messages: [ChatMessage])] = wave.map { batchNumber in
                let batch = batches[batchNumber]
                let messages: [ChatMessage] = [
                    .system(Spec.polishSystemPrompt),
                    .user(Self.polishPrompt(batchNumber: batchNumber, batches: batches, translations: working)),
                ]
                return (batchNumber, batch, messages)
            }

            let results = await withTaskGroup(
                of: (Int, Result<[Int: String], Error>).self
            ) { group -> [(Int, Result<[Int: String], Error>)] in
                for item in prepared {
                    group.addTask { [client] in
                        do {
                            let answer = try await client.complete(messages: item.messages)
                            return (item.batchNumber, .success(Self.parseBatchResult(answer, indices: item.batch)))
                        } catch {
                            return (item.batchNumber, .failure(error))
                        }
                    }
                }
                var collected: [(Int, Result<[Int: String], Error>)] = []
                for await item in group { collected.append(item) }
                return collected
            }

            for (batchNumber, result) in results {
                let batch = batches[batchNumber]
                switch result {
                case .success(let parsed):
                    var applied = 0
                    for index in batch {
                        guard let raw = parsed[index] else { continue }
                        let text = SRT.stripQuotes(raw)
                        guard !text.isEmpty else { continue }
                        working[index] = text
                        applied += 1
                    }
                    polished += applied
                    errors += batch.count - applied
                case .failure:
                    errors += batch.count
                }
            }

            // 与 legacy 一样按「段」推进润色进度，而不是按批次。
            finishedCues += wave.reduce(0) { $0 + batches[$1].count }
            onProgress?(CueProgress(
                stage: .polishing,
                completed: finishedCues,
                total: indices.count,
                successCount: polished,
                errorCount: errors
            ))
        }

        return PolishOutcome(translations: working, polishedCount: polished, errorCount: errors)
    }

    static func polishPrompt(batchNumber: Int, batches: [[Int]], translations: [String?]) -> String {
        let batch = batches[batchNumber]
        let numbered = batch.map { index in
            Spec.polishNumberedLine
                .replacingOccurrences(of: "{{index}}", with: String(index))
                .replacingOccurrences(of: "{{text}}", with: translations[index] ?? "")
        }.joined(separator: "\n")

        let contextStart = max(0, batchNumber - Spec.polishContextBatches)
        let contextIndices = batches[contextStart..<batchNumber].flatMap { $0 }
        let context = contextIndices.map { index in
            Spec.polishNumberedLine
                .replacingOccurrences(of: "{{index}}", with: String(index))
                .replacingOccurrences(of: "{{text}}", with: translations[index] ?? "")
        }.joined(separator: "\n")

        if context.isEmpty {
            return Spec.polishUserWithoutContext.replacingOccurrences(of: "{{numbered_text}}", with: numbered)
        }
        return Spec.polishUserWithContext
            .replacingOccurrences(of: "{{recent_context}}", with: context)
            .replacingOccurrences(of: "{{numbered_text}}", with: numbered)
    }

    // MARK: - 批量结果解析

    /// 与 legacy 的 parse_batch_result 一致，三种格式依次回退。
    public static func parseBatchResult(_ text: String, indices: [Int]) -> [Int: String] {
        let allowed = Set(indices)
        var parsed: [Int: String] = [:]

        for match in matches(pattern: Spec.batchResultPatterns[0], in: text) {
            guard let index = Int(match[0]), allowed.contains(index) else { continue }
            parsed[index] = match[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if parsed.count < indices.count / 2 {
            let fallback = matches(pattern: Spec.batchResultPatterns[1], in: text)
            if !fallback.isEmpty, fallback.count >= parsed.count {
                parsed.removeAll()
                for match in fallback {
                    guard let index = Int(match[0]), allowed.contains(index) else { continue }
                    parsed[index] = match[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        if parsed.count < indices.count / 2 {
            let lines = text
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if lines.count == indices.count {
                parsed.removeAll()
                for (index, line) in zip(indices, lines) {
                    let cleaned = line.replacingOccurrences(
                        of: #"^\[?\d+\]?[.:\s]*"#,
                        with: "",
                        options: .regularExpression
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        parsed[index] = cleaned
                    }
                }
            }
        }

        return parsed
    }

    /// 返回 [序号, 文本] 对。
    static func matches(pattern: String, in text: String) -> [[String]] {
        let normalized = pattern.replacingOccurrences(of: #"\Z"#, with: #"\z"#)
        guard let regex = try? NSRegularExpression(pattern: normalized, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let numberRange = Range(match.range(at: 1), in: text),
                  let textRange = Range(match.range(at: 2), in: text)
            else { return nil }
            return [String(text[numberRange]), String(text[textRange])]
        }
    }

    static func message(for error: Error) -> String {
        if let chat = error as? ChatHTTPError { return chat.message }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
