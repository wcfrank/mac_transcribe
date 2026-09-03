import Foundation

final class WhisperRuntimeManager {
    enum RuntimeError: LocalizedError {
        case uvNotFound
        case installationInProgress
        case installationFailed(String)

        var errorDescription: String? {
            switch self {
            case .uvNotFound:
                return "没有找到 uv。请先运行 `brew install uv`，或将 uv 安装到 ~/.local/bin/uv。"
            case .installationInProgress:
                return "Whisper MLX 正在安装"
            case .installationFailed(let detail):
                return "Whisper MLX 安装失败：\(detail)"
            }
        }
    }

    private(set) var isInstalling = false

    var applicationSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Transcribe", isDirectory: true)
    }

    var runtimeURL: URL {
        applicationSupportURL.appendingPathComponent("whisper-runtime", isDirectory: true)
    }

    var pythonExecutableURL: URL {
        runtimeURL.appendingPathComponent("bin/python3", isDirectory: false)
    }

    var modelCacheURL: URL {
        applicationSupportURL.appendingPathComponent("models", isDirectory: true)
    }

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: pythonExecutableURL.path)
    }

    func install(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isInstalling else {
            completion(.failure(RuntimeError.installationInProgress))
            return
        }

        guard let uvURL = findUVExecutable() else {
            completion(.failure(RuntimeError.uvNotFound))
            return
        }

        isInstalling = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let result: Result<Void, Error>
            do {
                try FileManager.default.createDirectory(
                    at: self.applicationSupportURL,
                    withIntermediateDirectories: true
                )
                try FileManager.default.createDirectory(
                    at: self.modelCacheURL,
                    withIntermediateDirectories: true
                )
                try self.run(
                    executableURL: uvURL,
                    arguments: ["venv", "--allow-existing", "--python", "3.10", self.runtimeURL.path]
                )
                try self.run(
                    executableURL: uvURL,
                    arguments: [
                        "pip", "install",
                        "--upgrade",
                        "--python", self.pythonExecutableURL.path,
                        "mlx-whisper==0.4.3"
                    ]
                )
                result = .success(())
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self.isInstalling = false
                completion(result)
            }
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

    private func run(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw RuntimeError.installationFailed(error.localizedDescription)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RuntimeError.installationFailed(
                output?.isEmpty == false ? output! : "进程退出码 \(process.terminationStatus)"
            )
        }
    }
}
