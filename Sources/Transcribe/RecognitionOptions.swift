import Foundation

enum RecognitionEngine: String, CaseIterable {
    case apple
    case whisperMLX

    var displayName: String {
        switch self {
        case .apple:
            return "Apple 语音识别"
        case .whisperMLX:
            return "Whisper MLX"
        }
    }
}

enum WhisperModelOption: String, CaseIterable {
    case small
    case largeV3Turbo

    var displayName: String {
        switch self {
        case .small:
            return "Small（约 481 MB）"
        case .largeV3Turbo:
            return "Large V3 Turbo（约 1.61 GB）"
        }
    }

    var repositoryIdentifier: String {
        switch self {
        case .small:
            return "mlx-community/whisper-small-mlx"
        case .largeV3Turbo:
            return "mlx-community/whisper-large-v3-turbo"
        }
    }
}

extension String {
    var whisperLanguageCode: String {
        switch self {
        case "zh-CN", "zh-TW":
            return "zh"
        case "en-US":
            return "en"
        case "ja-JP":
            return "ja"
        default:
            return "zh"
        }
    }
}
