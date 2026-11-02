import SeatInput

/// The pause reasons this failure names, looked up through the preparation
/// and sequence wrappers the driver attaches, so a caller can tell a pause
/// apart from everything else without unwrapping them itself.
public nonisolated func pauseReasons(of error: any Error) -> [InputPauseReason] {
    switch error {
    case let failure as InputFailure:
        if case .inputPaused(let reasons) = failure { return reasons }
        return []
    case let failure as InputPreparationFailure: return pauseReasons(of: failure.cause)
    case let failure as InputSequenceFailure:    return pauseReasons(of: failure.cause)
    case let failure as NativeTextInputFailure:  return pauseReasons(of: failure.cause)
    default:                                     return []
    }
}

