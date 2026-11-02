import Foundation

/// ApplicationLendingRefusal rejects a loan before any window moves or activation occurs.
/// The human episode remains usable; the caller can report the refusal without blocking control.
nonisolated public enum ApplicationLendingRefusal: Error, LocalizedError, Sendable {
    case noWindows
    case inventoryUnavailable
    case refreshFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noWindows:
            "No windows remain to lend. Nothing was moved."
        case .inventoryUnavailable:
            "The application window inventory could not be refreshed. Nothing was moved."
        case .refreshFailed(let reason):
            "The refreshed application windows could not be verified: \(reason). Nothing was moved."
        }
    }
}
