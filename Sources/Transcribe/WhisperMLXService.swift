import AVFoundation
import Foundation

final class WhisperMLXService {
    enum ServiceError: LocalizedError {
        case runtimeNotInstalled
        case helperMissing
        case couldNotStartAudio(String)
        case transcriptionFailed(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .runtimeNotInstalled:
                return "Whisper MLX 尚未安装，请从菜单选择“安装 / 更新 Whisper MLX…”"
            case .helperMissing:
                return "应用包中缺少 Whisper 转写脚本"
            case .couldNotStartAudio(let detail):
                return "无法启动麦克风：\(detail)"
            case .transcriptionFailed(let detail):
                return "Whisper MLX 转写失败：\(detail)"
            case .invalidResponse:
                return "Whisper MLX 返回了无法解析的结果"
            }
        }
    }

    private struct WhisperResponse: Decodable {
        let text: String
    }

    private let runtimeManager: WhisperRuntimeManager
    private let processLock = NSLock()
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var transcriptionProcess: Process?

    init(runtimeManager: WhisperRuntimeManager) {
        self.runtimeManager = runtimeManager
    }

    func start() throws {
        cancel()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Transcribe-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.prepareToRecord(), recorder.record() else {
                throw ServiceError.couldNotStartAudio("录音器无法开始录音")
            }
            audioRecorder = recorder
            recordingURL = url
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.couldNotStartAudio(error.localizedDescription)
        }
    }

    func finish(
        localeIdentifier: String,
        model: WhisperModelOption,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let recorder = audioRecorder, let recordingURL else {
            completion(.success(""))
            return
        }

        recorder.stop()
        audioRecorder = nil
        self.recordingURL = nil

        guard runtimeManager.isInstalled else {
            try? FileManager.default.removeItem(at: recordingURL)
            completion(.failure(ServiceError.runtimeNotInstalled))
            return
        }

        guard let helperURL = Bundle.main.url(
            forResource: "whisper_transcribe",
            withExtension: "py"
        ) else {
            try? FileManager.default.removeItem(at: recordingURL)
            completion(.failure(ServiceError.helperMissing))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: recordingURL) }

            do {
                let text = try self.runTranscription(
                    audioURL: recordingURL,
                    helperURL: helperURL,
                    language: localeIdentifier.whisperLanguageCode,
                    model: model
                )
                DispatchQueue.main.async {
                    completion(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func cancel() {
        audioRecorder?.stop()
        audioRecorder = nil
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil

        processLock.lock()
        let process = transcriptionProcess
        processLock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    private func runTranscription(
        audioURL: URL,
        helperURL: URL,
        language: String,
        model: WhisperModelOption
    ) throws -> String {
        try FileManager.default.createDirectory(
            at: runtimeManager.modelCacheURL,
            withIntermediateDirectories: true
        )

        let process = Process()
        let outputPipe = Pipe()
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Transcribe-error-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        guard let errorHandle = FileHandle(forWritingAtPath: errorURL.path) else {
            throw ServiceError.transcriptionFailed("无法创建错误日志")
        }
        defer {
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: errorURL)
        }

        process.executableURL = runtimeManager.pythonExecutableURL
        process.arguments = [
            helperURL.path,
            "--audio", audioURL.path,
            "--model", model.repositoryIdentifier,
            "--language", language
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HOME"] = runtimeManager.modelCacheURL.path
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorHandle

        processLock.lock()
        transcriptionProcess = process
        processLock.unlock()
        defer {
            processLock.lock()
            transcriptionProcess = nil
            processLock.unlock()
        }

        do {
            try process.run()
        } catch {
            throw ServiceError.transcriptionFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        try? errorHandle.synchronize()
        let errorText = (try? String(contentsOf: errorURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw ServiceError.transcriptionFailed(
                errorText?.isEmpty == false ? errorText! : "进程退出码 \(process.terminationStatus)"
            )
        }

        guard let response = try? JSONDecoder().decode(WhisperResponse.self, from: outputData) else {
            throw ServiceError.invalidResponse
        }
        return response.text
    }
}
