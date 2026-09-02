import AVFoundation
import Foundation
import Speech

final class SpeechRecognizerService {
    enum ServiceError: LocalizedError {
        case recognizerUnavailable
        case onDeviceRecognitionUnavailable
        case dictationDisabled
        case noInputDevice
        case couldNotStartAudio(String)
        case recognitionFailed(String)

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                return "当前语言的语音识别暂不可用"
            case .onDeviceRecognitionUnavailable:
                return "当前语言未安装本地语音识别模型；可在菜单中关闭“仅使用本地识别”"
            case .dictationDisabled:
                return "macOS 的“听写”当前已关闭。请在系统设置 → 键盘 → 听写中将它打开，然后重新尝试。"
            case .noInputDevice:
                return "没有找到可用的麦克风"
            case .couldNotStartAudio(let detail):
                return "无法启动麦克风：\(detail)"
            case .recognitionFailed(let detail):
                return "语音识别失败：\(detail)"
            }
        }
    }

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var latestText = ""
    private var pendingError: Error?
    private var completion: ((Result<String, Error>) -> Void)?
    private var finalizationTimeout: DispatchWorkItem?
    private var isCapturing = false

    func start(localeIdentifier: String, onDeviceOnly: Bool) throws {
        cancel()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            throw ServiceError.recognizerUnavailable
        }

        if onDeviceOnly && !recognizer.supportsOnDeviceRecognition {
            throw ServiceError.onDeviceRecognitionUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = onDeviceOnly
        recognitionRequest = request
        latestText = ""
        pendingError = nil

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            recognitionRequest = nil
            throw ServiceError.noInputDevice
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            recognitionRequest = nil
            throw ServiceError.couldNotStartAudio(error.localizedDescription)
        }
        isCapturing = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                self?.handleRecognition(result: result, error: error)
            }
        }
    }

    func finish(completion: @escaping (Result<String, Error>) -> Void) {
        guard isCapturing else {
            completion(.success(""))
            return
        }

        self.completion = completion
        stopAudioCapture()
        recognitionRequest?.endAudio()

        if let pendingError {
            complete(.failure(pendingError))
            return
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.completion != nil else { return }
            self.complete(.success(self.latestText))
        }
        finalizationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
    }

    func cancel() {
        finalizationTimeout?.cancel()
        finalizationTimeout = nil
        stopAudioCapture()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        completion = nil
        latestText = ""
        pendingError = nil
    }

    private func stopAudioCapture() {
        guard isCapturing else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isCapturing = false
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            latestText = result.bestTranscription.formattedString
            if result.isFinal {
                complete(.success(latestText))
                return
            }
        }

        if let error {
            let error = normalizedError(error)
            if completion == nil {
                pendingError = error
            } else if latestText.isEmpty {
                complete(.failure(error))
            } else {
                complete(.success(latestText))
            }
        }
    }

    private func normalizedError(_ error: Error) -> Error {
        if error is ServiceError {
            return error
        }

        let nsError = error as NSError
        let description = "\(nsError.localizedDescription) \(nsError) \(nsError.userInfo)".lowercased()
        if (nsError.domain == "kLSRErrorDomain" && nsError.code == 201)
            || (description.contains("dictation") && description.contains("disabled")) {
            return ServiceError.dictationDisabled
        }
        return ServiceError.recognitionFailed(nsError.localizedDescription)
    }

    private func complete(_ result: Result<String, Error>) {
        guard let completion else { return }
        self.completion = nil
        finalizationTimeout?.cancel()
        finalizationTimeout = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        latestText = ""
        pendingError = nil
        completion(result)
    }
}
