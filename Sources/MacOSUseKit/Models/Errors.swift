import Foundation

/// Actionable domain errors for `MacOSUseKit`.
public enum MacOSUseError: LocalizedError, Sendable {
    case permissionDenied(String)
    case targetNotFound(String)
    case captureFailed(String)
    case visionFailed(String)
    case inputFailed(String)
    case invalidArgument(String)
    case accessibilityUnavailable(String)
    case appOperationFailed(String)
    case timeout(String)
    case safetyBlocked(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let msg):
            return "Permission denied: \(msg)"
        case .targetNotFound(let msg):
            return "Target not found: \(msg)"
        case .captureFailed(let msg):
            return "Screen capture failed: \(msg)"
        case .visionFailed(let msg):
            return "Vision analysis failed: \(msg)"
        case .inputFailed(let msg):
            return "Input synthesis failed: \(msg)"
        case .invalidArgument(let msg):
            return "Invalid argument: \(msg)"
        case .accessibilityUnavailable(let msg):
            return "Accessibility unavailable: \(msg)"
        case .appOperationFailed(let msg):
            return "App operation failed: \(msg)"
        case .timeout(let msg):
            return "Operation timed out: \(msg)"
        case .safetyBlocked(let msg):
            return "Safety policy blocked action: \(msg)"
        }
    }
}
