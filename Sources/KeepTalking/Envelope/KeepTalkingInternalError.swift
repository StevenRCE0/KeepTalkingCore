import Foundation

enum KeepTalkingInternalError: LocalizedError {
    case unsupportedEnvelope

    var errorDescription: String? {
        switch self {
            case .unsupportedEnvelope:
                return "Unsupported envelope payload."
        }
    }
}
