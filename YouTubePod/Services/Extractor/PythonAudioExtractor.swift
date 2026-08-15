@preconcurrency import PythonKit
import Darwin
import Foundation

actor PythonAudioExtractor: AudioExtracting {
    private var cancellationURL: URL?
    private let worker = DispatchQueue(label: "com.rimtty.YouTubePod.python", qos: .userInitiated)

    func extract(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExtractedAudio {
        let runID = UUID().uuidString
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YouTubePod-\(runID)", isDirectory: true)
        let cancellation = workDirectory.appendingPathComponent("cancel")
        let progressFile = workDirectory.appendingPathComponent("progress.json")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        cancellationURL = cancellation

        let pollingTask = Task.detached {
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: progressFile),
                   let state = try? JSONDecoder().decode(ProgressPayload.self, from: data) {
                    progress(max(0, min(1, state.fraction)))
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer {
            pollingTask.cancel()
            cancellationURL = nil
        }

        do {
            let payload = try await runPython(
                url: url.absoluteString,
                outputDirectory: workDirectory.path,
                cancellationPath: cancellation.path,
                progressPath: progressFile.path
            )
            if payload.cancelled == true { throw ExtractionError.cancelled }
            guard payload.success, let path = payload.path else {
                throw ExtractionError.failed(payload.error ?? "音声を取得できませんでした。")
            }
            progress(1)
            return ExtractedAudio(
                fileURL: URL(fileURLWithPath: path),
                videoID: payload.videoID ?? YouTubeURLParser.videoID(from: url.absoluteString) ?? "",
                title: payload.title ?? "名称未設定",
                channel: payload.channel ?? "",
                duration: payload.duration ?? 0,
                thumbnailURL: payload.thumbnail.flatMap(URL.init(string:))
            )
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            throw error
        }
    }

    func cancel() async {
        guard let cancellationURL else { return }
        FileManager.default.createFile(atPath: cancellationURL.path, contents: Data())
    }

    private func runPython(
        url: String,
        outputDirectory: String,
        cancellationPath: String,
        progressPath: String
    ) async throws -> PythonResultPayload {
        try await withCheckedThrowingContinuation { continuation in
            worker.async {
                let gilState = CPythonGIL.acquire()
                let result: Result<PythonResultPayload, Error>
                do {
                    result = .success(try Self.invokePython(
                        url: url,
                        outputDirectory: outputDirectory,
                        cancellationPath: cancellationPath,
                        progressPath: progressPath
                    ))
                } catch {
                    result = .failure(error)
                }
                CPythonGIL.release(gilState)
                continuation.resume(with: result)
            }
        }
    }

    private nonisolated static func invokePython(
        url: String,
        outputDirectory: String,
        cancellationPath: String,
        progressPath: String
    ) throws -> PythonResultPayload {
        let sys = try PythonKit.Python.attemptImport("sys")
        guard let scriptsURL = Bundle.main.url(forResource: "PythonRuntime", withExtension: nil) else {
            throw ExtractionError.runtimeMissing
        }
        _ = sys.path.insert(0, scriptsURL.path)
        let module = try PythonKit.Python.attemptImport("download_audio")
        let pythonResult = module.download_audio(url, outputDirectory, cancellationPath, progressPath)
        guard let json = String(pythonResult), let data = json.data(using: .utf8) else {
            throw ExtractionError.invalidResult
        }
        return try JSONDecoder().decode(PythonResultPayload.self, from: data)
    }
}

enum CPythonGIL {
    typealias State = Int32

    private static let ensureFunction: @convention(c) () -> State = load("PyGILState_Ensure")
    private static let releaseFunction: @convention(c) (State) -> Void = load("PyGILState_Release")
    private static let saveThreadFunction: @convention(c) () -> UnsafeMutableRawPointer? = load("PyEval_SaveThread")

    static func acquire() -> State { ensureFunction() }
    static func release(_ state: State) { releaseFunction(state) }
    static func releaseInitializingThread() { _ = saveThreadFunction() }

    private static func load<T>(_ name: String) -> T {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(defaultHandle, name) else {
            preconditionFailure("Missing CPython symbol: \(name)")
        }
        return unsafeBitCast(symbol, to: T.self)
    }
}

private struct ProgressPayload: Decodable { let fraction: Double }
private struct PythonResultPayload: Decodable {
    let success: Bool
    let cancelled: Bool?
    let path: String?
    let videoID: String?
    let title: String?
    let channel: String?
    let duration: TimeInterval?
    let thumbnail: String?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case success, cancelled, path, title, channel, duration, thumbnail, error
        case videoID = "video_id"
    }
}

enum ExtractionError: LocalizedError {
    case cancelled, runtimeMissing, invalidResult, failed(String)
    var errorDescription: String? {
        switch self {
        case .cancelled: "取得をキャンセルしました。"
        case .runtimeMissing: "Pythonランタイムがありません。bootstrap.shを実行してください。"
        case .invalidResult: "音声取得処理から不正な結果を受け取りました。"
        case .failed(let value): Self.userFacingMessage(for: value)
        }
    }

    static func userFacingMessage(for rawMessage: String) -> String {
        let message = rawMessage.lowercased()
        if message.contains("requested format is not available")
            || message.contains("m4a audio format is unavailable") {
            return "この動画では保存できるM4A音声が提供されていません。通常の公開済み動画を選んでください。"
        }
        if message.contains("this video is unavailable") || message.contains("video unavailable") {
            return "この動画は現在利用できません。公開状態を確認して、別の動画を選んでください。"
        }
        if message.contains("live event") || message.contains("is live") || message.contains("livestream") {
            return "ライブ配信は音声保存の対象外です。公開済みの通常動画を選んでください。"
        }
        if message.contains("private video") || message.contains("members-only") || message.contains("members only") {
            return "限定公開・メンバー限定・非公開の動画は音声保存の対象外です。"
        }
        if message.contains("sign in") || message.contains("age-restricted") || message.contains("age restricted") {
            return "ログインや年齢確認が必要な動画は音声保存の対象外です。"
        }
        return "音声を保存できませんでした。通信状態を確認して、もう一度お試しください。"
    }
}
