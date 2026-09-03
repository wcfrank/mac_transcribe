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
    case tiny
    case base
    case small
    case medium
    case largeV2
    case largeV3Turbo
    case largeV3

    var displayName: String {
        switch self {
        case .tiny:
            return "Tiny（74.4 MB · 最快）"
        case .base:
            return "Base（144 MB · 快速）"
        case .small:
            return "Small（481 MB · 推荐）"
        case .medium:
            return "Medium（1.52 GB · 更准确）"
        case .largeV2:
            return "Large V2（3.08 GB · 旧版高精度）"
        case .largeV3Turbo:
            return "Large V3 Turbo（1.61 GB · 快且准确）"
        case .largeV3:
            return "Large V3（3.08 GB · 最高精度）"
        }
    }

    var repositoryIdentifier: String {
        switch self {
        case .tiny:
            return "mlx-community/whisper-tiny-mlx"
        case .base:
            return "mlx-community/whisper-base-mlx"
        case .small:
            return "mlx-community/whisper-small-mlx"
        case .medium:
            return "mlx-community/whisper-medium-mlx"
        case .largeV2:
            return "mlx-community/whisper-large-v2-mlx"
        case .largeV3Turbo:
            return "mlx-community/whisper-large-v3-turbo"
        case .largeV3:
            return "mlx-community/whisper-large-v3-mlx"
        }
    }

    var directoryName: String {
        repositoryIdentifier.replacingOccurrences(of: "/", with: "--")
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
