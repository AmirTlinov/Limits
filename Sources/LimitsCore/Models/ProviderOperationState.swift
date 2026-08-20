import Foundation

@frozen public enum ProviderOperationPhase: Equatable, Sendable {
    case idle
    case running
}

public struct ProviderOperationState: Equatable, Sendable {
    public var phase: ProviderOperationPhase
    public var progress: String?
    public var canCancel: Bool
    public var notice: String?
    public var error: String?

    public init(
        phase: ProviderOperationPhase = .idle,
        progress: String? = nil,
        canCancel: Bool = false,
        notice: String? = nil,
        error: String? = nil
    ) {
        self.phase = phase
        self.progress = progress
        self.canCancel = canCancel
        self.notice = notice
        self.error = error
    }

    public static let idle = ProviderOperationState()
}
