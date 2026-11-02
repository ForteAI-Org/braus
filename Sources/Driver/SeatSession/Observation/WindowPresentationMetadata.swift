import SeatCore

/// WindowPresentationMetadata carries optional AX labels from the existing inventory pass.
/// These labels describe presentation only and never authorize selection or input.
nonisolated package struct WindowPresentationMetadata: Sendable, Equatable {
    package var role: String?
    package var subrole: String?
    package var title: String
    package var parentWindowNumber: Int?

    package init(role: String? = nil, subrole: String? = nil, title: String = "", parentWindowNumber: Int? = nil) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.parentWindowNumber = parentWindowNumber
    }
}
