import Foundation

final class WhisperRuntimeManager {
    enum RuntimeError: LocalizedError {
        case uvNotFound
        case operationInProgress
        case storageUnavailable(String)
        case runtimeNotInstalled
        case helperMissing
        case installationFailed(String)
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .uvNotFound:
                return "没有找到 uv。请先运行 `brew install uv`，或将 uv 安装到 ~/.local/bin/uv。"
            case .operationInProgress:
                return "Whisper MLX 正在执行另一项任务"
            case .storageUnavailable(let path):
                return "Whisper 存储位置不可用或不可写：\(path)"
            case .runtimeNotInstalled:
                return "请先安装 Whisper MLX 运行环境"
            case .helperMissing:
                return "应用包中缺少 Whisper 模型下载脚本"
            case .installationFailed(let detail):
                return "Whisper MLX 安装失败：\(detail)"
            case .downloadFailed(let detail):
                return "Whisper 模型下载失败：\(detail)"
            }
        }
    }

    private struct CommandError: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    private let storagePathKey = "whisperStoragePath"
    private(set) var isInstalling = false
    private(set) var isDownloading = false

    var isBusy: Bool {
        isInstalling || isDownloading
    }

    var defaultStorageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Transcribe", isDirectory: true)
    }

    var hasConfiguredStorageLocation: Bool {
        UserDefaults.standard.string(forKey: storagePathKey) != nil
    }

    var storageURL: URL {
        guard let path = UserDefaults.standard.string(forKey: storagePathKey),
              !path.isEmpty else {
            return defaultStorageURL
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    var displayStoragePath: String {
        (storageURL.path as NSString).abbreviatingWithTildeInPath
    }

    var runtimeURL: URL {
        storageURL.appendingPathComponent("whisper-runtime", isDirectory: true)
    }

    var pythonExecutableURL: URL {
        runtimeURL.appendingPathComponent("bin/python3", isDirectory: false)
    }

    var modelCacheURL: URL {
        storageURL.appendingPathComponent("models", isDirectory: true)
    }

    var isStorageAvailable: Bool {
        FileManager.default.fileExists(atPath: storageURL.path)
            && FileManager.default.isWritableFile(atPath: storageURL.path)
    }

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: pythonExecutableURL.path)
    }

    func configureStorage(at url: URL) throws {
        guard !isBusy else { throw RuntimeError.operationInProgress }

        let selectedURL = url.standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: selectedURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw RuntimeError.storageUnavailable(selectedURL.path)
        }

        guard FileManager.default.isWritableFile(atPath: selectedURL.path) else {
            throw RuntimeError.storageUnavailable(selectedURL.path)
        }
        UserDefaults.standard.set(selectedURL.path, forKey: storagePathKey)
    }

    func modelURL(for model: WhisperModelOption) -> URL {
        modelCacheURL.appendingPathComponent(model.directoryName, isDirectory: true)
    }

    func isModelDownloaded(_ model: WhisperModelOption) -> Bool {
        let directory = modelURL(for: model)
        let marker = directory.appendingPathComponent(".transcribe-download-complete")
        let config = directory.appendingPathComponent("config.json")
        let npzWeights = directory.appendingPathComponent("weights.npz")
        let safeTensorWeights = directory.appendingPathComponent("weights.safetensors")

        return FileManager.default.fileExists(atPath: marker.path)
            && FileManager.default.fileExists(atPath: config.path)
            && (
                FileManager.default.fileExists(atPath: npzWeights.path)
                    || FileManager.default.fileExists(atPath: safeTensorWeights.path)
            )
    }

    func install(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isBusy else {
            completion(.failure(RuntimeError.operationInProgress))
            return
        }

        guard let uvURL = findUVExecutable() else {
            completion(.failure(RuntimeError.uvNotFound))
            return
        }

        let storageURL = storageURL
        let runtimeURL = runtimeURL
        let pythonURL = pythonExecutableURL
        isInstalling = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let result: Result<Void, Error>
            do {
                try self.prepareStorage(at: storageURL)
                let environment = [
                    "UV_CACHE_DIR": storageURL.appendingPathComponent("uv-cache").path,
                    "UV_PYTHON_INSTALL_DIR": storageURL.appendingPathComponent("uv-python").path
                ]
                try self.run(
                    executableURL: uvURL,
                    arguments: ["venv", "--allow-existing", "--python", "3.10", runtimeURL.path],
                    environmentOverrides: environment
                )
                try self.run(
                    executableURL: uvURL,
                    arguments: [
                        "pip", "install",
                        "--upgrade",
                        "--python", pythonURL.path,
                        "mlx-whisper==0.4.3"
                    ],
                    environmentOverrides: environment
                )
                result = .success(())
            } catch {
                result = .failure(RuntimeError.installationFailed(error.localizedDescription))
            }

            DispatchQueue.main.async {
                self.isInstalling = false
                completion(result)
            }
        }
    }

    func download(
        model: WhisperModelOption,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard !isBusy else {
            completion(.failure(RuntimeError.operationInProgress))
            return
        }
        guard isInstalled else {
            completion(.failure(RuntimeError.runtimeNotInstalled))
            return
        }
        guard let helperURL = Bundle.main.url(
            forResource: "whisper_download",
            withExtension: "py"
        ) else {
            completion(.failure(RuntimeError.helperMissing))
            return
        }

        let storageURL = storageURL
        let modelCacheURL = modelCacheURL
        let destinationURL = self.modelURL(for: model)
        let pythonURL = pythonExecutableURL
        isDownloading = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let result: Result<Void, Error>
            do {
                try self.prepareStorage(at: storageURL)
                try FileManager.default.createDirectory(
                    at: destinationURL,
                    withIntermediateDirectories: true
                )
                try self.run(
                    executableURL: pythonURL,
                    arguments: [
                        helperURL.path,
                        "--model", model.repositoryIdentifier,
                        "--destination", destinationURL.path
                    ],
                    environmentOverrides: [
                        "HF_HOME": modelCacheURL.appendingPathComponent(".huggingface").path,
                        "PYTHONUNBUFFERED": "1"
                    ]
                )
                let marker = destinationURL.appendingPathComponent(".transcribe-download-complete")
                try Data(model.repositoryIdentifier.utf8).write(to: marker, options: .atomic)
                result = .success(())
            } catch {
                result = .failure(RuntimeError.downloadFailed(error.localizedDescription))
            }

            DispatchQueue.main.async {
                self.isDownloading = false
                completion(result)
            }
        }
    }

    private func prepareStorage(at url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw RuntimeError.storageUnavailable(url.path)
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            throw RuntimeError.storageUnavailable(url.path)
        }
    }

    private func findUVExecutable() -> URL? {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        var candidates = [
            home.appendingPathComponent(".local/bin/uv"),
            home.appendingPathComponent(".cargo/bin/uv"),
            URL(fileURLWithPath: "/opt/homebrew/bin/uv"),
            URL(fileURLWithPath: "/usr/local/bin/uv")
        ]

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("uv")
            })
        }

        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private func run(
        executableURL: URL,
        arguments: [String],
        environmentOverrides: [String: String] = [:]
    ) throws {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        var environment = ProcessInfo.processInfo.environment
        environment.merge(environmentOverrides) { _, new in new }
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw CommandError(detail: error.localizedDescription)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CommandError(
                detail: output?.isEmpty == false
                    ? output!
                    : "进程退出码 \(process.terminationStatus)"
            )
        }
    }
}
